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

  /// 题材 is 分类's second level, so a rail assertion starts by entering that
  /// page -- by its own item of the navigation bar, which is where a viewer
  /// who wants the whole row of types goes.
  Future<void> openCategories(WidgetTester tester) async {
    await tester.tap(find.text('分类').first);
    await tester.pumpAndSettle();
  }

  /// The three types every build offers. On a phone the channel row is wider
  /// than the screen, so a choice is scrolled into view before it is tapped --
  /// the same swipe the viewer makes.
  Future<void> chooseGenre(WidgetTester tester, String genre) async {
    final chip = find.byKey(ValueKey('filter-genre-categories-$genre'));
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
      await openCategories(tester);
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
        expect(
          find.byKey(ValueKey('filter-genre-categories-$genre')),
          findsOneWidget,
        );
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
    'the strip stays with the viewer over a long scroll and keeps answering',
    (tester) async {
      await mount(tester, FakeRuntime(LongCatalog()), const Size(390, 844));
      await openCategories(tester);
      final rail = find.byKey(const ValueKey('theme-rail'));
      final top = find.byKey(const ValueKey('pane-top-categories'));
      final viewport = find.byKey(
        const ValueKey('catalog-results-categories-short_play-all'),
      );
      // At rest the strip hangs under the search box and the choice row, and
      // the list begins below it.
      expect(tester.widget<Visibility>(top).visible, isTrue);
      expect(
        tester.getRect(rail).bottom,
        lessThanOrEqualTo(tester.getRect(viewport).top),
      );
      await tester.drag(viewport, const Offset(0, -1600));
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(LibraryPage));
      expect(state.scroll.offset as double, greaterThan(100));
      // The questions the viewer already answered went with the header. Both
      // filter rows stayed: the strip that names where a sideways swipe landed,
      // and the row that says which mode and which type the list is in -- a fold
      // that took the type with it could only be undone by scrolling all the way
      // back to the top, which is not what a fold is for.
      expect(tester.widget<Visibility>(top).visible, isFalse);
      final choices = find.byKey(const ValueKey('filter-choices-categories'));
      expect(choices.hitTestable(), findsOneWidget);
      expect(
        tester.getRect(choices).bottom,
        lessThanOrEqualTo(tester.getRect(viewport).top),
      );
      expect(rail.hitTestable(), findsOneWidget);
      expect(
        tester.getRect(rail).bottom,
        lessThanOrEqualTo(tester.getRect(viewport).top),
      );
      // And either level still answers from the folded state.
      await chooseGenre(tester, 'comic_series');
      expect(state.genre, 'comic_series');
      await tester.pumpAndSettle();
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
      await openCategories(tester);
      final rail = find.byKey(const ValueKey('theme-rail'));
      final railRect = tester.getRect(rail);
      final calls = runtime.catalog.browseCalls;
      await chooseGenre(tester, 'comic_series');
      await tester.pump(const Duration(milliseconds: 100));
      // The first choice already settled, so count from where it left off.
      final settled = runtime.catalog.browseCalls;
      expect(settled, greaterThan(calls));
      await tester.tap(
        find.byKey(const ValueKey('filter-genre-categories-ai_series')),
      );
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
        find.byKey(const ValueKey('filter-genre-discover-short_play')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('filter-view-rank')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      // A board has no type of its own and no themes of its own: the type row
      // steps out, and the strip pinned under it is filled with the boards --
      // the second level of that mode, and the swipe still lands on them.
      expect(
        find.byKey(const ValueKey('filter-genre-discover-short_play')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('filter-board-hot')), findsOneWidget);
      expect(find.byKey(const ValueKey('theme-rail-cate_7')), findsNothing);
      expect(find.byKey(const ValueKey('filter-sort-hot_score')), findsNothing);
      // `rank(board)` takes no genre, so the title states the genre the board
      // actually ranks (upstream all three are 漫剧 boards) next to the board's
      // own name -- and nothing is written into the shared first level.
      expect(find.text('漫剧榜单'), findsNothing);
      expect(find.text('漫剧 · 推荐榜'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('filter-board-hot')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('漫剧 · 热播榜'), findsOneWidget);
      // 分类 never inherits 榜单: it shows its own types again.
      await tester.tap(find.text('分类').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('filter-view-rank')), findsNothing);
      expect(
        find.byKey(const ValueKey('filter-genre-categories-comic_series')),
        findsOneWidget,
      );
      // And the type still lit is the one the viewer was on -- 榜单 read as a
      // channel, not as a filter, so it never moved the shared first level.
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('filter-genre-categories-short_play')),
            )
            .selected,
        isTrue,
      );
      // And the rail 分类 owns is still there, holding the children of that same
      // shared first level -- 榜单 never cancelled or emptied it on the way by.
      expect(find.byKey(const ValueKey('theme-rail')), findsOneWidget);
      expect(find.byKey(const ValueKey('theme-rail-cate_7')), findsOneWidget);
      // A search answers neither question, so the row keeps only the way out.
      await tester.enterText(
        find.byKey(const ValueKey('search-field-categories')),
        '故事',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('clear-search-categories')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('filter-genre-categories-comic_series')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('theme-rail')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
