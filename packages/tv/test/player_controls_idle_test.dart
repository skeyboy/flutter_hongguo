import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import 'player_menu_test.dart' show mount, surface, press, menu;

void main() {
  testWidgets('controls hide after 30 seconds without changing playback', (
    t,
  ) async {
    var toggles = 0;
    await mount(t, surface(toggle: () => toggles++));
    await press(t, LogicalKeyboardKey.arrowUp);
    await t.pump(const Duration(seconds: 29));
    expect(find.text('选集'), findsOneWidget);
    await t.pump(const Duration(seconds: 1));
    await t.pumpAndSettle();
    expect(find.text('选集'), findsNothing);
    expect(find.byType(TvPlayerSurface), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-video');
    expect(toggles, 0);
  });
  testWidgets(
    'direction and child-consumed confirmation restart the idle deadline',
    (t) async {
      var toggles = 0;
      await mount(t, surface(toggle: () => toggles++));
      await press(t, LogicalKeyboardKey.arrowUp);
      await t.pump(const Duration(seconds: 25));
      await press(t, LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(seconds: 20));
      expect(find.text('选集'), findsOneWidget);
      await press(t, LogicalKeyboardKey.arrowLeft);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-play');
      await t.pump(const Duration(seconds: 25));
      await press(t, LogicalKeyboardKey.enter);
      expect(toggles, 1);
      await t.pump(const Duration(seconds: 29));
      expect(find.text('选集'), findsOneWidget);
      await t.pump(const Duration(seconds: 1));
      await t.pumpAndSettle();
      expect(find.text('选集'), findsNothing);
      expect(toggles, 1);
    },
  );
  testWidgets('Up returns to picture and held Up cannot reopen the controls', (
    t,
  ) async {
    await mount(t, surface());
    await press(t, LogicalKeyboardKey.arrowUp);
    await t.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    await t.pump();
    await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
    await t.pump();
    expect(find.text('选集'), findsNothing);
    await t.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
    await t.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-video');
    await press(t, LogicalKeyboardKey.arrowUp);
    expect(find.text('选集'), findsOneWidget);
  });
  testWidgets(
    'panels are not dismissed by the control timer; returning restarts it',
    (t) async {
      await mount(t, surface());
      await menu(t, 'tv-menu-quality');
      await press(t, LogicalKeyboardKey.select);
      await t.pump(const Duration(seconds: 40));
      expect(find.text('选择清晰度'), findsOneWidget);
      await press(t, LogicalKeyboardKey.escape);
      await t.pump(const Duration(seconds: 29));
      expect(find.text('选集'), findsOneWidget);
      await t.pump(const Duration(seconds: 1));
      await t.pumpAndSettle();
      expect(find.text('选集'), findsNothing);
    },
  );
  testWidgets('a disposed surface leaves no timer or keyboard handler', (
    t,
  ) async {
    await mount(t, surface());
    await press(t, LogicalKeyboardKey.arrowUp);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 31));
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(t.takeException(), isNull);
  });
}
