import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
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

/// [settle] is off for the catalogs that hold 题材 open: the pinned strip is a
/// loading spinner while a slow themes request is in the air on the page on
/// screen, and a spinner never lets [WidgetTester.pumpAndSettle] finish.
Future<void> mount(
  WidgetTester tester,
  FakeRuntime runtime,
  Size size, {
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  runtime.settings = const AppSettings(autoLoadMore: false);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [runtimeProvider.overrideWith((ref) async => runtime)],
      child: const HongguoApp(),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }
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

/// Enough children per type that the pinned strip has width of its own on a
/// narrow phone -- which is what a strip that can run out is asked about.
class WideThemesCatalog extends FakeCatalog {
  @override
  Future<List<CatalogFilter>> themes(String genre) async => const [
    CatalogFilter('玄幻', 'cate_7'),
    CatalogFilter('都市', 'cate_8'),
    CatalogFilter('悬疑', 'cate_9'),
    CatalogFilter('古风', 'cate_10'),
    CatalogFilter('甜宠', 'cate_11'),
  ];
}

/// Long enough that one list can be scrolled far past the band above it.
class LongRowsCatalog extends FakeCatalog {
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) async {
    browseCalls++;
    lastGenre = genre;
    lastSort = sort;
    lastTheme = theme;
    return CatalogPage(
      List.generate(
        60,
        (i) => Drama(id: 'row-$i', title: '长故事$i', episodeCount: 2),
      ),
    );
  }
}

dynamic shell(WidgetTester tester) => tester.state(find.byType(LibraryPage));

/// The shell's own view of which page is on screen and which route is active.
/// Reading both is the point: they are only allowed to agree.
void expectPage(WidgetTester tester, int index) {
  expect(shell(tester).destination, index);
  expect(shell(tester).tabs!.activeIndex, index);
}

/// One page's own first level -- 类型, the value both pages share. The chip
/// that names the same page is selected with it, because a swipe and a tap are
/// only allowed to be two ways of arriving in one place.
void expectInner(WidgetTester tester, int pane, String slot) {
  final state = shell(tester);
  expect(state.slotOfPane(pane), slot);
  final tabs = state.innerTabs[pane];
  expect(tabs, isNotNull, reason: 'page $pane has no router attached yet');
  expect(tabs.activeIndex, (state.slotSets[pane] as List).indexOf(slot));
}

/// The second level of one page: 题材 (or a 榜单 board, same notation) inside
/// the first-level page it is a child of. This is the innermost page a swipe
/// turns, so every handover test has to say which of the two it moved.
void expectLevel2(WidgetTester tester, int pane, String id) {
  final state = shell(tester);
  expect(state.level2At(pane, state.slotOfPane(pane) as String), id);
}

/// The list the viewer is actually looking at on one page: pane, 一级 and 二级
/// in one key. Dragging it is how a test asks the innermost level first, the
/// way a finger does.
Future<void> swipe(
  WidgetTester tester,
  int pane,
  double dx, {
  bool warnIfMissed = true,
}) async {
  final key = shell(tester).resultsKey(pane) as String;
  await tester.drag(
    find.byKey(ValueKey(key)),
    Offset(dx, 0),
    warnIfMissed: warnIfMissed,
  );
  await tester.pumpAndSettle();
}

/// The way from one catalog page to the other. Every pull answers one level --
/// 题材 first, then 类型 -- so the trip is as many drags as the pages between
/// where the viewer stands and the end of this page's own list.
Future<void> swipeTo(WidgetTester tester, int to) async {
  for (var i = 0; i < 16; i++) {
    final from = shell(tester).destination as int;
    if (from == to) return;
    await swipe(tester, from, to > from ? -300 : 300);
  }
  fail('the handover never arrived at page $to');
}

/// Turns one page to the end of its own two levels: every 题材 of the last
/// 类型, and no further.
Future<void> runToEnd(WidgetTester tester, int pane) async {
  for (var i = 0; i < 12; i++) {
    final state = shell(tester);
    if (state.slotOfPane(pane) == 'ai_series' &&
        state.level2At(pane, 'ai_series') == 'cate_7') {
      return;
    }
    await swipe(tester, pane, -300);
  }
  fail('page $pane never reached the end of its own levels');
}

/// The 玄幻 chip of the pinned strip -- both fakes hand every type the same
/// child, so the id is the same on whichever 类型 the test stands.
final Finder railTheme = find.byKey(const ValueKey('theme-rail-cate_7'));

void main() {
  testWidgets('a swipe turns the two levels inside 发现 first', (tester) async {
    final runtime = FakeRuntime();
    await mount(tester, runtime, const Size(390, 844));
    expectPage(tester, 0);
    expect(find.byKey(const ValueKey('swipe-hint')), findsOneWidget);
    // 发现 now answers the same two questions 分类 does, so its strip of 题材
    // is pinned on screen from the first frame.
    expect(find.byKey(const ValueKey('theme-rail')), findsOneWidget);
    // The innermost level first: 全部 → 玄幻 is one page of this type, and the
    // shell never hears of the pull.
    await swipe(tester, 0, -300);
    expectPage(tester, 0);
    expectInner(tester, 0, 'short_play');
    expectLevel2(tester, 0, 'cate_7');
    expect(runtime.catalog.lastTheme, 'cate_7');
    expect(tester.widget<ChoiceChip>(railTheme.hitTestable()).selected, isTrue);
    expect(find.text('山海之间'), findsWidgets);
    // 玄幻 is the end of this type's children: the next pull is spent on 类型
    // before anything above it.
    await swipe(tester, 0, -300);
    expectPage(tester, 0);
    expectInner(tester, 0, 'comic_series');
    expectLevel2(tester, 0, '');
    expect(runtime.catalog.lastGenre, 'comic_series');
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('filter-genre-discover-comic_series')),
          )
          .selected,
      isTrue,
    );
    // Back the same way: the pull from the left edge turns 类型 before it
    // turns anything else, and the theme picked inside 漫剧 belonged to 漫剧.
    await swipe(tester, 0, 300);
    expectPage(tester, 0);
    expectInner(tester, 0, 'short_play');
    expectLevel2(tester, 0, '');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pull past the last page of the last type is handed up', (
    tester,
  ) async {
    await mount(tester, FakeRuntime(), const Size(390, 844));
    final aiChip = find.byKey(
      const ValueKey('filter-genre-discover-ai_series'),
    );
    await tester.ensureVisible(aiChip);
    await tester.pumpAndSettle();
    await tester.tap(aiChip);
    await tester.pumpAndSettle();
    // A type is one of the page's own pages on either tab, so this tap moved
    // 发现 itself -- and the theme that rode the old type went with it.
    expectInner(tester, 0, 'ai_series');
    expectLevel2(tester, 0, '');
    await swipe(tester, 0, -300);
    expectLevel2(tester, 0, 'cate_7');
    // One more: nothing lies past 玄幻 and nothing lies past AI剧. What the
    // two levels of this page cannot spend the shell hears of, and 分类 opens
    // on the same two levels -- they are shared values, not per-page state.
    await swipe(tester, 0, -300);
    expectPage(tester, 1);
    expectInner(tester, 1, 'ai_series');
    expectLevel2(tester, 1, 'cate_7');
    expect(
      find.byKey(const ValueKey('theme-rail')).hitTestable(),
      findsOneWidget,
    );
    // The handover is the gesture the hint was waiting for.
    expect(find.byKey(const ValueKey('swipe-hint')), findsNothing);
    // Back by the bar: 发现 is still standing on the pages it was left on.
    await tester.tap(find.text('发现').first);
    await tester.pumpAndSettle();
    expectPage(tester, 0);
    expectInner(tester, 0, 'ai_series');
    expectLevel2(tester, 0, 'cate_7');
    expect(tester.takeException(), isNull);
  });

  testWidgets('分类 pages its own levels before it pages the shell', (
    tester,
  ) async {
    final runtime = FakeRuntime();
    await mount(tester, runtime, const Size(390, 844));
    await tester.tap(find.text('分类').first);
    await tester.pumpAndSettle();
    expectPage(tester, 1);
    expectInner(tester, 1, 'short_play');
    await swipe(tester, 1, -300);
    expectLevel2(tester, 1, 'cate_7');
    expectPage(tester, 1);
    await swipe(tester, 1, -300);
    expectInner(tester, 1, 'comic_series');
    expectPage(tester, 1);
    expect(runtime.catalog.lastGenre, 'comic_series');
    // Straight to the end of what this page itself holds.
    await runToEnd(tester, 1);
    expectInner(tester, 1, 'ai_series');
    expectLevel2(tester, 1, 'cate_7');
    // One more: there is nothing past 分类, and the end of its own pages is
    // the end of the swipe.
    await swipe(tester, 1, -300);
    expectPage(tester, 1);
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
    // opens on the first page of its first level, whose first page is also the
    // first of its own, so this pull has nowhere inside it and goes straight
    // to the shell.
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
    final start =
        tester.getCenter(
          find.byKey(ValueKey(shell(tester).resultsKey(0) as String)),
        ) +
        const Offset(-150, 120);
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
    // None of the three levels answers a mouse: a pointer that drags to
    // select text is not a viewer asking for the next page.
    expectPage(tester, 0);
    expectInner(tester, 0, 'short_play');
    expectLevel2(tester, 0, '');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a horizontal drag in a chip row scrolls the row, not the page', (
    tester,
  ) async {
    // Narrow enough that 频道 and 类型 together do not fit and the row has
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
    expectInner(tester, 0, 'short_play');
    expectLevel2(tester, 0, '');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pinned strip runs out into the type level, then the tab', (
    tester,
  ) async {
    await mount(tester, FakeRuntime(WideThemesCatalog()), const Size(320, 844));
    final rail = find.byKey(const ValueKey('theme-rail'));
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: rail, matching: find.byType(Scrollable)),
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    // While the strip has width of its own the pull is spent there: a strip
    // the viewer is reading is not a request to change the page under it.
    await tester.drag(rail, const Offset(-60, 0));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(0));
    expectPage(tester, 0);
    expectInner(tester, 0, 'short_play');
    // Past its own width the pull is asked of the level above it first: one
    // pull, one level -- and only what 类型 cannot spend reaches the shell.
    final state = shell(tester);
    for (var i = 0; i < 8 && state.destination == 0; i++) {
      await tester.drag(rail, const Offset(-260, 0));
      await tester.pumpAndSettle();
      if (state.genre != 'ai_series') expectPage(tester, 0);
    }
    expectPage(tester, 1);
    expectInner(tester, 1, 'ai_series');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the row of a level turned by a swipe shows what it turned to', (
    tester,
  ) async {
    await mount(tester, FakeRuntime(WideThemesCatalog()), const Size(320, 844));
    final rail = find.byKey(const ValueKey('theme-rail'));
    final choices = find.byKey(const ValueKey('filter-choices-discover'));
    final ai = find.byKey(const ValueKey('filter-genre-discover-ai_series'));
    // The row is wider than this page and is at its own start, so the last type
    // -- the one the strip is two pulls away from turning to -- is past its
    // edge, and nothing has been tapped to bring it in.
    expect(
      tester
          .state<ScrollableState>(
            find.descendant(of: choices, matching: find.byType(Scrollable)),
          )
          .position
          .maxScrollExtent,
      greaterThan(0),
    );
    expect(ai.hitTestable(), findsNothing);
    for (var i = 0; i < 8 && shell(tester).genre != 'ai_series'; i++) {
      await tester.drag(rail, const Offset(-260, 0));
      await tester.pumpAndSettle();
    }
    expectInner(tester, 0, 'ai_series');
    expectPage(tester, 0);
    // One row moved, and only that row: the chip its own level now names is
    // back inside it, and neither the page under it nor the shell was revealed
    // on the way -- which is why this is not Scrollable.ensureVisible, which
    // walks every ancestor viewport and would answer one swipe with two levels.
    expect(ai.hitTestable(), findsOneWidget);
    expect(
      tester.getRect(ai).right,
      lessThanOrEqualTo(tester.getRect(choices).right),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rail refilled by another type shows the level it starts at', (
    tester,
  ) async {
    await mount(tester, FakeRuntime(WideThemesCatalog()), const Size(320, 844));
    final rail = find.byKey(const ValueKey('theme-rail'));
    final railScroll = tester.state<ScrollableState>(
      find.descendant(of: rail, matching: find.byType(Scrollable)),
    );
    await tester.drag(rail, const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(railScroll.position.pixels, greaterThan(0));
    final all = find.byKey(const ValueKey('theme-rail-'));
    expect(all.hitTestable(), findsNothing);
    // Picking the type is a tap on the row above, not a drag on this one, so
    // nothing would otherwise bring the new type's own first chip back: the
    // chips that row was offset by belong to the type that was just left.
    final comic = find.byKey(
      const ValueKey('filter-genre-discover-comic_series'),
    );
    await tester.ensureVisible(comic);
    await tester.pumpAndSettle();
    await tester.tap(comic);
    await tester.pumpAndSettle();
    expect(shell(tester).genre, 'comic_series');
    expect(all.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a strip parked by the type it left shows the one back', (
    tester,
  ) async {
    await mount(tester, FakeRuntime(WideThemesCatalog()), const Size(320, 844));
    final rail = find.byKey(const ValueKey('theme-rail'));
    final all = find.byKey(const ValueKey('theme-rail-'));
    final comic = find.byKey(
      const ValueKey('filter-genre-discover-comic_series'),
    );
    final short = find.byKey(
      const ValueKey('filter-genre-discover-short_play'),
    );
    // A round trip through the other type, so this strip has already been asked
    // to show this very first chip once -- and did.
    await tester.ensureVisible(comic);
    await tester.pumpAndSettle();
    await tester.tap(comic);
    await tester.pumpAndSettle();
    await tester.ensureVisible(short);
    await tester.pumpAndSettle();
    await tester.tap(short);
    await tester.pumpAndSettle();
    // Park the row on the chips of the type it is standing on, the way reading
    // a strip does.
    await tester.drag(rail, const Offset(-140, 0));
    await tester.pumpAndSettle();
    expect(shell(tester).genre, 'short_play');
    expect(
      tester
          .state<ScrollableState>(
            find.descendant(of: rail, matching: find.byType(Scrollable)),
          )
          .position
          .pixels,
      greaterThan(0),
    );
    expect(all.hitTestable(), findsNothing);
    // Back to the type whose first chip this row was already showing. The row is
    // parked by chips it no longer holds, so showing where it stands is a
    // question asked again, not one this row has already answered.
    await tester.ensureVisible(comic);
    await tester.pumpAndSettle();
    await tester.tap(comic);
    await tester.pumpAndSettle();
    expect(shell(tester).genre, 'comic_series');
    expect(all.hitTestable(), findsOneWidget);
    expect(
      tester.getRect(all).left,
      greaterThanOrEqualTo(tester.getRect(rail).left - 0.5),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rail chip tapped from the edge of the strip is shown whole', (
    tester,
  ) async {
    await mount(tester, FakeRuntime(WideThemesCatalog()), const Size(320, 844));
    final rail = find.byKey(const ValueKey('theme-rail'));
    final third = find.byKey(const ValueKey('theme-rail-cate_9'));
    // Park the strip on the chips a thumb has been dragged along, then bring
    // this one back only as far as a reveal from outside puts it -- the state
    // the live fixture reaches before its tap, and the one the row is asked to
    // finish showing.
    await tester.drag(rail, const Offset(-120, 0));
    await tester.pumpAndSettle();
    await tester.ensureVisible(third);
    await tester.pumpAndSettle();
    final parkedLeft = tester.getRect(third).left;
    final stripLeft = tester.getRect(rail).left;
    await tester.tap(third);
    await tester.pumpAndSettle();
    expect(shell(tester).theme, 'cate_9');
    expect(
      tester.getRect(third).left,
      greaterThanOrEqualTo(stripLeft - 0.5),
      reason: 'tapped from $parkedLeft against a strip starting at $stripLeft',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the shared second level carries across the handover', (
    tester,
  ) async {
    final runtime = FakeRuntime();
    await mount(tester, runtime, const Size(390, 844));
    // 分类 narrows to its own theme; 发现 asks the same shared level the same way.
    await tester.tap(find.text('分类').first);
    await tester.pumpAndSettle();
    await tester.tap(railTheme.hitTestable());
    await tester.pumpAndSettle();
    expect(runtime.catalog.lastTheme, 'cate_7');
    await tester.tap(find.text('发现').first);
    await tester.pumpAndSettle();
    expectPage(tester, 0);
    expect(find.text('山海之间'), findsWidgets);
    // 题材 is the shared 二级: the page that was not on screen kept the pick
    // rather than disowning it, and its strip says so.
    expect(runtime.catalog.lastTheme, 'cate_7');
    expect(tester.widget<ChoiceChip>(railTheme.hitTestable()).selected, isTrue);
    // A type is one of this page's own pages: picking one moves the page and
    // drops the theme that was a child of the type being left.
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
    await tester.tap(find.text('分类').first);
    await tester.pumpAndSettle();
    expectInner(tester, 1, 'comic_series');
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('filter-genre-categories-comic_series')),
          )
          .selected,
      isTrue,
    );
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
    // 类型 is 发现's own first level too: the chip that filters 分类 pages
    // this one, and both follow the shared value.
    expectInner(tester, 0, 'ai_series');
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
    expect(railTheme, findsWidgets);
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
    await mount(
      tester,
      FakeRuntime(catalog),
      const Size(390, 844),
      settle: false,
    );
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
    expect(shell(tester).themesError, isNull);
    expectPage(tester, 1);
    expect(find.byKey(const ValueKey('theme-rail-cate_9')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('我的 stays out of the swipe', (tester) async {
    await mount(tester, FakeRuntime(), const Size(390, 844));
    await swipeTo(tester, 1);
    expectPage(tester, 1);
    await runToEnd(tester, 1);
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
    expect(
      find.byKey(const ValueKey('theme-rail')).hitTestable(),
      findsOneWidget,
    );
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
    final state = shell(tester);
    final left = state.feeds[state.feedKeyOf(1)];
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
      final state = shell(tester);
      expect(state.suggestionsPane, 0);
      // The panel covers the screen with a dismiss layer, so nothing can be
      // swiped out from under it -- which is also why one panel can never be
      // hanging over the other page: it has to be closed first. No level
      // moves while it is open, and the pull lands on the layer, not the list.
      await swipe(tester, 0, -300, warnIfMissed: false);
      expectPage(tester, 0);
      expectInner(tester, 0, 'short_play');
      expectLevel2(tester, 0, '');
      expect(state.suggestionsPane, 0);
      await tester.tap(
        find.byKey(const ValueKey('search-suggestions-dismiss')),
      );
      await tester.pumpAndSettle();
      expect(state.suggestionsPane, isNull);
      await swipe(tester, 0, -300);
      expectLevel2(tester, 0, 'cate_7');
      await swipeTo(tester, 1);
      expectPage(tester, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'one themes flight per type, even when the list reloads under it',
    (tester) async {
      final catalog = SlowThemeCatalog();
      await mount(
        tester,
        FakeRuntime(catalog),
        const Size(390, 844),
        settle: false,
      );
      expect(catalog.themeCalls.length, 1);
      await tester.enterText(
        find.byKey(const ValueKey('search-field-discover')),
        '山海',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
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
      expect(shell(tester).themesError, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a refresh takes over the page that was still on its way', (
    tester,
  ) async {
    final runtime = FakeRuntime(HeldMoreCatalog());
    await mount(tester, runtime, const Size(390, 844));
    final state = shell(tester);
    expect(state.feed.cursor, isNotNull);
    await tester.tap(find.text('加载更多').hitTestable());
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
    expect(find.text('加载更多').hitTestable(), findsOneWidget);
    held.complete(const CatalogPage([]));
    await tester.pumpAndSettle();
    final answered = runtime.catalog;
    final calls = answered.browseCalls;
    await tester.tap(find.text('加载更多').hitTestable());
    await tester.pumpAndSettle();
    // Paging is usable again, and the page that was dropped never appended.
    expect(answered.browseCalls, greaterThan(calls));
    expect(find.text('第二个故事'), findsWidgets);
    expect(state.feed.cursor, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the top folds away under a long scroll and the strip stays', (
    tester,
  ) async {
    await mount(tester, FakeRuntime(LongRowsCatalog()), const Size(390, 844));
    final top = find.byKey(const ValueKey('pane-top-discover'));
    final rail = find.byKey(const ValueKey('theme-rail'));
    final results = find.byKey(ValueKey(shell(tester).resultsKey(0) as String));
    expect(tester.widget<Visibility>(top).visible, isTrue);
    // At rest the strip hangs under the band, and the list begins below it.
    expect(
      tester.getRect(rail).bottom,
      lessThanOrEqualTo(tester.getRect(results).top),
    );
    await tester.drag(results, const Offset(0, -600));
    await tester.pumpAndSettle();
    // The questions the viewer already answered scroll out with the header;
    // the strip that names where a sideways swipe landed does not -- it moves
    // up to the top of the page and stays hit-testable there.
    expect(tester.widget<Visibility>(top).visible, isFalse);
    expect(rail.hitTestable(), findsOneWidget);
    expect(
      tester.getRect(rail).bottom,
      lessThanOrEqualTo(tester.getRect(results).top),
    );
    // Back near the top the band comes down again -- offstage, not gone, so
    // the search box returns with its text and its focus.
    await tester.drag(results, const Offset(0, 1400));
    await tester.pumpAndSettle();
    expect(tester.widget<Visibility>(top).visible, isTrue);
    // And a fold is not a lock: the swipe still answers the innermost level
    // from under the folded band -- the levels did not go anywhere the viewer
    // has to scroll back up to reach.
    await tester.drag(results, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.widget<Visibility>(top).visible, isFalse);
    await swipe(tester, 0, -300);
    expectLevel2(tester, 0, 'cate_7');
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
    final state = shell(tester);
    expect(state.feeds.length, lessThanOrEqualTo(32));
    expect(state.feeds.containsKey(state.feedKey), isTrue);
    expect(state.feeds.containsKey(state.feedKeyOf(1)), isTrue);
    expect(state.feed.items, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the handover answers on the platform that rubber-bands', (
    tester,
  ) async {
    // iOS is where this broke: its default physics is BouncingScrollPhysics,
    // which turns an out-of-range drag into stretched pixels and reports
    // nothing, so the level above stops hearing the swipe and the edge of a
    // page becomes a wall instead of a handover. The three swipeable levels
    // clamp for that reason, whatever the platform default says.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await mount(tester, FakeRuntime(), const Size(390, 844));
    await tester.tap(find.text('分类').first);
    await tester.pumpAndSettle();
    expectPage(tester, 1);
    expectInner(tester, 1, 'short_play');
    expectLevel2(tester, 1, '');
    // The innermost level still answers a level that has a page there, so the
    // clamp did not just turn every swipe into a handover.
    await swipe(tester, 1, -300);
    expectLevel2(tester, 1, 'cate_7');
    expectPage(tester, 1);
    // Back to the head of 题材: the last pull of this one, and nothing of 分类
    // lies to the right of it, so it goes up through 短剧 -- the first page of
    // the first level too -- and the shell is the only one left to answer.
    await swipe(tester, 1, 300);
    expectLevel2(tester, 1, '');
    await swipe(tester, 1, 300);
    expectPage(tester, 0);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('a strip moved from outside the drag paints without asserting', (
    tester,
  ) async {
    // The same platform is what found this one too: on mobile a `Scrollbar` with
    // no controller of its own reaches for the `PrimaryScrollController`, which
    // no sideways row attaches to, so the first scroll that does not come from a
    // finger inside the row -- a reveal of the chip the level now names -- dies in
    // the fade animation instead of painting.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await mount(tester, FakeRuntime(WideThemesCatalog()), const Size(320, 844));
    await tester.tap(find.text('分类').first);
    await tester.pumpAndSettle();
    final far = find.byKey(const ValueKey('theme-rail-cate_11'));
    expect(far, findsOneWidget);
    // Outside the row's own window, which is the only kind of chip worth
    // revealing.
    expect(
      tester.getRect(far).right,
      greaterThan(
        tester.getRect(find.byKey(const ValueKey('theme-rail'))).right,
      ),
    );
    await tester.ensureVisible(far);
    await tester.pumpAndSettle();
    expect(far.hitTestable(), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });
}
