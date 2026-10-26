import 'package:flutter/material.dart';
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

  /// The three types every build offers. On a phone the channel row is wider
  /// than the screen, so a choice is scrolled into view before it is tapped --
  /// the same swipe the viewer makes.
  Future<void> chooseGenre(WidgetTester tester, String genre) async {
    final chip = find.byKey(ValueKey('filter-genre-$genre'));
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  for (final size in [
    const Size(390, 600),
    const Size(600, 340),
    const Size(800, 600),
    const Size(1280, 900),
  ]) {
    testWidgets('every choice is already on screen without a sheet at $size', (
      tester,
    ) async {
      final runtime = FakeRuntime();
      await mount(tester, runtime, size);
      final rail = find.byKey(const ValueKey('theme-rail'));
      final railRect = tester.getRect(rail);
      // No trigger to open and nothing to fold away afterwards: the options
      // of each dimension are laid out where they are used.
      expect(find.byKey(const ValueKey('sticky-genre')), findsNothing);
      expect(
        find.byKey(const ValueKey('horizontal-filter-panel')),
        findsNothing,
      );
      for (final genre in ['short_play', 'comic_series', 'ai_series']) {
        expect(find.byKey(ValueKey('filter-genre-$genre')), findsOneWidget);
      }
      await chooseGenre(tester, 'comic_series');
      expect(runtime.catalog.lastGenre, 'comic_series');
      // Choosing a type refills the rail below it, but the rail keeps the
      // same rectangle: 题材加载中 and the chips share one fixed height.
      expect(tester.getRect(rail), railRect);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'the rail pins at the top of a long scroll while the header scrolls out',
    (tester) async {
      await mount(tester, FakeRuntime(LongCatalog()), const Size(390, 844));
      final rail = find.byKey(const ValueKey('theme-rail'));
      final viewport = tester.getRect(
        find.byKey(const ValueKey('catalog-results')),
      );
      // At rest the rail sits under the search box and the choice row.
      expect(tester.getRect(rail).top, greaterThan(viewport.top + 60));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1600));
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(LibraryPage));
      expect(state.scroll.offset as double, greaterThan(100));
      // The search box and the choices are header content: they left with the
      // brand band and are gone from the tree, not merely behind the fold.
      expect(find.byKey(const ValueKey('filter-choices')), findsNothing);
      // The rail is the one thing that stopped at the top, still tappable.
      expect(tester.getRect(rail).top, closeTo(viewport.top, 1));
      expect(rail.hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('theme-rail-cate_7')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.theme, 'cate_7');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rapid choices collapse into one request and keep the rail geometry',
    (tester) async {
      final runtime = FakeRuntime();
      await mount(tester, runtime, const Size(1280, 900));
      final rail = find.byKey(const ValueKey('theme-rail'));
      final railRect = tester.getRect(rail);
      final calls = runtime.catalog.browseCalls;
      await chooseGenre(tester, 'comic_series');
      await tester.pump(const Duration(milliseconds: 100));
      // The first choice already settled, so count from where it left off.
      final settled = runtime.catalog.browseCalls;
      expect(settled, greaterThan(calls));
      await tester.tap(find.byKey(const ValueKey('filter-genre-ai_series')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(runtime.catalog.browseCalls, settled);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(runtime.catalog.browseCalls, settled + 1);
      expect(runtime.catalog.lastGenre, 'ai_series');
      expect(tester.getRect(rail), railRect);
    },
  );

  testWidgets(
    '频道 belongs to 发现, 榜单 takes the type place, search leaves neither',
    (tester) async {
      final runtime = FakeRuntime(RankCatalog());
      await mount(tester, runtime, const Size(1280, 900));
      expect(
        find.byKey(const ValueKey('filter-view-recommend')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('filter-genre-short_play')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('filter-view-rank')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      // A board has no type of its own and no themes: the group under the
      // channel row becomes the three boards, and the rail steps out.
      expect(
        find.byKey(const ValueKey('filter-genre-short_play')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('filter-board-hot')), findsOneWidget);
      expect(find.byKey(const ValueKey('theme-rail')), findsNothing);
      expect(find.byKey(const ValueKey('filter-sort-hot_score')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('filter-board-hot')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      // 分类 never inherits 榜单: it shows its own types again.
      await tester.tap(find.text('分类').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('filter-view-rank')), findsNothing);
      expect(
        find.byKey(const ValueKey('filter-genre-comic_series')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('theme-rail')), findsOneWidget);
      // A search answers neither question, so the row keeps only the way out.
      await tester.enterText(find.byType(TextField), '故事');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('clear-search')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('filter-genre-short_play')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('theme-rail')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
