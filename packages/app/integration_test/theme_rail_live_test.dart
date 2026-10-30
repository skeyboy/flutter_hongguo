/// Real-window fixture for the three-level catalog (verification only; touches
/// no product code). Boots the shipping app against the live API, enters 分类 and
/// walks the levels a finger walks -- 题材 first, then 类型, then the tab itself --
/// printing wall-clock markers so tool/verify_theme_rail_live.sh can pull one
/// screenshot per state out of a screen recording (or take it directly from a
/// device). Product code is only ever read through the page's own state.
library;

import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/library_page.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_app/platform/background/host_policy.dart';
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

/// How long a marked state has to stay up. The still is taken when the marker
/// reaches the log, which is a second or so after the state was asked for, and
/// the next action starts a new state: a frame captured after that shows the
/// state after the one it is named for, which is worse than no frame at all.
Future<void> _hold(WidgetTester tester) => _live(tester, 1800);

dynamic _shell(WidgetTester tester) => tester.state(find.byType(LibraryPage));

/// The list the viewer is actually looking at on one page: pane, 一级 and 二级 in
/// one key. Dragging it is how the fixture asks the innermost level first, the
/// way a finger does.
Finder _page(WidgetTester tester, int pane) =>
    find.byKey(ValueKey(_shell(tester).resultsKey(pane) as String));

/// The strip of 题材 pinned under the choices. One key, and only one page of the
/// two is on stage at a time, so it names the visible one.
Finder _rail() => find.byKey(const ValueKey('theme-rail'));

/// 更多 ▾ — the mouse family's row hands everything past its head to this menu
/// instead of leaving it off the end of a sideways slide. Absent on the phone,
/// and absent on a desktop type whose 题材 all fit, which is why the fixture asks
/// for it rather than assuming it.
Finder _railMore() => find.byKey(const ValueKey('theme-rail-more'));

/// The lines of that menu, in the row's own order. Named by their key's prefix
/// because the ids in it are the live vocabulary's, not a list kept here.
Finder _railMenuItems() => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key as ValueKey<String>).value.startsWith('theme-rail-menu-'),
);

/// Whether the strip is showing the 二级 it stands on. Only worth reading after a
/// pull: a tap goes through `ensureVisible` first, and that moves the row for the
/// product rather than proving the product moves it. The settle is the point --
/// the product reveals on the frame after the one that changed level, so a
/// reading taken in the same breath as the marker measures the moment before.
Future<String> _railRevealed(WidgetTester tester, int pane) async {
  await _live(tester, 400);
  final level2 = _level2(tester, pane);
  final chip = find.byKey(ValueKey('theme-rail-$level2'));
  if (chip.evaluate().isEmpty) {
    // Two different nothings. On the mouse family a 题材 past the head of the
    // row is not in the row at all -- it is a line of 更多 ▾ -- so the strip is
    // not showing the level it stands on and nothing is broken either. On the
    // phone, or with no menu to hide it in, an absent chip really is an absent
    // row.
    return desktopHost && _railMore().evaluate().isNotEmpty
        ? ' chip=behind-more'
        : ' chip=none';
  }
  final c = tester.getRect(chip);
  final r = tester.getRect(_rail());
  final pixels = tester
      .state<ScrollableState>(
        find.descendant(of: _rail(), matching: find.byType(Scrollable)),
      )
      .position
      .pixels;
  return ' chip-in-strip=${c.left >= r.left - 0.5 && c.right <= r.right + 0.5}'
      ' chip=${c.left.round()}..${c.right.round()}'
      ' strip=${r.left.round()}..${r.right.round()} px=${pixels.round()}';
}

/// Where one page's innermost level stands: a 题材 id, `''` for 全部, or a
/// `board:` entry while 发现 ranks.
String _level2(WidgetTester tester, int pane) {
  final state = _shell(tester);
  return state.level2At(pane, state.slotOfPane(pane) as String) as String;
}

/// How many second-level pages this pane's type actually has, read off the page.
/// The mouse row shows the head of them and no more, so a count taken from the
/// chips says how wide the window is rather than how long the level is.
int _level2Count(WidgetTester tester, int pane) {
  final dynamic state = _shell(tester);
  return (state.level2Options(pane, state.slotOfPane(pane)) as List).length;
}

/// The rows of the second-level page a pane is showing, read out of the record
/// map rather than asked of the shell -- asking would create a record for a page
/// the viewer never laid out.
dynamic _visibleFeed(WidgetTester tester, int pane) {
  final state = _shell(tester);
  final key = state.feedKeyAtLevel(
    pane,
    state.slotOfPane(pane),
    _level2(tester, pane),
  ) as String;
  return (state.feeds as Map)[key];
}

Future<void> _waitRows(WidgetTester tester, int pane, String where) async {
  for (var i = 0; i < 80; i++) {
    final dynamic feed = _visibleFeed(tester, pane);
    if (feed != null && (feed.items as List).isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  final dynamic feed = _visibleFeed(tester, pane);
  _mark(
    'rows-timeout where=$where pane=$pane loading=${feed?.loading} '
    'error=${feed?.error}',
  );
}

double _offsetOf(WidgetTester tester, int pane) {
  final dynamic state = _shell(tester);
  final dynamic feed = _visibleFeed(tester, pane);
  if (feed == null) return (state.scroll.offset as double);
  final dynamic controller = state.scrollOf(feed);
  return (controller.hasClients ? controller.offset : 0.0) as double;
}

/// One sideways pull, given the way a thumb gives it: from inside the page, over
/// most of its width, and then time enough for the settle to finish. The
/// distance comes off the page's own width, because the same 320 px that crosses
/// a phone page springs back on a desktop window.
Future<void> _pull(WidgetTester tester, int pane, double dir) async {
  final rect = tester.getRect(_page(tester, pane));
  final start = Offset(
    rect.center.dx - dir * rect.width * 0.28,
    rect.center.dy,
  );
  await tester.dragFrom(start, Offset(dir * rect.width * 0.56, 0));
  await _live(tester, 1500);
}

/// The three levels a pull can answer, read together so a handover can be named
/// by which one of them moved.
({int destination, String genre, String level2}) _where(
  WidgetTester tester,
  int pane,
) {
  final state = _shell(tester);
  return (
    destination: state.destination as int,
    genre: state.slotOfPane(pane) as String,
    level2: _level2(tester, pane),
  );
}

/// The 题材 strip's chips, 全部 first. A live 类型 carries 20+ of them, so the
/// fixture reaches either end by tapping the end of what the row offers rather
/// than by pulling through every page a viewer would have to swipe past. On the
/// mouse family that row holds the head of them and no more ([_railMore]).
Finder _chips() =>
    find.descendant(of: _rail(), matching: find.byType(ChoiceChip));

/// Stands one page at one end of its own second level -- when that level has an
/// end to reach. A live 类型 whose 题材 came back empty answers with the retry
/// pill instead of a row, and a type with only 全部 has nothing past it: either
/// way the page already stands at the last 二级 it has, which is the same place
/// the tap would leave it, so the fixture says which one it is and pulls on.
Future<void> _tapRailEnd(
  WidgetTester tester,
  int pane, {
  required bool last,
}) async {
  // A type walked for the first time is still answering for its 题材 when the tap
  // is asked of it, and a strip is only tappable once the row exists.
  for (var i = 0; i < 60 && _chips().evaluate().isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  final count = _chips().evaluate().length;
  if (count == 0) {
    final dynamic state = _shell(tester);
    _mark(
      'rail-pilled pane=$pane genre=${state.slotOfPane(pane)} '
      'themes=${(state.themes as List).length} loading=${state.themesLoading} '
      'error=${state.themesError}',
    );
    return;
  }
  if (!last) {
    await _tapChip(tester, _chips().first);
    return;
  }
  // The end of the level is not the end of the row on the mouse family: its row
  // stops at the head and hands the tail to 更多 ▾, so tapping the row's last
  // chip would leave the page one 题材 short of the edge and the next pull would
  // be answered by 题材 rather than by 类型. Where the row does hold everything --
  // the phone, or a desktop type whose 题材 all fit -- its last chip is the last
  // 二级 there is.
  if (_railMore().evaluate().isNotEmpty) {
    await _tapRailMenuLast(tester);
    return;
  }
  await _tapChip(tester, _chips().last);
}

/// The last line of 更多 ▾, which is the last 题材 of the level because the menu
/// is the row's own tail in the row's own order. `ensureVisible` before the tap
/// for the same reason the chips have it: a live 类型 gives this list 20+ lines,
/// and a tap that quietly landed on the clip instead of on the line would be
/// filed as a pull that answered nothing.
Future<void> _tapRailMenuLast(WidgetTester tester) async {
  final more = _railMore();
  await tester.ensureVisible(more);
  await tester.tap(more);
  final items = _railMenuItems();
  for (var i = 0; i < 20 && items.evaluate().isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
  expect(items, findsWidgets, reason: '更多 ▾ opened with no line in it');
  final last = items.last;
  await tester.ensureVisible(last);
  await _live(tester, 300);
  await tester.tap(last);
  await _live(tester, 1200);
}

/// 「最近更新」is one line of 排序 · … on either family: the touch family opens it
/// as a bottom sheet instead of a dropdown, but the 档 the request carries -- and
/// the key that names it -- are the same, so the promise is what is asked for.
Future<void> _sortLatest(WidgetTester tester) async {
  await _pickSort(tester, 'online_time');
}

/// 「推荐」 was never a 档: on the phone its chip used to mean "put the choice back",
/// and upstream publishes exactly three. So the way back is named by the 档 this
/// page carried before the fixture touched it, and both families ask for it the
/// same way -- a chip with no answer behind it is the thing §6.1.2③ refuses.
Future<void> _sortBackToDefault(WidgetTester tester, String backTo) async {
  await _pickSort(tester, backTo);
}

/// Opens L3 and picks one 档 out of it. The mouse family's is an anchor whose
/// lines only exist while it is open; the touch family's is a route whose lines
/// only exist after the sheet has settled -- both are waited for here, because a
/// tap that raced the opening would throw about a finder instead of naming the
/// 档 the row failed to offer.
Future<void> _pickSort(WidgetTester tester, String sort) async {
  await tester.tap(find.byKey(const ValueKey('sort-menu')));
  final item = find.byKey(ValueKey('sort-$sort'));
  for (var i = 0; i < 20 && item.evaluate().isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
  expect(item, findsOneWidget, reason: '排序 never offered the $sort 档');
  await tester.tap(item);
  await _live(tester, 1200);
}

/// A chip tap a viewer can actually make. Both the strip and the chip row above
/// it scroll sideways, so a chip the last tap left outside the window is brought
/// back in first -- which is what a finger does, and what a tap that quietly
/// misses the widget is not.
Future<void> _tapChip(WidgetTester tester, Finder chip) async {
  await tester.ensureVisible(chip);
  await _live(tester, 300);
  await tester.tap(chip);
  await _live(tester, 1200);
}

/// Pulls until the shell itself answers -- which is the whole point of the
/// handover: every pull before that is spent on this page's own 题材 or 类型, and
/// the markers say which level gave up. A trip with nothing left inside is the
/// other half of the evidence: the very first pull was handed straight up.
Future<void> _swipeTo(WidgetTester tester, int to) async {
  var level2Pulls = 0, genrePulls = 0;
  for (var i = 0; i < 16; i++) {
    final dynamic state = _shell(tester);
    if (state.destination == to) {
      expect(state.tabs!.activeIndex, to, reason: 'the route index drifted');
      _mark(
        'handover to=$to theme-pulls=$level2Pulls genre-pulls=$genrePulls '
        'first-answer=${level2Pulls + genrePulls == 0 ? 'shell' : 'inside'}',
      );
      return;
    }
    final pane = state.destination as int;
    final dir = to > pane ? -1.0 : 1.0;
    final before = _where(tester, pane);
    await _pull(tester, pane, dir);
    final after = _where(tester, pane);
    if (after.destination != before.destination) continue;
    if (after.genre != before.genre) {
      genrePulls++;
      _mark('level-genre pane=$pane from=${before.genre} to=${after.genre}');
      continue;
    }
    if (after.level2 != before.level2) {
      level2Pulls++;
      _mark('level-theme pane=$pane from=${before.level2} to=${after.level2}');
      continue;
    }
    fail(
      'the pull answered nothing at pane=$pane: '
      '${before.genre}/${before.level2}',
    );
  }
  final dynamic state = _shell(tester);
  expect(state.destination, to, reason: 'the swipe never arrived at page $to');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the three levels page inside first and each keeps its own rows', (
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
      final dynamic probe = _shell(tester);
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
    await _live(tester, 1500);
    final dynamic railState = _shell(tester);
    _mark(
      'enter-categories destination=${railState.destination} '
      'genre=${railState.genre} theme=${railState.theme} '
      'themes=${(railState.themes as List).length}',
    );
    final chips = find.descendant(
      of: _rail(),
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
    // The first frame is the one that has to show the whole shape of the page,
    // so it waits for its rows instead of catching the skeleton.
    await _waitRows(tester, 1, 'rail');
    _mark('shot=rail');
    await _hold(tester);

    // 类型 is the 一级 of both pages: one tap on a chip in the row above the rail
    // moves it, and the 二级 under it empties with the type it belonged to.
    await tester.tap(
      find.byKey(const ValueKey('filter-genre-categories-comic_series')),
    );
    await _live(tester, 1400);
    _mark(
      'shot=genre-comic genre=${_shell(tester).genre} '
      'level2=${_level2(tester, 1)}',
    );
    await _hold(tester);
    await tester.tap(
      find.byKey(const ValueKey('filter-genre-categories-short_play')),
    );
    await _live(tester, 1200);

    // The innermost level answers the first two pulls, with the shell still on
    // 分类 and 类型 unmoved: 题材 is spent before anything above it is even asked.
    for (var i = 0; i < 2; i++) {
      final before = _where(tester, 1);
      await _pull(tester, 1, -1);
      final now = _where(tester, 1);
      expect(
        now.destination,
        before.destination,
        reason: 'pull $i skipped a level and moved the shell',
      );
      expect(
        now.genre,
        before.genre,
        reason: 'pull $i turned 类型 while 题材 had pages',
      );
      expect(
        now.level2,
        isNot(before.level2),
        reason: 'pull $i did not turn 题材',
      );
      if (i == 0) {
        final revealed = await _railRevealed(tester, 1);
        _mark(
          'shot=level2-first-pull from=${before.genre}/${before.level2} '
          'to=${now.genre}/${now.level2}$revealed',
        );
        // The still is for this state, and the next pull starts a new one.
        await _hold(tester);
      }
    }
    await _hold(tester);

    // The edge of this page's own second level, reached by tapping the end of its
    // row (`_tapRailEnd` takes the 更多 ▾ line where the row keeps a tail): a live
    // 类型 carries far more 题材 than a fixture should pull through to find the
    // end. The next pull is 类型's answer, not the shell's.
    await _tapRailEnd(tester, 1, last: true);
    final beforeEnd = _where(tester, 1);
    await _pull(tester, 1, -1);
    final atEnd = _where(tester, 1);
    expect(
      atEnd.destination,
      beforeEnd.destination,
      reason: 'the shell answered a pull 类型 still had inside it',
    );
    expect(
      atEnd.genre,
      isNot(beforeEnd.genre),
      reason: 'the last 题材 did not hand over to 类型',
    );
    final handoverRevealed = await _railRevealed(tester, 1);
    _mark(
      'shot=genre-handover from=${beforeEnd.genre}/${beforeEnd.level2} '
      'to=${atEnd.genre}/${atEnd.level2}$handoverRevealed',
    );
    await _hold(tester);

    // Back to the head of both of this page's levels the way a viewer does it:
    // a 题材 is a child of the type it was picked under, so the 短剧 chip alone puts
    // 二级 back on 全部 -- and with 短剧 the first 类型, the next pull has nothing
    // of 分类's own left to spend and goes straight to the shell.
    await _tapChip(
      tester,
      find.byKey(const ValueKey('filter-genre-categories-short_play')),
    );
    final head = _where(tester, 1);
    _mark('at-head genre=${head.genre} level2=${head.level2}');
    expect(
      head.level2,
      isEmpty,
      reason: 'leaving the type did not drop the 题材 picked inside it',
    );
    await _swipeTo(tester, 0);
    await _live(tester, 400);
    _mark('shot=tab-swipe-to-discover');
    await _hold(tester);

    // 发现 answers the same two questions with the same levels; its own extra row
    // is the mode, and 榜单 is no longer in it -- it is the third item of the
    // navigation, so the mode row only ever changes what this page sorts by. On
    // the mouse family that row is the L3 排序 dropdown, which is why the fixture
    // asks for the sort the page carries instead of for a chip.
    final defaultSort = _shell(tester).sort as String;
    await _sortLatest(tester);
    // A 档 whose request never answers is rolled back by the page, so the reason
    // names the record's own error rather than leaving the next run to tell a
    // refused 档 from a dead network.
    final latestSort = _shell(tester).sort as String;
    final dynamic latestFeed = _visibleFeed(tester, 0);
    expect(
      latestSort,
      'online_time',
      reason:
          'the 最新 path left the list on $latestSort '
          '(error=${latestFeed?.error} refresh=${latestFeed?.refreshError})',
    );
    _mark('shot=mode-latest sort=$latestSort');
    await _hold(tester);

    await tester.tap(find.byKey(const ValueKey('catalog-tab-2')));
    await _live(tester, 1600);
    _mark(
      'shot=rank-page boards=${find.byKey(const ValueKey('rank-boards')).evaluate().length} '
      'rows=${find.byKey(const ValueKey('rank-list')).evaluate().length}',
    );
    await _hold(tester);
    // Where the ranking list stands. `-1` when the page has nothing to scroll,
    // so the marker says "no list" rather than inventing a pixel.
    double rankOffset() {
      final list = find.byKey(const ValueKey('rank-list'));
      if (list.evaluate().isEmpty) return -1;
      final scrollable = find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first;
      return tester.state<ScrollableState>(scrollable).position.pixels;
    }

    final rankBefore = rankOffset();
    await tester.drag(
      find.byKey(const ValueKey('rank-list')),
      const Offset(0, -600),
    );
    await _live(tester, 1200);
    _mark(
      'shot=rank-scroll from=${rankBefore.round()} to=${rankOffset().round()} '
      'catalog-offset=${_offsetOf(tester, 0).round()}',
    );
    // Coming back is the promise the destination was added for: 发现 is where it
    // was, with the same 类型 lit and the same list scrolled to the same pixel.
    await tester.tap(find.byKey(const ValueKey('catalog-tab-0')));
    await _live(tester, 1200);
    expect(
      find.byKey(const ValueKey('rank-page')),
      findsNothing,
      reason:
          'the ranking destination stayed over the catalog after leaving it',
    );
    expect(
      find.byKey(const ValueKey('theme-rail')),
      findsOneWidget,
      reason: 'leaving 榜单 took 发现’s second row with it',
    );
    if (desktopHost) {
      // The same promise, in the controls this family has: its second row is the
      // 题材 head *and* the L3 that ends it, so a row that came back without the
      // 排序 is a row that came back half.
      expect(
        find.byKey(const ValueKey('sort-menu')),
        findsOneWidget,
        reason: 'leaving 榜单 took 发现’s 排序 with it',
      );
    }
    await _hold(tester);
    await _sortBackToDefault(tester, defaultSort);
    final backSort = _shell(tester).sort as String;
    expect(
      backSort,
      defaultSort,
      reason:
          'putting the mode back left the list on $backSort, not on '
          'the $defaultSort it carried before the fixture touched it',
    );

    // 上下滑: the search box folds away under the list and both filter rows stay
    // with the viewer. What they were asked for on the way down is still
    // answerable at the top of the screen -- a fold that took 类型 with it could
    // only be undone by scrolling all the way back.
    final dynamic foldState = _shell(tester);
    final choicesRow = find.byKey(const ValueKey('filter-choices-discover'));
    await tester.drag(_page(tester, 0), const Offset(0, -1600));
    await _live(tester, 1200);
    _mark(
      'shot=band-collapsed collapsed=${foldState.bandCollapsed[0]} '
      'rail-top=${tester.getRect(_rail()).top.round()} '
      'choices-top=${tester.getRect(choicesRow).top.round()} '
      'offset=${_offsetOf(tester, 0).round()}',
    );
    await _hold(tester);
    final beforeType = foldState.genre as String;
    final comicChip = find.byKey(
      const ValueKey('filter-genre-discover-comic_series'),
    );
    await _tapChip(tester, comicChip);
    // The row answers from under the folded band, and keeps the chip it just
    // selected inside itself rather than past its own edge.
    final inRow =
        tester.getRect(comicChip).right <= tester.getRect(choicesRow).right;
    _mark(
      'shot=filters-answered-folded genre=${foldState.genre} was=$beforeType '
      'collapsed=${foldState.bandCollapsed[0]} '
      'offset=${_offsetOf(tester, 0).round()} chip-in-row=$inRow',
    );
    await _hold(tester);
    await tester.drag(_page(tester, 0), const Offset(0, 1600));
    await _live(tester, 1200);
    _mark(
      'shot=band-expanded collapsed=${foldState.bandCollapsed[0]} '
      'offset=${_offsetOf(tester, 0).round()}',
    );
    await _hold(tester);

    // The last 类型 and its last 题材, both reached by tapping the end of what the
    // row offers -- the last chip on the phone, the last line of 更多 ▾ where the
    // row keeps a tail -- rather than by pulling through everything in between:
    // 发现 is the first tab, so the next pull finds nothing left inside this page
    // and opens 分类 -- the deep end of the handover, and the first answer the
    // shell is allowed to give from here.
    await _tapChip(
      tester,
      find.byKey(const ValueKey('filter-genre-discover-ai_series')),
    );
    _mark(
      // `chips` is what this window's row holds, `levels` what the type actually
      // has; the two come apart on the mouse family and the frame log has to say
      // which one it is reading.
      'end-of-levels genre=${_shell(tester).genre} '
      'chips=${_chips().evaluate().length} levels=${_level2Count(tester, 0)} '
      'tail-menu=${_railMore().evaluate().isNotEmpty}',
    );
    await _tapRailEnd(tester, 0, last: true);
    final beforeLast = _where(tester, 0);
    await _pull(tester, 0, -1);
    final afterLast = _where(tester, 0);
    expect(
      afterLast.destination,
      1,
      reason:
          'the pull past the end of 发现 did not open 分类: '
          '${beforeLast.genre}/${beforeLast.level2}',
    );
    _mark(
      'shot=tab-swipe-to-categories from=${beforeLast.genre}/${beforeLast.level2}',
    );
    await _hold(tester);

    // The keep-alive leg is judged on the type whose rail was already filled.
    await _tapChip(
      tester,
      find.byKey(const ValueKey('filter-genre-categories-short_play')),
    );

    // Two 题材 the outward walk never stood on (that walk spent 全部 and the first
    // two, then tapped the last), so these are feeds opened here for the first
    // time -- and returned to a moment later.
    final count = chips.evaluate().length;
    expect(
      count,
      greaterThanOrEqualTo(6),
      reason: 'the live rail is too short to name two unopened 题材',
    );
    await _tapChip(tester, chips.at(3));
    await _waitRows(tester, 1, 'theme-two');
    final themeTwoRevealed = await _railRevealed(tester, 1);
    _mark('shot=theme-two level2=${_level2(tester, 1)}$themeTwoRevealed');
    await _hold(tester);

    // Scroll inside this theme so the return can be judged against an offset.
    await tester.drag(_page(tester, 1), const Offset(0, -420));
    await _live(tester, 1600);
    final offset = _offsetOf(tester, 1);
    expect(offset, greaterThan(100), reason: 'the live list never scrolled');
    _mark('shot=theme-two-scrolled offset=${offset.round()}');
    await _hold(tester);

    await _tapChip(tester, chips.at(4));
    await _waitRows(tester, 1, 'theme-three');
    _mark('shot=theme-three level2=${_level2(tester, 1)}');
    await _hold(tester);

    // Back to the first of them: its rows and its offset are already painted
    // while only its head refresh is in flight.
    await _tapChip(tester, chips.at(3));
    await _live(tester, 400);
    _mark(
      'shot=theme-two-restored offset=${_offsetOf(tester, 1).round()} '
      'was=${offset.round()}',
    );
    await _live(tester, 2500);

    _mark('done');
    await _live(tester, 500);
  }, timeout: const Timeout(Duration(minutes: 6)));
}
