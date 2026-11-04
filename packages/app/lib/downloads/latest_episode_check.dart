import 'package:hongguo_api/hongguo_api.dart';

import '../catalog/local_library.dart';
import '../platform/runtime_contract.dart';

/// What 「检查最新剧集」 answers with: how long the series is online, how much of
/// it this shelf holds, and how many episodes a pick could still name. Nothing
/// here has been queued -- the check is a read, and 下载选集 is the only way in.
class EpisodeCheck {
  final int online, cached, downloadable, inQueue;
  final String quality;
  const EpisodeCheck({
    required this.online,
    required this.cached,
    required this.downloadable,
    required this.inQueue,
    required this.quality,
  });
  bool get hasNew => downloadable > 0;
  String get caption {
    if (downloadable > 0) {
      final waiting = inQueue > 0 ? '，另有 $inQueue 集已在下载中' : '';
      return '在线共 $online 集 · 本地 $cached 集 · $downloadable 集可下载，用「选择下载新集」挑要补的（${localQualityLabel(quality)}）$waiting';
    }
    if (online > 0 && cached >= online) {
      return '已是最新：在线 $online 集，本地都缓存好了';
    }
    if (inQueue > 0) {
      return '在线共 $online 集 · 本地 $cached 集 · 还差的 $inQueue 集已在下载中';
    }
    return '在线共 $online 集 · 本地 $cached 集 · 没有可新增的集数';
  }
}

/// What the catalog says a cached drama has online now, and which of those
/// episodes this shelf still cannot offer offline.
class OnlineEpisodes {
  final DramaDetail detail;

  /// Positions the disk does not hold and the queue has not been asked for --
  /// the cells 下载选集 can actually offer.
  final List<int> missing;

  /// Positions still missing from disk but held by a queue record, so a report
  /// can say 已在下载中 rather than counting them as new.
  final int inQueue;
  final String quality;
  final int cached;
  const OnlineEpisodes({
    required this.detail,
    required this.missing,
    required this.inQueue,
    required this.quality,
    required this.cached,
  });
  bool get hasNew => missing.isNotEmpty;
}

/// The one online read behind both shelf actions: ask for the drama a cache
/// group belongs to, keep the answer as the local metadata, and report the
/// episodes the phone neither holds on disk nor already keeps in the queue.
/// The check stops at that answer; 下载选集 is what turns the gap into transfers.
Future<OnlineEpisodes> scanOnlineEpisodes(
  AppRuntime runtime,
  LocalDramaGroup group,
) async {
  if (group.unidentified || group.drama.id.isEmpty) {
    throw StateError('这部剧还没有剧目标识，请先补全剧目信息再检查最新剧集');
  }
  final fresh = await runtime.catalog.detail(group.drama.id);
  await rememberDramaMetadata(runtime, fresh);
  final have = {for (final f in group.files) f.vid};
  final quality = _preferredQuality(group);
  final missing = <int>[];
  var inQueue = 0;
  for (var i = 0; i < fresh.episodes.length; i++) {
    final episode = fresh.episodes[i];
    if (have.contains(episode.vid)) continue;
    if (runtime is DownloadRuntime &&
        (runtime.downloads.taskFor(episode.vid, quality)?.retained ?? false)) {
      inQueue++;
      continue;
    }
    missing.add(i);
  }
  return OnlineEpisodes(
    detail: fresh,
    missing: missing,
    inQueue: inQueue,
    quality: quality,
    cached: have.length,
  );
}

/// Asks the catalog for the drama a cache group belongs to and keeps the answer
/// as the local metadata, then reports the gap -- without queueing it. This used
/// to enqueue the whole gap on contact, which put transfers in 下载中 that nobody
/// named; 选择下载新集 is the only way a new episode reaches the queue now.
Future<EpisodeCheck> checkLatestEpisodes(
  AppRuntime runtime,
  LocalDramaGroup group,
) async {
  final scan = await scanOnlineEpisodes(runtime, group);
  return EpisodeCheck(
    online: scan.detail.episodes.length,
    cached: scan.cached,
    downloadable: scan.missing.length,
    inQueue: scan.inQueue,
    quality: scan.quality,
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
