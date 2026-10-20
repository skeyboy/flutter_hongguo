import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:background_downloader/background_downloader.dart' as bg;
import 'package:dio/dio.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_api/hongguo_api.dart';

import '../../settings/settings_store_native.dart';
import '../../settings/settings_store.dart';

import 'package:path_provider/path_provider.dart';

/// Native transfer is opt-in. Decryption/publication remain in MediaCache.
class NativeDownloads {
  final AppSettings Function() settings;
  final Dio dio;
  Future<void>? _started;
  final _tasks = <String>{};
  final SessionVault vault;
  Directory? _journal;
  Future<void> _journalWrites = Future.value();
  NativeDownloads(
    this.settings,
    this.dio, {
    SessionVault? vault,
    Directory? journalDirectory,
  }) : vault = vault ?? SystemSessionVault(),
       _journal = journalDirectory;
  Future<T> _journalAction<T>(Future<T> Function() action) {
    final result = _journalWrites.then((_) => action());
    _journalWrites = result.then<void>((_) {}).catchError((Object _) {});
    return result;
  }

  Future<Directory> _journalDirectory() async {
    return _journal ??= Directory(
      '${(await getApplicationSupportDirectory()).path}/download-journal',
    );
  }

  Future<void> finish(String vid, String quality, {String? workingPath}) =>
      _journalAction(() => _finish(vid, quality, workingPath));
  Future<void> _finish(String vid, String quality, String? workingPath) async {
    if (_journal == null) return;
    final file = File('${_journal!.path}/${vid}_$quality.json');
    if (!await file.exists()) return;
    final record = jsonDecode(await file.readAsString()) as Map;
    if (workingPath != null &&
        record['filename'] != File(workingPath).uri.pathSegments.last) {
      return;
    }
    final ref = record['keyRef'];
    if (ref is String && ref.startsWith('hongguo.download.')) {
      await vault.delete(ref);
    }
    await file.delete();
  }

  Future<void> restore(
    Future<void> Function(String, String, String, String?) adopt,
  ) async {
    final journal = await _journalDirectory();
    if (!await journal.exists()) return;
    await initialize();
    final root = await getApplicationSupportDirectory();
    await for (final entry in journal.list()) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      Map? record;
      try {
        record = jsonDecode(await entry.readAsString()) as Map;
        final vid = record['vid'] as String,
            quality = record['quality'] as String,
            filename = record['filename'] as String;
        if (!RegExp(r'^\d{1,30}$').hasMatch(vid) ||
            !RegExp(r'^(best|auto|\d{3,4}p)$').hasMatch(quality) ||
            filename.contains('/') ||
            filename.contains('\\') ||
            !filename.startsWith('${vid}_$quality.mp4.') ||
            !filename.endsWith('.part')) {
          throw const FormatException('Invalid download journal');
        }
        final file = File('${root.path}/media-cache/$filename');
        if (await file.exists()) {
          final ref = record['keyRef'];
          if (ref is String && !ref.startsWith('hongguo.download.')) {
            throw const FormatException('Invalid key reference');
          }
          final key = ref is String ? await vault.read(ref) : null;
          await adopt(vid, quality, file.path, key);
        } else {
          // A previous process no longer owns a Dart decryption pipeline.
          // Completed files recover; unfinished orphaned transfers are stopped.
          await bg.FileDownloader().cancelTaskWithId(
            record['taskId'] as String,
          );
        }
        await finish(vid, quality);
      } catch (_) {
        // Keep encrypted key references when the keychain is temporarily locked;
        // this journal can be retried on the next launch, never shown as ready.
      }
    }
  }

  Future<void> initialize({bool requestNotification = false}) async {
    try {
      await (_started ??= bg.FileDownloader().start(autoCleanDatabase: true));
    } catch (_) {
      _started = null;
      rethrow;
    }
    bg.FileDownloader().configureNotification(
      running: const bg.TaskNotification(
        '正在缓存剧集',
        '{displayName} · {progress}',
      ),
      complete: const bg.TaskNotification('视频下载完成', '回到红果剧场完成解密与校验'),
      error: const bg.TaskNotification('缓存下载未完成', '请返回应用检查网络并重试'),
      paused: const bg.TaskNotification('缓存等待继续', '等待网络或系统调度'),
      progressBar: true,
      tapOpensFile: false,
    );
    if (requestNotification && (Platform.isAndroid || Platform.isIOS)) {
      await bg.FileDownloader().permissions.request(
        bg.PermissionType.notifications,
      );
    }
  }

  Future<void> download(
    String vid,
    String quality,
    VideoTrack track,
    String path,
    CancelToken cancel,
    void Function(int, int) progress,
  ) async {
    final url = track.url;
    if (!settings().backgroundDownloads) {
      await dio.download(
        url.toString(),
        path,
        cancelToken: cancel,
        deleteOnError: true,
        options: Options(
          followRedirects: false,
          headers: {'User-Agent': 'Mozilla/5.0'},
          receiveTimeout: const Duration(seconds: 120),
        ),
        onReceiveProgress: progress,
      );
      return;
    }
    await initialize();
    if (cancel.isCancelled) throw cancel.cancelError!;
    final root = await getApplicationSupportDirectory();
    final parent = File(path).parent.path;
    if (!parent.startsWith('${root.path}${Platform.pathSeparator}')) {
      throw StateError('下载目标不在应用私有目录');
    }
    final directory = parent.substring(root.path.length + 1);
    final task = bg.DownloadTask(
      url: url.toString(),
      filename: File(path).uri.pathSegments.last,
      directory: directory,
      baseDirectory: bg.BaseDirectory.applicationSupport,
      headers: const {'User-Agent': 'Mozilla/5.0'},
      displayName: '剧集视频',
      group: 'hongguo-media',
      updates: bg.Updates.statusAndProgress,
      requiresWiFi:
          (Platform.isAndroid || Platform.isIOS) &&
          settings().backgroundWifiOnly,
      allowPause: true,
      retries: 2,
    );
    final journal = await _journalDirectory();
    await journal.create(recursive: true);
    final keyRef = track.encrypted ? 'hongguo.download.${task.taskId}' : null;
    if (keyRef != null) await vault.write(keyRef, track.spadeA);
    try {
      await _journalAction(
        () =>
            FilePreferencesBackend(File('${journal.path}/${vid}_$quality.json'))
                .write({
                  'vid': vid,
                  'quality': quality,
                  'filename': task.filename,
                  'taskId': task.taskId,
                  'keyRef': keyRef,
                }),
      );
    } catch (_) {
      if (keyRef != null) await vault.delete(keyRef);
      rethrow;
    }
    _tasks.add(task.taskId);
    try {
      final transfer = await bg.FileDownloader().transfers.start(task);
      final updates = bg.FileDownloader().updates.listen((update) {
        if (update is bg.TaskProgressUpdate &&
            update.task.taskId == task.taskId &&
            update.progress >= 0 &&
            update.expectedFileSize > 0) {
          progress(
            (update.progress * update.expectedFileSize).round(),
            update.expectedFileSize,
          );
        }
      });
      void held() {
        if (transfer.holdReasonNotifier.value != bg.TransferHoldReason.none) {
          progress(0, -1);
        }
      }

      transfer.holdReasonNotifier.addListener(held);
      held();
      unawaited(
        cancel.whenCancel
            .then((_) => transfer.cancel())
            .catchError((Object _) => false),
      );
      try {
        final file = await transfer.file;
        if (cancel.isCancelled) throw cancel.cancelError!;
        if (file.path != path) {
          await file.copy(path);
          await file.delete();
        }
        final size = await File(path).length();
        progress(size, size);
      } finally {
        transfer.holdReasonNotifier.removeListener(held);
        await updates.cancel();
      }
    } finally {
      _tasks.remove(task.taskId);
    }
  }

  Future<void> cancel() async {
    if (_tasks.isNotEmpty) {
      await bg.FileDownloader().cancelTasksWithIds(_tasks.toList());
    }
  }
}
