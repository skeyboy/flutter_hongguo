import 'package:hongguo_api/hongguo_api.dart';

import '../settings/settings_store.dart';

Map<String, dynamic> dramaJson(Drama d) => {
  'series_id': d.id,
  'series_title': d.title,
  'series_cover': d.cover,
  'series_intro': d.intro,
  'episode_cnt': d.episodeCount,
};

class FeedSnapshot {
  final CatalogPage page;
  final DateTime updated;
  const FeedSnapshot(this.page, this.updated);
}

/// Ordered snapshots and episode metadata. No session, video source URLs or content keys.
class LibraryCache {
  final PreferencesBackend? backend;
  final DateTime Function() now;
  final _feeds = <String, Map<String, dynamic>>{};
  final _details = <String, Map<String, dynamic>>{};
  final _videoOwners = <String, String>{};
  final _feedDramas = <String, Drama>{};
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  LibraryCache({this.backend, DateTime Function()? now})
    : now = now ?? DateTime.now;

  Future<void> _load() => _loading ??= () async {
    try {
      final data = await backend?.read();
      if (data?['version'] != 1) return;
      for (final pair in (data?['feeds'] as Map? ?? {}).entries) {
        if (pair.key is String && pair.value is Map) {
          _feeds[pair.key as String] = Map<String, dynamic>.from(
            pair.value as Map,
          );
        }
      }
      for (final pair in (data?['details'] as Map? ?? {}).entries) {
        if (pair.key is String && pair.value is Map) {
          _details[pair.key as String] = Map<String, dynamic>.from(
            pair.value as Map,
          );
        }
      }
    } catch (_) {
      /* A damaged snapshot must not prevent online browsing. */
    }
    _indexFeeds();
    _reindex();
  }();

  Future<FeedSnapshot?> readFeed(String key) async {
    await _load();
    try {
      final record = _feeds[key];
      if (record == null) return null;
      final at = DateTime.parse(record['updated'] as String);
      if (now().difference(at) > const Duration(days: 7)) return null;
      final items = (record['items'] as List)
          .map((e) => Drama.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      return FeedSnapshot(
        CatalogPage(items, nextCursor: record['cursor'] as String?),
        at,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> writeFeed(String key, CatalogPage page) async {
    await _load();
    _feeds.removeWhere((_, value) {
      final at = DateTime.tryParse('${value['updated']}');
      return at == null || now().difference(at) > const Duration(days: 7);
    });
    _feeds.remove(key);
    _feeds[key] = {
      'updated': now().toUtc().toIso8601String(),
      'items': page.items.take(500).map(dramaJson).toList(),
      'cursor': page.items.length > 500 ? null : page.nextCursor,
    };
    while (_feeds.length > 80) {
      _feeds.remove(_feeds.keys.first);
    }
    _indexFeeds();
    await _persist();
  }

  Future<void> clearFeeds() async {
    await _load();
    _feeds.clear();
    _feedDramas.clear();
    await _persist();
  }

  Drama _enrich(Drama value, Drama? previous) {
    final fromFeed = _feedDramas[value.id];
    String first(String a, String? b, String? c) => a.trim().isNotEmpty
        ? a
        : b?.trim().isNotEmpty == true
        ? b!
        : c ?? '';
    return Drama(
      id: value.id,
      title: first(value.title, previous?.title, fromFeed?.title),
      cover: first(value.cover, previous?.cover, fromFeed?.cover),
      intro: first(value.intro, previous?.intro, fromFeed?.intro),
      episodeCount: [
        value.episodeCount,
        previous?.episodeCount ?? 0,
        fromFeed?.episodeCount ?? 0,
      ].reduce((a, b) => a > b ? a : b),
    );
  }

  DramaDetail? _decodeDetail(String id) {
    try {
      final data = _details[id];
      if (data == null) return null;
      final drama = Drama.fromJson(
        Map<String, dynamic>.from(data['drama'] as Map),
      );
      final episodes = (data['episodes'] as List)
          .map(
            (e) => Episode(
              vid: e['vid'] as String,
              index: e['index'] as int,
              title: e['title'] as String? ?? '',
            ),
          )
          .where((e) => e.vid.isNotEmpty && e.index > 0)
          .toList();
      return DramaDetail(_enrich(drama, null), episodes);
    } catch (_) {
      return null;
    }
  }

  void _indexFeeds() {
    _feedDramas.clear();
    for (final record in _feeds.values) {
      for (final raw
          in record['items'] is List ? record['items'] as List : const []) {
        if (raw is! Map) continue;
        final d = Drama.fromJson(Map<String, dynamic>.from(raw));
        if (d.id.isNotEmpty) _feedDramas[d.id] = d;
      }
    }
  }

  void _reindex() {
    _videoOwners.clear();
    final ambiguous = <String>{};
    for (final record in _details.entries) {
      final raw = record.value['episodes'];
      if (raw is! List) continue;
      for (final episode in raw) {
        if (episode is! Map || episode['vid'] is! String) continue;
        final vid = episode['vid'] as String;
        final previous = _videoOwners[vid];
        if (previous != null && previous != record.key) ambiguous.add(vid);
        _videoOwners[vid] = record.key;
      }
    }
    for (final vid in ambiguous) {
      _videoOwners.remove(vid);
    }
  }

  Future<void> rememberDetail(DramaDetail detail) async {
    await _load();
    if (detail.drama.id.isEmpty) return;
    final old = _decodeDetail(detail.drama.id);
    final episodes = {for (final e in old?.episodes ?? <Episode>[]) e.vid: e};
    for (final e in detail.episodes) {
      if (e.vid.isEmpty || e.index <= 0) continue;
      final previous = episodes[e.vid];
      episodes[e.vid] = Episode(
        vid: e.vid,
        index: e.index,
        title: e.title.isNotEmpty ? e.title : previous?.title ?? '',
      );
    }
    final ordered = episodes.values.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final enriched = _enrich(detail.drama, old?.drama);
    final total = ordered.fold(
      enriched.episodeCount,
      (count, e) => e.index > count ? e.index : count,
    );
    _details[detail.drama.id] = {
      'drama': dramaJson(
        Drama(
          id: enriched.id,
          title: enriched.title,
          cover: enriched.cover,
          intro: enriched.intro,
          episodeCount: total > ordered.length ? total : ordered.length,
        ),
      ),
      'episodes': [
        for (final e in ordered)
          {'vid': e.vid, 'index': e.index, 'title': e.title},
      ],
    };
    // Media metadata is independent of the expiring/bounded feed snapshots.
    _reindex();
    await _persist();
  }

  Future<DramaDetail?> readDetail(String seriesId) async {
    await _load();
    return _decodeDetail(seriesId);
  }

  Future<DramaDetail?> detailForVideo(String vid) async {
    await _load();
    final owner = _videoOwners[vid];
    return owner == null ? null : _decodeDetail(owner);
  }

  Future<Map<String, DramaDetail>> detailsForVideos(
    Iterable<String> videos,
  ) async {
    await _load();
    final decoded = <String, DramaDetail?>{};
    final result = <String, DramaDetail>{};
    for (final vid in videos) {
      final owner = _videoOwners[vid];
      if (owner == null) continue;
      final detail = decoded.putIfAbsent(owner, () => _decodeDetail(owner));
      if (detail != null) result[vid] = detail;
    }
    return result;
  }

  Future<List<Drama>> knownDramas([String query = '']) async {
    await _load();
    final dramas = Map<String, Drama>.of(_feedDramas);
    for (final id in _details.keys) {
      final detail = _decodeDetail(id);
      if (detail != null) dramas[id] = detail.drama;
    }
    final text = query.trim().toLowerCase();
    return dramas.values
        .where((d) => d.title.toLowerCase().contains(text))
        .toList();
  }

  Future<void> _persist() {
    final operation = _writes.then((_) async {
      await backend?.write({
        'version': 1,
        'feeds': _feeds,
        'details': _details,
      });
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }
}
