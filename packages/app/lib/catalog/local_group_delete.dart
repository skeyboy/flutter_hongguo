import '../downloads/download_manager.dart';
import '../platform/runtime_contract.dart';
import 'local_library.dart';

/// What one 归类删除 call did: files are only counted as deleted after the
/// cache is read back, so a file the system refused to unlock stays reported.
class LocalGroupRemoval {
  final int removed, kept, tasksForgotten, bytes;
  const LocalGroupRemoval({
    required this.removed,
    required this.kept,
    required this.tasksForgotten,
    required this.bytes,
  });
  bool get complete => kept == 0;
  String get caption => [
    if (removed > 0) '已删除 $removed 个文件 · ${localBytesLabel(bytes)}',
    if (tasksForgotten > 0) '清掉 $tasksForgotten 条未完成的下载',
    if (kept > 0) '$kept 个正在使用中或暂时删不掉',
    if (removed == 0 && tasksForgotten == 0 && kept == 0) '没有可删除的缓存',
  ].join('，');
}

/// Deletes a whole drama's cached files and its unfinished queue records in one
/// pass. The per-file row stays available because a drama can hold one episode
/// the viewer still wants; this is the only path that answers 「这部剧我不看了」.
Future<LocalGroupRemoval> removeLocalDrama(
  AppRuntime runtime,
  LocalDramaGroup group,
) async {
  if (runtime is! LocalMediaRuntime) {
    throw StateError('这台设备暂时读不到本地缓存，未删除任何文件');
  }
  final attempted = {for (final f in group.files) '${f.vid}_${f.quality}'};
  for (final file in group.files) {
    if (file.inUse) continue;
    try {
      await runtime.evict(file.vid, quality: file.quality);
    } catch (_) {
      // The player took the file between the list and the delete; the read-back
      // below is what decides whether it is gone, not this exception.
    }
  }
  final remaining = {
    for (final f in await runtime.localEpisodes()) '${f.vid}_${f.quality}',
  };
  final gone = attempted.where((key) => !remaining.contains(key)).toSet();
  final bytes = group.files
      .where((f) => gone.contains('${f.vid}_${f.quality}'))
      .fold(0, (sum, f) => sum + f.bytes);
  var tasksForgotten = 0;
  if (runtime is DownloadRuntime && !group.unidentified) {
    final manager = runtime.downloads;
    for (final task
        in manager.tasks.where((t) => t.drama.id == group.id).toList()) {
      // A ready task's record was already dropped with its file; anything still
      // queued, paused or failed only disappears with the drama.
      if (task.phase == DownloadPhase.ready) continue;
      await manager.forget(task.episode.vid, task.quality);
      tasksForgotten++;
    }
  }
  return LocalGroupRemoval(
    removed: gone.length,
    kept: attempted.length - gone.length,
    tasksForgotten: tasksForgotten,
    bytes: bytes,
  );
}
