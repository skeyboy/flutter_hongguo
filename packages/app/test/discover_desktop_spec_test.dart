import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart' show ChoiceChip, Scrollbar, ValueKey;
import 'package:flutter_test/flutter_test.dart';

import 'desktop_fakes.dart';

/// The handful of §6.1 / §10 promises the desktop layer suite does not already
/// hold: that 榜单 is a destination rather than a filter (and round-trips leave
/// the page alone), that the mouse family's 主题 row overflows to 更多 ▾ instead
/// of sliding sideways, that 词表缺行 speaks instead of opening an empty box, and
/// that a multi-dimension choice keeps the drawer under the viewer's hand.
void main() {
  testWidgets('榜单 is a destination: opening it writes nothing 发现 owns', (
    tester,
  ) async {
    final catalog = await mount(tester, DesktopCatalog());
    // 发现 has already asked for its own page; snapshot the levels it owns.
    final browseCalls = catalog.browseCalls;
    final genre = catalog.lastGenre;
    final theme = catalog.lastTheme;
    expect(catalog.rankRequests, isEmpty);

    await tester.tap(find.text('榜单'));
    await tester.pumpAndSettle();

    // A trip to 榜单 takes neither 类型 nor 题材: the discover page issued no new
    // browse and its level choices did not move while the board was on screen.
    expect(catalog.browseCalls, browseCalls);
    expect(catalog.lastGenre, genre);
    expect(catalog.lastTheme, theme);
    // It did ask its own endpoint, though -- and that request names a 赛道, not a
    // genre/theme the discover page owns.
    expect(catalog.rankRequests, isNotEmpty);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('coming back from 榜单 leaves 类型 and 主题 where they were', (
    tester,
  ) async {
    await mount(tester, DesktopCatalog());
    // Stand on one 主题 of one 类型 so "where it was" has a value to read back.
    await tester.tap(find.byKey(const ValueKey('theme-rail-cate_7')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('榜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发现'));
    await tester.pumpAndSettle();

    // The second row is still the 主题 the viewer chose, and the type above it
    // never left 短剧: the overlay came off, the levels were not re-decided.
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('theme-rail-cate_7')))
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('filter-genre-discover-short_play')),
          )
          .selected,
      isTrue,
    );
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('on desktop the 主题 row overflows to a menu, not a sideways slide', (
    tester,
  ) async {
    await mount(tester, DesktopCatalog());
    final rail = find.byKey(const ValueKey('theme-rail'));
    // The mouse family keeps a bare `SingleChildScrollView` so a window too
    // narrow for even the head can still wheel along it -- so a literal "no
    // Scrollable at all" is NOT what the code offers. What it drops is the touch
    // row's `Scrollbar`/drag-to-page controller (`_rowPhysics`): the widget that
    // makes a sideways pull turn the level. Without it there is nothing to slide.
    expect(
      find.ancestor(of: rail, matching: find.byType(Scrollbar)),
      findsNothing,
    );
    // And the overflow became a menu, not the end of a slide: the ninth+ 主题 is
    // not a child of the row anywhere (a scrolled-off touch chip would still be
    // built here), it is only behind 更多 ▾.
    expect(find.byKey(const ValueKey('theme-rail-cate_15')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('theme-rail-more')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('theme-rail-menu-cate_15')),
      findsOneWidget,
    );
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('词表缺行: the drawer says so and the 类型 row still works', (
    tester,
  ) async {
    final catalog = await mount(tester, UnfilteredCatalog());
    // 主题 and the drawer come from the SAME filterRows call, so when that call is
    // empty the whole 主题 rail disappears rather than showing empty chips -- the
    // §6.1.5 desktop branch replaces the row's body with a status line.
    expect(find.byKey(const ValueKey('theme-rail')), findsNothing);
    expect(find.byKey(const ValueKey('theme-rail-missing')), findsOneWidget);
    // 类型 does not ride on selector_rows: the row is still here and still tappable.
    final genre = find.byKey(
      const ValueKey('filter-genre-discover-comic_series'),
    );
    expect(genre, findsOneWidget);
    await tester.tap(genre);
    await tester.pumpAndSettle();
    expect(catalog.lastGenre, 'comic_series');

    await tester.tap(find.text('≡ 更多筛选'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-panel')), findsOneWidget);
    // Not a blank box: it names the missing vocabulary and offers the way back.
    expect(find.text('本次词表没给任何筛选维度。'), findsOneWidget);
    expect(find.byKey(const ValueKey('filter-panel-missing')), findsOneWidget);
    expect(find.byKey(const ValueKey('filter-panel-retry')), findsOneWidget);
    // No 维度 was invented to fill the gap: the rows the vocabulary would have
    // carried are absent.
    expect(find.text('穿越'), findsNothing);
    expect(find.text('男频'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('a second 维度 does not close the drawer', (tester) async {
    final catalog = await mount(tester, DesktopCatalog());
    await tester.tap(find.text('≡ 更多筛选'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('filter-dim-gender-gender_1')));
    await tester.pumpAndSettle();
    // 选一项立刻发请求, but the drawer stays: a multi-dimension decision is made
    // one line at a time, closing is the viewer's call.
    expect(find.byKey(const ValueKey('filter-panel')), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('filter-dim-category_dim_role-role_1')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-panel')), findsOneWidget);
    // Both dimensions are in force: the trigger counts them, and the last query
    // the list is made of carries both.
    expect(find.text('≡ 更多筛选 · 2'), findsOneWidget);
    expect(catalog.filtered.last.dims['gender'], ['gender_1']);
    expect(catalog.filtered.last.dims['category_dim_role'], ['role_1']);

    // 「不限」 clears only its own 维度: the request that goes out now is the other
    // dimension alone. (受众 is cleared rather than 设定 so the remaining 设定-only
    // feed is one the 保活 cache has never served -- clearing 设定 first would land
    // on the 受众-only feed already fetched above and restore it from cache rather
    // than ask again, which is the right behaviour but not one `browseFiltered`
    // gets to witness.)
    await tester.tap(find.byKey(const ValueKey('filter-any-gender')));
    await tester.pumpAndSettle();
    expect(find.text('≡ 更多筛选 · 1'), findsOneWidget);
    expect(catalog.filtered.last.dims.containsKey('gender'), isFalse);
    expect(catalog.filtered.last.dims['category_dim_role'], ['role_1']);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });
}
