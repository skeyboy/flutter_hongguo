import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart' as bg;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_update/hongguo_update.dart';

import '../platform/background/host_policy.dart';

/// The folder installer files are staged in, under the app's support directory.
///
/// One name for both lanes: the system lane spells its destination relative to
/// that base, and the install reads the absolute path back out of the note -- so
/// 「the file we verified」 and 「the file the system wrote」 cannot drift apart.
const updatePackagePath = 'updates';

/// Where an installer file on this device stands.
enum UpdatePackageStage {
  /// A transfer owns it. On the system lane this can outlive the app: the
  /// download runs on after the process is taken away, and only the note and the
  /// bytes beside it remain.
  transferring,

  /// The bytes are on disk and matched the digest the feed gave.
  ready,
}

/// One installer file this device took or is taking.
class UpdatePackageRecord {
  const UpdatePackageRecord({
    required this.tag,
    required this.name,
    required this.path,
    required this.downloadUrl,
    required this.bytes,
    required this.sha256,
    required this.stage,
    this.taskId = '',
  });

  /// The release this package installs, so an offer and its file are never
  /// confused: a device can hold `v0.4.0` while `v0.5.0` is being fetched.
  final String tag;
  final String name;

  /// Where the file sits -- recorded rather than derived, because the system lane
  /// writes under the support directory while the note lives beside the file.
  final String path;
  final String downloadUrl;
  final int bytes;

  /// What the bytes have to hash to before anything is installed.
  final String sha256;
  final UpdatePackageStage stage;

  /// The system lane's own id, empty for a transfer this process runs.
  final String taskId;

  Map<String, Object> toJson() => {
    'tag': tag,
    'name': name,
    'path': path,
    'url': downloadUrl,
    'bytes': bytes,
    'sha256': sha256,
    'stage': stage.name,
    'taskId': taskId,
  };

  static UpdatePackageRecord? fromMap(Object? value) {
    if (value is! Map) return null;
    final tag = value['tag'], name = value['name'], path = value['path'];
    final url = value['url'], sha = value['sha256'], stage = value['stage'];
    if (tag is! String ||
        name is! String ||
        path is! String ||
        url is! String ||
        sha is! String ||
        stage is! String) {
      return null;
    }
    // An asset name is what the file is written under: a value with a separator
    // in it would move the install outside the stage directory.
    if (tag.isEmpty || name.contains(RegExp(r'[/\\]'))) return null;
    return UpdatePackageRecord(
      tag: tag,
      name: name,
      path: path,
      downloadUrl: url,
      bytes: value['bytes'] is int ? value['bytes'] as int : 0,
      sha256: sha,
      stage: UpdatePackageStage.values.firstWhere(
        (s) => s.name == stage,
        orElse: () => UpdatePackageStage.transferring,
      ),
      taskId: value['taskId'] is String ? value['taskId'] as String : '',
    );
  }

  UpdatePackageRecord copyWith({UpdatePackageStage? stage, String? taskId}) =>
      UpdatePackageRecord(
        tag: tag,
        name: name,
        path: path,
        downloadUrl: downloadUrl,
        bytes: bytes,
        sha256: sha256,
        stage: stage ?? this.stage,
        taskId: taskId ?? this.taskId,
      );
}

/// The disk note of installer files this device took or is taking.
///
/// A backgrounded transfer is invisible to a process that was killed while it ran,
/// and a file on disk says nothing about which release it belongs to; this note is
/// what lets a return tell 「下载完了，该问要不要装」 from 「这是上个版本的残留」.
class UpdateJournal {
  UpdateJournal({required this.stageDirectory});

  static const fileName = 'hongguo-update-journal.json';

  /// Enough to answer for the standing offer and the one before it. Older tags are
  /// dropped with their files: an installer for a release this device already ran
  /// is only storage nobody asked for.
  static const _keep = 2;

  final Future<String> Function() stageDirectory;

  Future<File> _file() async =>
      File('${await stageDirectory()}${Platform.pathSeparator}$fileName');

  Future<List<UpdatePackageRecord>> records() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return const [];
      return decoded
          .map(UpdatePackageRecord.fromMap)
          .whereType<UpdatePackageRecord>()
          .toList();
    } on FileSystemException {
      return const [];
    } on FormatException {
      return const [];
    }
  }

  Future<UpdatePackageRecord?> forTag(String tag) async {
    for (final record in await records()) {
      if (record.tag == tag) return record;
    }
    return null;
  }

  /// Upsert, then forget tags that no longer matter -- including the file each one
  /// named, so a superseded release does not sit in private storage forever.
  Future<void> put(UpdatePackageRecord record) async {
    final merged =
        (await records())
            .where((existing) => existing.tag != record.tag)
            .toList()
          ..add(record);
    while (merged.length > _keep) {
      await _deleteFile(merged.removeAt(0));
    }
    try {
      await (await _file()).writeAsString(
        jsonEncode(merged.map((r) => r.toJson()).toList()),
      );
    } on FileSystemException {
      // A note this app cannot write is a transfer it will not run: the caller
      // finds out from the file check, not from an exception here.
    }
  }

  Future<void> drop(String tag) async {
    final record = await forTag(tag);
    if (record != null) await _deleteFile(record);
    final rest = (await records())
        .where((r) => r.tag != tag)
        .map((r) => r.toJson())
        .toList();
    try {
      await (await _file()).writeAsString(jsonEncode(rest));
    } on FileSystemException {
      // Nothing owed means nothing lost.
    }
  }

  Future<void> _deleteFile(UpdatePackageRecord record) async {
    try {
      final file = File(record.path);
      if (await file.exists()) await file.delete();
      final part = File('${record.path}.part');
      if (await part.exists()) await part.delete();
    } on FileSystemException {
      // Storage cleanup already took it, which is the outcome wanted here.
    }
  }
}

/// The system's own transfer lane, behind the two questions this app asks it.
abstract interface class InstallerEngine {
  /// Runs [task] to completion and reports bytes as they arrive.
  Future<void> transfer(
    bg.DownloadTask task, {
    void Function(int received, int total)? onProgress,
  });

  /// Whether the system still has work queued for [taskId] -- the answer that
  /// keeps a second press from starting a duplicate download.
  Future<bool> isLive(String taskId);

  /// Stops a transfer the app no longer has any reason to keep.
  Future<void> abandon(String taskId);
}

/// The real lane: `background_downloader`, the same one episode caches use.
class SystemInstallerEngine implements InstallerEngine {
  static const group = 'hongguo-update';

  Future<void>? _started;

  Future<void> _initialize() async {
    // Its own memo: the episode lane starts the same singleton, and a second
    // start is harmless but must not be paid for on every press.
    await (_started ??= bg.FileDownloader().start(autoCleanDatabase: true));
    bg.FileDownloader().configureNotificationForGroup(
      group,
      running: const bg.TaskNotification(
        '正在下载新版本',
        '{displayName} · {progress}',
      ),
      complete: const bg.TaskNotification('新版本已下载完成', '回到应用即可安装'),
      error: const bg.TaskNotification('新版本下载未完成', '返回应用检查网络后重试'),
      paused: const bg.TaskNotification('新版本下载等待继续', '等待网络或系统调度'),
      progressBar: true,
      // Tapping must not hand an APK straight to the system installer: the app
      // asks first, because the bytes still have to be checked by it.
      tapOpensFile: false,
    );
  }

  @override
  Future<void> transfer(
    bg.DownloadTask task, {
    void Function(int received, int total)? onProgress,
  }) async {
    await _initialize();
    final transfer = await bg.FileDownloader().transfers.start(task);
    final updates = bg.FileDownloader().updates.listen((update) {
      if (update is bg.TaskProgressUpdate &&
          update.task.taskId == task.taskId &&
          update.expectedFileSize > 0) {
        onProgress?.call(
          (update.progress * update.expectedFileSize).round(),
          update.expectedFileSize,
        );
      }
    });
    try {
      await transfer.file;
    } finally {
      await updates.cancel();
    }
  }

  @override
  Future<bool> isLive(String taskId) async {
    if (taskId.isEmpty) return false;
    try {
      await _initialize();
      final records = await bg.FileDownloader().database.recordsForIds([
        taskId,
      ]);
      if (records.isEmpty) return false;
      return records.single.status.isNotFinalState;
    } on Object {
      // A lane that cannot answer is not holding anything: better to start one
      // transfer than to sit on a note nobody can confirm.
      return false;
    }
  }

  @override
  Future<void> abandon(String taskId) async {
    if (taskId.isEmpty) return;
    await _initialize();
    await bg.FileDownloader().cancelTaskWithId(taskId);
  }
}

/// Which lane an installer download runs on, and what a return finds there.
///
/// Both lanes reuse what is already on disk: the in-app one inside
/// [ReleaseDownloader.fetch], this class for transfers the system finished while
/// the app slept -- which no downloader in this process ever saw.
class UpdateTransferLane {
  UpdateTransferLane({
    required this.journal,
    required this.settings,
    required this.dio,
    required this.packageDirectory,
    required this.packagePath,
    InstallerEngine? engine,
    bool Function()? systemLaneAllowed,
  }) : engine = engine ?? SystemInstallerEngine(),
       systemLaneAllowed =
           systemLaneAllowed ??
           (() =>
               useSystemTransferLane(enabled: settings().backgroundDownloads));

  final UpdateJournal journal;
  final AppSettings Function() settings;
  final Dio dio;
  final InstallerEngine engine;

  /// The folder installer files land in, absolute -- which is what a later return
  /// reads out of the note rather than re-deriving.
  final Future<String> Function() packageDirectory;

  /// The same folder spelled the way the system lane addresses it: relative to
  /// its application-support base. Wiring both from one directory is what keeps
  /// 「the file we verified」 and 「the file the system wrote」 the same file.
  final String packagePath;

  /// Injectable because a desktop suite has no system lane to hand a transfer to,
  /// and the choice is a policy -- not something this class may assume.
  final bool Function() systemLaneAllowed;

  bool get usesSystemLane => systemLaneAllowed();

  /// The folder the in-app lane downloads into.
  Future<Directory> _stage() async => Directory(await packageDirectory());

  /// Packages this process has handed to the system and is still waiting on.
  ///
  /// Static, like the kernel's own: a second lane instance in the same process is
  /// still the same app, and two handovers of one file are two system tasks for
  /// the same bytes. The disk note cannot cover this -- it is written by the very
  /// press that is being raced.
  static final _handedOver = <String>{};

  ReleaseDownloader _downloader(Directory destination) =>
      ReleaseDownloader(dio: dio, destination: destination);

  /// Download and verify the installer, on whichever lane this host runs.
  ///
  /// The system lane hands the transfer over and returns as soon as the file is
  /// checked, so the caller may close the dialog and let the download outlive the
  /// app; a second press while it runs gets [UpdateFailure] with the words that
  /// say so rather than a duplicate.
  Future<DownloadedRelease> fetch(
    ReleaseAsset asset,
    ReleaseInfo release, {
    void Function(int received, int total)? onProgress,
  }) async {
    // The first check happens before this method suspends, so two presses in one
    // frame cannot both slip past it.
    if (usesSystemLane && !_handedOver.add(_handoverKey(asset, release))) {
      throw const UpdateFailure('安装包已在后台下载，进度见通知栏；下载完成回到应用会提示是否安装，不需要重复下载。');
    }
    try {
      return await _fetchOnLane(asset, release, onProgress);
    } finally {
      _handedOver.remove(_handoverKey(asset, release));
    }
  }

  String _handoverKey(ReleaseAsset asset, ReleaseInfo release) =>
      '${release.tag}|${asset.downloadUrl}';

  Future<DownloadedRelease> _fetchOnLane(
    ReleaseAsset asset,
    ReleaseInfo release,
    void Function(int received, int total)? onProgress,
  ) async {
    final stage = await _stage();
    await stage.create(recursive: true);
    final downloader = _downloader(stage);
    final expected = await downloader.expectedDigest(asset, release);
    if (expected == null) {
      throw const UpdateFailure('这个发布附件没有可对照的校验值，已停止安装。');
    }
    if (!usesSystemLane) {
      return downloader.fetch(asset, release, onProgress: onProgress);
    }
    final path = '${stage.path}${Platform.pathSeparator}${asset.name}';
    if (await ReleaseDownloader.verify(path, expected, bytes: asset.bytes)) {
      onProgress?.call(asset.bytes, asset.bytes);
      await journal.put(
        _record(
          release,
          asset,
          path,
          expected,
        ).copyWith(stage: UpdatePackageStage.ready),
      );
      return DownloadedRelease(
        path: path,
        bytes: asset.bytes,
        sha256: expected,
        reused: true,
      );
    }
    final standing = await journal.forTag(release.tag);
    if (standing != null &&
        standing.stage == UpdatePackageStage.transferring &&
        await engine.isLive(standing.taskId)) {
      throw const UpdateFailure('安装包已在后台下载，进度见通知栏；下载完成回到应用会提示是否安装，不需要重复下载。');
    }
    final task = bg.DownloadTask(
      url: asset.downloadUrl,
      filename: asset.name,
      directory: packagePath,
      baseDirectory: bg.BaseDirectory.applicationSupport,
      displayName: '新版本 ${release.tag}',
      group: SystemInstallerEngine.group,
      updates: bg.Updates.statusAndProgress,
      requiresWiFi:
          !kIsWeb &&
          (Platform.isAndroid || Platform.isIOS) &&
          settings().backgroundWifiOnly,
      allowPause: true,
      retries: 2,
    );
    await journal.put(
      _record(release, asset, path, expected).copyWith(taskId: task.taskId),
    );
    try {
      await engine.transfer(task, onProgress: onProgress);
    } on Object {
      await journal.drop(release.tag);
      throw const UpdateFailure('更新文件没下载完，请稍后重试。');
    }
    // The system reported success, and there are two ways that is still not a
    // package: nothing arrived, or the wrong bytes did. They deserve different
    // words, because only one of them is a network the viewer can retry.
    if (!await File(path).exists()) {
      await journal.drop(release.tag);
      throw const UpdateFailure('更新文件没下载完，请稍后重试。');
    }
    if (!await ReleaseDownloader.verify(path, expected, bytes: asset.bytes)) {
      await journal.drop(release.tag);
      throw const UpdateFailure('下载文件的校验值与发布记录不一致，已删除并停止安装。');
    }
    await journal.put(
      _record(
        release,
        asset,
        path,
        expected,
      ).copyWith(taskId: task.taskId, stage: UpdatePackageStage.ready),
    );
    return DownloadedRelease(path: path, bytes: asset.bytes, sha256: expected);
  }

  /// A package this device already holds for [tag], checked now.
  ///
  /// This is how a download that finished while the app was away becomes a
  /// question instead of a mystery: the note says which release the bytes are
  /// for, and the digest says they arrived whole.
  Future<DownloadedRelease?> settle(String tag) async {
    final record = await journal.forTag(tag);
    if (record == null) return null;
    final intact = await ReleaseDownloader.verify(
      record.path,
      record.sha256,
      bytes: record.bytes,
    );
    if (intact) {
      if (record.stage != UpdatePackageStage.ready) {
        await journal.put(record.copyWith(stage: UpdatePackageStage.ready));
      }
      return DownloadedRelease(
        path: record.path,
        bytes: record.bytes,
        sha256: record.sha256,
        reused: true,
      );
    }
    // A note whose file is gone or corrupt is not a debt: keeping it would have
    // the app promise an install it cannot perform. A transfer still running is
    // left alone, because its bytes are legitimately not there yet.
    if (record.stage == UpdatePackageStage.ready) await journal.drop(tag);
    return null;
  }

  /// Whether a transfer this process no longer runs is still alive on the system
  /// lane -- the answer that turns 「稍后再说」 into a bar rather than a dead button.
  Future<bool> isTransferring(String tag) async {
    final record = await journal.forTag(tag);
    if (record == null || record.stage != UpdatePackageStage.transferring) {
      return false;
    }
    return engine.isLive(record.taskId);
  }

  /// Stop a transfer the viewer asked to forget, and the note that would re-offer
  /// its bytes.
  Future<void> cancel(String tag) async {
    final record = await journal.forTag(tag);
    if (record != null) await engine.abandon(record.taskId);
    await journal.drop(tag);
  }

  UpdatePackageRecord _record(
    ReleaseInfo release,
    ReleaseAsset asset,
    String path,
    String sha256,
  ) => UpdatePackageRecord(
    tag: release.tag,
    name: asset.name,
    path: path,
    downloadUrl: asset.downloadUrl,
    bytes: asset.bytes,
    sha256: sha256,
    stage: UpdatePackageStage.transferring,
  );
}
