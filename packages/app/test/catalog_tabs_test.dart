import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/features/library_page.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'fakes.dart';

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
  await tester.pumpAndSettle();
}

/// Themes answers late, the way a slow upstream does on a real phone, so the
/// entry into 分类 can be made while that request is still in the air.
class SlowThemeCatalog extends FakeCatalog {
  final themeCalls = <Completer<List<CatalogFilter>>>[];
  @override
  Future<List<CatalogFilter>> themes(String genre) {
    final result = Completer<List<CatalogFilter>>();
    themeCalls.add(result);
    return result.future;
  }
}

/// The next page of a list the viewer already has, held open the way a slow
/// connection does, so a refresh can be made to arrive while it is still
/// travelling.
class HeldMoreCatalog extends FakeCatalog {
  final pending = <Completer<CatalogPage>>[];
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) {
    if (cursor == null) {
      return super.browse(
        genre: genre,
        sort: sort,
        theme: theme,
        cursor: cursor,
        seen: seen,
      );
    }
    final result = Completer<CatalogPage>();
    pending.add(result);
    return result.future;
  }
}

/// The shell's own view of which page is on screen and which route is active.
/// Reading both is the point: they are only allowed to agree.
void expectPage(WidgetTester tester, int index) {
  final dynamic state = tester.state(find.byType(LibraryPage));
  expect(state.destination, index);
  expect(state.tabs!.activeIndex, index);
}

/// One page's own first level, as the viewer sees it and as its router holds
/// it. The chip that names the same page is selected with it, because a swipe
/// and a tap are only allowed to be two ways of arriving in one place.
void expectInner(WidgetTester tester, int pane, String slot) {
  final dynamic state = tester.state(find.byType(LibraryPage));
  expect(state.slotOfPane(pane), slot);
  final tabs = state.innerTabs[pane];
  expect(tabs, isNotNull, reason: 'page $pane has no router attached yet');
  expect(tabs.activeIndex, (state.slotSets[pane] as List).indexOf(slot));
}

Finder page(String name) => find.byKey(ValueKey('catalog-results-$name'));

/// A touch swipe is what a phone viewer has; the drag has to cross the page
/// with the same slop a finger does. One drag answers one level: the page it
/// started in moves its own first level, and a pull that runs out of those
/// pages is what the shell hears.
Future<void> swipe(WidgetTester tester, int pane, double dx) async {
  await tester.drag(page(pane == 0 ? 'discover' : 'categories'), Offset(dx, 0));
  await tester.pumpAndSettle();
}

/// The way from one catalog page to the other: the pages of the page being
/// left, then the one pull that has nowhere left to go inside it.
Future<void> swipeTo(WidgetTester tester, int to) async {
  for (var i = 0; i < 5; i++) {
    final dynamic state = tester.state(find.byType(LibraryPage));
    final from = state.destination as int;
    if (from == to) return;
    await swipe(tester, from, to > from ? -300 : 300);
  }
  fail('the handover never arrived at page $to');
}

void main() {
  testWidgets('a swipe moves one page of 发现 and nothing above it', (
    tester,
  ) async {
    final runtime = FakeRuntime();
    await mount(tester, runtime, const Size(390, 844));
    expectPage(tester, 0);
    expect(find.byKey(const ValueKey('swipe-hint')), findsOneWidget);
    final calls = runtime.catalog.browseCalls;
    await swipe(tester, 0, -300);
    // 推荐 → 最新 is a page of its own: the shell never hears of the pull, so
    // the catalog page stays where it was and its route does not move.
    expectPage(tester, 0);
    expectInner(tester, 0, 'latest');
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('filter-view-latest')))
          .selected,
      isTrue,
    );
    expect(runtime.catalog.browseCalls, greaterThan(calls));
    expect(find.text('山海之间'), findsWidgets);
    // The hint promises the handover too, and that has not happened yet.
    expect(find.byKey(const ValueKey('swipe-hint')), findsOneWidget);
    await swipe(tester, 0, 300);
    expectInner(tester, 0, 'recommend');
    expectPage(tester, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pull past the last of a page is handed to the shell', (
    tester,
  ) async {
    await mount(tester, FakeRuntime(), const Size(390, 844));
    await swipe(tester, 0, -300);
    expectInner(tester, 0, 'latest');
    // One more in the same direction: 最新 is the end of 发现's own pages, so
    // what is left of the pull belongs to the shell, and 分类 answers with its
    // own first level -- the type the catalog is shared on.
    await swipe(tester, 0, -300);
    expectPage(tester, 1);
    expectInner(tester, 1, 'short_play');
    expect(find.byKey(const ValueKey('theme-rail')), findsOneWidget);
    // The handover is the gesture the hint was waiting for.
    expect(find.byKey(const ValueKey('swipe-hint')), findsNothing);
    // Back the same way, and 发现 is still standing on the page it was left on.
    await swipe(tester, 1, 300);
    expectPage(tester, 0);
    expectInner(tester, 0, 'latest');
    expect(tester.takeException(), isNull);
  });

  testWidgets('分类 pages its own types before it pages the shell', (
    tester,
  ) async {
    final runtime = FakeRuntime();
    await mount(tester, runtime, const Size(390, 844));
    await swipeTo(tester, 1);
    expectInner(tester, 1, 'short_play');
    await swipe(tester, 1, -300);
    expectInner(tester, 1, 'comic_series');
    expectPage(tester, 1);
    expect(runtime.catalog.lastGenre, 'comic_series');
    await swipe(tester, 1, -300);
    expectInner(tester, 1, 'ai_series');
    expectPage(tester, 1);
    // One more: there is nothing past 分类, and the end of its own pages is
    // the end of the swipe.
    await swipe(tester, 1, -300);
    expectPage(tester, 1);
    expectInner(tester, 1, 'ai_series');
    expect(find.byKey(const ValueKey('my-page')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the navigation bar drives the same route as the swipe', (
    tester,
  ) async {
    await mount(tester, FakeRuntime(), const Size(390, 844));
    await tester.tap(find.text('分类').first);
    await tester.pumpAndSettle();
    expectPage(tester, 1);
    expectInner(tester, 1, 'short_play');
    // Back by hand rather than by the bar: the two ways cannot disagree. 分类
    // opens on the first of its own pages, so this pull has nowhere inside it
    // and goes straight to the shell.
    await swipe(tester, 1, 300);
    expectPage(tester, 0);
    expect(
      tester
          .widget<NavigationBar>(find.byKey(const ValueKey('catalog-tabs')))
          .selectedIndex,
      0,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a mouse drag pages nothing', (tester) async {
    await mount(tester, FakeRuntime(), const Size(1280, 900));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final start = tester.getCenter(page('discover')) + const Offset(-150, 120);
    await mouse.addPointer(location: start);
    await mouse.down(start);
    await tester.pump();
    // TestGesture timestamps are absolute, so the clock must move with every
    // step or the velocity estimate stays zero and the fling dies at release.
    for (final step in [1, 2, 3, 4]) {
      await mouse.moveTo(
        start - Offset(step * 100.0, 0),
        timeStamp: Duration(milliseconds: step * 20),
      );
      await tester.pump(Duration(milliseconds: 20));
    }
    await mouse.up(timeStamp: const Duration(milliseconds: 100));
    await mouse.removePointer();
    await tester.pumpAndSettle();
    // Neither level of the gesture answers a mouse: a pointer that drags to
    // select text is not a viewer asking for the next page.
    expectPage(tester, 0);
    expectInner(tester, 0, 'recommend');
    expect(find.byKey(const ValueKey('theme-rail')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a horizontal drag in a chip row scrolls the row, not the page', (
    tester,
  ) async {
    // Narrow enough that the two levels of 发现 do not fit and the row has
    // somewhere to scroll to.
    await mount(tester, FakeRuntime(), const Size(320, 844));
    final row = find.byKey(const ValueKey('filter-choices-discover'));
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: row, matching: find.byType(Scrollable)),
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    await tester.drag(row, const Offset(-160, 0));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(0));
    // The row still had width of its own, so the pull was spent there: not on
    // this page's level, and not on the shell's.
    expectPage(tester, 0);
    expectInner(tester, 0, 'recommend');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a row that runs out hands over one level at a time', (
    tester,
  ) async {
    await mount(tester, FakeRuntime(), const Size(320, 844));
    final row = find.byKey(const ValueKey('filter-choices-discover'));
    final dynamic state = tester.state(find.byType(LibraryPage));
    final innerLast = (state.slotSets[0] as List).length - 1;
    // Pull the row past its own width again and again. One pull can only be
    // charged to one level, because the level that spends it stops the
    // notification: so while 推荐 → 最新 is still available inside 发现, the
    // shell has to stay put -- and the same gesture still reaches it.
    for (var i = 0; i < 6 && state.destination == 0; i++) {
      final before = state.innerTabs[0].activeIndex as int;
      await tester.drag(row, const Offset(-260, 0));
      await tester.pumpAndSettle();
      if (before < innerLast) expectPage(tester, 0);
    }
    expectInner(tester, 0, 'latest');
    expectPage(tester, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('each page keeps its own rows across the handover', (
    tester,
  ) async {
    final runtime = FakeRuntime();
    await mount(tester, runtime, const Size(390, 844));
    // 分类 narrows to its own theme; 发现 keeps recommending.
    await swipeTo(tester, 1);
    await tester.tap(find.byKey(const ValueKey('theme-rail-cate_7')));
    await tester.pumpAndSettle();
    expect(runtime.catalog.lastTheme, 'cate_7');
    await swipeTo(tester, 0);
    expectPage(tester, 0);
    expect(find.text('山海之间'), findsWidgets);
    // 发现 asks for its stream without the theme picked one page over. The row
    // is wider than a phone, so the type is swiped into view first.
    final comicChip = find.byKey(
      const ValueKey('filter-genre-discover-comic_series'),
    );
    final calls = runtime.catalog.browseCalls;
    await tester.ensureVisible(comicChip);
    await tester.pumpAndSettle();
    await tester.tap(comicChip);
    await tester.pumpAndSettle();
    expect(runtime.catalog.browseCalls, greaterThan(calls));
    expect(runtime.catalog.lastTheme, isNull);
    expect(runtime.catalog.lastGenre, 'comic_series');
    // ...and the page left behind answers the same first level, because that
    // is one value shared by both.
    expect(tester.takeException(), isNull);
  });

  testWidgets('the shared type opens the matching page over there', (
    tester,
  ) async {
    final runtime = FakeRuntime();
    await mount(tester, runtime, const Size(390, 844));
    final aiChip = find.byKey(
      const ValueKey('filter-genre-discover-ai_series'),
    );
    await tester.ensureVisible(aiChip);
    await tester.pumpAndSettle();
    await tester.tap(aiChip);
    await tester.pumpAndSettle();
    // A shared type is a filter for 发现, not a page of it: the page on screen
    // stays the one the viewer was reading.
    expectInner(tester, 0, 'recommend');
    await swipeTo(tester, 1);
    expectPage(tester, 1);
    // The chip that names the shared level is selected over here too, and it
    // is selected by being the page on screen -- the router was brought to the
    // type, not told which page to draw.
    expectInner(tester, 1, 'ai_series');
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('filter-genre-categories-ai_series')),
          )
          .selected,
      isTrue,
    );
    expect(runtime.catalog.lastGenre, 'ai_series');
    expect(find.byKey(const ValueKey('theme-rail-cate_7')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('theme-rail')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('entering 分类 mid-flight leaves the theme request alone', (
    tester,
  ) async {
    final catalog = SlowThemeCatalog();
    await mount(tester, FakeRuntime(catalog), const Size(390, 844));
    // The page asks for its themes as it opens; the entry below lands while
    // that is still in the air.
    expect(catalog.themeCalls.length, 1);
    await tester.tap(find.text('分类').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // Refilling here would start a second request, and themes is one shared
    // flight: the new call cancels the running one and then joins its
    // cancellation, which the viewer reads as 题材加载失败.
    expect(catalog.themeCalls.length, 1);
    catalog.themeCalls.last.complete(const [CatalogFilter('悬疑', 'cate_9')]);
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(LibraryPage));
    expect(state.themesError, isNull);
    expectPage(tester, 1);
    expect(find.byKey(const ValueKey('theme-rail-cate_9')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('我的 stays out of the swipe', (tester) async {
    await mount(tester, FakeRuntime(), const Size(390, 844));
    await swipeTo(tester, 1);
    expectPage(tester, 1);
    // One more fling in the same direction: there is nothing past 分类.
    await swipe(tester, 1, -300);
    expectPage(tester, 1);
    expect(find.byKey(const ValueKey('my-page')), findsNothing);
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-page')), findsOneWidget);
    expectPage(tester, 1);
    // Coming back restores the page that was left, not a fresh request.
    await tester.tap(find.text('分类').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-page')), findsNothing);
    expectPage(tester, 1);
    expect(find.byKey(const ValueKey('theme-rail')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a page left during its own entry still fills its rows', (
    tester,
  ) async {
    await mount(tester, FakeRuntime(), const Size(390, 844));
    await tester.tap(find.text('分类').first);
    await tester.pump();
    expectPage(tester, 1);
    // 分类 is now waiting out the debounce it armed on entry. Leaving right
    // away puts 发现 back on screen while that is pending, so a single shared
    // timer would be cancelled as 发现's -- and a guard that reads the visible
    // page would skip the refresh of the page that asked for it.
    await tester.tap(find.text('发现').first);
    await tester.pump(const Duration(milliseconds: 100));
    expectPage(tester, 0);
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(LibraryPage));
    final dynamic left = state.feeds[state.feedKeyOf(1)];
    expect(left, isNotNull);
    expect(left.loading, isFalse);
    expect(left.refreshing, isFalse);
    expect(left.items, isNotEmpty);
    // The page that stayed never lost its own rows to the trip.
    expect(state.feed.items, isNotEmpty);
    expect(find.text('山海之间'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the open search panel is dismissed before the list can be swiped',
    (tester) async {
      await mount(tester, FakeRuntime(), const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('search-field-discover')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final dynamic state = tester.state(find.byType(LibraryPage));
      expect(state.suggestionsPane, 0);
      // The panel covers the screen with a dismiss layer, so nothing can be
      // swiped out from under it -- which is also why one panel can never be
      // hanging over the other page: it has to be closed first. Neither level
      // moves while it is open.
      await tester.drag(page('discover'), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expectPage(tester, 0);
      expectInner(tester, 0, 'recommend');
      expect(state.suggestionsPane, 0);
      await tester.tap(
        find.byKey(const ValueKey('search-suggestions-dismiss')),
      );
      await tester.pumpAndSettle();
      expect(state.suggestionsPane, isNull);
      await swipe(tester, 0, -300);
      expectInner(tester, 0, 'latest');
      await swipeTo(tester, 1);
      expectPage(tester, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'one themes flight per type, even when the list reloads under it',
    (tester) async {
      final catalog = SlowThemeCatalog();
      await mount(tester, FakeRuntime(catalog), const Size(390, 844));
      expect(catalog.themeCalls.length, 1);
      await tester.enterText(
        find.byKey(const ValueKey('search-field-discover')),
        '山海',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      // Clearing the term reloads 发现 from its first page, and that reload asks
      // for the themes of the type it is already waiting on. Starting a second
      // flight would cancel the first and then join its cancellation, which the
      // viewer reads as 题材加载失败.
      await tester.tap(find.byKey(const ValueKey('clear-search-discover')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(catalog.themeCalls.length, 1);
      catalog.themeCalls.last.complete(const [CatalogFilter('悬疑', 'cate_9')]);
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(LibraryPage));
      expect(state.themesError, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a refresh takes over the page that was still on its way', (
    tester,
  ) async {
    final runtime = FakeRuntime(HeldMoreCatalog());
    await mount(tester, runtime, const Size(390, 844));
    final dynamic state = tester.state(find.byType(LibraryPage));
    expect(state.feed.cursor, isNotNull);
    await tester.tap(find.text('加载更多'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // The second page is in the air, and nothing resets while 我的 covers the
    // list -- the overlay is not a feed switch.
    final held = (runtime.catalog as HeldMoreCatalog).pending.single;
    expect(state.feed.loadingMore, isTrue);
    await tester.tap(find.text('我的').last);
    // Short pumps, not settle: the footer spinner for the page still in the
    // air is an animation that never ends until the refresh supersedes it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('my-page')), findsOneWidget);
    // Something in 我的 moved the feed without changing what this page asks
    // for, so coming back refreshes it in place. A new catalog object answers
    // that refresh; the held page stays on its way.
    runtime.catalog = FakeCatalog();
    await runtime.saveSettings(const AppSettings(autoLoadMore: false));
    await tester.pump();
    await tester.tap(find.text('发现').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    // The refresh supersedes that page, so its flag has to go with it: left
    // set, the footer spins for a request that stopped existing and every
    // further 加载更多 is refused.
    expect(state.feed.loadingMore, isFalse);
    expect(find.text('正在加载更多…'), findsNothing);
    expect(find.text('加载更多'), findsOneWidget);
    held.complete(const CatalogPage([]));
    await tester.pumpAndSettle();
    final answered = runtime.catalog;
    final calls = answered.browseCalls;
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    // Paging is usable again, and the page that was dropped never appended.
    expect(answered.browseCalls, greaterThan(calls));
    expect(find.text('第二个故事'), findsWidgets);
    expect(state.feed.cursor, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the kept rows stop at a bound a typed search cannot outgrow', (
    tester,
  ) async {
    await mount(tester, FakeRuntime(), const Size(390, 844));
    // Both pages get a feed of their own before the terms start piling up: the
    // bound has to spare the two pages, not just whichever one is on screen.
    await swipeTo(tester, 1);
    await swipeTo(tester, 0);
    final field = find.byKey(const ValueKey('search-field-discover'));
    // One retained feed per term, so a viewer who searches their way through a
    // list of titles would otherwise keep every page they ever asked for.
    for (var i = 0; i < 36; i++) {
      await tester.enterText(field, '第$i次搜索');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
    }
    final dynamic state = tester.state(find.byType(LibraryPage));
    expect(state.feeds.length, lessThanOrEqualTo(32));
    expect(state.feeds.containsKey(state.feedKey), isTrue);
    expect(state.feeds.containsKey(state.feedKeyOf(1)), isTrue);
    expect(state.feed.items, isNotEmpty);
    expect(tester.takeException(), isNull);
  });
}
