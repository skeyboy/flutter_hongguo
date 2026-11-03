import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_update/hongguo_update.dart';

import 'android_update_channel.dart';
import 'app_release.dart';
import 'install_strategy.dart';
import 'update_transfer.dart';

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

  /// The operating system's transfer lane, or a stand-in for a suite that has no
  /// plugin to hand a download to.
  final InstallerEngine? installerEngine;

  /// Whether this host may run an installer download in the background at all --
  /// the same policy the episode cache uses, read from the viewer's own setting.
  final bool Function()? systemLaneAllowed;

  /// What to do with a file whose bytes matched. Injectable because the real
  /// handoff opens Finder, starts an installer, or ends this process -- and a
  /// suite that only wants to see the order of operations may do none of those.
  final Future<InstallPlan> Function(
    DownloadedRelease file,
    ReleaseInfo release,
    AndroidInstaller android,
  )
  handoff;

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

  /// An Android handoff left a verified APK owed an install, and the debt is
  /// still unpaid. Read off the note beside the APK -- not off a field set on the
  /// way out -- so a payment made after the process was taken away clears it too.
  bool installOwed = false;

  /// The installer for [offer] is on this device, its bytes checked, and nothing
  /// has been handed to the system yet: a background transfer that finished while
  /// the app slept, or one that completed after its dialog closed. The prompt
  /// turns 立即更新 into 立即安装 on this, and asks once.
  bool installReady = false;

  /// A transfer the operating system owns. It keeps running when this dialog
  /// closes and when the app is taken away, so the press that started it is not
  /// the thing that has to stay alive.
  bool transferring = false;

  bool _watchingLifecycle = false;

  /// Android's install is the one handoff that can outlive the app: the verified
  /// APK is written down as owed and paid on a later return, so the note lives in
  /// the same stage directory the downloader wrote into.
  late final AndroidInstaller _android = AndroidInstaller(
    stageDirectory: stageDirectory,
  );

  /// The note of installer files this device took or is taking, and the two lanes
  /// that can fill it.
  late final UpdateJournal _journal = UpdateJournal(
    stageDirectory: stageDirectory,
  );

  late final UpdateTransferLane _transfers = UpdateTransferLane(
    journal: _journal,
    settings: readSettings,
    // Its own transport, held for the controller's life: the runtime's Dio
    // carries the upstream video API's timeouts, a multi-minute installer
    // download must not inherit them -- and a transfer the app was told to
    // outlive cannot be closed when the dialog that started it goes away.
    dio: _transferDio(),
    packageDirectory: stageDirectory,
    packagePath: updatePackagePath,
    engine: installerEngine,
    systemLaneAllowed: systemLaneAllowed,
  );

  UpdateController({
    required Dio dio,
    required this.readSettings,
    required this.writeSettings,
    required this.stageDirectory,
    this.exitApp = _leaveProcess,
    this.policy = const UpdatePolicy(),
    this.installerEngine,
    this.systemLaneAllowed,
    this.handoff = _handOffDefault,
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

  bool get busy => checking || downloading || transferring;

  /// Whether this platform can be given an installer at all.
  bool get canInstall =>
      offer != null && currentUpdateTarget().hasInstallableAsset;

  /// Whether the line under the buttons is worth reading: a transfer running, a
  /// package waiting to be installed, or a debt still unpaid. Each of those can
  /// arrive while `downloading` is already false, and a prompt that swallows the
  /// sentence is what the viewer is left staring at.
  bool get showsMessage =>
      downloading || transferring || installOwed || installReady;

  /// Startup check. The resumed observer is registered here, so a background
  /// return re-checks through the same throttled path -- and a launch the system
  /// started after it took the app during the settings trip pays the install that
  /// trip was blocking, without a second press.
  ///
  /// Safe to call again: the controller outlives the pages that use it, and a
  /// second mount must not register a second observer or a second startup check.
  void start() {
    if (_watchingLifecycle) return;
    _watchingLifecycle = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_returnToForeground());
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

  /// Coming back to the app answers three things, in this order: the daily check,
  /// then a package the system finished while the app was away, then the install
  /// the settings screen was blocking -- last, so that the system's own words about
  /// the session are what the viewer reads.
  ///
  /// Only Android owes the third one. Every other platform finishes its handoff
  /// inside [install], and the desktop builds have no `hongguo/update` handler.
  Future<void> _returnToForeground() async {
    await runQuietly();
    await settleOnReturn();
    if (currentUpdateTarget().platform != ReleasePlatform.android) return;
    final hadDebt = await _android.hasOwedInstall();
    final word = await _android.resume();
    installOwed = await _android.hasOwedInstall();
    if (hadDebt && !installOwed) {
      // The debt is paid, so the package it named is spent: a note left behind
      // would ask this viewer to install the release they just installed.
      final release = offer;
      if (release != null) await _journal.drop(release.tag);
      installReady = false;
    }
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
  ///
  /// Bytes that are already on this device and already checked are never fetched
  /// again, which is what a second press -- or a press after a background
  /// transfer finished -- costs nothing.
  Future<InstallPlan?> install() async {
    final release = offer;
    if (release == null || downloading || transferring) return null;
    final asset = (await _targetForDevice()).installer(release);
    if (asset == null) {
      error = '这个发布没有适配本机的安装包，请打开发布页下载。';
      notifyListeners();
      return null;
    }
    // Bytes already on this device and already checked are never fetched again:
    // this is what a press after a finished background transfer, and a press that
    // repeats one, costs nothing. Only the lane that journals files can answer it,
    // and the desktop handoff needs no note at all.
    var file = _transfers.usesSystemLane
        ? await _transfers.settle(release.tag)
        : null;
    if (file == null) {
      if (_transfers.usesSystemLane) {
        // Handed over rather than awaited here: the dialog must be free to close,
        // and the transfer has to keep running when the app is taken away.
        transferring = true;
        progress = null;
        _announced = 0;
        error = null;
        message = '安装包正在后台下载，进度见通知栏；下载完成后会提示是否安装。';
        notifyListeners();
        unawaited(_transferInBackground(release, asset));
        return null;
      }
      downloading = true;
      progress = null;
      _announced = 0;
      error = null;
      notifyListeners();
      try {
        file = await _transfers.fetch(
          asset,
          release,
          onProgress: reportProgress,
        );
      } on UpdateFailure catch (failure) {
        error = failure.message;
        return null;
      } on Object {
        error = '更新文件没能准备好，请稍后重试。';
        return null;
      } finally {
        downloading = false;
        progress = null;
        notifyListeners();
      }
    }
    return _handOff(file, release);
  }

  /// The one place a checked file becomes an install, so a background transfer
  /// that lands later says the same things the pressed button said before.
  Future<InstallPlan> _handOff(
    DownloadedRelease file,
    ReleaseInfo release,
  ) async {
    installReady = false;
    final plan = await handoff(file, release, _android);
    message = plan.message;
    installOwed = plan.owesInstall;
    // A package the system has taken needs no note and no bytes: keeping it would
    // have a later return offer to install a release that is already installed.
    // Only where the install reads the file itself -- on the desktop the verified
    // download *is* what the viewer still has to open, so it stays.
    if (!plan.owesInstall &&
        currentUpdateTarget().platform == ReleasePlatform.android) {
      await _journal.drop(release.tag);
    }
    // The prompt was answered: a transfer this device just handed to the system
    // must not come back as a new interruption later in the same session.
    unseenOffer = null;
    if (plan.appWillExit) await exitApp();
    notifyListeners();
    return plan;
  }

  /// The system lane's transfer, finished wherever this process still is.
  ///
  /// Nothing here is owed an answer: when the app was taken away mid-transfer the
  /// note and [settleOnReturn] carry the outcome, and this only makes the prompt
  /// arrive as soon as the bytes are checked.
  Future<void> _transferInBackground(
    ReleaseInfo release,
    ReleaseAsset asset,
  ) async {
    try {
      final file = await _transfers.fetch(
        asset,
        release,
        onProgress: reportProgress,
      );
      if (offer?.tag != release.tag) return;
      installReady = true;
      message =
          '新版本 ${release.tag} 已下载完成（${(file.bytes / 1024 / 1024).toStringAsFixed(1)} MB），是否安装？';
      // Re-raised rather than announced from the runner: the prompt already knows
      // how to wait for the player or a download page to clear.
      unseenOffer = release;
    } on UpdateFailure catch (failure) {
      error = failure.message;
    } on Object {
      error = '更新文件没能准备好，请稍后重试。';
    } finally {
      transferring = false;
      progress = null;
      notifyListeners();
    }
  }

  /// A package this device already holds for the standing offer.
  ///
  /// Runs on every return, because this is the only way a download the system
  /// finished in the app's absence turns into a question instead of a file nobody
  /// mentions again. A host that never hands a download over has no note to read,
  /// so it is asked no question and touches no disk.
  Future<void> settleOnReturn() async {
    final release = offer;
    if (release == null ||
        !_transfers.usesSystemLane ||
        transferring ||
        installReady) {
      return;
    }
    final file = await _transfers.settle(release.tag);
    if (file != null) {
      installReady = true;
      message = '新版本 ${release.tag} 已下载完成，是否安装？';
      unseenOffer = release;
      notifyListeners();
      return;
    }
    if (await _transfers.isTransferring(release.tag)) {
      transferring = true;
      message = '安装包仍在后台下载，完成后会提示是否安装。';
      notifyListeners();
    }
  }

  /// Back from the 「安装未知应用」 screen the prompt sent the viewer to. Android-only:
  /// every other platform finishes its handoff inside [install].
  Future<void> openInstallSettings() async {
    await AndroidUpdate.openInstallPermissionSettings();
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

/// What the operating system does with a file whose bytes matched -- the product
/// answer, which a suite replaces rather than inherits.
Future<InstallPlan> _handOffDefault(
  DownloadedRelease file,
  ReleaseInfo release,
  AndroidInstaller android,
) => handOff(file, release, android: android);
