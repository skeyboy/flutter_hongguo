import 'package:hongguo_api/hongguo_api.dart';

import '../platform/runtime_contract.dart';

class LocalDramaGroup {
  final String id;
  final Drama drama;
  final List<LocalEpisode> files;
  final bool unidentified;
  const LocalDramaGroup({
    required this.id,
    required this.drama,
    required this.files,
    this.unidentified = false,
  });
  int get episodeCount => files.map((e) => e.vid).toSet().length;
  int get bytes => files.fold(0, (sum, e) => sum + e.bytes);
  DateTime get modified =>
      files.map((e) => e.modified).reduce((a, b) => a.isAfter(b) ? a : b);
  String? get coverPath =>
      files.map((e) => e.coverPath).whereType<String>().firstOrNull;
  String get badge => unidentified
      ? '$episodeCount 个待识别视频'
      : '已缓存 $episodeCount${drama.episodeCount > 0 ? ' / ${drama.episodeCount}' : ''} 集';
  List<LocalEpisode> sortedFiles() =>
      List<LocalEpisode>.of(files)..sort((a, b) {
        final ai = episodeFor(a)?.index ?? 0, bi = episodeFor(b)?.index ?? 0;
        final order = ai.compareTo(bi);
        return order != 0
            ? order
            : a.vid != b.vid
            ? a.vid.compareTo(b.vid)
            : a.quality.compareTo(b.quality);
      });
  Episode? episodeFor(LocalEpisode file) =>
      file.detail?.episodes.where((e) => e.vid == file.vid).firstOrNull;
}

List<LocalDramaGroup> groupLocalEpisodes(List<LocalEpisode> files) {
  final buckets = <String, List<LocalEpisode>>{};
  for (final file in files) {
    final detail = file.detail;
    final confirmed =
        detail != null &&
        detail.drama.id.isNotEmpty &&
        detail.episodes.any((e) => e.vid == file.vid);
    final id = confirmed ? detail.drama.id : '__unidentified__';
    (buckets[id] ??= []).add(file);
  }
  final groups =
      buckets.entries.map((bucket) {
        final unknown = bucket.key == '__unidentified__';
        final sources = bucket.value
            .map((e) => e.detail?.drama)
            .whereType<Drama>()
            .toList();
        String field(String Function(Drama) read) =>
            sources.map(read).where((s) => s.trim().isNotEmpty).firstOrNull ??
            '';
        return LocalDramaGroup(
          id: bucket.key,
          files: List.unmodifiable(bucket.value),
          unidentified: unknown,
          drama: unknown
              ? const Drama(id: '__unidentified__', title: '待识别视频')
              : Drama(
                  id: bucket.key,
                  title: field((d) => d.title).isEmpty
                      ? '未命名剧目'
                      : field((d) => d.title),
                  cover: field((d) => d.cover),
                  intro: field((d) => d.intro),
                  episodeCount: sources.fold(
                    0,
                    (n, d) => d.episodeCount > n ? d.episodeCount : n,
                  ),
                ),
        );
      }).toList()..sort(
        (a, b) => a.unidentified != b.unidentified
            ? (a.unidentified ? 1 : -1)
            : b.modified.compareTo(a.modified),
      );
  return groups;
}

String localQualityLabel(String value) => switch (value) {
  'best' || 'auto' => '自动清晰度',
  _ => value,
};
String localBytesLabel(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
