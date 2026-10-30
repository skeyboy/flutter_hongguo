import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/features/library_page.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'desktop_fakes.dart'
    show DesktopCatalog, UnfilteredCatalog, openSort, sortTo;
import 'fakes.dart';

/// The touch family's counterpart to `discover_desktop_layers_test.dart`.
///
/// Same four layers, same promises -- L1 换页 and it resets L2/L2′, L2 主题 the
/// pinned second row, L2′ and L3 reached from the two controls nailed to that
/// row's tail -- but the shapes are the finger's, not the pointer's: the mouse
/// family's anchored overlay and hover dropdown become bottom sheets here, and
/// the two words 「推荐」/「最新」 that used to sit in the first row are gone from
/// both families because 「推荐」 names no sort upstream publishes.
///
/// `desktopHost` is read from the platform, and `flutter_test`'s default target
/// platform is android -- which is exactly this family. So, unlike the desktop
/// suite, this mount never touches `debugDefaultTargetPlatformOverride`: a test
/// that did would flip itself onto the other family and stop testing the sheet.
Future<DesktopCatalog> mountMobile(
  WidgetTester tester,
  FakeCatalog catalog,
) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final runtime = FakeRuntime(catalog)
    ..settings = const AppSettings(autoLoadMore: false);
  addTearDown(runtime.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [runtimeProvider.overrideWith((ref) async => runtime)],
      child: const HongguoApp(),
    ),
  );
  await tester.pumpAndSettle();
  return catalog as DesktopCatalog;
}

/// The `≡` nailed to the tail of the touch family's pinned second row. The
/// contract names it `filter-narrow`; the mouse family keeps a `GlobalKey` for
/// the anchored overlay instead, so a touch test reaches this one by key.
Finder narrowChip() => find.byKey(const ValueKey('filter-narrow'));

Future<void> openNarrow(WidgetTester tester) async {
  await tester.tap(narrowChip());
  await tester.pumpAndSettle();
}

/// A chip in a horizontally scrolling row is not on screen until the viewer
/// slides to it -- which is what `ensureVisible` stands in for here, since a
/// 390-point screen cannot hold 三个类型 and a whole row of 主题 at once.
Future<void> tapRowChip(WidgetTester tester, Finder chip) async {
  await tester.ensureVisible(chip);
  await tester.pumpAndSettle();
  await tester.tap(chip);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// The 发现 entry card borrows its three rows from 榜单, and a board with no rows
/// declines to draw itself (`RankEntryCard` returns a shrink when it has nothing
/// to place). The shared desktop fake publishes the 赛道 tree without rows,
/// because the desktop suite never asks for the card; this answers the same 榜
/// with the three 剧 the touch contract is checked against -- heat text verbatim
/// from `rec_text_item`, position from the array index, nothing invented.
class EntryCatalog extends DesktopCatalog {
  @override
  Future<RankPage> rankBoard({
    String track = rankSeedTrack,
    String? board,
    String? cursor,
  }) async {
    rankRequests.add((track, board));
    return const RankPage(
      tracks: [
        RankTrack('comic_series_rank', '漫剧', [
          RankBoard('comic_series_hot_play', '热播榜', selected: true),
        ]),
      ],
      entries: [
        RankEntry(drama: FakeCatalog.demo, position: 0, heat: '9388万热度'),
        RankEntry(
          drama: Drama(id: '2', title: '第二个故事', episodeCount: 2),
          position: 1,
          heat: '6190万热度',
        ),
        RankEntry(
          drama: Drama(id: '3', title: '第三个故事', episodeCount: 2),
          position: 2,
          heat: '6182万热度',
        ),
      ],
    );
  }
}

void main() {
  testWidgets('the strip of the touch family ends in ≡ and 排序', (tester) async {
    await mountMobile(tester, DesktopCatalog());
    // The two controls the design nails to the tail of the pinned second row:
    // `≡` for L2′ and a 排序 chip for L3. They are keyed the way the mouse
    // family's dropdown is (`sort-menu`), so 「换排序不换页」 is asked of either
    // shape without a test having to know which family it drove.
    expect(narrowChip(), findsOneWidget);
    expect(find.text('≡'), findsOneWidget);
    expect(find.byKey(const ValueKey('sort-menu')), findsOneWidget);
    expect(find.textContaining('排序 ·'), findsOneWidget);
    // Both are on screen and pressable, not parked off the edge of the row they
    // are supposed to stay pinned to.
    expect(narrowChip().hitTestable(), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sort-menu')).hitTestable(),
      findsOneWidget,
    );
    // The two words the L3 sheet replaced are gone from the row, not hidden
    // behind the chip: 推荐 maps to no sort upstream publishes, so a chip for it
    // would be a question with no answer.
    expect(find.byKey(const ValueKey('filter-view-recommend')), findsNothing);
    expect(find.byKey(const ValueKey('filter-view-latest')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('词表缺行: a pressable retry chip, and the tail controls stay', (
    tester,
  ) async {
    final catalog = await mountMobile(tester, UnfilteredCatalog());
    // The type answered with no 主题 row. That is a normal branch, so the touch
    // family collapses the whole row into one pressable chip -- a sentence the
    // finger can act on, not a dead label -- and does NOT hand the viewer an
    // empty page (the list still carries 类型 + 排序).
    expect(find.byKey(const ValueKey('theme-rail')), findsNothing);
    final retry = find.byKey(const ValueKey('theme-rail-retry'));
    expect(retry, findsOneWidget);
    expect(find.text('主题词表这次没回 · 重试'), findsOneWidget);
    // And the two controls that only ever change the request survive the missing
    // row beside the retry: what is absent is the 主题 vocabulary, not the page's
    // ability to narrow or reorder itself.
    expect(narrowChip(), findsOneWidget);
    expect(find.byKey(const ValueKey('sort-menu')), findsOneWidget);
    // 类型 rides on no selector_rows: the first row is still here and still turns
    // the page even with the second row's vocabulary gone.
    await tapRowChip(
      tester,
      find.byKey(const ValueKey('filter-genre-discover-comic_series')),
    );
    expect(catalog.lastGenre, 'comic_series');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '≡ opens the sheet, a line changes the request and leaves it open',
    (tester) async {
      final catalog = await mountMobile(tester, DesktopCatalog());
      await openNarrow(tester);
      expect(find.byKey(const ValueKey('filter-panel')), findsOneWidget);
      final before = catalog.browseCalls;
      await tester.tap(
        find.byKey(const ValueKey('filter-dim-category_dim_role-role_1')),
      );
      await tester.pumpAndSettle();
      // 只改请求：the sheet stays under the thumb (a multi-dimension decision is
      // made one line at a time, and closing it is the viewer's call), the page
      // does not turn, and the dimension went into the query the list is made of.
      expect(find.byKey(const ValueKey('filter-panel')), findsOneWidget);
      expect(catalog.filtered.last.dims['category_dim_role'], ['role_1']);
      expect(catalog.browseCalls, before);
      expect(find.text('≡ 1'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('filter-panel-done')));
      await tester.pumpAndSettle();
      // `完成` -- not the pick -- is what closes it.
      expect(find.byKey(const ValueKey('filter-panel')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('排序 opens a sheet of exactly the three 档 upstream publishes', (
    tester,
  ) async {
    await mountMobile(tester, DesktopCatalog());
    await openSort(tester);
    expect(find.byKey(const ValueKey('sort-sheet')), findsOneWidget);
    // The three, and only the three: `online_time` / `hot_score` / `hot_collect`,
    // spelled with the same `sort-$档` keys the mouse dropdown uses.
    expect(find.byKey(const ValueKey('sort-online_time')), findsOneWidget);
    expect(find.byKey(const ValueKey('sort-hot_score')), findsOneWidget);
    expect(find.byKey(const ValueKey('sort-hot_collect')), findsOneWidget);
    // No fourth 「推荐」 档, and no leftover of the chips it displaced.
    expect(find.byKey(const ValueKey('sort-recommend')), findsNothing);
    expect(find.byKey(const ValueKey('filter-view-recommend')), findsNothing);
    expect(find.text('三档就是上游全部：没有「推荐」，也没有「追剧」。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('picking a 档 asks for the same page again and does not move it', (
    tester,
  ) async {
    final catalog = await mountMobile(tester, DesktopCatalog());
    // The list the viewer is looking at, named by the page it belongs to. The
    // 档 is picked away from the default on purpose -- choosing the one already
    // in force short-circuits in `_reQuery` and asks for nothing, which would
    // pass the promise without ever exercising it.
    final viewport = find.byKey(
      const ValueKey('catalog-results-discover-short_play-all'),
    );
    final rect = tester.getRect(viewport);
    await sortTo(tester, 'online_time');
    // The 档 reached the request -- and the sheet popped on the pick, which is
    // 「one question with one answer」 and the opposite of 更多筛选's drawer.
    expect(catalog.lastSort, 'online_time');
    expect(find.byKey(const ValueKey('sort-sheet')), findsNothing);
    // The chip reads the 档 actually in force...
    expect(find.text('排序 · 最新上架'), findsOneWidget);
    // ...and the level it sits on has not moved: 全部主题 is still the row's own
    // selection, and the grid occupies exactly the rectangle it had before the
    // pick. That the list is the same page, in the same place, is what makes
    // 「排序 ≠ 换页」 something you can see rather than something the doc claims.
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('theme-rail-')))
          .selected,
      isTrue,
    );
    expect(tester.getRect(viewport), rect);
    expect(tester.takeException(), isNull);
  });

  testWidgets('排序 sheet 的「收起」关闭它且不问任何东西', (tester) async {
    final catalog = await mountMobile(tester, DesktopCatalog());
    await openSort(tester);
    expect(find.byKey(const ValueKey('sort-sheet')), findsOneWidget);
    final before = catalog.browseCalls;
    final sort = catalog.lastSort;
    await tester.tap(find.byKey(const ValueKey('sort-sheet-dismiss')));
    await tester.pumpAndSettle();
    // Opening the sheet to look and putting it back down is not a decision: the
    // 档 in force is what it was, and nothing was asked for.
    expect(find.byKey(const ValueKey('sort-sheet')), findsNothing);
    expect(catalog.lastSort, sort);
    expect(catalog.browseCalls, before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('换类型归零 the 主题 level and the picked dims', (tester) async {
    final catalog = await mountMobile(tester, DesktopCatalog());
    // Stand on one 主题 and one 维度, so "reset" has a value to read back off.
    await tapRowChip(tester, find.byKey(const ValueKey('theme-rail-cate_7')));
    expect(catalog.lastTheme, 'cate_7');
    await openNarrow(tester);
    await tester.tap(
      find.byKey(const ValueKey('filter-dim-category_dim_role-role_1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter-panel-done')));
    await tester.pumpAndSettle();
    expect(find.text('≡ 1'), findsOneWidget);

    // 类型 is the one layer that turns the page, and the semantic the release
    // already shipped holds to: leaving a type drops the 主题 and the 维度 that
    // were its children rather than carrying ids that name a different parent.
    await tapRowChip(
      tester,
      find.byKey(const ValueKey('filter-genre-discover-comic_series')),
    );
    expect(catalog.lastGenre, 'comic_series');
    expect(catalog.lastTheme, isNull);
    // Back to 全部主题, and the drawer's count is empty again -- 归零, not a
    // second reset rule the 维度 obey differently from the 主题.
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('theme-rail-')))
          .selected,
      isTrue,
    );
    expect(find.text('≡ 1'), findsNothing);
    expect(find.text('≡'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('榜单入口卡 sits above the grid, and 全部榜单 is a destination', (
    tester,
  ) async {
    final catalog = await mountMobile(tester, EntryCatalog());
    // The one place 榜单 content is allowed on 发现: a strip of the top three,
    // position from the array index and 热度 from `rec_text_item` verbatim.
    expect(find.byKey(const ValueKey('rank-entry-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('rank-entry-heat-0')), findsOneWidget);
    expect(find.text('全部榜单 ›'), findsOneWidget);
    // Stand the page on a level and a dim first, so the promise 「点它是换目的地
    // 而不是换筛选」 has something it must not disturb.
    await tapRowChip(tester, find.byKey(const ValueKey('theme-rail-cate_7')));
    await openNarrow(tester);
    await tester.tap(find.byKey(const ValueKey('filter-dim-gender-gender_1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter-panel-done')));
    await tester.pumpAndSettle();

    final genre = catalog.lastGenre;
    final theme = catalog.lastTheme;
    final browseBefore = catalog.browseCalls;
    await tester.tap(find.byKey(const ValueKey('rank-entry-more')));
    await tester.pumpAndSettle();

    // Destination switched: the board page is on screen over the kept-alive
    // feed layer.
    expect(find.byKey(const ValueKey('rank-page')), findsOneWidget);
    // ...and the request that made the card is untouched: `rankBoard` takes
    // neither 类型 nor 题材, so this is a trip, not a narrowing. The 主题 the
    // viewer was on and the 维度 in the drawer both still hold.
    expect(catalog.lastGenre, genre);
    expect(catalog.lastTheme, theme);
    expect(catalog.browseCalls, browseBefore);
    expect(catalog.filtered.last.dims['gender'], ['gender_1']);
    final dynamic state = tester.state(find.byType(LibraryPage));
    expect(state.theme, 'cate_7');
    expect(tester.takeException(), isNull);
  });
}
