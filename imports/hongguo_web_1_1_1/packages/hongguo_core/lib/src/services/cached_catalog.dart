import 'dart:convert';
import '../models/models.dart';
import '../ports/key_value_store.dart';
import '../ports/repository.dart';
import '../ports/runtime.dart';

/// Persists detail/episode metadata so an existing cached video can play offline.
class CachedCatalog implements CatalogRepository {
  final CatalogRepository source;
  final KeyValueStore store;
  final Clock clock;
  final Duration ttl;
  CachedCatalog(
    this.source,
    this.store, {
    this.clock = const SystemClock(),
    this.ttl = const Duration(hours: 6),
  });
  @override
  Future<Page<Series>> search(String query, {int offset = 0, int limit = 20}) =>
      source.search(query, offset: offset, limit: limit);
  @override
  Future<Page<Series>> browse({
    String genre = 'short_play',
    int offset = 0,
    int limit = 20,
    Set<String> seen = const {},
  }) => source.browse(genre: genre, offset: offset, limit: limit, seen: seen);
  @override
  Future<SeriesDetail> detail(String seriesId) async {
    if (!RegExp(r'^\d{1,30}$').hasMatch(seriesId))
      throw ArgumentError('Invalid series ID');
    SeriesDetail? cached;
    var at = 0;
    try {
      final raw = await store.read('detail-$seriesId');
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        at = intValue(j['at']);
        cached = SeriesDetail.fromJson(j);
      }
    } catch (_) {
      /* Corrupt or unavailable cache must not prevent a fresh request. */
    }
    if (cached != null && clock.milliseconds - at < ttl.inMilliseconds)
      return cached;
    try {
      final detail = await source.detail(seriesId);
      try {
        await store.write(
          'detail-$seriesId',
          jsonEncode({
            'at': clock.milliseconds,
            'meta': detail.series.toJson(),
            'episodes': [
              for (final e in detail.episodes)
                {
                  'vid': e.vid,
                  'index': e.index,
                  'title': e.title,
                  'duration': e.duration,
                },
            ],
          }),
        );
      } catch (_) {
        /* Metadata caching is best effort; media publication is strict. */
      }
      return detail;
    } catch (_) {
      if (cached != null) return cached;
      rethrow;
    }
  }
}
