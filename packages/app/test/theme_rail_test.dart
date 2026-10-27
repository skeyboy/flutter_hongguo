import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/features/library_page.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'fakes.dart';

/// Every browse call is held open by the test, so a theme switch can be
/// observed before and after its response arrives.
class RailCatalog extends FakeCatalog {
  final pending = <Completer<CatalogPage>>[];
  @override
  Future<List<CatalogFilter>> themes(String genre) async => const [
    CatalogFilter('玄幻', 'cate_7'),
    CatalogFilter('都市', 'cate_8'),
  ];

  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) {
    lastGenre = genre;
    lastTheme = theme;
    final result = Completer<CatalogPage>();
    pending.add(result);
    return result.future;
  }
}

/// The 排行 board answers immediately; only the browse feeds are held open.
class RailRankCatalog extends RailCatalog implements RankCatalogRepository {
  @override
  Future<CatalogPage> rank({
    String board = 'recommend',
    String? cursor,
  }) async => rows('榜');
}

CatalogPage rows(String tag) => CatalogPage(
  List.generate(90, (i) => Drama(id: '$tag-$i', title: '$tag故事$i')),
  nextCursor: '$tag-next',
);

Future<void> mount(WidgetTester tester, FakeRuntime runtime, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  runtime.settings = const AppSettings(autoLoadMore: false);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [runtimeProvider.overrideWith((ref) async => runtime)],
      child: const HongguoApp(),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

/// Enters 分类, where the rail has 全部 / 玄幻 / 都市, and answers the request.
Future<void> openCategory(WidgetTester tester, RailCatalog catalog) async {
  // Nothing settles while a held request is open, so answer 发现 first.
  for (final page in catalog.pending) {
    if (!page.isCompleted) page.complete(rows('发现'));
  }
  await tester.pump();
  await tester.tap(find.text('分类').first);
  // A page that has never been opened waits out the switch pause before it
  // asks for its first page, so the request is not there yet right after the
  // tap.
  await tester.pump(const Duration(milliseconds: 300));
  catalog.pending.last.complete(rows('全部'));
  await tester.pumpAndSettle();
}

/// Answers every request a move between the two pages woke up. Entering a page
/// refreshes the one it left, and a held request keeps that refresh spinner
/// turning, so nothing here may be left to [WidgetTester.pumpAndSettle] alone.
Future<void> answer(
  WidgetTester tester,
  RailCatalog catalog,
  String tag,
) async {
  await tester.pump(const Duration(milliseconds: 300));
  for (final page in catalog.pending) {
    if (!page.isCompleted) page.complete(rows(tag));
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the rail is on screen without opening a sheet', (tester) async {
    final catalog = RailCatalog();
    await mount(tester, FakeRuntime(catalog), const Size(390, 844));
    await openCategory(tester, catalog);
    expect(find.byKey(const ValueKey('theme-rail')), findsOneWidget);
    expect(find.text('玄幻'), findsOneWidget);
    expect(find.text('都市'), findsOneWidget);
    // The panel trigger the theme used to hide behind is gone.
    expect(find.byKey(const ValueKey('sticky-theme')), findsNothing);
    expect(find.byKey(const ValueKey('horizontal-filter-panel')), findsNothing);
  });

  testWidgets('a kept theme returns with its rows, cursor and offset', (
    tester,
  ) async {
    final catalog = RailCatalog();
    await mount(tester, FakeRuntime(catalog), const Size(1280, 900));
    await openCategory(tester, catalog);
    await tester.tap(find.byKey(const ValueKey('theme-rail-cate_7')));
    await tester.pump(const Duration(milliseconds: 300));
    catalog.pending.last.complete(rows('玄幻'));
    await tester.pumpAndSettle();
    expect(find.text('玄幻故事0'), findsWidgets);
    await tester.drag(
      find.byKey(const ValueKey('catalog-results-categories')),
      const Offset(0, -2000),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(LibraryPage));
    final offset = state.scroll.offset as double;
    expect(offset, greaterThan(100));

    await tester.tap(find.byKey(const ValueKey('theme-rail-cate_8')));
    await tester.pump(const Duration(milliseconds: 300));
    catalog.pending.last.complete(rows('都市'));
    await tester.pumpAndSettle();
    expect(find.text('都市故事0'), findsWidgets);
    expect(find.text('玄幻故事0'), findsNothing);
    expect(state.feed.cursor, '都市-next');

    // Back to 玄幻: the rows and the scroll position are already there, even
    // though its refresh is still in flight. The restored offset means the
    // first row is off screen again, so any 玄幻 row proves the list is back.
    final before = catalog.pending.length;
    await tester.tap(find.byKey(const ValueKey('theme-rail-cate_7')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('玄幻故事'), findsWidgets);
    expect(state.scroll.offset, offset);
    expect(state.feed.cursor, '玄幻-next');
    expect(catalog.pending.length, before + 1);
    catalog.pending.last.complete(rows('玄幻'));
    await tester.pumpAndSettle();
    expect(find.textContaining('玄幻故事'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid taps wait for the pause and send one request', (
    tester,
  ) async {
    final catalog = RailCatalog();
    await mount(tester, FakeRuntime(catalog), const Size(1280, 900));
    await openCategory(tester, catalog);
    final before = catalog.pending.length;
    await tester.tap(find.byKey(const ValueKey('theme-rail-cate_7')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('theme-rail-cate_8')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(catalog.pending.length, before);
    await tester.pump(const Duration(milliseconds: 150));
    expect(catalog.pending.length, before + 1);
    expect(catalog.lastTheme, 'cate_8');
    catalog.pending.last.complete(rows('都市'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late response cannot overwrite the theme on screen', (
    tester,
  ) async {
    final catalog = RailCatalog();
    await mount(tester, FakeRuntime(catalog), const Size(1280, 900));
    await openCategory(tester, catalog);
    await tester.tap(find.byKey(const ValueKey('theme-rail-cate_7')));
    await tester.pump(const Duration(milliseconds: 300));
    final stale = catalog.pending.last;
    await tester.tap(find.byKey(const ValueKey('theme-rail-cate_8')));
    await tester.pump(const Duration(milliseconds: 300));
    final current = catalog.pending.last;
    current.complete(rows('都市'));
    await tester.pumpAndSettle();
    stale.complete(rows('玄幻'));
    await tester.pumpAndSettle();
    expect(find.text('都市故事0'), findsWidgets);
    expect(find.text('玄幻故事0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading a theme never moves the grid or the rail', (
    tester,
  ) async {
    final catalog = RailCatalog();
    await mount(tester, FakeRuntime(catalog), const Size(1280, 900));
    await openCategory(tester, catalog);
    final results = find.byKey(const ValueKey('catalog-results-categories'));
    final rail = find.byKey(const ValueKey('theme-rail'));
    final resultsRect = tester.getRect(results);
    final railRect = tester.getRect(rail);
    await tester.tap(find.byKey(const ValueKey('theme-rail-cate_7')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getRect(results), resultsRect);
    expect(tester.getRect(rail), railRect);
    catalog.pending.last.completeError(const CatalogError('上游暂时不可用'));
    await tester.pumpAndSettle();
    expect(tester.getRect(results), resultsRect);
    expect(tester.getRect(rail), railRect);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search and rank keep the rail out of the way', (tester) async {
    final catalog = RailRankCatalog();
    await mount(tester, FakeRuntime(catalog), const Size(1280, 900));
    await openCategory(tester, catalog);
    await tester.enterText(
      find.byKey(const ValueKey('search-field-categories')),
      '故事',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('theme-rail')), findsNothing);
    await tester.tap(find.text('清除搜索'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('theme-rail')), findsOneWidget);

    // 排行 boards have no themes, so the rail steps aside there too.
    await tester.tap(find.text('发现').first);
    await answer(tester, catalog, '发现');
    await tester.tap(find.byKey(const ValueKey('filter-view-rank')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('theme-rail')), findsNothing);
  });

  testWidgets('the keyboard selects the focused theme chip', (tester) async {
    final catalog = RailCatalog();
    await mount(tester, FakeRuntime(catalog), const Size(1280, 900));
    await openCategory(tester, catalog);
    await tabUntilFocused(
      tester,
      find.byKey(const ValueKey('theme-rail-cate_8')),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 300));
    expect(catalog.lastTheme, 'cate_8');
    catalog.pending.last.complete(rows('都市'));
    await tester.pumpAndSettle();
    expect(find.text('都市故事0'), findsWidgets);
  });
}

/// Tabs until the focus lands inside [target], which is how a viewer on a
/// keyboard reaches a chip. Short pumps are deliberate: the traversal passes
/// through an indeterminate spinner that never lets pumpAndSettle finish.
Future<void> tabUntilFocused(WidgetTester tester, Finder target) async {
  final wanted = target.evaluate().single;
  // Both pages are alive, so the traversal passes the whole 发现 page -- and
  // the suggestions panel its search box opens -- before it reaches the rail.
  for (var i = 0; i < 40; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final context = FocusManager.instance.primaryFocus?.context;
    if (context is! Element) continue;
    var inside = identical(context, wanted);
    context.visitAncestorElements((ancestor) {
      if (identical(ancestor, wanted)) inside = true;
      return true;
    });
    if (inside) return;
  }
  throw StateError('the theme chip never received focus');
}
