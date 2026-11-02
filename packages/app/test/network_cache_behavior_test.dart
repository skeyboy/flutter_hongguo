import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/catalog/library_cache.dart';
import 'package:hongguo_app/features/library_page.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'interaction_cache_test.dart'
    show ControlledCatalog, CacheRuntime, mount;

class ScopedCatalog extends ControlledCatalog {
  final scopes = <CatalogRequestScope?>[];
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) {
    scopes.add(CatalogRequestScope.current);
    return super.browse(
      genre: genre,
      sort: sort,
      theme: theme,
      cursor: cursor,
      seen: seen,
    );
  }
}

/// Records where each 问话 was pointed, because the launch behaviour is now a
/// claim about the request: a relaunch must ask at the stored position and with
/// the stored rows as the exclusion list, and nothing in the client may move it
/// by itself.
class ResumeCatalog extends ControlledCatalog {
  final asks = <({List<String> seen, String? cursor})>[];
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) {
    asks.add((cursor: cursor, seen: seen));
    return super.browse(
      genre: genre,
      sort: sort,
      theme: theme,
      cursor: cursor,
      seen: seen,
    );
  }
}

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'fresh cache skips refresh and explicit refresh retains data on failure at $width',
      (t) async {
        final catalog = ControlledCatalog();
        final runtime = CacheRuntime(catalog)
          ..settings = const AppSettings(autoLoadMore: false);
        addTearDown(runtime.dispose);
        await mount(t, runtime, Size(width, 900));
        catalog.pending[0].complete(
          const CatalogPage([Drama(id: '1', title: '已缓存发现')]),
        );
        await t.pumpAndSettle();
        await t.tap(find.text('分类').first);
        await t.pump(const Duration(milliseconds: 300));
        catalog.pending[1].complete(
          const CatalogPage([Drama(id: '2', title: '已缓存分类')]),
        );
        await t.pumpAndSettle();
        // Swiping back to a page the viewer already loaded keeps its rows on
        // screen and asks for them again in the background -- the same promise
        // a kept theme makes.
        await t.tap(find.text('发现').first);
        await t.pump(const Duration(milliseconds: 300));
        await t.pump(const Duration(milliseconds: 300));
        expect(catalog.pending, hasLength(3));
        expect(find.text('已缓存发现'), findsWidgets);
        final dynamic state = t.state(find.byType(LibraryPage));
        expect(state.feed.refreshing, isTrue);
        catalog.pending[2].completeError(const CatalogError('offline'));
        await t.pumpAndSettle();
        expect(find.text('已缓存发现'), findsWidgets);
        expect(find.text('网络刷新失败，仍显示上次结果。'), findsOneWidget);
        // 刷新 is the explicit path: it reads the stored page back first, so a
        // failure still leaves the cached rows and their message on screen.
        await t.tap(find.text('重试刷新'));
        await t.pump();
        await t.pump();
        expect(catalog.pending, hasLength(4));
        expect(find.text('已缓存发现'), findsWidgets);
        catalog.pending.last.completeError(const CatalogError('offline'));
        await t.pumpAndSettle();
        expect(find.text('已缓存发现'), findsWidgets);
        expect(find.text('网络刷新失败，正在显示本地缓存。'), findsOneWidget);
      },
    );
    testWidgets('switch and dispose cancel caller scopes at $width', (t) async {
      final catalog = ScopedCatalog();
      final runtime = CacheRuntime(catalog)
        ..settings = const AppSettings(autoLoadMore: false);
      addTearDown(runtime.dispose);
      await mount(t, runtime, Size(width, 900));
      expect(catalog.scopes.first, isNotNull);
      await t.tap(find.text('分类').first);
      await t.pump(const Duration(milliseconds: 300));
      expect(catalog.scopes.first!.isCancelled, isTrue);
      expect(catalog.scopes.last!.isCancelled, isFalse);
      catalog.pending.last.complete(
        const CatalogPage([Drama(id: '2', title: '当前内容')]),
      );
      catalog.pending.first.complete(
        const CatalogPage([Drama(id: '1', title: '旧内容')]),
      );
      await t.pumpAndSettle();
      expect(find.text('当前内容'), findsWidgets);
      expect(find.text('旧内容'), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
      expect(catalog.scopes.last!.isCancelled, isTrue);
    });
  }
  testWidgets('a relaunch paints the stored rows, then asks one page deeper', (
    t,
  ) async {
    final catalog = ResumeCatalog();
    final clock = DateTime.utc(2026, 10, 21);
    final runtime = CacheRuntime(catalog, LibraryCache(now: () => clock))
      ..settings = const AppSettings(autoLoadMore: false);
    addTearDown(runtime.dispose);
    await mount(t, runtime, const Size(390, 900));
    // The first launch has no history, so it asks the head of the list -- and
    // the page it gets hands back the position after itself.
    expect(catalog.asks.single.cursor, isNull);
    expect(catalog.asks.single.seen, isEmpty);
    catalog.pending.first.complete(
      const CatalogPage([Drama(id: '1', title: '第一屏')], nextCursor: '18'),
    );
    await t.pumpAndSettle();
    // Close the page and mount it again -- the same runtime, so the disk
    // snapshot survives, and at this frozen clock it is zero seconds old. The
    // age guard would serve those rows again and never ask; a launch has to ask,
    // and it has to ask *past* the rows already on screen because upstream
    // answers an identical request with the identical page.
    await t.pumpWidget(const SizedBox.shrink());
    await mount(t, runtime, const Size(390, 900));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('第一屏'), findsWidgets);
    expect(catalog.asks, hasLength(2));
    expect(catalog.asks[1].cursor, '18');
    expect(catalog.asks[1].seen, ['1']);
    final dynamic state = t.state(find.byType(LibraryPage));
    expect(state.feed.refreshing, isTrue);
    catalog.pending.last.complete(
      const CatalogPage([Drama(id: '2', title: '第二屏')], nextCursor: '36'),
    );
    await t.pumpAndSettle();
    expect(find.text('第二屏'), findsWidgets);
    expect(find.text('第一屏'), findsNothing);
    // A third launch walks on again rather than bouncing back to the first
    // screen: the position it resumes from is the one the second screen ended at.
    await t.pumpWidget(const SizedBox.shrink());
    await mount(t, runtime, const Size(390, 900));
    await t.pump(const Duration(milliseconds: 300));
    expect(catalog.asks[2].cursor, '36');
    expect(catalog.asks[2].seen, ['2']);
  });

  testWidgets(
    'a resumed ask that comes back empty falls back to the newest rows',
    (t) async {
      final catalog = ResumeCatalog();
      final clock = DateTime.utc(2026, 10, 21);
      final runtime = CacheRuntime(catalog, LibraryCache(now: () => clock))
        ..settings = const AppSettings(autoLoadMore: false);
      addTearDown(runtime.dispose);
      await mount(t, runtime, const Size(390, 900));
      catalog.pending.first.complete(
        const CatalogPage([Drama(id: '1', title: '第一屏')], nextCursor: '18'),
      );
      await t.pumpAndSettle();
      await t.pumpWidget(const SizedBox.shrink());
      await mount(t, runtime, const Size(390, 900));
      await t.pump(const Duration(milliseconds: 300));
      expect(catalog.asks[1].cursor, '18');
      // The pool shrank, so the resumed position answers with rows the viewer has
      // already seen -- the client's exclusion leaves nothing. The launch must not
      // paint an empty page: it re-asks the head with no exclusion.
      catalog.pending[1].complete(const CatalogPage([]));
      await t.pump(const Duration(milliseconds: 300));
      expect(catalog.asks, hasLength(3));
      expect(catalog.asks[2].cursor, isNull);
      expect(catalog.asks[2].seen, isEmpty);
      catalog.pending.last.complete(
        const CatalogPage([Drama(id: '3', title: '最新的一屏')], nextCursor: '18'),
      );
      await t.pumpAndSettle();
      expect(find.text('最新的一屏'), findsWidgets);
    },
  );

  testWidgets('a walk past the bound starts at the newest rows again', (
    t,
  ) async {
    final catalog = ResumeCatalog();
    final clock = DateTime.utc(2026, 10, 21);
    final runtime = CacheRuntime(catalog, LibraryCache(now: () => clock))
      ..settings = const AppSettings(autoLoadMore: false);
    addTearDown(runtime.dispose);
    await mount(t, runtime, const Size(390, 900));
    // A viewer who paged this feed nine screens deep leaves the stored position
    // far behind the head of the list.
    catalog.pending.first.complete(
      const CatalogPage([Drama(id: '9', title: '走到底的那一屏')], nextCursor: '162'),
    );
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox.shrink());
    await mount(t, runtime, const Size(390, 900));
    await t.pump(const Duration(milliseconds: 300));
    // The bound is reached, so the walk is over: this launch asks the head --
    // where the newest 内容 lives -- instead of spending a request on a position
    // it has already given up on.
    expect(catalog.asks, hasLength(2));
    expect(catalog.asks[1].cursor, isNull);
    expect(find.text('走到底的那一屏'), findsWidgets);
  });
}
