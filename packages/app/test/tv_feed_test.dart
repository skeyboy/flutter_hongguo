import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_tv/hongguo_tv.dart';
import 'package:hongguo_app/features/tv/tv_library_page.dart';
import 'package:hongguo_app/features/tv/tv_feed_page.dart';
import 'package:hongguo_app/features/local_cache_page.dart';
import 'package:hongguo_app/features/my_page.dart';
import 'package:auto_route/auto_route.dart';

import 'fakes.dart';

class FeedCatalog extends FakeCatalog {
  final calls =
      <({String genre, String sort, String? theme, String? cursor})>[];
  Completer<CatalogPage>? pendingPage;
  Completer<CatalogPage>? pendingFirst;
  bool failMore = false, duplicates = false;
  int firstCount = 30;
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) async {
    calls.add((genre: genre, sort: sort, theme: theme, cursor: cursor));
    if (cursor == null && pendingFirst != null) return pendingFirst!.future;
    if (cursor != null && failMore) throw const CatalogError('续页失败');
    if (cursor != null && pendingPage != null) return pendingPage!.future;
    final offset = cursor == null || duplicates ? 0 : 30;
    return CatalogPage(
      [
        for (
          var i = offset;
          i < offset + (cursor == null ? firstCount : 30);
          i++
        )
          Drama(id: '$genre-${theme ?? "all"}-$i', title: '剧目 $i'),
      ],
      nextCursor: cursor == null
          ? '30'
          : duplicates
          ? '${int.parse(cursor) + 1}'
          : null,
    );
  }

  @override
  Future<List<CatalogFilter>> themes(String genre) async => [
    for (var i = 0; i < 24; i++) CatalogFilter('题材 $i', 't$i'),
  ];
}

Future<void> mount(WidgetTester t, FakeRuntime runtime) async {
  await t.binding.setSurfaceSize(const Size(1280, 720));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      builder: (_, child) =>
          TvEnvironment(enabled: true, child: TvNavigation(child: child!)),
      home: TvLibraryPage(runtime: runtime),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('local cache and My are independent retained sidebar routes', (
    t,
  ) async {
    final r = FakeRuntime(FeedCatalog());
    addTearDown(r.dispose);
    await mount(t, r);
    Future<void> key(LogicalKeyboardKey k) async {
      await t.sendKeyEvent(k);
      await t.pumpAndSettle();
    }

    for (var i = 0; i < 3; i++) {
      await key(LogicalKeyboardKey.arrowDown);
    }
    final cache = t.state(find.byType(LocalCachePage));
    await key(LogicalKeyboardKey.arrowDown);
    final my = t.state(find.byType(MyPage));
    await key(LogicalKeyboardKey.arrowUp);
    expect(t.state(find.byType(LocalCachePage)), same(cache));
    await key(LogicalKeyboardKey.arrowDown);
    expect(t.state(find.byType(MyPage)), same(my));
  });
  testWidgets('sidebar focus alone activates all five retained routes', (
    t,
  ) async {
    final c = FeedCatalog();
    final r = FakeRuntime(c);
    addTearDown(r.dispose);
    await mount(t, r);
    for (var index = 1; index < 5; index++) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'nav-$index');
      final nav = t.widget<TvFocusable>(
        find.byWidgetPredicate(
          (w) => w is TvFocusable && w.focusNode?.debugLabel == 'nav-$index',
        ),
      );
      expect(nav.selected, isTrue);
      if (index < 3) {
        expect(
          c.calls.last.genre,
          ['short_play', 'comic_series', 'ai_series'][index],
        );
      }
    }
    for (var index = 3; index >= 0; index--) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'nav-$index');
    }
  });

  testWidgets(
    'comic left/right pane transfers preserve selected sidebar, theme, card and requests',
    (t) async {
      final c = FeedCatalog();
      final r = FakeRuntime(c);
      addTearDown(r.dispose);
      await mount(t, r);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pumpAndSettle();
      expect(c.calls.last.genre, 'comic_series');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pumpAndSettle();
      final theme = t.widget<TvFocusable>(
        find.byKey(const ValueKey('tv-theme-t3')),
      );
      theme.focusNode!.requestFocus();
      await t.pumpAndSettle();
      final card = t.widget<TvFocusable>(
        find.byKey(const ValueKey('comic_series-t3-0')),
      );
      card.focusNode!.requestFocus();
      await t.pumpAndSettle();
      final gridState = t.state(find.byType(TvGrid));
      final calls = c.calls.length;
      for (var round = 0; round < 3; round++) {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await t.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'nav-1');
        expect(c.calls.length, calls);
        await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await t.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'tv-grid-comic_series-t3-0',
        );
        expect(t.state(find.byType(TvGrid)), same(gridState));
        expect(
          t
              .widget<TvFocusable>(find.byKey(const ValueKey('tv-theme-t3')))
              .selected,
          isTrue,
        );
        expect(c.calls.length, calls);
      }
      // A queued card move must not steal focus back after an immediate Left.
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'nav-1');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv-grid-comic_series-t3-0',
      );
      // Changing the sidebar route and returning keeps this genre's own page.
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pumpAndSettle();
      expect(c.calls.last.genre, 'ai_series');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv-grid-comic_series-t3-0',
      );
      expect(t.state(find.byType(TvGrid)), same(gridState));
    },
  );
  testWidgets(
    'auto_route keeps each theme grid, scroll and loaded pages through background refresh',
    (t) async {
      final c = FeedCatalog();
      final r = FakeRuntime(c);
      addTearDown(r.dispose);
      await mount(t, r);
      expect(
        find.byWidgetPredicate((w) => w is AutoTabsRouter),
        findsNWidgets(2),
      );
      void select(String id) => t
          .widget<TvFocusable>(find.byKey(ValueKey('tv-theme-$id')))
          .onActivate!();
      select('t1');
      await t.pumpAndSettle();
      await t.drag(find.byType(GridView), const Offset(0, -1000));
      await t.pumpAndSettle();
      final state = t.state(find.byType(TvGrid));
      final scroll = t.widget<GridView>(find.byType(GridView)).controller!;
      final offset = scroll.offset;
      final rect = t.getRect(find.byType(TvGrid));
      final length = t.widget<TvGrid>(find.byType(TvGrid)).ids.length;
      expect(offset, greaterThan(0));
      select('t2');
      await t.pumpAndSettle();
      c.pendingFirst = Completer<CatalogPage>();
      select('t1');
      await t.pump();
      expect(t.state(find.byType(TvGrid)), same(state));
      expect(scroll.offset, offset);
      expect(t.getRect(find.byType(TvGrid)), rect);
      expect(t.widget<TvGrid>(find.byType(TvGrid)).ids.length, length);
      await t.pump(const Duration(milliseconds: 250));
      expect(t.getRect(find.byType(TvGrid)), rect);
      c.pendingFirst!.complete(
        CatalogPage([
          for (var i = 0; i < 30; i++)
            Drama(id: 'short_play-t1-$i', title: '剧目 $i'),
        ], nextCursor: '30'),
      );
      await t.pumpAndSettle();
      expect(t.state(find.byType(TvGrid)), same(state));
      expect(scroll.offset, offset);
      expect(t.widget<TvGrid>(find.byType(TvGrid)).ids.length, length);
    },
  );

  testWidgets(
    'moving between visible cards never recenters or resizes the page',
    (t) async {
      final r = FakeRuntime(FeedCatalog());
      addTearDown(r.dispose);
      await mount(t, r);
      final rect = t.getRect(find.byType(TvGrid));
      final grid = t.widget<GridView>(find.byType(GridView));
      final first = t.widget<TvFocusable>(
        find.byKey(const ValueKey('short_play-all-0')),
      );
      first.focusNode!.requestFocus();
      await t.pumpAndSettle();
      final offset = grid.controller!.offset;
      for (var i = 0; i < 3; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await t.pumpAndSettle();
        expect(grid.controller!.offset, offset);
        expect(t.getRect(find.byType(TvGrid)), rect);
      }
    },
  );
  testWidgets(
    'search stays pinned beside themes and remote crosses the right edge in both directions',
    (t) async {
      final c = FeedCatalog();
      final r = FakeRuntime(c);
      addTearDown(r.dispose);
      await mount(t, r);
      final searchFinder = find.byWidgetPredicate(
        (w) => w is TvFocusable && w.focusNode?.debugLabel == 'tv-search',
      );
      final initial = t.getRect(searchFinder);
      final first = t.widget<TvFocusable>(
        find.byKey(const ValueKey('tv-theme-')),
      );
      first.focusNode!.requestFocus();
      await t.pumpAndSettle();
      for (var i = 0; i < 24; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await t.pumpAndSettle();
        expect(t.getRect(searchFinder), initial);
      }
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-search');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-last-theme-0');
      final rail = t.getRect(find.byKey(const ValueKey('tv-theme-scroll')));
      final last = t.getRect(find.byKey(const ValueKey('tv-theme-t23')));
      expect(last.right, lessThanOrEqualTo(rail.right + 1));
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await t.enterText(find.byType(TextField), '测试关键词');
      await t.testTextInput.receiveAction(TextInputAction.search);
      await t.pumpAndSettle();
      expect(find.text('搜索：测试关键词'), findsOneWidget);
      expect(find.byKey(const ValueKey('tv-theme-scroll')), findsOneWidget);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-search');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.pumpAndSettle();
      expect(find.text('搜索：测试关键词'), findsNothing);
      expect(c.calls.last.theme, 't23');
    },
  );
  testWidgets(
    'theme cache displays immediately, refreshes and survives network failure',
    (t) async {
      final c = FeedCatalog();
      final r = FakeRuntime(c);
      addTearDown(r.dispose);
      await mount(t, r);
      void select(String id) => t
          .widget<TvFocusable>(find.byKey(ValueKey('tv-theme-$id')))
          .onActivate!();
      select('t1');
      await t.pump(const Duration(milliseconds: 250));
      await t.pumpAndSettle();
      select('t2');
      await t.pump(const Duration(milliseconds: 250));
      await t.pumpAndSettle();
      c.pendingFirst = Completer<CatalogPage>();
      select('t1');
      await t.pump();
      expect(
        t.widget<TvGrid>(find.byType(TvGrid)).ids.first,
        'short_play-t1-0',
      );
      await t.pump(const Duration(milliseconds: 250));
      expect(c.calls.last.theme, 't1');
      expect(t.widget<TvGrid>(find.byType(TvGrid)).ids.length, 30);
      c.pendingFirst!.complete(
        const CatalogPage([
          Drama(id: 'short_play-t1-0', title: '更新的标题'),
          Drama(id: 'short_play-t1-0', title: '重复'),
          Drama(id: 'added', title: '新增剧目'),
        ]),
      );
      await t.pumpAndSettle();
      expect(find.text('更新的标题'), findsWidgets);
      expect(t.widget<TvGrid>(find.byType(TvGrid)).ids, [
        'short_play-t1-0',
        'added',
      ]);
      c.pendingFirst = null;
      select('t2');
      await t.pump(const Duration(milliseconds: 250));
      await t.pumpAndSettle();
      c.pendingFirst = Completer<CatalogPage>();
      select('t1');
      await t.pump(const Duration(milliseconds: 250));
      c.pendingFirst!.completeError(const CatalogError('offline'));
      await t.pumpAndSettle();
      expect(find.text('更新的标题'), findsWidgets);
      expect(find.text('重试'), findsOneWidget);
    },
  );
  testWidgets('a late first-page refresh cannot overwrite another theme', (
    t,
  ) async {
    final c = FeedCatalog();
    final r = FakeRuntime(c);
    addTearDown(r.dispose);
    await mount(t, r);
    final pending = Completer<CatalogPage>();
    c.pendingFirst = pending;
    t
        .widget<TvFocusable>(find.byKey(const ValueKey('tv-theme-t1')))
        .onActivate!();
    await t.pump(const Duration(milliseconds: 250));
    c.pendingFirst = null;
    t
        .widget<TvFocusable>(find.byKey(const ValueKey('tv-theme-t2')))
        .onActivate!();
    await t.pump(const Duration(milliseconds: 250));
    await t.pumpAndSettle();
    pending.complete(const CatalogPage([Drama(id: 'stale', title: '过期首屏')]));
    await t.pumpAndSettle();
    expect(t.widget<TvGrid>(find.byType(TvGrid)).ids.first, 'short_play-t2-0');
    expect(find.text('过期首屏'), findsNothing);
  });
  for (final pair in [
    (0, 'short_play'),
    (1, 'comic_series'),
    (2, 'ai_series'),
  ]) {
    testWidgets(
      '${pair.$2}: focus switches themes without confirm and reloads only final fast choice',
      (t) async {
        final c = FeedCatalog();
        final runtime = FakeRuntime(c);
        addTearDown(runtime.dispose);
        await mount(t, runtime);
        if (pair.$1 > 0) {
          final nav = t.widget<TvFocusable>(
            find.byWidgetPredicate(
              (w) =>
                  w is TvFocusable &&
                  w.focusNode?.debugLabel == 'nav-${pair.$1}',
            ),
          );
          nav.onActivate!();
          await t.pumpAndSettle();
        }
        final first = t.widget<TvFocusable>(
          find.byKey(const ValueKey('tv-theme-')),
        );
        first.focusNode!.requestFocus();
        await t.pumpAndSettle();
        final before = c.calls.length;
        for (var i = 0; i < 7; i++) {
          await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await t.pump(const Duration(milliseconds: 20));
        }
        await t.pump(const Duration(milliseconds: 250));
        await t.pumpAndSettle();
        expect(c.calls.length, before + 1);
        expect(c.calls.last.genre, pair.$2);
        expect(c.calls.last.theme, 't6');
        expect(find.text('加载更多'), findsNothing);
        expect(find.text('排序'), findsNothing);
      },
    );
  }
  testWidgets(
    'auto-pagination preserves items, bounds retries and does not expose a load button',
    (t) async {
      final c = FeedCatalog();
      final r = FakeRuntime(c);
      addTearDown(r.dispose);
      await mount(t, r);
      c.pendingPage = Completer<CatalogPage>();
      await t.drag(find.byType(GridView), const Offset(0, -5000));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      expect(c.calls.where((v) => v.cursor != null).length, 1);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'nav-0');
      c.pendingPage!.complete(
        CatalogPage([
          for (var i = 30; i < 60; i++)
            Drama(id: 'short_play-all-$i', title: '剧目 $i'),
        ]),
      );
      await t.pumpAndSettle();
      expect(c.calls.length, 2);
      expect(find.text('加载更多'), findsNothing);
      await t.drag(find.byType(GridView), const Offset(0, -9000));
      await t.pumpAndSettle();
      expect(c.calls.length, 2);
    },
  );
  testWidgets('switching theme rejects a stale pending next page', (t) async {
    final c = FeedCatalog();
    final runtime = FakeRuntime(c);
    addTearDown(runtime.dispose);
    await mount(t, runtime);
    c.pendingPage = Completer<CatalogPage>();
    await t.drag(find.byType(GridView), const Offset(0, -5000));
    await t.pump(const Duration(milliseconds: 200));
    final theme = t.widget<TvFocusable>(
      find.byKey(const ValueKey('tv-theme-t1')),
    );
    theme.focusNode!.requestFocus();
    await t.pump(const Duration(milliseconds: 250));
    await t.pumpAndSettle();
    c.pendingPage!.complete(
      const CatalogPage([Drama(id: 'stale', title: '旧续页内容')]),
    );
    await t.pumpAndSettle();
    expect(c.calls.last.theme, 't1');
    expect(find.text('旧续页内容'), findsNothing);
  });
  testWidgets(
    'global sort changes refetch the active feed using saved preference',
    (t) async {
      final c = FeedCatalog();
      final r = FakeRuntime(c);
      addTearDown(r.dispose);
      await mount(t, r);
      await r.saveSettings(
        r.settings.copyWith(catalogSort: 'hot_collect', tvPageSize: 50),
      );
      await t.pumpAndSettle();
      expect(c.calls.last.sort, 'hot_collect');
      expect(find.byKey(const ValueKey('catalog-sort-setting')), findsNothing);
    },
  );
  testWidgets(
    'a short first page fills the viewport without a scroll or button',
    (t) async {
      final c = FeedCatalog()..firstCount = 2;
      final runtime = FakeRuntime(c);
      addTearDown(runtime.dispose);
      await mount(t, runtime);
      expect(c.calls.length, 2);
      expect(c.calls.last.cursor, '30');
      expect(find.text('加载更多'), findsNothing);
    },
  );
  testWidgets('failed automatic page stops retrying until explicit retry', (
    t,
  ) async {
    final c = FeedCatalog(), runtime = FakeRuntime(FeedCatalog());
    addTearDown(runtime.dispose);
    final r = FakeRuntime(c);
    addTearDown(r.dispose);
    await mount(t, r);
    c.failMore = true;
    await t.drag(find.byType(GridView), const Offset(0, -5000));
    await t.pumpAndSettle();
    expect(c.calls.length, 2);
    await t.drag(find.byType(GridView), const Offset(0, -500));
    await t.pumpAndSettle();
    expect(c.calls.length, 2);
    c.failMore = false;
    await t.tap(find.text('重试'));
    await t.pumpAndSettle();
    expect(c.calls.length, 3);
    expect(c.calls.last.cursor, '30');
  });
  testWidgets(
    'successive pages with no new IDs cannot create an infinite load loop',
    (t) async {
      final c = FeedCatalog()..duplicates = true,
          r = FakeRuntime(FeedCatalog());
      addTearDown(r.dispose);
      final runtime = FakeRuntime(c);
      addTearDown(runtime.dispose);
      await mount(t, runtime);
      await t.drag(find.byType(GridView), const Offset(0, -5000));
      await t.pumpAndSettle();
      expect(c.calls.length, 3);
      await t.pump(const Duration(seconds: 2));
      expect(c.calls.length, 3);
    },
  );
  testWidgets(
    'loaded feeds use the full height and silent refresh/error recovery never resizes cards',
    (t) async {
      final catalog = FeedCatalog();
      final runtime = FakeRuntime(catalog);
      addTearDown(runtime.dispose);
      await mount(t, runtime);
      final bounds = t.getRect(find.byType(GridView));
      final grid = t.state(find.byType(TvGrid));
      expect(bounds.bottom, closeTo(708, 1));
      expect(find.byKey(const ValueKey('tv-feed-status')), findsNothing);
      expect(find.text('暂无更多内容'), findsNothing);
      catalog.pendingFirst = Completer<CatalogPage>();
      final page = t.widget<TvFeedPage>(find.byType(TvFeedPage));
      page.active.value = '';
      page.active.value = page.routeId;
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('正在更新'), findsNothing);
      expect(find.text('正在加载'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(t.getRect(find.byType(GridView)), bounds);
      catalog.pendingFirst!.completeError(const CatalogError('刷新失败'));
      await t.pumpAndSettle();
      expect(find.text('重试'), findsOneWidget);
      expect(t.getRect(find.byType(GridView)), bounds);
      expect(t.state(find.byType(TvGrid)), same(grid));
      catalog.pendingFirst = null;
      await t.tap(find.text('重试'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('tv-feed-status')), findsNothing);
      expect(t.getRect(find.byType(GridView)), bounds);
      expect(t.state(find.byType(TvGrid)), same(grid));
    },
  );
}
