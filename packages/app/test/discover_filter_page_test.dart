import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/main.dart';
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

/// The entry page is the same full-screen page on both families; these promises
/// are asked on the touch family (390×844), where the chip rows are the
/// horizontally sliding ones the contract names.
Future<FilterPageCatalog> mountPage(WidgetTester tester, FilterPageCatalog catalog) async {
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

  testWidgets('鼠标经过筛选 chip 时整圈 rim 高亮', (tester) async {
    await mountPage(tester, FilterPageCatalog());
    await openPage(tester);
    final chip = find.byKey(const ValueKey('filter-page-theme-all'));
    final scale = find.ancestor(
      of: chip,
      matching: find.byType(AnimatedScale),
    );
    expect(tester.widget<AnimatedScale>(scale).scale, 1.0);

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
}
