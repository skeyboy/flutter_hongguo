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

/// The shell's own view of which page is on screen and which route is active.
/// Reading both is the point: they are only allowed to agree.
void expectPage(WidgetTester tester, int index) {
  final dynamic state = tester.state(find.byType(LibraryPage));
  expect(state.destination, index);
  expect(state.tabs!.activeIndex, index);
}

Finder page(String name) => find.byKey(ValueKey('catalog-results-$name'));

/// A touch swipe is what a phone viewer has; the drag has to cross the page
/// with the same slop a finger does.
Future<void> swipe(WidgetTester tester, int from, double dx) async {
  await tester.drag(page(from == 0 ? 'discover' : 'categories'), Offset(dx, 0));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a touch swipe moves the page and the route together', (
    tester,
  ) async {
    await mount(tester, FakeRuntime(), const Size(390, 844));
    expectPage(tester, 0);
    expect(find.byKey(const ValueKey('swipe-hint')), findsOneWidget);
    await swipe(tester, 0, -300);
    expectPage(tester, 1);
    expect(find.byKey(const ValueKey('theme-rail')), findsOneWidget);
    // The hint was there for a gesture the viewer has now made.
    expect(find.byKey(const ValueKey('swipe-hint')), findsNothing);
    await swipe(tester, 1, 300);
    expectPage(tester, 0);
    expect(find.byKey(const ValueKey('theme-rail')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the navigation bar drives the same route as the swipe', (
    tester,
  ) async {
    await mount(tester, FakeRuntime(), const Size(390, 844));
    await tester.tap(find.text('分类').first);
    await tester.pumpAndSettle();
    expectPage(tester, 1);
    // Back by hand rather than by the bar: the two ways cannot disagree.
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
    expectPage(tester, 0);
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
    expectPage(tester, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('each page keeps its own rows across the swipe', (tester) async {
    final runtime = FakeRuntime();
    await mount(tester, runtime, const Size(390, 844));
    // 分类 narrows to its own theme; 发现 keeps recommending.
    await swipe(tester, 0, -300);
    await tester.tap(find.byKey(const ValueKey('theme-rail-cate_7')));
    await tester.pumpAndSettle();
    expect(runtime.catalog.lastTheme, 'cate_7');
    await swipe(tester, 1, 300);
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

  testWidgets('the shared type refills the rail on the other side', (
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
    await swipe(tester, 0, -300);
    expectPage(tester, 1);
    // The chip that names the shared level is selected over here too, and the
    // rail is showing the themes of that type -- the genre this page asked
    // for, not the one it started on.
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
    await swipe(tester, 0, -300);
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
}
