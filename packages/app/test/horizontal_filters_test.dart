import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_app/features/library_page.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'fakes.dart';

class RankCatalog extends FakeCatalog implements RankCatalogRepository {
  @override
  Future<CatalogPage> rank({
    String board = 'recommend',
    String? cursor,
  }) async => const CatalogPage([]);
}

class LongCatalog extends FakeCatalog {
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) async =>
      CatalogPage(List.generate(80, (i) => Drama(id: '$i', title: '长列表$i')));
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    FakeRuntime runtime,
    Size size,
  ) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    runtime.settings = const AppSettings(autoLoadMore: false);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [runtimeProvider.overrideWith((ref) async => runtime)],
        child: const HongguoApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final size in [
    const Size(390, 600),
    const Size(600, 340),
    const Size(800, 600),
    const Size(1280, 900),
  ]) {
    testWidgets(
      'horizontal panel anchors below toolbar without overflow at $size',
      (tester) async {
        await mount(tester, FakeRuntime(), size);
        final anchor = find.byKey(const ValueKey('sticky-genre'));
        final top = tester.getTopLeft(anchor);
        final results = find.byKey(const ValueKey('catalog-results'));
        final listRect = tester.getRect(results);
        final card = find.byType(DramaCard).first;
        final cardRect = tester.getRect(card);
        await tester.tap(anchor);
        await tester.pumpAndSettle();
        expect(find.byType(DropdownButton<String>), findsNothing);
        expect(find.byType(BottomSheet), findsNothing);
        expect(
          find.byKey(const ValueKey('horizontal-filter-panel')),
          findsOneWidget,
        );
        expect(tester.getTopLeft(anchor), top);
        expect(tester.getRect(results), listRect);
        expect(tester.getRect(card), cardRect);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('收起筛选'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('horizontal-filter-panel')),
          findsNothing,
        );
      },
    );
  }
  testWidgets(
    'overlay preserves a scrolled results position until a filter changes',
    (tester) async {
      await mount(tester, FakeRuntime(LongCatalog()), const Size(390, 844));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1600));
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(LibraryPage));
      final before = state.scroll.offset as double;
      expect(before, greaterThan(100));
      final viewport = tester.getRect(
        find.byKey(const ValueKey('catalog-results')),
      );
      await tester.tap(find.byKey(const ValueKey('sticky-genre')));
      await tester.pumpAndSettle();
      expect(state.scroll.offset, before);
      expect(
        tester.getRect(find.byKey(const ValueKey('catalog-results'))),
        viewport,
      );
      await tester.tap(find.text('收起筛选'));
      await tester.pumpAndSettle();
      expect(state.scroll.offset, before);
    },
  );

  testWidgets(
    'rapid choices debounce one request, remain open and keep the anchor stable',
    (tester) async {
      final runtime = FakeRuntime();
      await mount(tester, runtime, const Size(1280, 900));
      final anchor = find.byKey(const ValueKey('sticky-genre'));
      final top = tester.getTopLeft(anchor);
      await tester.tap(anchor);
      await tester.pumpAndSettle();
      final calls = runtime.catalog.browseCalls;
      await tester.tap(find.byKey(const ValueKey('filter-genre-comic_series')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('filter-genre-ai_series')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(runtime.catalog.browseCalls, calls);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(runtime.catalog.browseCalls, calls + 1);
      expect(runtime.catalog.lastGenre, 'ai_series');
      expect(
        find.byKey(const ValueKey('horizontal-filter-panel')),
        findsOneWidget,
      );
      expect(tester.getTopLeft(anchor), top);
      await tester.tap(find.byKey(const ValueKey('filter-genre-ai_series')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(runtime.catalog.browseCalls, calls + 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('horizontal-filter-panel')),
        findsNothing,
      );
    },
  );
  testWidgets(
    'latest, rank and search show only supported options; outside tap only closes',
    (tester) async {
      final runtime = FakeRuntime(RankCatalog());
      await mount(tester, runtime, const Size(1280, 900));
      await tester.tap(find.byKey(const ValueKey('sticky-view')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-view-latest')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('filter-sort-hot_score')), findsNothing);
      expect(
        find.byKey(const ValueKey('filter-sort-online_time')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('filter-view-rank')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('filter-board-hot')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('filter-genre-short_play')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('filter-dismiss-area')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('horizontal-filter-panel')),
        findsNothing,
      );
      expect(find.text('开始观看'), findsNothing);
      await tester.enterText(find.byType(TextField), '故事');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sticky-genre')), findsNothing);
      expect(find.text('清除搜索'), findsOneWidget);
    },
  );
}
