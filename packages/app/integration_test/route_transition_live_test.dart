/// Real-window fixture for the push/pop transition (verification only; touches
/// no product code). Boots the shipping app with its real auto_route stack,
/// walks catalog -> detail -> catalog and prints wall-clock markers plus the
/// window rect, so tool/verify_route_transition_live.sh can cut a screen
/// recording into per-transition frame strips.
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
    print('HGTRANS t=${DateTime.now().millisecondsSinceEpoch} ev=$event');

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

  testWidgets('catalog to detail and back slides horizontally', (tester) async {
    // window_manager only exists in the desktop embedders; the iOS run records
    // the whole simulator screen, so it needs no window bookkeeping.
    final isDesktop =
        Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    if (isDesktop) {
      await windowManager.ensureInitialized();
      await windowManager.setSize(const Size(1100, 760));
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
    // Leave room for the recorder to start before the first transition.
    await _live(tester, 4000);
    for (var i = 0; i < 4; i++) {
      _mark('push');
      await tester.tap(cards.first);
      await _live(tester, 1400);
      _mark('pop');
      await tester.binding.handlePopRoute();
      await _live(tester, 1400);
    }
    _mark('done');
    await _live(tester, 500);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
