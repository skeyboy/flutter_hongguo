import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/features/tv/data/tv_feed_cache.dart';

void main() {
  const key = (
    genre: 'short_play',
    theme: 't1',
    query: '',
    sort: 'hot_score',
    pageSize: 30,
  );
  test('reconcile updates metadata, order and cursor, removes stale rows and reuses unchanged objects', () {
    final cache = TvFeedCache();
    const unchanged = Drama(id: 'a', title: 'A');
    cache.reconcile(
      key,
      const CatalogPage([
        unchanged,
        Drama(id: 'b', title: 'old'),
        Drama(id: 'removed', title: 'old'),
      ], nextCursor: 'old'),
    );
    final fresh = cache.reconcile(
      key,
      CatalogPage([
        const Drama(id: 'b', title: 'updated'),
        Drama(id: 'a', title: 'A'),
        const Drama(id: 'b', title: 'duplicate'),
        const Drama(id: '', title: 'invalid'),
        const Drama(id: 'new', title: 'new'),
      ], nextCursor: 'new'),
    );
    expect(fresh.items.map((d) => d.id), ['b', 'a', 'new']);
    expect(fresh.items.first.title, 'updated');
    expect(identical(fresh.items[1], unchanged), isTrue);
    expect(fresh.nextCursor, 'new');
  });
  test('partial network metadata preserves cached cover and details', () {
    final cache = TvFeedCache();
    cache.reconcile(
      key,
      const CatalogPage([
        Drama(
          id: 'a',
          title: 'old',
          cover: 'cover',
          intro: 'intro',
          episodeCount: 12,
        ),
      ]),
    );
    final page = cache.reconcile(
      key,
      const CatalogPage([Drama(id: 'a', title: 'updated')]),
    );
    expect(page.items.single.title, 'updated');
    expect(page.items.single.cover, 'cover');
    expect(page.items.single.intro, 'intro');
    expect(page.items.single.episodeCount, 12);
  });
  test('cache isolates preferences and evicts least recently used entry', () {
    final cache = TvFeedCache(capacity: 2);
    final other = (
      genre: key.genre,
      theme: 't2',
      query: '',
      sort: key.sort,
      pageSize: 30,
    );
    final changedSize = (
      genre: key.genre,
      theme: key.theme,
      query: '',
      sort: key.sort,
      pageSize: 50,
    );
    cache.reconcile(key, const CatalogPage([]));
    cache.reconcile(other, const CatalogPage([]));
    expect(cache.read(key), isNotNull);
    cache.reconcile(changedSize, const CatalogPage([]));
    expect(cache.read(other), isNull);
    expect(cache.read(key), isNotNull);
    expect(cache.read(changedSize), isNotNull);
  });
}
