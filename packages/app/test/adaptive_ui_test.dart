import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/catalog/library_cache.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_app/features/library_page.dart';
import 'package:hongguo_app/features/settings_page.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'fakes.dart';

class PagedCatalog extends FakeCatalog {
  int calls = 0;
  bool stuck = false, failPage = false;
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) async {
    calls++;
    if (cursor == null) {
      return CatalogPage(
        List.generate(
          12,
          (i) => Drama(id: '${i + 100}', title: '首屏$i', episodeCount: 3),
        ),
        nextCursor: 'page1',
      );
    }
    if (failPage) throw const CatalogError('分页暂时失败');
    if (stuck) return const CatalogPage([], nextCursor: 'page1');
    return CatalogPage(
      List.generate(
        12,
        (i) => Drama(id: '${i + 200}', title: '续页$i', episodeCount: 3),
      ),
    );
  }
}

class SourceCacheRuntime extends FakeRuntime implements LibraryCacheRuntime {
  SourceCacheRuntime([super.catalog]) : libraryCache = LibraryCache();

  @override
  final LibraryCache libraryCache;
}

class PendingBoardCatalog extends FakeCatalog {
  final pending = <Completer<CatalogPage>>[];
  bool holdBoards = false;

  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) {
    if (holdBoards &&
        cursor == null &&
        (sort == 'online_time' || sort == 'hot_score')) {
      browseCalls++;
      lastGenre = genre;
      lastSort = sort;
      final result = Completer<CatalogPage>();
      pending.add(result);
      return result.future;
    }
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
  Future<void> mount(
    WidgetTester tester,
    FakeRuntime runtime,
    Size size,
  ) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [runtimeProvider.overrideWith((ref) async => runtime)],
        child: const HongguoApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final size in [
    const Size(390, 844),
    const Size(700, 900), // Narrow Split View still uses the bottom bar.
    const Size(800, 900),
    const Size(834, 900), // iPad portrait rail.
    const Size(1112, 900), // Desktop sidebar.
    const Size(1280, 900),
  ]) {
    testWidgets('navigation adapts at ${size.width} without overflow', (
      tester,
    ) async {
      await mount(tester, FakeRuntime(), size);
      expect(
        find.byType(NavigationBar),
        size.width < 720 ? findsOneWidget : findsNothing,
      );
      expect(
        find.byType(NavigationRail),
        size.width >= 720 && size.width < 1100 ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(const ValueKey('catalog-tab-0')),
        size.width >= 1100 ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('focused Back closes suggestions and 我的/榜单, not hidden panes', (
    tester,
  ) async {
    await mount(tester, FakeRuntime(), const Size(390, 844));
    final dynamic state = tester.state(find.byType(LibraryPage));
    final search = find.byKey(
      const ValueKey('search-field-discover'),
      skipOffstage: false,
    );
    final focusExclusion = find
        .ancestor(of: search, matching: find.byType(ExcludeFocus))
        .last;
    final semanticsExclusion = find
        .ancestor(of: search, matching: find.byType(ExcludeSemantics))
        .last;

    await tester.tap(search);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-suggestions')), findsOneWidget);
    final catalogPop = find.byWidgetPredicate((widget) => widget is PopScope);
    expect(tester.widget<PopScope>(catalogPop).canPop, isFalse);
    final catalogRoute = ModalRoute.of(
      tester.element(find.byType(LibraryPage)),
    )!;
    expect(catalogRoute.popDisposition, RoutePopDisposition.doNotPop);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-suggestions')), findsNothing);
    expect(state.suggestionsPane, isNull);

    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-page')), findsOneWidget);
    expect(tester.widget<ExcludeFocus>(focusExclusion).excluding, isTrue);
    expect(
      tester.widget<ExcludeSemantics>(semanticsExclusion).excluding,
      isTrue,
    );
    state.paneFocus[0]!.requestFocus();
    state.paneSearch[0]!.text = '隐藏页搜索';
    await tester.pump();
    expect(state.paneFocus[0]!.hasFocus, isFalse);
    expect(state.suggestionsPane, isNull);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-page')), findsNothing);
    expect(find.byType(LibraryPage), findsOneWidget);
    expect(state.paneFocus[0]!.hasFocus, isTrue);
    expect(state.suggestionsPane, isNull);

    await tester.tap(find.byIcon(Icons.leaderboard_outlined));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rank-page')), findsOneWidget);
    expect(tester.widget<ExcludeFocus>(focusExclusion).excluding, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rank-page')), findsNothing);
    expect(find.byType(LibraryPage), findsOneWidget);
    expect(state.paneFocus[0]!.hasFocus, isTrue);
    expect(state.suggestionsPane, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Back closes suggestions above a peek before closing the peek', (
    tester,
  ) async {
    await mount(tester, FakeRuntime(), const Size(1280, 900));
    final dynamic state = tester.state(find.byType(LibraryPage));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(DramaCard).first));
    await tester.pump(const Duration(milliseconds: 1600));
    expect(find.byKey(const ValueKey('peek-title-123')), findsOneWidget);

    // Keep the pointer on the card so the peek remains open while the field is
    // focused programmatically, as a keyboard user can do.
    state.paneFocus[0]!.requestFocus();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-suggestions')), findsOneWidget);
    expect(find.byKey(const ValueKey('peek-title-123')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-suggestions')), findsNothing);
    expect(find.byKey(const ValueKey('peek-title-123')), findsOneWidget);
    expect(state.paneFocus[0]!.hasFocus, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(state.suggestionsPane, isNull);
    expect(state.peekEntry, isNull);
    expect(find.byKey(const ValueKey('peek-title-123')), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('late recommendations cannot reopen or paint a closed panel', (
    tester,
  ) async {
    final catalog = PendingBoardCatalog();
    await mount(tester, FakeRuntime(catalog), const Size(390, 844));
    final dynamic state = tester.state(find.byType(LibraryPage));
    catalog.holdBoards = true;
    await tester.tap(find.byKey(const ValueKey('search-field-discover')));
    await tester.pump();
    expect(catalog.pending.length, 2);
    expect(find.byKey(const ValueKey('search-suggestions')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(state.suggestionsPane, isNull);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('search-field-discover')),
          )
          .focusNode!
          .hasFocus,
      isTrue,
    );
    catalog.pending[0].complete(
      const CatalogPage([
        Drama(id: 'late-new', title: '迟到的新剧', episodeCount: 2),
      ]),
    );
    catalog.pending[1].complete(
      const CatalogPage([
        Drama(id: 'late-hot', title: '迟到的热门', episodeCount: 2),
      ]),
    );
    await tester.pumpAndSettle();
    expect(state.suggestionRows, isEmpty);
    expect(find.byKey(const ValueKey('search-suggest-late-new')), findsNothing);

    // The service may keep the answer, but only a new, current focus request is
    // allowed to apply it.
    await tester.tap(find.byKey(const ValueKey('search-field-discover')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('search-suggest-late-new')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('source changes isolate feed and disk-cache keys', (
    tester,
  ) async {
    final catalog = PagedCatalog();
    final runtime = SourceCacheRuntime(catalog)
      ..settings = const AppSettings(themeMode: 'light', autoLoadMore: false);
    await mount(tester, runtime, const Size(390, 844));
    final dynamic state = tester.state(find.byType(LibraryPage));
    final legacyKey = state.feedKey as String;
    expect(state.paramsOf(legacyKey)['sources'], isNull);
    await runtime.libraryCache.writeFeed(
      legacyKey,
      const CatalogPage([
        Drama(id: 'old-source', title: '旧片源缓存', episodeCount: 1),
      ]),
    );

    final before = catalog.calls;
    await runtime.saveSettings(
      runtime.settings.copyWith(
        sources: runtime.settings.sources.withBuiltin('xifan', false),
      ),
    );
    await tester.pumpAndSettle();
    final toggledKey = state.feedKey as String;
    expect(toggledKey, isNot(legacyKey));
    expect(state.paramsOf(toggledKey)['sources'], ['hema', 'hongguo']);
    expect(find.text('旧片源缓存'), findsNothing);
    expect(catalog.calls, greaterThan(before));
    expect(
      (await runtime.libraryCache.readFeed(legacyKey))!.page.items.single.title,
      '旧片源缓存',
    );

    const uuid = '123e4567-e89b-42d3-a456-426614174000';
    final beforeCustom = catalog.calls;
    await runtime.saveSettings(
      runtime.settings.copyWith(
        sources: runtime.settings.sources.upsertCustom(
          const CustomSourceConfig(
            uuid: uuid,
            name: '测试片源',
            url: 'https://api.example.org/api.php/provide/vod/',
            enabled: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final customKey = state.feedKey as String;
    expect(customKey, isNot(toggledKey));
    expect(state.paramsOf(customKey)['sources'], [
      'custom:$uuid',
      'hema',
      'hongguo',
    ]);
    expect(customKey, isNot(contains('example.org')));
    expect(catalog.calls, greaterThan(beforeCustom));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'scroll proximity loads one next page without pressing a button',
    (tester) async {
      final catalog = PagedCatalog();
      await mount(tester, FakeRuntime(catalog), const Size(390, 844));
      expect(catalog.calls, 1);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
      await tester.pumpAndSettle();
      expect(catalog.calls, 2);
      final dynamic state = tester.state(find.byType(LibraryPage));
      expect(state.feed.items.length, 24);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
      await tester.pumpAndSettle();
      expect(catalog.calls, 2);
    },
  );
  testWidgets('stuck cursor and page errors pause automatic retries', (
    tester,
  ) async {
    final catalog = PagedCatalog()..stuck = true;
    await mount(tester, FakeRuntime(catalog), const Size(390, 844));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(catalog.calls, 2);
    final dynamic state = tester.state(find.byType(LibraryPage));
    expect(state.feed.autoPaused, isTrue);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(catalog.calls, 2);
    catalog.stuck = false;
    catalog.failPage = true;
    await tester.ensureVisible(find.text('重试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(catalog.calls, 3);
    expect(find.text('分页暂时失败'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(catalog.calls, 3);
  });
  for (final size in [const Size(390, 844), const Size(1280, 900)]) {
    testWidgets('the theme rail applies a choice without a sheet at $size', (
      tester,
    ) async {
      final runtime = FakeRuntime();
      await mount(tester, runtime, size);
      await tester.tap(find.text('分类').first);
      await tester.pumpAndSettle();
      // 题材 lives in the rail now, so choosing one never opens a sheet.
      expect(
        find.byKey(const ValueKey('horizontal-filter-panel')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('theme-rail-cate_7')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(runtime.catalog.lastTheme, 'cate_7');
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'settings save 5-episode lookahead and render in mobile navigation',
    (tester) async {
      final runtime = FakeRuntime();
      await mount(tester, runtime, const Size(390, 844));
      // The catalog header no longer repeats the navigation: the destination
      // itself is the only way to 我的.
      await tester.tap(find.byIcon(Icons.person_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('my-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      // A closed dropdown shows only its own value, so the next row has to be
      // scrolled into view before its tap can open the menu.
      await tester.ensureVisible(find.text('3 集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('3 集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5 集').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('浅色'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('浅色'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('深色').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      expect(runtime.settings.prefetchEpisodes, 5);
      expect(runtime.saves, 2);
      expect(find.text('设置已保存'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'session fields are masked, saved explicitly, and signing refresh is independent',
    (tester) async {
      final runtime = FakeRuntime();
      await mount(tester, runtime, const Size(1280, 900));
      // The catalog header no longer repeats the navigation: the destination
      // itself is the only way to 我的.
      await tester.tap(find.byIcon(Icons.person_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('my-settings')));
      await tester.pumpAndSettle();
      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Cookie',
      );
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).obscureText, isTrue);
      await tester.enterText(field, 'test-cookie-only');
      expect(runtime.credentials.cookie, isEmpty);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(runtime.credentials.cookie, 'test-cookie-only');
      final refresh = find.text('刷新签名状态');
      await tester.ensureVisible(refresh);
      await tester.pumpAndSettle();
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(runtime.signRefreshes, 1);
      expect(runtime.credentials.cookie, 'test-cookie-only');
      expect(tester.takeException(), isNull);
    },
  );
}
