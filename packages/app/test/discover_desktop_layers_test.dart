import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart' show ChoiceChip, ValueKey;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/library_page.dart' show DramaCard;

import 'desktop_fakes.dart';

void main() {
  testWidgets('the strip of the mouse family ends in 更多筛选 and 排序', (
    tester,
  ) async {
    await mount(tester, DesktopCatalog());
    expect(find.text('≡ 更多筛选'), findsOneWidget);
    expect(find.byKey(const ValueKey('sort-menu')), findsOneWidget);
    // The two words the dropdown replaced are gone from the row, not hidden
    // behind it: 推荐 maps to no sort upstream publishes, so on this family the
    // chip would be a question with no answer.
    expect(find.byKey(const ValueKey('filter-view-latest')), findsNothing);
    expect(find.byKey(const ValueKey('filter-view-recommend')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('the theme row stops at eight and hands the tail to 更多 ▾', (
    tester,
  ) async {
    await mount(tester, DesktopCatalog());
    expect(find.byKey(const ValueKey('theme-rail-cate_10')), findsOneWidget);
    // The ninth theme and 全部 make the head eight; the rest is in the menu.
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

  testWidgets(
    'F opens the drawer, a line of it changes the request, Esc closes',
    (tester) async {
      final catalog = await mount(tester, DesktopCatalog());
      await tester.tap(find.text('≡ 更多筛选'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('filter-panel')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('filter-panel-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('filter-panel')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('filter-panel')), findsOneWidget);
      final before = catalog.browseCalls;
      await tester.tap(
        find.byKey(const ValueKey('filter-dim-category_dim_role-role_1')),
      );
      await tester.pumpAndSettle();
      // 只改请求：the drawer stays, the page does not turn, and the dimension went
      // into the query the list is now made of.
      expect(find.byKey(const ValueKey('filter-panel')), findsOneWidget);
      expect(catalog.filtered.last.dims['category_dim_role'], ['role_1']);
      expect(catalog.browseCalls, before);
      expect(find.text('≡ 更多筛选 · 1'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('filter-panel')), findsNothing);
      // 规格：`Esc` 把焦点还给触发它的那枚 chip,不是还给页面顶部。
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'discover-filter-chip',
      );
      debugDefaultTargetPlatformOverride = null;
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('O opens 排序, Esc closes it without asking for anything', (
    tester,
  ) async {
    final catalog = await mount(tester, DesktopCatalog());
    // The keys live on the shell, so they answer wherever the pointer left the
    // focus -- here on the 更多筛选 chip, which is where 完成 handed it back.
    await tester.tap(find.text('≡ 更多筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter-panel-done')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sort-hot_score')), findsOneWidget);
    final before = catalog.browseCalls;
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sort-hot_score')), findsNothing);
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'discover-sort-chip',
    );
    // Opening and dismissing a dropdown is not a decision: nothing was asked for.
    expect(catalog.browseCalls, before);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('排序 asks for the same page again and does not move the list', (
    tester,
  ) async {
    final catalog = await mount(tester, DesktopCatalog());
    await openSort(tester);
    expect(find.byKey(const ValueKey('sort-hot_score')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sort-hot_score')));
    await tester.pumpAndSettle();
    expect(catalog.lastSort, 'hot_score');
    // The dropdown reads the 档 actually in force, and the level it sits on has
    // not moved: 全部主题 is still the row's own selection.
    expect(find.text('排序 · 最高热度'), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('theme-rail-')))
          .selected,
      isTrue,
    );
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('hovering a card for 1.5s brings the preview and 找同题材 hits', (
    tester,
  ) async {
    final catalog = await mount(tester, TaggedCatalog(const ['玄幻']));
    await hover(tester, find.byType(DramaCard));
    // Not before the pause is up: crossing the grid is not an interest signal.
    await tester.pump(const Duration(milliseconds: 1400));
    expect(find.byKey(const ValueKey('peek-drill-theme')), findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('peek-drill-theme')), findsOneWidget);
    expect(find.text('玄幻 · 12 集'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('peek-drill-theme')));
    await tester.pumpAndSettle();
    expect(catalog.lastTheme, 'cate_7');
    expect(find.byKey(const ValueKey('peek-drill-theme')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('a word outside this type list is not stretched to a near one', (
    tester,
  ) async {
    final catalog = await mount(tester, TaggedCatalog(const ['恋爱']));
    await hover(tester, find.byType(DramaCard));
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.tap(find.byKey(const ValueKey('peek-drill-theme')));
    await tester.pumpAndSettle();
    // 未命中：the theme goes back to 全部 rather than to the nearest word, and the
    // readout names how many themes this type actually publishes.
    expect(catalog.lastTheme, isNull);
    expect(
      find.textContaining('本类型只有 12 个主题', skipOffstage: false),
      findsOneWidget,
    );
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('看它所在的榜 switches destination on the mapped 赛道', (tester) async {
    final catalog = await mount(tester, TaggedCatalog(const ['玄幻']));
    await hover(tester, find.byType(DramaCard));
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.tap(find.byKey(const ValueKey('peek-drill-rank')));
    await tester.pumpAndSettle();
    // 短剧 is ranked by the `human` 赛道, and the 热播榜 under it is named from the
    // tree this fake published rather than from an id pinned in the client.
    expect(catalog.rankRequests.first.$1, 'human');
    expect(catalog.rankRequests.last.$2, 'human_hot_play');
    expect(find.byKey(const ValueKey('rank-tracks')), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('a single key does not steal a letter the viewer is typing', (
    tester,
  ) async {
    await mount(tester, DesktopCatalog());
    await tester.tap(find.byKey(const ValueKey('search-field-discover')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-panel')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });
}
