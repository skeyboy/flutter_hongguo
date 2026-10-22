import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_cast/hongguo_cast.dart';
import 'package:hongguo_tv/hongguo_tv.dart' show tvBuild;

import '../platform/background/host_policy.dart';
import '../platform/multicast_lock.dart';
import '../platform/runtime.dart';

/// How the LAN media server is opened, so widget tests can bind loopback.
typedef MediaServerBinder = Future<LanMediaServer> Function();

/// Casting needs a phone on a Wi-Fi network and a runtime that can hand out a
/// decrypted local file; desktops, web and the TV flavour have no reason to
/// show the entry at all.
bool castSupported(AppRuntime runtime) =>
    mobileHost && !tvBuild && runtime is LocalMediaRuntime;

/// One cast session per app session.
///
/// The television keeps pulling the file out of this phone after the screen
/// that started it is gone, so the cache pin, the LAN server and the SOAP
/// session cannot belong to a page; they belong to the runtime, exactly like
/// [personalLibraryFor] does.
final _services = Expando<CastService>();

CastService castServiceFor(AppRuntime runtime) =>
    _services[runtime] ??= CastService(runtime);

/// Drives discovery, the local media source, one SOAP session and the episode
/// queue that session is playing from.
///
/// `hongguo_cast` reports protocol failures as exceptions; this half turns them
/// into state the sheet, the remote page and the floating window can render, and
/// holds the cache pin plus the multicast lock for as long as the television may
/// still be pulling a file.
class CastService extends ChangeNotifier {
  CastService(
    this.runtime, {
    DeviceBrowser? browser,
    this.bindServer = LanMediaServer.bind,
    this.openSession = _defaultSession,
  }) : browser = browser ?? DeviceBrowser();

  static CastSession _defaultSession(UpnpDevice device) =>
      CastSession(device: device);

  final AppRuntime runtime;
  final DeviceBrowser browser;
  final MediaServerBinder bindServer;

  /// Seam for tests and for later tuning the poll interval of a real renderer.
  final CastSession Function(UpnpDevice device) openSession;
  final _multicast = MulticastLock();

  LanMediaServer? _server;
  CastSession? _session;
  PlaybackJob? _pin;
  StreamSubscription<CastSnapshot>? _updates;
  String? _servedId;
  bool _closed = false;

  List<KnownRenderer> devices = const [];
  KnownRenderer? target;
  bool browsing = false;
  CastPhase phase = CastPhase.idle;
  Duration position = Duration.zero;
  Duration? duration;
  int? volumePercent;
  String? error;

  DramaDetail? _series;
  int _index = 0;
  String _quality = 'best';
  bool _userStopped = false, _nearEnd = false, _advancing = false;

  /// How close to the end the television has to report before a `STOPPED` counts
  /// as "this episode finished" rather than "the viewer stopped it".
  static const _tail = Duration(seconds: 20);

  /// The series being cast, or `null` before the first episode is handed over.
  List<Episode> get episodes => _series?.episodes ?? const [];
  int get index => _index;
  String get quality => _quality;
  Episode? get episode => episodes.isEmpty ? null : episodes[_index];
  String? get title => episodes.isEmpty ? null : _label(_index);
  bool get canPrevious => _series != null && _index > 0;
  bool get canNext => _series != null && _index < episodes.length - 1;

  /// Whether the viewer's own preference says to follow on to the next episode.
  bool get autoNext => settingsFor(runtime).autoNext;

  bool get active =>
      phase == CastPhase.preparing ||
      phase == CastPhase.streaming ||
      phase == CastPhase.paused;

  /// Where the television is; the player screen resumes local playback here.
  Duration get tvPosition => _session?.snapshot.position ?? position;

  /// Refreshes the renderer list. Allowed while casting, because the remote page
  /// offers 换设备 without dropping the queue first.
  Future<void> browse() async {
    if (browsing) return;
    _change(() {
      browsing = true;
      error = null;
    });
    try {
      await _multicast.acquire();
      await _ensureServer();
      devices = await browser.refresh();
      if (devices.isEmpty) error = _noRenderer;
    } on Object catch (failure) {
      devices = const [];
      error = _describe(failure);
    } finally {
      _change(() => browsing = false);
    }
  }

  /// Starts casting episode [index] of [detail] on [renderer].
  Future<void> open({
    required DramaDetail detail,
    required int index,
    required KnownRenderer renderer,
    String quality = 'best',
    Duration? expectedDuration,
    Duration? at,
  }) async {
    if (detail.episodes.isEmpty) {
      _change(() => error = _noCachedFile);
      return;
    }
    _series = detail;
    _index = index.clamp(0, detail.episodes.length - 1);
    _quality = quality;
    await _handover(
      renderer: renderer,
      expectedDuration: expectedDuration,
      at: at,
    );
  }

  /// Re-points the running session at another episode of the same series.
  Future<void> playAt(int next) async {
    if (_series == null || target == null) return;
    if (next < 0 || next >= episodes.length || next == _index) return;
    _index = next;
    await _handover();
  }

  /// Returns whether the queue actually moved.
  Future<bool> next() async {
    if (!canNext) return false;
    await playAt(_index + 1);
    return true;
  }

  Future<bool> previous() async {
    if (!canPrevious) return false;
    await playAt(_index - 1);
    return true;
  }

  /// Re-serves the same episode at another quality and puts the television back
  /// where it was, so switching quality is not switching episodes.
  Future<void> setQuality(String value) async {
    if (_series == null || value == _quality) return;
    final resumeAt = tvPosition;
    _quality = value;
    await _handover(at: resumeAt);
  }

  /// Hands the current episode over to another television at the same position.
  Future<void> switchTo(KnownRenderer renderer) async {
    if (_series == null) return;
    await _handover(renderer: renderer, at: tvPosition);
  }

  Future<void> pause() async => _session?.pause();

  Future<void> resume() async => _session?.resume();

  Future<void> seekTo(Duration value) async => _session?.seek(value);

  Future<void> setVolume(int percent) async => _session?.setVolume(percent);

  /// Leaves the television stopped and keeps the last position so the caller can
  /// resume it locally.
  Future<Duration> stop() async {
    final last = tvPosition;
    final session = _session;
    _userStopped = true;
    if (session != null) await session.stop();
    _releaseAll();
    _change(() {
      phase = CastPhase.stopped;
      position = last;
      target = null;
    });
    return last;
  }

  Future<void> forget(KnownRenderer renderer) async {
    browser.forget(renderer.udn);
    _change(
      () => devices = List.unmodifiable(
        devices.where((device) => device.udn != renderer.udn),
      ),
    );
  }

  String _label(int at) =>
      '${_series!.drama.title} · 第 ${episodes[at].index} 集';

  Future<void> _handover({
    KnownRenderer? renderer,
    Duration? at,
    Duration? expectedDuration,
  }) async {
    final local = runtime;
    if (local is! LocalMediaRuntime) {
      _change(() => error = _noCachedFile);
      return;
    }
    final series = _series;
    if (series == null || episodes.isEmpty) return;
    final chosen = renderer ?? target;
    if (chosen == null) return;
    final episode = episodes[_index];
    final name = _label(_index);
    // The previous episode stops being served before the new one is handed over.
    _releaseMedia();
    final reuse = _session != null && _session!.device.udn == chosen.device.udn;
    if (!reuse) _releaseSession();
    _userStopped = false;
    _nearEnd = false;
    _change(() {
      target = chosen;
      duration = expectedDuration;
      position = Duration.zero;
      phase = CastPhase.preparing;
      error = null;
    });
    try {
      final server = await _ensureServer();
      final job = local.prepareLocal(episode.vid, quality: _quality);
      _pin = job;
      final path = await job.source;
      final lease = await server.publish(
        File(Uri.parse(path).toFilePath()),
        title: name,
      );
      _servedId = lease.id;
      final session = reuse ? _session! : openSession(chosen.device);
      if (!reuse) {
        _updates = session.updates.listen(_onSnapshot);
        _session = session;
      }
      await session.cast(
        DidlItem(
          uri: lease.uri,
          mimeType: lease.mimeType,
          title: name,
          sizeBytes: lease.sizeBytes,
          duration: expectedDuration,
        ),
      );
      _onSnapshot(session.snapshot);
      var failure = session.snapshot.error;
      if (failure == null && at != null && at > Duration.zero) {
        await session.seek(at);
        failure = session.snapshot.error;
      }
      if (failure != null) {
        _releaseAll();
        _change(() => error = failure);
      }
    } on Object catch (failure) {
      _releaseAll();
      _change(() {
        error = _describe(failure);
        phase = CastPhase.failed;
      });
    }
  }

  void _onSnapshot(CastSnapshot snapshot) {
    // A snapshot still in flight after `_releaseSession` belongs to a session we
    // no longer show, and must not undo the phase the exit just set.
    if (_updates == null) return;
    final total = snapshot.duration ?? duration;
    if (total != null && snapshot.position >= total - _tail) _nearEnd = true;
    final finished =
        !_userStopped &&
        !_advancing &&
        _nearEnd &&
        snapshot.phase == CastPhase.stopped;
    _change(() {
      phase = snapshot.phase;
      position = snapshot.position;
      if (snapshot.duration != null) duration = snapshot.duration;
      volumePercent = snapshot.volumePercent ?? volumePercent;
      if (snapshot.error != null) error = snapshot.error;
    });
    if (finished) unawaited(_followOn());
  }

  Future<void> _followOn() async {
    if (!autoNext || !canNext) return;
    _advancing = true;
    try {
      await playAt(_index + 1);
    } finally {
      _advancing = false;
    }
  }

  Future<LanMediaServer> _ensureServer() async {
    final existing = _server;
    if (existing != null) return existing;
    final server = await bindServer();
    _server = server;
    return server;
  }

  void _releaseMedia() {
    final served = _servedId;
    if (served != null) _server?.revoke(served);
    _servedId = null;
    _pin?.release();
    _pin = null;
  }

  /// Local teardown is fire-and-forget.
  ///
  /// Awaiting the subscription's end would make the exit wait for the session's
  /// stream to deliver its last event, which is not something the viewer should
  /// have to wait for; the session cancels its poll timer synchronously.
  void _releaseSession() {
    final updates = _updates;
    _updates = null;
    unawaited(updates?.cancel());
    final session = _session;
    _session = null;
    unawaited(session?.dispose());
  }

  void _releaseAll() {
    _releaseMedia();
    _releaseSession();
  }

  void _change(VoidCallback update) {
    update();
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _releaseAll();
    unawaited(_server?.close());
    _server = null;
    unawaited(_multicast.release());
    browser.clear();
    super.dispose();
  }
}

const _noRenderer = '未发现电视或盒子。请确认两台设备在同一 Wi-Fi、电视端已开启 DLNA，且路由器没有开启 AP 隔离。';
const _noCachedFile = '该内容暂不支持投屏，请先缓存后再试。';
const _noWifi = '手机未连接可用 Wi-Fi。投屏需要与电视处在同一个局域网。';

String _describe(Object failure) {
  if (failure is UpnpException) {
    final message = failure.message;
    if (message.contains('private Wi-Fi address')) return _noWifi;
    return message;
  }
  if (failure is StateError) return failure.message;
  if (failure is FileSystemException) return _noCachedFile;
  return '投屏失败：$failure';
}
