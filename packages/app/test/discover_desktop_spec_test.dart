import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart'
    show ChoiceChip, Offset, Scrollable, ScrollableState, Scrollbar, Size, ValueKey;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_fakes.dart';

/// The handful of §6.1 / §10 promises the desktop layer suite does not already
/// hold: that 榜单 is a destination rather than a filter (and round-trips leave
/// the page alone), that the mouse family's 主题 row is the whole vocabulary on
/// one sliding strip with the same controller contract as the touch family, that
/// 词表缺行 speaks instead of opening an empty box, and that a multi-dimension
/// choice keeps the entry page under the viewer's hand.
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

  testWidgets('on desktop the 主题 row slides sideways with a controller of its own', (
    tester,
    ) async {
    await mount(tester, DesktopCatalog());
    final rail = find.byKey(const ValueKey('theme-rail'));
    // 整词表横滑之后，这一行归入触控族同一条 controller 契约：Scrollbar 挂在
    // 自己的 controller 上，而不是落在断言过的 PrimaryScrollController 陷阱里。
    expect(
      find.ancestor(of: rail, matching: find.byType(Scrollbar)),
      findsOneWidget,
    );
    // 溢出不再是菜单：第九个之后的 主题 也是行的孩子，整行靠水平滑动读完。
    expect(find.byKey(const ValueKey('theme-rail-cate_15')), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-rail-more')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('词表缺行: the entry page says so and the 类型 row still works', (
    tester,
  ) async {
    final catalog = await mount(tester, UnfilteredCatalog());
    // 主题 and the entry page come from the SAME filterRows call, so when that
    // call is empty the whole 主题 rail disappears rather than showing empty
    // chips -- the §6.1.5 desktop branch replaces the row's body with a status line.
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
    expect(find.byKey(const ValueKey('filter-page-band')), findsOneWidget);
    // Not a blank box: it names the dimensions this type was expected to
    // publish and did not get (缺维三态如实呈现).
    expect(find.byKey(const ValueKey('filter-page-missing')), findsOneWidget);
    expect(
      find.text('本次词表没给：设定、背景、受众、状态、时间、画风'),
      findsOneWidget,
    );
    // No 维度 was invented to fill the gap: the rows the vocabulary would have
    // carried are absent.
    expect(find.text('穿越'), findsNothing);
    expect(find.text('男频'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('picking two 维度 on the entry page keeps both and writes back', (
    tester,
  ) async {
    final catalog = await mount(tester, DesktopCatalog());
    await tester.tap(find.text('≡ 更多筛选'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('filter-page-dim-gender-gender_1')),
    );
    await tester.pumpAndSettle();
    // 选一项立刻发请求, but the page stays: a multi-dimension decision is made
    // one line at a time, closing is the viewer's call.
    expect(find.byKey(const ValueKey('filter-page-band')), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('filter-page-dim-category_dim_role-role_1')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-page-band')), findsOneWidget);
    // Both dimensions are in force: the last query the page asked carries both.
    expect(catalog.filtered.last.dims['gender'], ['gender_1']);
    expect(catalog.filtered.last.dims['category_dim_role'], ['role_1']);

    // 「不限」 clears only its own 维度: the request that goes out now is the other
    // dimension alone. (受众 is cleared rather than 设定 so the remaining 设定-only
    // query is one the 保活 cache has never served -- clearing 设定 first would land
    // on the 受众-only feed already fetched above and restore it from cache rather
    // than ask again, which is the right behaviour but not one `browseFiltered`
    // gets to witness.)
    await tester.tap(find.byKey(const ValueKey('filter-page-any-gender')));
    await tester.pumpAndSettle();
    expect(catalog.filtered.last.dims.containsKey('gender'), isFalse);
    expect(catalog.filtered.last.dims['category_dim_role'], ['role_1']);

    // Esc closes the page, and the count the trigger reads back is the same
    // state the page wrote into -- no second sync pass.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-page-band')), findsNothing);
    expect(find.text('≡ 更多筛选 · 1'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  /// 三十条主题的词表在 1000 宽的行里横得足够远：第 10 枚 chip 点选后不被
  /// clamp 顶回两端，居中的量测是真的。
  Future<void> mountLong(WidgetTester tester) async {
    await mount(tester, LongThemeCatalog());
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpAndSettle();
  }

  double railPixels(WidgetTester tester) => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('theme-rail')),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position
      .pixels;

  double railMax(WidgetTester tester) => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('theme-rail')),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position
      .maxScrollExtent;

  testWidgets('点选第 10 枚 chip 后它停在行的水平中心', (tester) async {
    await mountLong(tester);
    final rail = find.byKey(const ValueKey('theme-rail'));
    final chip = find.byKey(const ValueKey('theme-rail-cate_30'));
    // 先把目标带进视口：观者必须点得到它，然后行再把读到的那一句送到中心。
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pumpAndSettle();
    final chipCenter = tester.getCenter(chip).dx;
    final viewportCenter = tester.getRect(rail).center.dx;
    final chipWidth = tester.getSize(chip).width;
    expect(
      (chipCenter - viewportCenter).abs(),
      lessThanOrEqualTo(chipWidth / 2),
      reason: 'chip center $chipCenter against viewport center $viewportCenter',
    );
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('行两端的箭头把行滑出一段，且到边界即隐', (tester) async {
    await mountLong(tester);
    final rail = find.byKey(const ValueKey('theme-rail'));
    // 箭头 hover 渐显：指针落到行上之前，行尾只有渐隐，没有按钮。
    expect(find.byKey(const ValueKey('theme-rail-arrow-right')), findsNothing);
    await hover(tester, rail);
    await tester.pump();
    final right = find.byKey(const ValueKey('theme-rail-arrow-right'));
    expect(right, findsOneWidget);
    await tester.tap(right);
    await tester.pumpAndSettle();
    expect(railPixels(tester), greaterThan(0));
    // 滑过一段之后左端也有内容可回，左箭头就位；连点右箭头滑到尽头，右箭头隐去。
    // （不把行拖过界：rail 拖到尽头的余量按既有仲裁交给上一级，会切类型重铺。）
    expect(find.byKey(const ValueKey('theme-rail-arrow-left')), findsOneWidget);
    for (var i = 0; i < 6; i++) {
      final rightNow = find.byKey(const ValueKey('theme-rail-arrow-right'));
      if (rightNow.evaluate().isEmpty) break;
      await tester.tap(rightNow);
      await tester.pumpAndSettle();
    }
    expect(railPixels(tester), railMax(tester));
    expect(find.byKey(const ValueKey('theme-rail-arrow-right')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('减少动态效果时点选的居中即时到位', (tester) async {
    await mountLong(tester);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    // 先把行停在中间某处，再点一枚目标 offset 不同的 chip。
    await tester.drag(find.byKey(const ValueKey('theme-rail')), const Offset(-400, 0));
    await tester.pumpAndSettle();
    final chip = find.byKey(const ValueKey('theme-rail-cate_30'));
    await tester.tap(chip);
    // 只泵一帧：post-frame 的 jumpTo 已经执行，没有 200ms 的滑行可等。
    await tester.pump();
    final jumped = railPixels(tester);
    await tester.pumpAndSettle();
    final settled = railPixels(tester);
    expect(jumped, settled);
    expect(jumped, greaterThan(0));
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });
}
