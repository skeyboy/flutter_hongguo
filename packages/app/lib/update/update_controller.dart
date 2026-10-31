import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_update/hongguo_update.dart';

import 'android_update_channel.dart';
import 'app_release.dart';
import 'install_strategy.dart';

/// A version check, its verdict in the user's words, and the one file this
/// device would install. Everything platform-specific arrives through the four
/// callbacks, so this class runs in a widget test with no plugins and no
/// network.
class UpdateController extends ChangeNotifier with WidgetsBindingObserver {
  static const _none = 0;

  final ReleaseFeed feed;
  final UpdatePolicy policy;
  final AppSettings Function() readSettings;
  final Future<void> Function(AppSettings value) writeSettings;
  final Future<String> Function() stageDirectory;

  /// What to do when a platform can only install by taking over the app itself.
  /// Injectable because a test must not be able to end the process.
  final Future<void> Function() exitApp;

  DateTime Function() clock = DateTime.now;

  bool checking = false;
  bool downloading = false;
  double? progress;
  double _announced = 0;
  String? message;
  String? error;

  /// The newest release we know of. Kept after a dialog was dismissed so the
  /// settings row can still offer 立即更新.
  ReleaseInfo? offer;

  /// An offer the root page has not shown yet.
  ReleaseInfo? unseenOffer;

  bool _watchingLifecycle = false;

  /// Android's install is the one handoff that can only finish across a trip to
  /// the settings screen, so the verified APK parks here until a return.
  final AndroidInstaller _android = AndroidInstaller();

  UpdateController({
    required Dio dio,
    required this.readSettings,
    required this.writeSettings,
    required this.stageDirectory,
    this.exitApp = _leaveProcess,
    this.policy = const UpdatePolicy(),
  }) : feed = ReleaseFeed(dio: dio, repository: AppRelease.repository);

  static Future<void> _leaveProcess() async {
    // `flutter test` sets FLUTTER_TEST in the runner's environment; a suite on
    // the Windows CI host must not be able to end itself through this path.
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    exit(0);
  }

  ReleaseVersion get current =>
      ReleaseVersion.tryParse(AppRelease.version) ??
      const ReleaseVersion(numbers: [0, 0, 0]);

  bool get busy => checking || downloading;

  /// Whether this platform can be given an installer at all.
  bool get canInstall =>
      offer != null && currentUpdateTarget().hasInstallableAsset;

  /// Startup check. The resumed observer is registered here, so a background
  /// return re-checks through the same throttled path.
  ///
  /// Safe to call again: the controller outlives the pages that use it, and a
  /// second mount must not register a second observer or a second startup check.
  void start() {
    if (_watchingLifecycle) return;
    _watchingLifecycle = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(runQuietly());
  }

  @override
  void dispose() {
    if (_watchingLifecycle) WidgetsBinding.instance.removeObserver(this);
    _watchingLifecycle = false;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_returnToForeground());
  }

  /// Coming back from the settings screen answers two things, in this order: the
  /// daily check first, then the install it was blocking -- last, so that the
  /// system's own words about the session are what the viewer reads.
  Future<void> _returnToForeground() async {
    await runQuietly();
    final word = await _android.resume();
    if (word == null) return;
    error = null;
    message = word;
    notifyListeners();
  }

  /// The silent path: never reports, never interrupts. A throttled or failed
  /// check leaves the UI exactly as it was.
  Future<void> runAutomatic() async {
    final settings = readSettings();
    if (!policy.shouldCheck(
      automatic: true,
      enabled: settings.updateChecksEnabled,
      lastCheckAt: _lastCheck(settings),
      now: clock(),
    )) {
      return;
    }
    await _check(settings: settings);
  }

  /// Startup and resume share this one entry point, and neither may surface a
  /// failure: the next day's check, or the settings row, tries again.
  Future<void> runQuietly() async {
    try {
      await runAutomatic();
    } catch (error) {
      debugPrint('update: background check failed: $error');
    }
  }

  /// The settings row: always asks, always answers in words.
  Future<void> checkNow() async {
    await _check(settings: readSettings());
  }

  Future<UpdateOutcome> _check({required AppSettings settings}) async {
    if (checking) return UpdateOutcome.unavailable;
    checking = true;
    error = null;
    notifyListeners();
    ReleaseFeedResult result;
    try {
      result = await feed.latest(
        ifNoneMatch: settings.updateFeedEtag.isEmpty
            ? null
            : settings.updateFeedEtag,
      );
    } on Object {
      // Whatever the feed did not already turn into words still must not leave
      // a check as an unhandled error.
      result = const ReleaseFeedResult(
        status: ReleaseFeedStatus.unavailable,
        message: '更新检查未完成，请稍后重试。',
      );
    } finally {
      checking = false;
    }
    final outcome = policy.classify(
      current: current,
      feed: result,
      ignoredTag: settings.ignoredUpdateVersion,
    );
    if (outcome == UpdateOutcome.available ||
        outcome == UpdateOutcome.ignored) {
      offer = result.release;
      if (outcome == UpdateOutcome.available) unseenOffer = result.release;
    } else if (outcome == UpdateOutcome.upToDate) {
      offer = null;
      unseenOffer = null;
    }
    message = _words(outcome, result, offer);
    // A feed that never answered must not spend the day's check: the retry
    // belongs to the next launch or resume, and nothing is written for it.
    if (result.status != ReleaseFeedStatus.unavailable) {
      await _retain(
        result,
        keepEtag:
            outcome == UpdateOutcome.upToDate ||
            outcome == UpdateOutcome.unchanged,
      );
    }
    notifyListeners();
    return outcome;
  }

  /// The timestamp that throttles the next check, in one write per answer.
  ///
  /// The `ETag` is only kept while nothing is owed: with an offer standing, a 304
  /// would come back as 「自上次检查以来没有新版本」 over a release the viewer still has
  /// not installed or ignored, so a standing offer has to pay for the whole body
  /// until 立即更新 or 忽略本次更新 settles it.
  Future<void> _retain(
    ReleaseFeedResult result, {
    required bool keepEtag,
  }) async {
    final settings = readSettings();
    await writeSettings(
      settings.copyWith(
        lastUpdateCheckAt: clock().millisecondsSinceEpoch,
        updateFeedEtag: keepEtag ? result.etag ?? settings.updateFeedEtag : '',
      ),
    );
  }

  /// 忽略本次更新: that exact tag stops asking, everything after it still does.
  Future<void> ignoreOffer() async {
    final release = offer;
    if (release == null) return;
    unseenOffer = null;
    final settings = readSettings();
    await writeSettings(settings.copyWith(ignoredUpdateVersion: release.tag));
    message = '已忽略 ${release.tag}，下次有更新的版本再提醒你。';
    notifyListeners();
  }

  /// Stop nagging for this session without recording anything.
  void dismissOffer() {
    unseenOffer = null;
    notifyListeners();
  }

  /// Back on, after an earlier 忽略: forget the dismissed tag and check again.
  Future<void> remindAgain() async {
    final settings = readSettings();
    await writeSettings(settings.copyWith(ignoredUpdateVersion: ''));
    await checkNow();
  }

  Future<UpdateTarget> _targetForDevice() async {
    // Only an Android device has to be asked which ABI it runs; the desktop
    // builds read their own architecture out of the Dart version string.
    final host = currentUpdateTarget();
    if (host.platform != ReleasePlatform.android) return host;
    return currentUpdateTarget(abis: await AndroidUpdate.supportedAbis());
  }

  /// Download, verify, then hand the file to the operating system. Every return
  /// path leaves either a message that says what to do next or an error the
  /// settings row shows -- and never a half-written installer.
  Future<InstallPlan?> install() async {
    final release = offer;
    if (release == null || downloading) return null;
    final asset = (await _targetForDevice()).installer(release);
    if (asset == null) {
      error = '这个发布没有适配本机的安装包，请打开发布页下载。';
      notifyListeners();
      return null;
    }
    downloading = true;
    progress = null;
    _announced = 0;
    error = null;
    notifyListeners();
    Dio? transfer;
    try {
      // Its own transport: the runtime's Dio carries the upstream video API's
      // timeouts, and a multi-minute installer download must not inherit them.
      transfer = _transferDio();
      final downloader = ReleaseDownloader(
        dio: transfer,
        destination: Directory(await stageDirectory()),
      );
      final file = await downloader.fetch(
        asset,
        release,
        onProgress: reportProgress,
      );
      final plan = await handOff(file, release, android: _android);
      message = plan.message;
      // The prompt was answered: a transfer this device just handed to the system
      // must not come back as a new interruption later in the same session.
      unseenOffer = null;
      if (plan.appWillExit) await exitApp();
      return plan;
    } on UpdateFailure catch (failure) {
      error = failure.message;
      return null;
    } on Object {
      error = '更新文件没能准备好，请稍后重试。';
      return null;
    } finally {
      transfer?.close(force: true);
      downloading = false;
      progress = null;
      notifyListeners();
    }
  }

  /// One notification per percentage point, not per socket chunk.
  ///
  /// The comparison is against the fraction last *announced*: a 22 MB installer
  /// arrives in ~5 KB chunks, so each one moves the bar by a fifth of a point,
  /// and a transfer that compared itself to the previous chunk would rebuild
  /// nothing and leave the dialog without a bar until the last byte.
  void reportProgress(int received, int total) {
    if (total <= 0) return;
    final next = (received / total).clamp(0.0, 1.0);
    progress = next;
    if (next >= 1.0 || (next - _announced) * 100 >= 1) {
      _announced = next;
      notifyListeners();
    }
  }

  DateTime? _lastCheck(AppSettings settings) =>
      settings.lastUpdateCheckAt == _none
      ? null
      : DateTime.fromMillisecondsSinceEpoch(settings.lastUpdateCheckAt);

  static String _words(
    UpdateOutcome outcome,
    ReleaseFeedResult feed,
    ReleaseInfo? offer,
  ) => switch (outcome) {
    UpdateOutcome.available => '发现新版本 ${offer?.tag ?? ''}',
    UpdateOutcome.ignored => '最新版本 ${offer?.tag ?? ''} 你已选择忽略',
    UpdateOutcome.upToDate => '已经是最新版本',
    UpdateOutcome.unchanged => '自上次检查以来没有新版本',
    UpdateOutcome.unavailable =>
      feed.message.isEmpty ? '更新检查未完成' : feed.message,
  };
}

Dio _transferDio() =>
    Dio(BaseOptions(connectTimeout: const Duration(seconds: 20)))
      ..options.receiveTimeout = null;
