import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/catalog/library_cache.dart';
import 'package:hongguo_app/settings/settings_store.dart';

class MemoryBackend implements PreferencesBackend {
  Map<String, dynamic>? data;
  bool failWrite = false;
  @override
  Future<Map<String, dynamic>?> read() async => data;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    if (failWrite) throw StateError('disk full');
    data = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  }
}

void main() {
  test('feed order, fields and cursor survive restart; keys and expiry are isolated', () async {
    final backend = MemoryBackend();
    final at = DateTime(2026, 10, 19);
    final cache = LibraryCache(backend: backend, now: () => at);
    await cache.writeFeed(
      'recommend',
      const CatalogPage([
        Drama(
          id: '2',
          title: '第二',
          cover: 'cover',
          intro: '简介',
          episodeCount: 6,
        ),
        Drama(id: '1', title: '第一'),
      ], nextCursor: 'next'),
    );
    await cache.writeFeed(
      'genre',
      const CatalogPage([Drama(id: '3', title: '分类')]),
    );
    final restarted = LibraryCache(backend: backend, now: () => at);
    final feed = (await restarted.readFeed('recommend'))!;
    expect(feed.page.items.map((d) => d.id), ['2', '1']);
    expect(feed.page.items.first.episodeCount, 6);
    expect(feed.page.items.first.intro, '简介');
    expect(feed.page.nextCursor, 'next');
    expect((await restarted.readFeed('genre'))!.page.items.single.id, '3');
    expect(await restarted.readFeed('search'), isNull);
    expect(
      await LibraryCache(
        backend: backend,
        now: () => at.add(const Duration(days: 8)),
      ).readFeed('recommend'),
      isNull,
    );
  });
  test(
    'bounded snapshots do not retain a cursor after dropping rows',
    () async {
      final cache = LibraryCache();
      for (var i = 0; i < 81; i++) {
        await cache.writeFeed(
          '$i',
          CatalogPage(
            List.generate(501, (n) => Drama(id: '$n', title: '$n')),
            nextCursor: 'later',
          ),
        );
      }
      expect(await cache.readFeed('0'), isNull);
      final page = (await cache.readFeed('80'))!.page;
      expect(page.items.length, 500);
      expect(page.nextCursor, isNull);
    },
  );
  test(
    'metadata survives restart; failed write does not poison subsequent writes',
    () async {
      final backend = MemoryBackend();
      final cache = LibraryCache(backend: backend);
      backend.failWrite = true;
      await expectLater(
        cache.writeFeed('a', const CatalogPage([])),
        throwsStateError,
      );
      backend.failWrite = false;
      await cache.rememberDetail(
        const DramaDetail(Drama(id: '1', title: '故事'), [
          Episode(vid: '99', index: 7),
        ]),
      );
      final stored = await LibraryCache(backend: backend).detailForVideo('99');
      expect(stored!.drama.title, '故事');
      expect(stored.episodes.single.index, 7);
      expect(await cache.detailForVideo('100'), isNull);
    },
  );
  test('malformed cache allows online replacement', () async {
    final backend = MemoryBackend()
      ..data = {
        'version': 1,
        'feeds': {
          'bad': {'items': 'broken'},
        },
      };
    final cache = LibraryCache(backend: backend);
    expect(await cache.readFeed('bad'), isNull);
    await cache.writeFeed(
      'bad',
      const CatalogPage([Drama(id: '4', title: '修复')]),
    );
    expect((await cache.readFeed('bad'))!.page.items.single.id, '4');
  });
  test('partial detail preserves title, poster and sibling episodes across restart', () async {
    final backend = MemoryBackend();
    final cache = LibraryCache(backend: backend);
    await cache.writeFeed(
      'home',
      const CatalogPage([
        Drama(
          id: '1',
          title: '首页标题',
          cover: 'https://img.example/cover',
          episodeCount: 20,
        ),
      ]),
    );
    await cache.rememberDetail(
      const DramaDetail(Drama(id: '1', title: ''), [
        Episode(vid: '11', index: 1, title: '初见'),
      ]),
    );
    await cache.rememberDetail(
      const DramaDetail(Drama(id: '1', title: ''), [
        Episode(vid: '12', index: 2),
      ]),
    );
    await cache.clearFeeds();
    final restored = LibraryCache(backend: backend);
    final detail = (await restored.detailForVideo('12'))!;
    expect(detail.drama.title, '首页标题');
    expect(detail.drama.cover, 'https://img.example/cover');
    expect(detail.drama.episodeCount, 20);
    expect(detail.episodes.map((e) => e.vid), ['11', '12']);
    expect((await restored.detailForVideo('11'))!.episodes.first.title, '初见');
    final batch = await restored.detailsForVideos(['11', '12', 'unknown']);
    expect(batch.keys, ['11', '12']);
    expect(identical(batch['11'], batch['12']), isTrue);
  });
  test('ambiguous video ownership does not invent a series match', () async {
    final cache = LibraryCache();
    for (final id in ['1', '2']) {
      await cache.rememberDetail(
        DramaDetail(Drama(id: id, title: '剧$id'), const [
          Episode(vid: '11', index: 1),
        ]),
      );
    }
    expect(await cache.detailForVideo('11'), isNull);
  });
}
