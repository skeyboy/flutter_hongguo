import 'package:hongguo_api/hongguo_api.dart';

import '../catalog/local_library.dart';
import '../platform/runtime_contract.dart';

class LocalPlaybackQueue {
  final DramaDetail detail;
  final int initialPosition;
  const LocalPlaybackQueue(this.detail, this.initialPosition);
}

/// Only this series' completed local episodes; quality variants appear once.
LocalPlaybackQueue localPlaybackQueue(
  LocalDramaGroup group,
  LocalEpisode selected,
) {
  if (group.unidentified) {
    return LocalPlaybackQueue(
      DramaDetail(Drama(id: selected.vid, title: '本地视频 ${selected.vid}'), [
        Episode(vid: selected.vid, index: 1),
      ]),
      0,
    );
  }
  final byVideo = <String, Episode>{};
  for (final file in group.sortedFiles()) {
    final episode = group.episodeFor(file);
    if (episode != null) byVideo.putIfAbsent(episode.vid, () => episode);
  }
  final episodes = byVideo.values.toList();
  final start = episodes.indexWhere((e) => e.vid == selected.vid);
  if (start < 0) throw StateError('所选分集不在本地缓存列表中');
  return LocalPlaybackQueue(DramaDetail(group.drama, episodes), start);
}

String? localQualityFor(
  String vid,
  Iterable<LocalEpisode> files,
  String preferred,
) {
  final available = files
      .where((e) => e.vid == vid)
      .map((e) => e.quality)
      .toSet();
  for (final quality in [
    preferred,
    'best',
    '1080p',
    '720p',
    ...available.toList()..sort(),
  ]) {
    if (available.contains(quality)) return quality;
  }
  return null;
}

/// A missing episode must not silently skip part of the story during auto-next.
bool localEpisodesAreConsecutive(Episode current, Episode next) =>
    next.index == current.index + 1;
