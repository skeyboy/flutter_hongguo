import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_app/widgets/hover_glow.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'desktop_fakes.dart' show DesktopCatalog;
import 'fakes.dart';

/// A filtered browse the entry page can be pinned against: records every
/// `browseFiltered` it is asked (inherited from `DesktopCatalog`), and can be
/// told to answer empty or to fail, so the three states the page owes the
/// viewer (empty / error) are exercised against the real branches.
class FilterPageCatalog extends DesktopCatalog {
  FilterPageCatalog({this.empty = false, bool fail = false}) {
    this.fail = fail;
  }
  final bool empty;
  @override
  Future<CatalogPage> browseFiltered(CatalogQuery query) async {
    filtered.add(query);
    lastGenre = query.genre;
    lastSort = query.sort;
    if (this.fail) throw const CatalogError('上游暂时不可用');
    if (empty) return const CatalogPage([]);
    return cursorPage(query.cursor);
  }
}

/// A grid long enough to scroll past the band's fold threshold.
class LongFilterPageCatalog extends FilterPageCatalog {
  @override
  Future<CatalogPage> browseFiltered(CatalogQuery query) async {
    filtered.add(query);
    lastGenre = query.genre;
    lastSort = query.sort;
    return CatalogPage([
      for (var i = 0; i < 24; i++)
        Drama(id: 'long-$i', title: '长列表故事$i', episodeCount: 12),
    ]);
  }
}

/// 触控端自动加载用的源：首屏给 24 张且带 nextCursor（列表足够长，能滚到
/// 「接近底部」），下一页可控地失败。盯住「失败后停止自动重试，只有显式重试
/// 才再问一次」这条契约。
class AutoMoreCatalog extends FilterPageCatalog {
  bool failMore = false;

  @override
  Future<CatalogPage> browseFiltered(CatalogQuery query) async {
    filtered.add(query);
    lastGenre = query.genre;
    lastSort = query.sort;
    if (query.cursor != null && failMore) {
      throw const CatalogError('下一页暂时不可用');
    }
    return CatalogPage([
      for (var i = 0; i < 24; i++)
        Drama(
          id: 'auto-${query.cursor ?? 'first'}-$i',
          title: '自动加载故事$i',
          episodeCount: 12,
        ),
    ], nextCursor: query.cursor == null ? 'next' : null);
  }
}

/// 真实上游一次给齐的五个维度：桌面窗口矮一点时，筛选带的自然高度就会超过
/// 整页可用高度——这正是 macOS 上 Column 底部 overflow 的那一类输入。
class TallFilterPageCatalog extends FilterPageCatalog {
  @override
  Future<CatalogPage> browseFiltered(CatalogQuery query) async => CatalogPage([
    for (var i = 0; i < 24; i++)
      Drama(id: 'tall-$i', title: '长列表故事$i', episodeCount: 12),
  ]);

  @override
  Future<List<CatalogDim>> filterRows(String genre) async => [
    CatalogDim(
      key: categoryThemeKey,
      label: catalogDimRowNames[categoryThemeKey]!,
      items: DesktopCatalog.themeItems,
    ),
    for (final key in const <String>[
      'category_dim_role',
      'category_dim_epoch',
      'gender',
      'online_time',
    ])
      CatalogDim(
        key: key,
        label: catalogDimRowNames[key] ?? key,
        items: [
          CatalogFilter('选项一', '${key}_1'),
          CatalogFilter('选项二', '${key}_2'),
        ],
      ),
  ];
}

/// 桌面尺寸下把入口页挂起来：macOS 宿主 + 矮窗口，筛选带是固定头。
Future<void> mountDesktopPage(
  WidgetTester tester,
  FilterPageCatalog catalog, {
  Size size = const Size(1000, 600),
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  await tester.binding.setSurfaceSize(size);
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
  // 桌面族的入口是 `≡ 更多筛选` 按钮，键是 GlobalKey，按文案点。
  await tester.tap(find.text('≡ 更多筛选'));
  await tester.pumpAndSettle();
}

/// The entry page is the same full-screen page on both families; these promises
/// are asked on the touch family (390×844), where the chip rows are the
/// horizontally sliding ones the contract names.
Future<FilterPageCatalog> mountPage(
  WidgetTester tester,
  FilterPageCatalog catalog, {
  bool autoLoadMore = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final runtime = FakeRuntime(catalog)
    ..settings = AppSettings(autoLoadMore: autoLoadMore);
  addTearDown(runtime.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [runtimeProvider.overrideWith((ref) async => runtime)],
      child: const HongguoApp(),
    ),
  );
  await tester.pumpAndSettle();
  return catalog;
}

/// The `≡` at the tail of the touch family's pinned second row opens the page.
Future<void> openPage(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('filter-narrow')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('打开即带当前 genre 与已选 dims', (tester) async {
    final catalog = await mountPage(tester, FilterPageCatalog());
    // Stand on one 题材 first, so the page has a selection to arrive with.
    await tester.ensureVisible(find.byKey(const ValueKey('theme-rail-cate_7')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('theme-rail-cate_7')));
    await tester.pumpAndSettle();

    await openPage(tester);
    // The page's first grid request was made before the viewer touched
    // anything: same genre, same theme -- one state, not a copy.
    expect(catalog.filtered.last.genre, 'short_play');
    expect(
      catalog.filtered.last.dims['category_dim_theme'],
      ['cate_7'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('点维度 chip 后 grid 收到的 dims 变化', (tester) async {
    final catalog = await mountPage(tester, FilterPageCatalog());
    await openPage(tester);
    await tester.tap(
      find.byKey(const ValueKey('filter-page-dim-category_dim_role-role_1')),
    );
    await tester.pumpAndSettle();
    // The query the page's own grid asked for now carries the pick.
    expect(
      catalog.filtered.last.dims['category_dim_role'],
      ['role_1'],
    );
    // 「不限」 puts it back: an empty key is what upstream expects.
    await tester.tap(find.byKey(const ValueKey('filter-page-any-category_dim_role')));
    await tester.pumpAndSettle();
    expect(
      catalog.filtered.last.dims.containsKey('category_dim_role'),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('切一级清失效选中并 toast 明示', (tester) async {
    final catalog = await mountPage(tester, FilterPageCatalog());
    await openPage(tester);
    await tester.tap(
      find.byKey(const ValueKey('filter-page-dim-category_dim_role-role_1')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('filter-page-genre-comic_series')));
    await tester.pumpAndSettle();
    // The pick belonged to the type that went away: the query the new type's
    // grid asked carries no 维度 at all, and the clearing was said out loud.
    expect(catalog.filtered.last.genre, 'comic_series');
    expect(catalog.filtered.last.dims.isEmpty, isTrue);
    expect(find.byKey(const ValueKey('filter-page-toast')), findsOneWidget);
    expect(find.textContaining('已清空'), findsOneWidget);
    // 让 SnackBar 的 4s 计时器走完，测试收尾不留 pending timer。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('重置按钮清空题材与全部维度', (tester) async {
    final catalog = await mountPage(tester, FilterPageCatalog());
    await openPage(tester);
    await tester.tap(
      find.byKey(const ValueKey('filter-page-dim-category_dim_role-role_1')),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('filter-page-theme-cate_8')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter-page-theme-cate_8')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('filter-page-reset')));
    await tester.pumpAndSettle();
    // 重置后问出去的请求不带任何选中：题材与维度一起回到「不限」。
    expect(catalog.filtered.last.dims.isEmpty, isTrue);
    expect(find.byKey(const ValueKey('filter-page-toast')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('加载更多按 cursor 追加', (tester) async {
    final catalog = await mountPage(tester, FilterPageCatalog());
    await openPage(tester);
    // Discover page keeps its own card with the same title underneath, so the
    // page's grid is addressed by its own card key.
    expect(find.byKey(const ValueKey('filter-page-card-123')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('filter-page-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter-page-more')));
    await tester.pumpAndSettle();
    // The next page was asked with the cursor the first one handed back, and
    // its rows are appended, not swapped in.
    expect(catalog.filtered.last.cursor, '18');
    expect(
      catalog.filtered.last.seen,
      contains('123'),
    );
    expect(find.byKey(const ValueKey('filter-page-card-123')), findsOneWidget);
    expect(find.byKey(const ValueKey('filter-page-card-124')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空结果给空态文案', (tester) async {
    await mountPage(tester, FilterPageCatalog(empty: true));
    await openPage(tester);
    expect(find.byKey(const ValueKey('filter-page-empty')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('错误态给重试，恢复后重新填上', (tester) async {
    final catalog = await mountPage(tester, FilterPageCatalog(fail: true));
    await openPage(tester);
    expect(find.byKey(const ValueKey('filter-page-error')), findsOneWidget);
    // The failure is not a dead end: recover it and the retry refills the grid.
    catalog.fail = false;
    await tester.tap(find.byKey(const ValueKey('filter-page-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-page-error')), findsNothing);
    expect(find.byKey(const ValueKey('filter-page-card-123')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面矮窗口下结果列表仍可滚动，筛选带不撑破页面', (tester) async {
    await mountDesktopPage(tester, TallFilterPageCatalog());

    // 结果列表有一个真正可滚的视口，而不是被固定筛选带吃到 0 高。
    final results = find.byKey(const ValueKey('filter-page-results'));
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: results, matching: find.byType(Scrollable)),
    );
    expect(tester.getSize(results).height, greaterThan(120));
    expect(scroll.position.maxScrollExtent, greaterThan(0));

    // 下滑：带让出高度，列表继续可滚，收起的是高度不是筛选状态。
    await tester.drag(results, const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-page-band')), findsNothing);
    expect(scroll.position.pixels, greaterThan(0));
    expect(tester.getSize(results).height, greaterThan(160));

    // 上滑：筛选项回到手边，收展契约在桌面矮窗口下一样成立。
    await tester.drag(results, const Offset(0, 80));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-page-band')), findsOneWidget);
    // 平台覆写要在测试体内还原：_verifyInvariants 先于 addTearDown 跑。
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('顶部筛选带随纵向滚动方向收展', (tester) async {
    await mountPage(tester, LongFilterPageCatalog());
    await openPage(tester);
    expect(find.byKey(const ValueKey('filter-page-band')), findsOneWidget);

    final results = find.byKey(const ValueKey('filter-page-results'));
    await tester.drag(results, const Offset(0, -300));
    await tester.pumpAndSettle();
    // Down the list the band gives its height to the grid.
    expect(find.byKey(const ValueKey('filter-page-band')), findsNothing);

    await tester.drag(results, const Offset(0, 80));
    await tester.pumpAndSettle();
    // Any upward flick brings the filters back, not only a trip to the top.
    expect(find.byKey(const ValueKey('filter-page-band')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('换筛选条件后结果从顶部呈现，收展本身不改 offset', (tester) async {
    await mountPage(tester, LongFilterPageCatalog());
    await openPage(tester);

    final results = find.byKey(const ValueKey('filter-page-results'));
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: results, matching: find.byType(Scrollable)),
    );
    // 滚到列表深处：带让出高度，offset > 0。
    await tester.drag(results, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, greaterThan(0));
    expect(find.byKey(const ValueKey('filter-page-band')), findsNothing);

    // 上滑把带带回手边：收展只改视口，不改 offset。
    await tester.drag(results, const Offset(0, 80));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-page-band')), findsOneWidget);
    expect(scroll.position.pixels, greaterThan(0));

    // 点题材 chip 换条件：新答案落地后从顶部呈现。
    final chip = find.byKey(const ValueKey('filter-page-theme-cate_7'));
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, greaterThan(0));
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('滚轮在横滑的题材行上横向走，不抢页面滚动', (tester) async {
    await mountPage(tester, FilterPageCatalog());
    await openPage(tester);
    final row = find.descendant(
      of: find.byKey(const ValueKey('filter-page-row-theme')),
      matching: find.byType(SingleChildScrollView),
    );
    final controller = tester.widget<SingleChildScrollView>(row).controller!;
    expect(controller.offset, 0);
    expect(controller.position.maxScrollExtent, greaterThan(0));

    final wheel = TestPointer(3, PointerDeviceKind.mouse);
    // A hover gives the pointer a location before the scroll signal is built.
    wheel.hover(tester.getCenter(row));
    await tester.sendEventToBinding(wheel.scroll(const Offset(0, 160)));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
    // 信号被这一行认领，外层列表不该同时被这一滚轮带跑。
    expect(find.byKey(const ValueKey('filter-page-band')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('键盘焦点得到同一圈高亮，方向键沿筛选行走', (tester) async {
    await mountPage(tester, FilterPageCatalog());
    await openPage(tester);
    final first = find.byKey(const ValueKey('filter-page-theme-all'));
    final second = find.byKey(const ValueKey('filter-page-theme-cate_7'));

    // Tab into the row: `Focus.of` here is the chip's non-focusable observer
    //, whose `hasFocus` covers its descendant when the real button owns focus.
    for (var i = 0; i < 12 && !Focus.of(tester.element(first)).hasFocus; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(Focus.of(tester.element(first)).hasFocus, isTrue);
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      tester.widget<AnimatedScale>(
        find.ancestor(of: first, matching: find.byType(AnimatedScale)),
      ).scale,
      closeTo(1.04, 0.001),
    );

    // 左右键在行内交棒，高亮跟着焦点走；Esc 仍留给页面关闭。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(second)).hasFocus, isTrue);
    expect(
      tester.widget<AnimatedScale>(
        find.ancestor(of: second, matching: find.byType(AnimatedScale)),
      ).scale,
      closeTo(1.04, 0.001),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('鼠标经过筛选 chip 时整圈 rim 高亮', (tester) async {
    await mountPage(tester, FilterPageCatalog());
    await openPage(tester);
    final chip = find.byKey(const ValueKey('filter-page-theme-all'));
    final scale = find.ancestor(
      of: chip,
      matching: find.byType(AnimatedScale),
    );
    expect(tester.widget<AnimatedScale>(scale).scale, 1.0);
    // rim 圆角跟随 M3 ChoiceChip 的 8，和 library_page 题材 chip 同一条契约；
    // 不再是一圈落在 chip 内侧、读成错位边框的 18。
    final glow = find.ancestor(of: chip, matching: find.byType(HoverGlow));
    expect(tester.widget<HoverGlow>(glow).radius, 8);

    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(pointer.removePointer);
    await pointer.addPointer(location: tester.getCenter(chip));
    await pointer.moveTo(tester.getCenter(chip));
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.widget<AnimatedScale>(scale).scale, closeTo(1.04, 0.001));

    await pointer.moveTo(Offset.zero);
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.widget<AnimatedScale>(scale).scale, 1.0);
    expect(tester.takeException(), isNull);
  });

  /// 把触控端结果列表挪到「接近底部」，让 extentAfter 落到 600 以内。
  Future<ScrollableState> nearBottom(WidgetTester tester) async {
    final results = find.byKey(const ValueKey('filter-page-results'));
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: results, matching: find.byType(Scrollable)),
    );
    scroll.position.jumpTo(scroll.position.maxScrollExtent - 100);
    await tester.pumpAndSettle();
    return scroll;
  }

  testWidgets('触控端接近底部自动加载下一页', (tester) async {
    final catalog = await mountPage(
      tester,
      AutoMoreCatalog(),
      autoLoadMore: true,
    );
    await openPage(tester);
    expect(catalog.filtered.length, 1);

    await nearBottom(tester);
    // 自动加载用首屏给的 nextCursor 追问了第二页，卡片追加进来。
    expect(catalog.filtered.length, 2);
    expect(catalog.filtered.last.cursor, 'next');
    expect(
      find.byKey(const ValueKey('filter-page-card-auto-next-0')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('加载更多失败后停自动重试，只有显式重试才再问一次', (tester) async {
    final catalog = AutoMoreCatalog()..failMore = true;
    await mountPage(tester, catalog, autoLoadMore: true);
    await openPage(tester);
    expect(catalog.filtered.length, 1);

    await nearBottom(tester);
    // 自动加载问了第二页、失败，结果尾部露出显式重试入口。
    expect(catalog.filtered.length, 2);
    expect(find.byKey(const ValueKey('filter-page-more-retry')), findsOneWidget);

    // 继续在底部附近滑动：不该再刷出一串注定失败的请求。
    final scroll = await nearBottom(tester);
    scroll.position.jumpTo(scroll.position.maxScrollExtent - 20);
    await tester.pumpAndSettle();
    expect(catalog.filtered.length, 2);

    // 只有显式重试才再问一次，成功后重试入口退场。
    catalog.failMore = false;
    await tester.tap(find.byKey(const ValueKey('filter-page-more-retry')));
    await tester.pumpAndSettle();
    expect(catalog.filtered.length, 3);
    expect(find.byKey(const ValueKey('filter-page-more-retry')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('换筛选清掉过期的加载更多错误，自动加载恢复', (tester) async {
    final catalog = AutoMoreCatalog()..failMore = true;
    await mountPage(tester, catalog, autoLoadMore: true);
    await openPage(tester);

    await nearBottom(tester);
    expect(find.byKey(const ValueKey('filter-page-more-retry')), findsOneWidget);

    // 上滑把筛选带带回手边，换一个题材——这是一次全新的提问。
    final results = find.byKey(const ValueKey('filter-page-results'));
    await tester.drag(results, const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-page-band')), findsOneWidget);

    catalog.failMore = false;
    final chip = find.byKey(const ValueKey('filter-page-theme-cate_7'));
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pumpAndSettle();

    final before = catalog.filtered.length;
    await nearBottom(tester);
    // 新结果集里自动加载重新工作。
    expect(catalog.filtered.length, before + 1);
    expect(catalog.filtered.last.cursor, 'next');
    expect(tester.takeException(), isNull);
  });

  testWidgets('顶部导航栏筛选按钮收起与展开抽屉', (tester) async {
    await mountPage(tester, FilterPageCatalog());
    await openPage(tester);
    // 默认展开：完整筛选带从顶部拉下。
    expect(find.byKey(const ValueKey('filter-page-band')), findsOneWidget);
    expect(find.byKey(const ValueKey('filter-page-drawer')), findsOneWidget);
    expect(find.byKey(const ValueKey('filter-page-drawer-peek')), findsNothing);

    final toggle = find.byKey(const ValueKey('filter-page-drawer-toggle'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    // 收起：带退场，留一条常驻窄条，结果列表仍在。
    expect(find.byKey(const ValueKey('filter-page-band')), findsNothing);
    expect(find.byKey(const ValueKey('filter-page-drawer-peek')), findsOneWidget);
    expect(find.byKey(const ValueKey('filter-page-results')), findsOneWidget);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    // 再点：带回来。
    expect(find.byKey(const ValueKey('filter-page-band')), findsOneWidget);
    expect(find.byKey(const ValueKey('filter-page-drawer-peek')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('收起态点常驻窄条可再次抽出抽屉', (tester) async {
    await mountPage(tester, FilterPageCatalog());
    await openPage(tester);
    await tester.tap(find.byKey(const ValueKey('filter-page-drawer-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-page-drawer-peek')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('filter-page-drawer-peek')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-page-band')), findsOneWidget);
    expect(find.byKey(const ValueKey('filter-page-drawer-peek')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('把手上拖收起、窄条下拖展开抽屉', (tester) async {
    await mountPage(tester, FilterPageCatalog());
    await openPage(tester);
    final handle = find.byKey(const ValueKey('filter-page-drawer-handle'));
    expect(handle, findsOneWidget);

    await tester.drag(handle, const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-page-band')), findsNothing);
    expect(find.byKey(const ValueKey('filter-page-drawer-peek')), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('filter-page-drawer-peek')),
      const Offset(0, 60),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-page-band')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('抽屉收起后结果列表仍可滚，窄条显示已选数量', (tester) async {
    await mountPage(tester, LongFilterPageCatalog());
    await openPage(tester);
    await tester.tap(
      find.byKey(const ValueKey('filter-page-dim-category_dim_role-role_1')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('filter-page-drawer-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('1 项已选'), findsOneWidget);

    final results = find.byKey(const ValueKey('filter-page-results'));
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: results, matching: find.byType(Scrollable)),
    );
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    await tester.drag(results, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
}
