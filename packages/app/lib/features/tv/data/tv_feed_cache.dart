import 'package:hongguo_api/hongguo_api.dart';

typedef TvFeedKey = ({
  String genre,
  String theme,
  String query,
  String sort,
  int pageSize,
});

/// Bounded, page-lifetime cache. Only first pages are cached so a refreshed
/// cursor is never mixed with continuation pages from an older server snapshot.
class TvFeedCache {
  final int capacity;
  final _pages = <TvFeedKey, CatalogPage>{};
  TvFeedCache({this.capacity = 32}) : assert(capacity > 0);

  CatalogPage? read(TvFeedKey key) {
    final page = _pages.remove(key);
    if (page != null) _pages[key] = page;
    return page;
  }

  CatalogPage reconcile(TvFeedKey key, CatalogPage fresh) {
    final previous = read(key);
    final old = {for (final d in previous?.items ?? <Drama>[]) d.id: d};
    final ids = <String>{};
    final merged = <Drama>[];
    for (final d in fresh.items) {
      if (d.id.isEmpty || !ids.add(d.id)) continue;
      final cached = old[d.id];
      final value = cached == null
          ? d
          : Drama(
              id: d.id,
              title: d.title.isEmpty ? cached.title : d.title,
              cover: d.cover.isEmpty ? cached.cover : d.cover,
              intro: d.intro.isEmpty ? cached.intro : d.intro,
              episodeCount: d.episodeCount > 0
                  ? d.episodeCount
                  : cached.episodeCount,
            );
      merged.add(cached != null && sameDrama(cached, value) ? cached : value);
    }
    final page = CatalogPage(
      List.unmodifiable(merged),
      nextCursor: fresh.nextCursor,
    );
    _pages[key] = page;
    while (_pages.length > capacity) {
      _pages.remove(_pages.keys.first);
    }
    return page;
  }

  static bool sameDrama(Drama a, Drama b) =>
      a.id == b.id &&
      a.title == b.title &&
      a.cover == b.cover &&
      a.intro == b.intro &&
      a.episodeCount == b.episodeCount;
}
