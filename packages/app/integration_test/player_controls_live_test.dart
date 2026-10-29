/// Live evidence fixture for the playback control bar. It only walks the player
/// through the states the bar has to show and prints a marker per state;
/// `tool/verify_player_controls_live.sh` screenshots each marker. Deliberately
/// free of assertions about the redesigned controls, so the same fixture runs
/// against the tree before and after it.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/features/player_page.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' hide VideoTrack;
import 'package:window_manager/window_manager.dart';

/// The live player, so every marker can report where the playhead actually is.
/// Timing claims about the bar (does the seek flash still be on screen when the
/// frame is grabbed?) only mean something against the fixture's own sampling.
Player? _probe;

void _mark(String event) => print(
  'HGCTRL t=${DateTime.now().millisecondsSinceEpoch} ev=$event'
  '${_probe == null ? '' : ' pos=${_probe!.state.position.inSeconds}s'
            ' rate=${_probe!.state.rate}'}',
);

/// Reports the window rectangle the capture script grabs; the script uses the
/// most recent line, so every resize has to announce itself again.
Future<void> _window() async {
  final bounds = await windowManager.getBounds();
  final screen = ui.PlatformDispatcher.instance.views.first.display;
  print(
    'HGWIN x=${bounds.left.round()} y=${bounds.top.round()} '
    'w=${bounds.width.round()} h=${bounds.height.round()} '
    'display=${screen.size.width.round()}x${screen.size.height.round()}',
  );
}

/// Real-time pump loop: the engine renders on its own vsync, this only keeps the
/// test binding advancing while the wall clock passes.
Future<void> _live(WidgetTester tester, int ms) async {
  final until = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(until)) {
    await Future<void>.delayed(const Duration(milliseconds: 16));
    await tester.pump();
  }
}

Future<void> _show(WidgetTester tester) async {
  final dynamic state = tester.state(find.byType(PlayerPage));
  state.compactControls.currentState?.show();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) return;
  await tester.tap(target.first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// The state a marker describes only exists where the bar carries the item:
/// portrait phone has neither a quality entry nor a volume one, so a frame
/// claiming `quality-open` there would show a bar with nothing open.
Future<bool> _open(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) return false;
  await _tap(tester, target);
  return true;
}

/// A popup route eats the tap that dismisses it, so the picture underneath never
/// sees it and never toggles play; anywhere clear of the menu will do. On a
/// desktop host a picture click *is* the play key, so the state the next marker
/// describes has to be put back rather than left to whatever the tap did.
Future<void> _dismiss(WidgetTester tester, Player player) async {
  await tester.tapAt(const Offset(30, 120));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await player.play();
  await _show(tester);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  testWidgets('the control bar shows every state it owns', (tester) async {
    final desktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    if (desktop) {
      await windowManager.ensureInitialized();
      await windowManager.setSize(const Size(1280, 800));
      await windowManager.show();
      await windowManager.focus();
    }

    final runtime = await createRuntime();
    // The upstream list endpoint answers empty as a whole page now and then
    // (docs recorded it for the theme rail), and an empty list here is not a
    // product defect worth failing the capture over.
    var dramas = const <Drama>[];
    for (var attempt = 0; attempt < 5 && dramas.isEmpty; attempt++) {
      try {
        dramas = (await runtime.catalog.browse()).items;
      } on Object catch (failure) {
        print('HGNOTE browse-retry($failure)');
      }
      if (dramas.isEmpty) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    expect(
      dramas,
      isNotEmpty,
      reason: 'the live catalog answered empty 5 times',
    );
    final first = dramas.first;
    final detail = await runtime.catalog.detail(first.id);
    expect(
      detail.episodes,
      isNotEmpty,
      reason: 'the live drama has no episode',
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: PlayerPage(runtime: runtime, detail: detail),
      ),
    );
    await tester.pump();
    final dynamic state = tester.state(find.byType(PlayerPage));
    final player = state.player as Player;
    _probe = player;
    await player.setVolume(0);
    state.autoNext = false;
    for (var i = 0; i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (state.error != null) {
        print('HGPLAYER boot-failed=${state.error}');
        fail('the live episode never started: ${state.error}');
      }
      if ((player.state.width ?? 0) > 0 &&
          player.state.duration > const Duration(seconds: 1) &&
          !state.preparing) {
        break;
      }
    }
    expect(state.preparing, isFalse, reason: 'still preparing after a minute');
    expect(player.state.width, greaterThan(0));

    if (desktop) await _window();
    print('HGPLAYER duration=${player.state.duration.inSeconds}s');
    _mark('armed');
    await _live(tester, 1500);

    // 1. The bar over a playing episode.
    await _show(tester);
    _mark('controls');
    await _live(tester, 2600);

    // One mouse pointer for the whole run, like the device it stands in for, and
    // on a high pointer id: `createGesture` defaults to 1, which is the id the
    // engine gives the real cursor sitting over this window, and two sources
    // sharing it trips arena.dart's `isOpen` before the recognizers ever see the
    // click.
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 50,
    );

    // 2. Hover the progress bar itself: the bubble follows the pointer, not the
    // playhead, so the pointer parks past the middle of the track. The bar sits
    // below the title and clock rows, so an offset from the top of the whole
    // chrome lands on text, not on the track. Touch surfaces have no hover, so
    // there is no state to photograph and no marker to print.
    final bar = find.byKey(const ValueKey('player-progress'));
    var parked = false;
    if (desktop && bar.evaluate().isNotEmpty) {
      final rect = tester.getRect(bar.first);
      await mouse.addPointer(
        location: rect.topLeft + Offset(rect.width * .45, rect.height / 2),
      );
      parked = true;
      await tester.pump();
      await mouse.moveTo(
        rect.topLeft + Offset(rect.width * .62, rect.height / 2),
      );
      await tester.pump();
    }
    if (parked) {
      _mark('progress-hover');
      await _live(tester, 2600);
    }

    // 3. Paused: the centre of the picture has to answer for itself.
    await player.pause();
    await _show(tester);
    _mark('paused');
    await _live(tester, 2600);
    await player.play();

    // 4-6. The popups the bar owns.
    await _show(tester);
    if (await _open(tester, find.byTooltip('播放速度'))) {
      _mark('speed-open');
      await _live(tester, 2600);
      await _dismiss(tester, player);
    }
    if (await _open(tester, find.byTooltip('清晰度'))) {
      _mark('quality-open');
      await _live(tester, 2600);
      await _dismiss(tester, player);
    }
    // The wide desktop surface answers with a mute toggle instead of a popup,
    // so this step names whichever of the two the bar is wearing.
    final muteTip = find.byTooltip('取消静音（M）');
    final volume = muteTip.evaluate().isNotEmpty
        ? muteTip
        : find.byTooltip('音量');
    if (await _open(tester, volume)) {
      _mark('volume-open');
      await _live(tester, 2600);
      await _dismiss(tester, player);
    }

    // 7. The seek flash. Where the bar carries ±10s buttons, press them: a
    // synthesized mouse `down` trips arena.dart's `isOpen` against the real
    // cursor already sitting over this window, so a double-tap never reaches the
    // recognizers on a desktop host. Portrait phone has no such buttons, so
    // double-tap the half of the picture there. Both routes land in `_nudge`.
    // Each press needs its own pointer id — once the first sequence resolves, the
    // arena for that id is closed and a second `down` on it asserts — and the two
    // have to stay inside the 300ms window, so nothing pumps between them.
    final picture = find.byKey(const ValueKey('compact-player-picture'));
    Future<void> tapOnce(Offset at, int id) async {
      final touch = await tester.createGesture(
        kind: PointerDeviceKind.touch,
        pointer: id,
      );
      await touch.addPointer(location: at);
      await touch.down(at);
      await touch.up();
    }

    Future<void> seek(Finder button, double fraction, int tap) async {
      await _show(tester);
      if (button.evaluate().isNotEmpty) {
        await _tap(tester, button);
      } else if (picture.evaluate().isNotEmpty) {
        final spot = tester.getRect(picture.first);
        final at =
            spot.topLeft + Offset(spot.width * fraction, spot.height * .5);
        await tapOnce(at, tap);
        await tapOnce(at, tap + 1);
      }
      await tester.pump();
    }

    await seek(find.byKey(const ValueKey('transport-seek-back')), .25, 60);
    _mark('seek-back');
    await _live(tester, 1200);
    await seek(find.byKey(const ValueKey('transport-seek-forward')), .75, 62);
    _mark('seek-forward');
    await _live(tester, 1200);

    // 8. The narrow desktop layout, where the clusters drop items in order.
    if (desktop) {
      await windowManager.setSize(const Size(680, 430));
      await tester.pump(const Duration(milliseconds: 600));
      // The capture is a region grab of whatever rect was reported last, so a
      // resize has to re-report it or the frame keeps the old, wider rectangle.
      await _window();
      await _show(tester);
      _mark('narrow');
      await _live(tester, 2600);
      await windowManager.setSize(const Size(1280, 800));
      await tester.pump(const Duration(milliseconds: 600));
      await _window();
    }

    if (parked) {
      await mouse.removePointer();
      await tester.pump();
    }
    _mark('done');
    await _live(tester, 500);
  }, timeout: const Timeout(Duration(minutes: 8)));
}
