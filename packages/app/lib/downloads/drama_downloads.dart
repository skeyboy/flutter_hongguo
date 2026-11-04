import 'package:hongguo_api/hongguo_api.dart';

import '../catalog/local_library.dart';
import '../platform/runtime_contract.dart';
import 'download_manager.dart';

/// One drama as 下载管理 sees it: the queue's records joined with the files that
/// are really on that drama's shelf. The card's counts, the drill-in rows and
/// 「删除本剧」 then describe one subject instead of three guesses about what is
/// offline -- a record whose file vanished and a file the queue never saw are
/// both visible in the same numbers the delete works on.
class DramaDownloads {
  final Drama drama;
  final List<EpisodeDownload> tasks;
  final List<LocalEpisode> files;
  const DramaDownloads({
    required this.drama,
    required this.tasks,
    required this.files,
  });

  String get id => drama.id;

  /// Distinct episodes across both sides, so a drama cached while playing and
  /// topped up from the picker is counted once per 集, not once per record.
  int get episodeCount => {
    for (final t in tasks) t.episode.vid,
    for (final f in files) f.vid,
  }.length;

  /// Watchable offline is what the disk says, not what a record claims.
  int get offlineCount => files.map((f) => f.vid).toSet().length;

  int get transferringCount => tasks
      .where(
        (t) =>
            t.phase == DownloadPhase.queued || t.phase == DownloadPhase.running,
      )
      .length;

  /// Everything that holds a record but is not moving and not finished: paused,
  /// failed and cancelled all answer with 继续下载 in the row list.
  int get resumableCount =>
      tasks.where((t) => !t.retained || t.phase == DownloadPhase.paused).length;

  int get bytes => files.fold(0, (sum, f) => sum + f.bytes);

  bool get hasInFlight => transferringCount > 0 || resumableCount > 0;
  bool get hasOffline => offlineCount > 0;

  /// Determinate by construction: a running episode contributes its own fraction
  /// and nothing else, so the bar settles when the queue settles. An
  /// indeterminate bar would keep `pumpAndSettle` spinning forever.
  double get progress {
    final total = episodeCount;
    if (total == 0) return 0;
    var done = offlineCount.toDouble();
    for (final task in tasks) {
      if (task.phase == DownloadPhase.running) {
        done += (task.fraction ?? 0).clamp(0.0, 1.0);
      }
    }
    return (done / total).clamp(0.0, 1.0);
  }

  /// 「已完成 3 / 8 集 · 下载中 2 · 待继续 1」 -- only the parts that are true.
  String get caption {
    final parts = ['已完成 $offlineCount / $episodeCount 集'];
    if (transferringCount > 0) parts.add('下载中 $transferringCount');
    if (resumableCount > 0) parts.add('待继续 $resumableCount');
    return parts.join(' · ');
  }
}

/// The queue grouped by drama, each group joined with its shelf. A drama with
/// files but no record is the 离线剧集 page's subject, not this one's: 下载管理
/// lists what was asked for, and those files reach it from inside a listed
/// drama's row, where a pick and a playback cache sit side by side.
List<DramaDownloads> groupDramaDownloads(
  DownloadManager manager,
  List<LocalEpisode> files,
) {
  final records = <String, List<EpisodeDownload>>{};
  for (final task in manager.tasks) {
    (records[task.drama.id] ??= []).add(task);
  }
  final shelves = <String, List<LocalEpisode>>{
    for (final group in groupLocalEpisodes(files))
      if (!group.unidentified) group.id: group.files,
  };
  return [
    for (final entry in records.entries)
      DramaDownloads(
        drama: entry.value.first.drama,
        tasks: entry.value,
        files: shelves[entry.key] ?? const [],
      ),
  ];
}

/// Cheap fingerprint of what the queue *is*, ignoring how far each job got: a
/// record that lands, fails or pauses changes what the shelf should hold, so that
/// is the one moment a page re-reads the disk. Progress ticks fire the listener
/// many times a second and never change the answer.
String queueSignature(DownloadManager manager) =>
    [for (final task in manager.tasks) '${task.key}:${task.phase}'].join();

/// One episode of one drama as the progress page lists it: the record the queue
/// holds, the file the disk holds, or a playback cache the queue never heard of.
class DownloadEpisodeRow {
  final int index;
  final String vid, quality;
  final EpisodeDownload? task;
  final LocalEpisode? file;
  const DownloadEpisodeRow({
    required this.index,
    required this.vid,
    required this.quality,
    this.task,
    this.file,
  });

  String get key => '${vid}_$quality';
  bool get cachedOnly => task == null && file != null;
  bool get isRunning => task?.phase == DownloadPhase.running;
}

/// The join, on `vid_quality` -- the same key the queue and the file store use.
/// Two tracks of one episode are two rows, because deleting one leaves the
/// other, and a list that merged them would promise more than it does.
List<DownloadEpisodeRow> downloadEpisodeRows(
  List<EpisodeDownload> tasks,
  List<LocalEpisode> files,
  LocalDramaGroup? group,
) {
  final rows = <String, DownloadEpisodeRow>{};
  for (final task in tasks) {
    rows[task.key] = DownloadEpisodeRow(
      index: task.episode.index,
      vid: task.episode.vid,
      quality: task.quality,
      task: task,
    );
  }
  for (final file in files) {
    final key = '${file.vid}_${file.quality}';
    final known = rows[key];
    rows[key] = DownloadEpisodeRow(
      index: known?.index ?? group?.episodeFor(file)?.index ?? 0,
      vid: file.vid,
      quality: file.quality,
      task: known?.task,
      file: file,
    );
  }
  return rows.values.toList()..sort((a, b) {
    final order = a.index.compareTo(b.index);
    return order != 0 ? order : a.quality.compareTo(b.quality);
  });
}
