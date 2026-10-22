// Regression cover for the two focus defects measured on the Android TV
// emulator with v0.3.2 (build/verification/tv/v0.3.2/findings.md):
//
//   D1  the D-pad could never step from the action line into the episode grid,
//       because a vertical move only searches nodes owned by the same vertical
//       Scrollable as the focused node, and the grid had its own;
//   D2  turning a page with an arrow could leave the whole page without a
//       focus, because the hand-off asked for a cell node before the target
//       page existed.
//
// Both need the pager to sit in a scrolling page under an action line, so this
// host mirrors tv_detail_page.dart rather than the widget-only host of
// episode_pager_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/playback/episode_pager.dart';
import 'package:hongguo_tv/hongguo_tv.dart' show TvFocusable, TvNavigation;

const _indicatorKey = ValueKey('episode-pager-page-indicator');

/// 1920 - 2 * 36 of pager width at cellExtent 170 (spacing 10) is ten columns,
/// so a page holds 4 rows x 10 = 40 cells and 86 episodes fill three pages.
const _columns = 10;
const _rows = 4;

List<Episode> _episodes(int count) => [
  for (var i = 0; i < count; i++) Episode(vid: 'v$i', index: i + 1),
];

Widget _host(List<Episode> episodes, {EpisodePagerController? controller}) {
  return MaterialApp(
    theme: ThemeData(colorScheme: const ColorScheme.dark()),
    home: Scaffold(
      body: TvNavigation(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(36),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  TvFocusable(
                    label: '开始观看',
                    autofocus: true,
                    onActivate: () {},
                    child: const Padding(
                      padding: EdgeInsets.all(14),
                      child: Text('▶ 开始观看'),
                    ),
                  ),
                  TvFocusable(
                    label: '下载剧集',
                    onActivate: () {},
                    child: const Padding(
                      padding: EdgeInsets.all(14),
                      child: Text('下载剧集'),
                    ),
                  ),
                ],
              ),
              EpisodePager(
                episodes: episodes,
                currentIndex: () => -1,
                onSelected: (_) {},
                controller: controller,
                rows: _rows,
                cellExtent: 170,
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  for (final title in <String>['推荐A', '推荐B'])
                    TvFocusable(
                      label: title,
                      onActivate: () {},
                      child: SizedBox(
                        width: 168,
                        height: 284,
                        child: Text(title),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

String? _focus() => FocusManager.instance.primaryFocus?.debugLabel;

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

/// The pager owns its arrow nodes, so reach them from the root rather than
/// through `Focus.of`, which stops at TvFocusable's ExcludeFocus layer.
FocusNode? _nodeByLabel(WidgetTester tester, String needle) {
  FocusNode? found;
  void scan(Element element) {
    if (found != null) return;
    final widget = element.widget;
    if (widget is Focus &&
        (widget.focusNode?.debugLabel ?? '').contains(needle)) {
      found = widget.focusNode;
    }
    element.visitChildren(scan);
  }

  tester.binding.rootElement!.visitChildren(scan);
  return found;
}

String _indicator(WidgetTester tester) =>
    (tester.widget<Text>(find.byKey(_indicatorKey)).data)!;

Future<void> _useTvSurface(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('Down from the action line enters the first episode cell', (
    tester,
  ) async {
    await _useTvSurface(tester);
    await tester.pumpWidget(_host(_episodes(86)));
    await tester.pumpAndSettle();
    expect(_focus(), contains('开始观看'));

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focus(), 'episode-cell-0', reason: 'D1: the grid is skipped again');
  });

  testWidgets('Down walks the rows and leaves the grid into the rail', (
    tester,
  ) async {
    await _useTvSurface(tester);
    await tester.pumpWidget(_host(_episodes(86)));
    await tester.pumpAndSettle();
    await _press(tester, LogicalKeyboardKey.arrowDown);

    for (var row = 1; row < _rows; row++) {
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focus(), 'episode-cell-${row * _columns}');
    }
    // Past the last row the block is done: the page below it takes focus.
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focus(), '推荐A');

    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focus(), 'episode-cell-${(_rows - 1) * _columns}');
  });

  testWidgets('Up from the first row goes back to the action line', (
    tester,
  ) async {
    await _useTvSurface(tester);
    await tester.pumpWidget(_host(_episodes(86)));
    await tester.pumpAndSettle();
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focus(), 'episode-cell-0');

    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focus(), contains('开始观看'));
  });

  testWidgets('an arrow turn always leaves the focus inside the pager', (
    tester,
  ) async {
    await _useTvSurface(tester);
    final controller = EpisodePagerController();
    await tester.pumpWidget(_host(_episodes(86), controller: controller));
    await tester.pumpAndSettle();
    controller.jumpToPage(1);
    await tester.pumpAndSettle();
    expect(_indicator(tester), '第 2/3 页');

    final prev = _nodeByLabel(tester, 'episode-pager-prev');
    expect(prev, isNotNull);
    prev!.requestFocus();
    await tester.pumpAndSettle();
    await _press(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(_indicator(tester), '第 1/3 页');
    // D2: this used to leave the page with no focus at all, so that no further
    // key did anything. Either landing is inside the pager and still moves.
    expect(_focus(), isNotNull);
    expect(_focus(), startsWith('episode-'));
  });
}
