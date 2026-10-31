import '../catalog/local_library.dart';
import '../platform/runtime_contract.dart';

class EpisodePull {
  final int online, cached, added;
  final String quality;
  const EpisodePull({
    required this.online,
    required this.cached,
    required this.added,
    required this.quality,
  });
  bool get hasNew => added > 0;
  String get caption => added > 0
      ? '在线共 $online 集 · 本地 $cached 集 · 新加入 $added 集下载（${localQualityLabel(quality)}）'
      : online > 0 && cached >= online
      ? '已是最新：在线 $online 集，本地都缓存好了'
      : '在线共 $online 集 · 本地 $cached 集 · 没有可新增的集数';
}

/// Asks the catalog for the drama a cache group belongs to, keeps the answer as
/// the local metadata, and queues only the episodes the phone does not have yet.
/// A cached drama is the one place where 「下载更多」 has a real subject: the queue
/// already knows which series and which quality the viewer picked.
Future<EpisodePull> pullLatestEpisodes(
  AppRuntime runtime,
  LocalDramaGroup group,
) async {
  if (group.unidentified || group.drama.id.isEmpty) {
    throw StateError('这部剧还没有剧目标识，请先补全剧目信息再拉取最新剧集');
  }
  final fresh = await runtime.catalog.detail(group.drama.id);
  await rememberDramaMetadata(runtime, fresh);
  final have = {for (final f in group.files) f.vid};
  final quality = _preferredQuality(group);
  final missing = <int>[];
  for (var i = 0; i < fresh.episodes.length; i++) {
    final episode = fresh.episodes[i];
    if (have.contains(episode.vid)) continue;
    if (runtime is DownloadRuntime &&
        (runtime.downloads.taskFor(episode.vid, quality)?.retained ?? false)) {
      continue;
    }
    missing.add(i);
  }
  var added = 0;
  if (missing.isNotEmpty && runtime is DownloadRuntime) {
    added = await runtime.downloads.enqueue(fresh, missing, quality);
  }
  return EpisodePull(
    online: fresh.episodes.length,
    cached: have.length,
    added: added,
    quality: quality,
  );
}

/// New episodes continue the quality the rest of the drama was cached at; a
/// group with only unidentified leftovers falls back to the automatic track.
String _preferredQuality(LocalDramaGroup group) {
  final counts = <String, int>{};
  for (final file in group.files) {
    counts[file.quality] = (counts[file.quality] ?? 0) + 1;
  }
  String? best;
  for (final entry in counts.entries) {
    if (best == null || entry.value > (counts[best] ?? 0)) best = entry.key;
  }
  return best != null && RegExp(r'^(best|auto|\d{3,4}p)$').hasMatch(best)
      ? best
      : 'best';
}
