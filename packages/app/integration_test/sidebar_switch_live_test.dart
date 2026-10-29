/// Real-window fixture for the sidebar switch (verification only; touches no
/// product code). Boots the shipping app on the desktop layout, then alternates
/// a sidebar click -- which must land with nothing left to slide -- with a 类型
/// chip click, whose pager still animates, so one recording holds both a jump
/// and a slide to compare. Prints wall-clock markers plus the window rect, so
/// tool/verify_sidebar_switch_live.sh can cut the clip into per-switch strips.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/library_page.dart';
import 'package:hongguo_app/main.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

void _mark(String event) =>
    print('HGSIDE t=${DateTime.now().millisecondsSinceEpoch} ev=$event');

Future<void> _tap(WidgetTester tester, String key) async {
  final chip = find.byKey(ValueKey(key));
  await tester.tap(chip.first);
  // The click has to be delivered before the marker is printed, or the strip
  // is cut around the wrong frame.
  await tester.pump();
}

/// Real-time pump loop: the engine renders on its own vsync, this only keeps
/// the test binding advancing while the wall clock passes.
Future<void> _live(WidgetTester tester, int ms) async {
  final until = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(until)) {
    await Future<void>.delayed(const Duration(milliseconds: 16));
    await tester.pump();
  }
}

/// The shell's own pager position, sampled as fast as the loop goes: 0.00 with
/// 发现 in front, 1.00 with 分类, and a value between the two in every frame a
/// slide is still drawing. This is the reading the claim rests on -- the frame
/// strips cut from the recording are the illustration of the same switch.
Future<void> _sampleShell(WidgetTester tester, int ms) async {
  final until = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(until)) {
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    print(
      'HGSIDE t=${DateTime.now().millisecondsSinceEpoch} ev=page '
      'page=${(position.pixels / position.viewportDimension).toStringAsFixed(2)} '
      'pixels=${position.pixels.toStringAsFixed(0)} '
      'viewport=${position.viewportDimension.toStringAsFixed(0)}',
    );
    await Future<void>.delayed(const Duration(milliseconds: 8));
    await tester.pump();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the sidebar jumps and the type row still slides', (
    tester,
  ) async {
    // window_manager only exists in the desktop embedders.
    await windowManager.ensureInitialized();
    // Wide enough for the sidebar layout, which is the one the viewer clicks.
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.show();
    await windowManager.focus();

    await tester.pumpWidget(const ProviderScope(child: HongguoApp()));
    final cards = find.byType(DramaCard);
    for (var i = 0; i < 150 && cards.evaluate().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
    expect(cards, findsWidgets, reason: 'the live catalog never rendered');
    final sidebar = find.byKey(const ValueKey('catalog-tab-1'));
    await tester.pump();
    expect(
      sidebar,
      findsOneWidget,
      reason: 'the window is not on the wide layout',
    );

    final bounds = await windowManager.getBounds();
    final screen = ui.PlatformDispatcher.instance.views.first.display;
    print(
      'HGWIN x=${bounds.left.round()} y=${bounds.top.round()} '
      'w=${bounds.width.round()} h=${bounds.height.round()} '
      'display=${screen.size.width.round()}x${screen.size.height.round()}',
    );
    _mark('armed');
    // Leave room for the recorder to start before the first switch.
    await _live(tester, 4000);
    for (var i = 0; i < 4; i++) {
      _mark(i.isEven ? 'jump-in' : 'jump-out');
      await _tap(tester, i.isEven ? 'catalog-tab-1' : 'catalog-tab-0');
      await _sampleShell(tester, 500);
      await _live(tester, 600);
      if (i.isEven) {
        // The control inside the same clip: 类型 is turned by the page's own
        // pager, which is left animating.
        _mark('slide');
        await _tap(tester, 'filter-genre-categories-comic_series');
        await _live(tester, 1100);
        _mark('slide-back');
        await _tap(tester, 'filter-genre-categories-short_play');
        await _live(tester, 1100);
      }
    }
    _mark('done');
    await _live(tester, 500);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
