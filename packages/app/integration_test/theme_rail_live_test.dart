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
    final chips = find.descendant(
      of: find.byKey(const ValueKey('theme-rail')),
      matching: find.byType(ChoiceChip),
    );
    for (var i = 0; i < 100 && chips.evaluate().length < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
    expect(
      chips.evaluate().length,
      greaterThanOrEqualTo(3),
      reason: 'the live themes never filled the rail',
    );
    _mark('shot=rail');
    await _live(tester, 900);

    // The second theme of the live list: a feed the viewer has never opened.
    await tester.tap(chips.at(1));
    await _live(tester, 1200);
    _mark('shot=theme-two');
    await _live(tester, 900);

    // Scroll inside this theme so the return can be judged against an offset.
    await tester.drag(
      find.byKey(const ValueKey('catalog-results')),
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
