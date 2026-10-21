import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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

/// Drives discovery, the local media source and one SOAP session for the
/// player screen.
///
/// `hongguo_cast` reports protocol failures as exceptions; this half turns them
/// into state the sheet and the remote page can render, and holds the cache pin
/// plus the multicast lock for as long as the television may still be pulling
/// the file.
class CastController extends ChangeNotifier {
  CastController({
    required this.runtime,
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
  String? title;
  bool browsing = false;
  CastPhase phase = CastPhase.idle;
  Duration position = Duration.zero;
  Duration? duration;
  int? volumePercent;
  String? error;

  bool get active =>
      phase == CastPhase.preparing ||
      phase == CastPhase.streaming ||
      phase == CastPhase.paused;

  /// Where the television is; the player screen resumes local playback here.
  Duration get tvPosition => _session?.snapshot.position ?? position;

  Future<void> browse() async {
    if (browsing || active) return;
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

  Future<void> start({
    required KnownRenderer renderer,
    required String vid,
    required String episodeTitle,
    String quality = 'best',
    Duration? expectedDuration,
  }) async {
    final local = runtime;
    if (local is! LocalMediaRuntime) {
      _change(() => error = _noCachedFile);
      return;
    }
    final reuse =
        _session != null && _session!.device.udn == renderer.device.udn;
    // The previous episode stops being served before the new one is handed over.
    _releaseMedia();
    if (!reuse) _releaseSession();
    _change(() {
      target = renderer;
      title = episodeTitle;
      duration = expectedDuration;
      position = Duration.zero;
      phase = CastPhase.preparing;
      error = null;
    });
    try {
      final server = await _ensureServer();
      final job = local.prepareLocal(vid, quality: quality);
      _pin = job;
      final path = await job.source;
      final lease = await server.publish(
        File(Uri.parse(path).toFilePath()),
        title: episodeTitle,
      );
      _servedId = lease.id;
      final session = reuse ? _session! : openSession(renderer.device);
      if (!reuse) {
        _updates = session.updates.listen(_onSnapshot);
        _session = session;
      }
      await session.cast(
        DidlItem(
          uri: lease.uri,
          mimeType: lease.mimeType,
          title: episodeTitle,
          sizeBytes: lease.sizeBytes,
          duration: expectedDuration,
        ),
      );
      _onSnapshot(session.snapshot);
      final failure = session.snapshot.error;
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

  Future<void> pause() async => _session?.pause();

  Future<void> resume() async => _session?.resume();

  Future<void> seekTo(Duration value) async => _session?.seek(value);

  Future<void> setVolume(int percent) async => _session?.setVolume(percent);

  /// Leaves the television stopped and keeps the last position so the caller can
  /// resume it locally.
  Future<Duration> stop() async {
    final last = tvPosition;
    final session = _session;
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

  void _onSnapshot(CastSnapshot snapshot) {
    // A snapshot still in flight after `_releaseSession` belongs to a session we
    // no longer show, and must not undo the phase the exit just set.
    if (_updates == null) return;
    _change(() {
      phase = snapshot.phase;
      position = snapshot.position;
      if (snapshot.duration != null) duration = snapshot.duration;
      volumePercent = snapshot.volumePercent ?? volumePercent;
      if (snapshot.error != null) error = snapshot.error;
    });
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
