/// Real-window fixture for the in-app update chain (verification only; touches
/// no product code). Runs against the live GitHub release feed with
/// `AppRelease.version` temporarily set behind the published tag, so the start-up
/// check really does find something and one run holds every surface the feature
/// has: the prompt over the live catalog, its scrolling note, the download
/// progress and the macOS handoff message read back from the 更新 section.
///
/// Each moment is announced as `HGUPD t=<epoch ms> ev=<name>` and then held idle
/// for two seconds, so tool/verify_auto_update_live.sh can take a full-screen
/// still and crop it to the `HGWIN` rect the fixture prints.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/library_page.dart';
import 'package:hongguo_app/features/settings_page.dart';
import 'package:hongguo_app/main.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

void _mark(String event) =>
    print('HGUPD t=${DateTime.now().millisecondsSinceEpoch} ev=$event');

Future<void> _idle(WidgetTester tester, int ms) async {
  final until = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(until)) {
    await Future<void>.delayed(const Duration(milliseconds: 16));
    await tester.pump();
  }
}

/// Waits for a real network answer, up to [ms]; false means it never came.
/// [gone] asks for the opposite: until the widget is no longer on screen.
Future<bool> _until(
  WidgetTester tester,
  Finder what,
  int ms, {
  bool gone = false,
}) async {
  final until = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(until)) {
    final present = what.evaluate().isNotEmpty;
    if (gone ? !present : present) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
  return gone ? what.evaluate().isEmpty : what.evaluate().isNotEmpty;
}

/// Waits until the button can actually be pressed -- a check still in flight
/// leaves it disabled, and a tap on a disabled button is a silent no-op.
Future<bool> _waitEnabled(WidgetTester tester, Finder what, int ms) async {
  final until = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(until)) {
    for (final element in what.evaluate()) {
      final widget = element.widget;
      final enabled = widget is FilledButton
          ? widget.onPressed != null
          : widget is ButtonStyleButton
          ? widget.enabled
          : false;
      if (enabled) return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
  return false;
}

/// Whatever the dialog is currently saying, for a run that does not behave.
void _dumpDialog(String when) {
  print(
    'HGUPD ev=dump at=$when dialogOpen='
    '${find.byType(AlertDialog).evaluate().isNotEmpty}',
  );
  for (final element
      in find
          .descendant(of: find.byType(AlertDialog), matching: find.byType(Text))
          .evaluate()) {
    final data = (element.widget as Text).data;
    if (data != null && data.isNotEmpty) print('HGUPD text=$data');
  }
}

/// What the tree can say about a download in flight, for the watch loop below.
String _heartbeat() {
  final dialog = find.byType(AlertDialog).evaluate().isNotEmpty;
  final bar = find.byType(LinearProgressIndicator).evaluate().length;
  final texts = <String>[];
  if (dialog) {
    for (final element
        in find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(Text),
            )
            .evaluate()) {
      final data = (element.widget as Text).data;
      if (data != null && data.contains('下载') && data.length < 60) {
        texts.add(data);
      }
    }
  }
  return 'dialog=$dialog bar=$bar texts=$texts';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('start-up check prompts, scrolls, downloads and hands off', (
    tester,
  ) async {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1180, 820));
    await windowManager.show();
    await windowManager.focus();

    await tester.pumpWidget(const ProviderScope(child: HongguoApp()));
    final cards = find.byType(DramaCard);
    for (var i = 0; i < 200 && cards.evaluate().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
    expect(cards, findsWidgets, reason: 'the live catalog never rendered');

    final bounds = await windowManager.getBounds();
    final screen = ui.PlatformDispatcher.instance.views.first.display;
    print(
      'HGWIN x=${bounds.left.round()} y=${bounds.top.round()} '
      'w=${bounds.width.round()} h=${bounds.height.round()} '
      'display=${screen.size.width.round()}x${screen.size.height.round()}',
    );
    _mark('armed');
    await _idle(tester, 3000);

    // The start-up check is the one that prompts, with nothing pressed. Inside
    // its 24-hour throttle the offer has to be parked by a manual check instead,
    // which is the same prompt arriving from the other entry point.
    var prompted = await _until(tester, find.byType(AlertDialog), 8000);
    if (!prompted) {
      print('HGUPD ev=throttled-fallback');
      await tester.tap(find.byIcon(Icons.person_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('my-settings')));
      await tester.pumpAndSettle();
      final check = find.byKey(const Key('检查更新'));
      await tester.ensureVisible(check);
      await tester.pumpAndSettle();
      _mark('settings-before');
      await _idle(tester, 2000);
      await tester.tap(check);
      await tester.pump();
      final answered = await _until(
        tester,
        find.textContaining('发现新版本 v'),
        30000,
      );
      expect(answered, isTrue, reason: 'the live feed never answered');
      await tester.ensureVisible(find.textContaining('发现新版本 v').first);
      await tester.pumpAndSettle();
      _mark('settings-check');
      await _idle(tester, 2000);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      prompted = await _until(tester, find.byType(AlertDialog), 10000);
    }
    expect(prompted, isTrue, reason: 'nothing ever prompted');
    _mark('dialog-prompt');
    await _idle(tester, 2000);

    final notes = find
        .descendant(
          of: find.byKey(const Key('更新说明')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.drag(notes, const Offset(0, -900));
    await tester.pumpAndSettle();
    await tester.drag(notes, const Offset(0, -900));
    await tester.pumpAndSettle();
    _mark('dialog-scrolled');
    await _idle(tester, 2000);

    final install = find.byKey(const Key('立即更新'));
    final ready = await _waitEnabled(tester, install, 30000);
    print('HGUPD ev=install-ready value=$ready');
    expect(ready, isTrue, reason: 'the install button stayed disabled');
    await tester.tap(install);
    await tester.pump();
    // One line per second while the transfer is meant to be on screen: whether
    // the dialog is still up, whether its bar exists, and what it says.
    var started = false;
    for (var second = 0; second < 20 && !started; second++) {
      for (var tick = 0; tick < 20 && !started; tick++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        started = find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
      }
      print('HGUPD ev=progress-watch second=$second ${_heartbeat()}');
    }
    if (!started) _dumpDialog('no-progress-bar');
    expect(started, isTrue, reason: 'the download never began');
    _mark('downloading');
    await _idle(tester, 2000);

    // Verified bytes hand off to the platform, which closes the dialog; the
    // message it left behind belongs to the 更新 section, so that is where both
    // the handoff and a second, manual check are read from.
    final closed = await _until(
      tester,
      find.byType(AlertDialog),
      240000,
      gone: true,
    );
    expect(closed, isTrue, reason: 'the update never handed off');
    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('my-settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    final handoff = find.textContaining('镜像');
    final explained = await _until(tester, handoff, 10000);
    expect(explained, isTrue, reason: 'the handoff message never appeared');
    await tester.ensureVisible(handoff.first);
    await tester.pumpAndSettle();
    _mark('settings-handoff');
    await _idle(tester, 2000);

    final check = find.byKey(const Key('检查更新'));
    await tester.ensureVisible(check);
    await tester.pumpAndSettle();
    await tester.tap(check);
    await tester.pump();
    final again = await _until(tester, find.textContaining('发现新版本 v'), 30000);
    expect(again, isTrue, reason: 'the manual check never answered');
    await tester.ensureVisible(find.textContaining('发现新版本 v').first);
    await tester.pumpAndSettle();
    _mark('settings-check');
    await _idle(tester, 2000);
    _mark('done');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
