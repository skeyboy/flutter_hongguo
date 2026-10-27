/// Real-window fixture for the theme rail (verification only; touches no
/// product code). Boots the shipping app against the live API, enters 分类 and
/// walks 题材 -> 题材 -> back, printing wall-clock markers so
/// tool/verify_theme_rail_live.sh can pull one screenshot per state out of a
/// screen recording.
library;

import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/library_page.dart';
import 'package:hongguo_app/main.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

void _mark(String event) =>
    print('HGRAIL t=${DateTime.now().millisecondsSinceEpoch} ev=$event');

/// Real-time pump loop: the engine renders on its own vsync, this only keeps
/// the test binding advancing while the wall clock passes.
Future<void> _live(WidgetTester tester, int ms) async {
  final until = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(until)) {
    await Future<void>.delayed(const Duration(milliseconds: 16));
    await tester.pump();
  }
}

/// Wait until the live feed behind the visible pane actually has rows. A theme
/// the viewer never opened is a skeleton until the upstream answers, and
/// dragging a skeleton says nothing about the offset a return has to restore.
Future<void> _waitRows(WidgetTester tester, String where) async {
  for (var i = 0; i < 80; i++) {
    final dynamic state = tester.state(find.byType(LibraryPage));
    final dynamic feed = state.feed;
    if ((feed.items as List).isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  final dynamic state = tester.state(find.byType(LibraryPage));
  final dynamic feed = state.feed;
  _mark(
    'rows-timeout where=$where loading=${feed.loading} error=${feed.error}',
  );
}

/// One page of the swipe, by the key its own pane puts on the scroll view.
Finder _page(String name) => find.byKey(ValueKey('catalog-results-$name'));

/// Drag far enough sideways to settle on the other page -- which is the last
/// thing a drag does, not the first. Inside the page it started in, each pull
/// moves one of that page's own first-level lists, and only a pull that found
/// nothing left inside is handed to the shell. So the fixture keeps pulling in
/// one direction until the shell answers, and reports how many pulls were
/// spent below. The distance comes off the page's own width: the same 320 px
/// that crosses a phone page springs back on a desktop window, and a fixture
/// that quietly stays put is worse than one that fails here.
Future<void> _swipe(WidgetTester tester, String from, String to) async {
  final dir = to == 'categories' ? -1.0 : 1.0;
  final expected = to == 'categories' ? 1 : 0;
  var spentInside = 0;
  for (var i = 0; i < 5; i++) {
    final rect = tester.getRect(_page(from));
    // A page swap needs more than half the width, so the finger starts near the
    // far edge and ends inside the same page -- a path that leaves the window
    // would be clipped by the embedder instead of moving the page.
    final start = Offset(
      rect.center.dx - dir * rect.width * 0.28,
      rect.center.dy,
    );
    await tester.dragFrom(start, Offset(dir * rect.width * 0.56, 0));
    await _live(tester, 1200);
    final dynamic state = tester.state(find.byType(LibraryPage));
    if (state.destination != expected) {
      spentInside++;
      continue;
    }
    // Both answers are evidence, and they say opposite things: pulls > 0 means
    // the page's own level absorbed the pulls before the shell heard anything,
    // pulls == 0 means the level was already at its end and the very first pull
    // was handed up.
    _mark(
      spentInside > 0
          ? 'inner-first from=$from pulls=$spentInside'
          : 'edge-first from=$from pulls=0',
    );
    expect(
      state.tabs!.activeIndex,
      expected,
      reason: 'the route index drifted',
    );
    return;
  }
  final dynamic state = tester.state(find.byType(LibraryPage));
  expect(
    state.destination,
    expected,
    reason: 'the swipe from $from did not land on $to',
  );
}

/// One pull expected to be answered inside the page it started in: the shell
/// stays where it is and that page's own first level moves one step.
Future<void> _swipeInner(
  WidgetTester tester,
  String list,
  double dir,
  String slot,
) async {
  final pane = list == 'discover' ? 0 : 1;
  final dynamic before = tester.state(find.byType(LibraryPage));
  final startIndex = before.innerTabs[pane].activeIndex as int;
  final rect = tester.getRect(_page(list));
  final start = Offset(
    rect.center.dx - dir * rect.width * 0.28,
    rect.center.dy,
  );
  await tester.dragFrom(start, Offset(dir * rect.width * 0.56, 0));
  await _live(tester, 1200);
  final dynamic state = tester.state(find.byType(LibraryPage));
  expect(
    state.destination,
    before.destination,
    reason: 'the pull skipped a level and moved the shell',
  );
  expect(state.slotOfPane(pane), slot, reason: 'the pull did not page inside');
  expect(
    state.innerTabs[pane].activeIndex,
    startIndex + (dir < 0 ? 1 : -1),
    reason: 'the inner route and the level it names disagree',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the rail stays put and each theme keeps its own rows', (
    tester,
  ) async {
    // window_manager only exists in the desktop embedders; a simulator run
    // records the whole device screen and needs no window bookkeeping.
    final isDesktop =
        Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    if (isDesktop) {
      await windowManager.ensureInitialized();
      await windowManager.setSize(const Size(1100, 760));
      // The recorder grabs the whole screen, so the window has to stay above
      // whatever else the desktop has open while the clip runs.
      await windowManager.setAlwaysOnTop(true);
      await windowManager.show();
      await windowManager.focus();
    }

    await tester.pumpWidget(const ProviderScope(child: HongguoApp()));
    final cards = find.byType(DramaCard);
    for (var i = 0; i < 150 && cards.evaluate().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
    if (cards.evaluate().isEmpty) {
      // Name the transport failure instead of leaving the next run to guess.
      // The feed record is per page now, so the probe reads the active one.
      final dynamic probe = tester.state(find.byType(LibraryPage));
      _mark(
        'boot-failed destination=${probe.destination} '
        'loading=${probe.feed.loading} error=${probe.feed.error} '
        'items=${(probe.feed.items as List).length}',
      );
    }
    expect(cards, findsWidgets, reason: 'the live catalog never rendered');

    if (isDesktop) {
      final bounds = await windowManager.getBounds();
      final screen = ui.PlatformDispatcher.instance.views.first.display;
      print(
        'HGWIN x=${bounds.left.round()} y=${bounds.top.round()} '
        'w=${bounds.width.round()} h=${bounds.height.round()} '
        'display=${screen.size.width.round()}x${screen.size.height.round()}',
      );
    }
    _mark('armed');
    // Leave room for the recorder to start before the first state is captured.
    await _live(tester, 4000);

    await tester.tap(find.text('分类').first);
    final dynamic railState = tester.state(find.byType(LibraryPage));
    _mark(
      'enter-categories destination=${railState.destination} '
      'themes=${(railState.themes as List).length}',
    );
    final chips = find.descendant(
      of: find.byKey(const ValueKey('theme-rail')),
      matching: find.byType(ChoiceChip),
    );
    for (var i = 0; i < 100 && chips.evaluate().length < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
    if (chips.evaluate().length < 3) {
      // Name which half of the entry failed: the tap never reached 分类, or the
      // live theme list came back empty/errored.
      _mark(
        'rail-empty destination=${railState.destination} '
        'loading=${railState.themesLoading} error=${railState.themesError}',
      );
    }
    expect(
      chips.evaluate().length,
      greaterThanOrEqualTo(3),
      reason: 'the live themes never filled the rail',
    );
    _mark('shot=rail');
    await _live(tester, 900);

    // The choices are on screen now: switching type is one tap on a chip in the
    // row above the rail, and the rail keeps its rectangle while its themes
    // reload for the new type. The type row belongs to this page, so its keys
    // carry the page name.
    await tester.tap(
      find.byKey(const ValueKey('filter-genre-categories-comic_series')),
    );
    await _live(tester, 1400);
    _mark('shot=genre-comic');
    await _live(tester, 900);
    await tester.tap(
      find.byKey(const ValueKey('filter-genre-categories-short_play')),
    );
    await _live(tester, 1200);

    // 发现 carries the channel group next to the types; 榜单 takes the type
    // group's place and the rail steps out with it.
    await tester.tap(find.text('发现').first);
    await _live(tester, 1600);
    _mark('shot=discover');
    await _live(tester, 900);

    // 发现 pages its own first level before the shell hears of the pull: one
    // drag lands on 最新 with the navigation still on 发现, the one back lands
    // on 推荐. The rank demo below then changes the same level by chip, which
    // has to arrive at the same page the drag would have.
    await _swipeInner(tester, 'discover', -1, 'latest');
    _mark('shot=inner-latest');
    await _live(tester, 900);
    await _swipeInner(tester, 'discover', 1, 'recommend');

    await tester.tap(find.byKey(const ValueKey('filter-view-rank')));
    await _live(tester, 1600);
    _mark('shot=rank');
    await _live(tester, 900);
    await tester.tap(find.byKey(const ValueKey('filter-view-recommend')));
    await _live(tester, 1200);

    // The page swap itself: a horizontal drag on the grid changes the route,
    // and the two pages keep their own state across it. The fixture drives the
    // gesture, which is what a finger does; the stills show where it lands.
    await _swipe(tester, 'discover', 'categories');
    await _live(tester, 400);
    _mark('shot=tab-swipe-to-categories');
    await _live(tester, 900);

    // 分类 answers the same question with its own level: 短剧/漫剧/AI 短剧 are
    // pages here, so two pulls walk to the end of them without the shell
    // hearing a word, and the rail under the chips follows the page it is on.
    await _swipeInner(tester, 'categories', -1, 'comic_series');
    await _swipeInner(tester, 'categories', -1, 'ai_series');
    _mark('shot=inner-categories-last');
    await _live(tester, 900);
    await _swipeInner(tester, 'categories', 1, 'comic_series');
    await _swipeInner(tester, 'categories', 1, 'short_play');
    await _live(tester, 900);

    await _swipe(tester, 'categories', 'discover');
    _mark('shot=tab-swipe-back-to-discover');
    await _live(tester, 900);
    await _swipe(tester, 'discover', 'categories');
    await _live(tester, 1600);

    // The second theme of the live list: a feed the viewer has never opened.
    await tester.tap(chips.at(1));
    await _live(tester, 1200);
    await _waitRows(tester, 'theme-two');
    _mark('shot=theme-two');
    await _live(tester, 900);

    // Scroll inside this theme so the return can be judged against an offset.
    await tester.drag(
      find.byKey(const ValueKey('catalog-results-categories')),
      const Offset(0, -420),
    );
    await _live(tester, 1600);
    final dynamic state = tester.state(find.byType(LibraryPage));
    final offset = state.scroll.offset as double;
    expect(offset, greaterThan(100), reason: 'the live list never scrolled');
    _mark('shot=theme-two-scrolled offset=${offset.round()}');
    await _live(tester, 600);

    await tester.tap(chips.at(2));
    await _live(tester, 1200);
    await _waitRows(tester, 'theme-three');
    _mark('shot=theme-three');
    await _live(tester, 600);

    // Back to the second theme: its rows and its offset are already painted
    // while only its head refresh is in flight.
    await tester.tap(chips.at(1));
    await _live(tester, 400);
    _mark(
      'shot=theme-two-restored offset=${(state.scroll.offset as double).round()}',
    );
    await _live(tester, 2500);

    _mark('done');
    await _live(tester, 500);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
