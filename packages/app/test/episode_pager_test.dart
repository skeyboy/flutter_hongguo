import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/playback/episode_pager.dart';
import 'package:hongguo_tv/hongguo_tv.dart' show TvFocusable, TvNavigation;

/// 610 - 4 * 10 = 570 of cell width, i.e. five columns of cellExtent 100,
/// so every full page holds rows(3) * 5 = 15 episodes.
const _width = 610.0;
const _pagerKey = ValueKey('episode-pager-column');
const _pageViewKey = ValueKey('episode-pager-pageview');
const _indicatorKey = ValueKey('episode-pager-page-indicator');
final _pageView = find.byKey(_pageViewKey);

String _indicator(WidgetTester tester) =>
    (tester.widget<Text>(find.byKey(_indicatorKey)).data)!;

List<Episode> _episodes(int count) => [
  for (var i = 0; i < count; i++) Episode(vid: 'v$i', index: i + 1),
];

Widget _host({
  required List<Episode> episodes,
  int current = -1,
  ValueChanged<int>? onSelect,
  EpisodePagerController? controller,
  bool tv = false,
  int rows = 3,
}) {
  final pager = EpisodePager(
    episodes: episodes,
    currentIndex: () => current,
    onSelected: onSelect ?? (_) {},
    rows: rows,
    cellExtent: 100,
    controller: controller,
  );
  return MaterialApp(
    theme: ThemeData(colorScheme: const ColorScheme.dark()),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: _width,
          child: tv ? TvNavigation(child: pager) : pager,
        ),
      ),
    ),
  );
}

/// Focuses a cell by its visible number. Walks ancestors for the pager's own
/// `episode-cell-<global>` node because in TV mode `Focus.of` would stop at
/// `TvFocusable`'s internal ExcludeFocus layer.
void _focusCell(WidgetTester tester, String episodeNumber) {
  FocusNode? node;
  tester.element(find.text(episodeNumber)).visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is Focus &&
        (widget.focusNode?.debugLabel ?? '').startsWith('episode-cell-')) {
      node = widget.focusNode;
      return false;
    }
    return true;
  });
  node!.requestFocus();
}

void main() {
  testWidgets('block height never grows with the episode count', (
    tester,
  ) async {
    await tester.pumpWidget(_host(episodes: _episodes(15)));
    await tester.pumpAndSettle();
    final onePage = tester.getRect(find.byKey(_pagerKey)).height;
    await tester.pumpWidget(_host(episodes: _episodes(100)));
    await tester.pumpAndSettle();
    final tenWorth = tester.getRect(find.byKey(_pagerKey)).height;
    expect(onePage, greaterThan(0));
    expect(tenWorth, onePage);
    // 3 rows of (570/5)/1.5 = 76 plus 2 * 10 spacing, footer excluded.
    expect(tester.getRect(_pageView).height, 3 * 76 + 2 * 10);
  });

  testWidgets('a full page shows rows x columns cells', (tester) async {
    await tester.pumpWidget(_host(episodes: _episodes(100)));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _pageView, matching: find.byType(Text)),
      findsNWidgets(15),
    );
    expect(_indicator(tester), '第 1/7 页');
  });

  testWidgets('the last page shows only the remainder', (tester) async {
    await tester.pumpWidget(_host(episodes: _episodes(100), current: 99));
    await tester.pumpAndSettle();
    // 100 - 6 * 15 cells, and the pager revealed the current episode's page.
    expect(
      find.descendant(of: _pageView, matching: find.byType(Text)),
      findsNWidgets(10),
    );
    expect(_indicator(tester), '第 7/7 页');
  });

  testWidgets('the arrow turns the page and a tap reports the global index', (
    tester,
  ) async {
    final taps = <int>[];
    await tester.pumpWidget(
      _host(episodes: _episodes(100), onSelect: taps.add),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('episode-pager-arrow-下一页')));
    await tester.pumpAndSettle();
    expect(_indicator(tester), '第 2/7 页');
    await tester.tap(find.text('16'));
    expect(taps, [15]);
    await tester.tap(find.byKey(const ValueKey('episode-pager-arrow-上一页')));
    await tester.pumpAndSettle();
    expect(_indicator(tester), '第 1/7 页');
    await tester.tap(find.text('7'));
    expect(taps, [15, 6]);
  });

  testWidgets('edge arrows are greyed and inert on their edge page', (
    tester,
  ) async {
    await tester.pumpWidget(_host(episodes: _episodes(100)));
    await tester.pumpAndSettle();
    final prev = find.byKey(const ValueKey('episode-pager-arrow-上一页'));
    final next = find.byKey(const ValueKey('episode-pager-arrow-下一页'));
    expect(tester.widget<IconButton>(prev).onPressed, isNull);
    expect(tester.widget<IconButton>(next).onPressed, isNotNull);

    final controller = EpisodePagerController();
    await tester.pumpWidget(
      _host(episodes: _episodes(100), current: 99, controller: controller),
    );
    await tester.pumpAndSettle();
    // The state survives the re-pump, so the one-shot initial reveal does not
    // run again; drive it through the controller instead.
    controller.jumpToPage(6);
    await tester.pumpAndSettle();
    expect(_indicator(tester), '第 7/7 页');
    expect(tester.widget<IconButton>(next).onPressed, isNull);
    expect(tester.widget<IconButton>(prev).onPressed, isNotNull);
  });

  testWidgets('a current episode off the first page is revealed and bolded', (
    tester,
  ) async {
    await tester.pumpWidget(_host(episodes: _episodes(100), current: 76));
    await tester.pumpAndSettle();
    expect(_indicator(tester), '第 6/7 页');
    final bolded = tester.widget<Text>(find.text('77'));
    expect(bolded.style!.fontWeight, FontWeight.w700);
    expect(
      tester.widget<Text>(find.text('90')).style!.fontWeight,
      isNot(FontWeight.w700),
    );
  });

  testWidgets('the controller jumps to a page and shows the current one', (
    tester,
  ) async {
    final controller = EpisodePagerController();
    await tester.pumpWidget(
      _host(episodes: _episodes(100), current: 92, controller: controller),
    );
    await tester.pumpAndSettle();
    expect(_indicator(tester), '第 7/7 页');
    controller.jumpToPage(0);
    await tester.pumpAndSettle();
    expect(_indicator(tester), '第 1/7 页');
    controller.showCurrent();
    await tester.pumpAndSettle();
    expect(_indicator(tester), '第 7/7 页');
  });

  testWidgets('TV reuses TvFocusable and Right on the tail hands focus over', (
    tester,
  ) async {
    await tester.pumpWidget(_host(episodes: _episodes(100), tv: true));
    await tester.pumpAndSettle();
    expect(find.byType(TvFocusable), findsWidgets);
    _focusCell(tester, '15');
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode-cell-14');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(_indicator(tester), '第 2/7 页');
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode-cell-15');
  });

  testWidgets('TV Left on the page head turns back and focuses its tail', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(episodes: _episodes(100), current: 92, tv: true),
    );
    await tester.pumpAndSettle();
    expect(_indicator(tester), '第 7/7 页');
    _focusCell(tester, '91'); // head cell of the last page
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(_indicator(tester), '第 6/7 页');
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode-cell-89');
  });

  testWidgets('arrow keys never walk past either end of the pager', (
    tester,
  ) async {
    final controller = EpisodePagerController();
    await tester.pumpWidget(
      _host(episodes: _episodes(100), tv: true, controller: controller),
    );
    await tester.pumpAndSettle();
    _focusCell(tester, '1');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(_indicator(tester), '第 1/7 页');
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode-cell-0');

    controller.jumpToPage(6);
    await tester.pumpAndSettle();
    _focusCell(tester, '100');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(_indicator(tester), '第 7/7 页');
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode-cell-99');
  });

  testWidgets('the plain Material fallback pages on arrows too', (
    tester,
  ) async {
    await tester.pumpWidget(_host(episodes: _episodes(100)));
    await tester.pumpAndSettle();
    expect(find.byType(TvFocusable), findsNothing);
    _focusCell(tester, '15');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(_indicator(tester), '第 2/7 页');
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode-cell-15');
  });

  testWidgets('a touch swipe drags pages by hand', (tester) async {
    await tester.pumpWidget(_host(episodes: _episodes(100)));
    await tester.pumpAndSettle();
    // tester.drag is kind: touch, and its events share one stamp, so this is
    // a pure distance drag — 500 of 610 crosses the halfway snap target.
    await tester.drag(_pageView, const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(_indicator(tester), '第 2/7 页');
    await tester.drag(_pageView, const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(_indicator(tester), '第 1/7 页');
  });

  testWidgets('a mouse drag pages as well', (tester) async {
    await tester.pumpWidget(_host(episodes: _episodes(100)));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    // Start right of centre so the whole 400 px drag stays inside the window.
    final start = Offset(
      tester.getCenter(_pageView).dx + 150,
      tester.getCenter(_pageView).dy,
    );
    await mouse.addPointer(location: start);
    await mouse.down(start);
    await tester.pump();
    // TestGesture timestamps are absolute, so the clock must move with every
    // step or the velocity estimate stays zero and the fling dies at release.
    for (var step = 1; step <= 4; step++) {
      await mouse.moveTo(
        Offset(start.dx - step * 100.0, start.dy),
        timeStamp: Duration(milliseconds: step * 20),
      );
      await tester.pump(Duration(milliseconds: 20));
    }
    await mouse.up(timeStamp: const Duration(milliseconds: 100));
    await mouse.removePointer();
    await tester.pumpAndSettle();
    expect(_indicator(tester), '第 2/7 页');
  });

  testWidgets('arrows and cells carry tooltips and semantics labels', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(episodes: _episodes(100)));
    await tester.pumpAndSettle();
    expect(find.byTooltip('上一页'), findsOneWidget);
    expect(find.byTooltip('下一页'), findsOneWidget);
    // The merged cell label also carries the cell's own number text.
    expect(find.bySemanticsLabel(RegExp('第 3 集')), findsOneWidget);
    semantics.dispose();
  });
}
