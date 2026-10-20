import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

void main() {
  test('seek preview clamps and cancellation never commits', () {
    final s = TvPlayerState();
    s.seekBy(
      const Duration(seconds: -5),
      const Duration(seconds: 2),
      const Duration(seconds: 20),
    );
    expect(s.preview, Duration.zero);
    expect(s.back(), isTrue);
    expect(s.commit(), isNull);
    expect(s.back(), isFalse);
    s.dispose();
  });
  test('seek repeats accumulate once and commit once', () {
    final s = TvPlayerState();
    s.seekBy(
      const Duration(seconds: 5),
      const Duration(seconds: 10),
      const Duration(seconds: 18),
    );
    s.seekBy(
      const Duration(seconds: 5),
      Duration.zero,
      const Duration(seconds: 18),
    );
    expect(s.commit(), const Duration(seconds: 18));
    expect(s.commit(), isNull);
    s.dispose();
  });
  test('back closes exactly one layer', () {
    final s = TvPlayerState();
    s.openPanel();
    expect(s.back(), isTrue);
    expect(s.layer, TvPlayerLayer.controls);
    expect(s.back(), isTrue);
    expect(s.layer, TvPlayerLayer.video);
    expect(s.back(), isFalse);
    s.dispose();
  });
  testWidgets(
    'D-pad moves and center activates once, repeats do not activate',
    (t) async {
      var a = 0, b = 0;
      await t.pumpWidget(
        MaterialApp(
          home: TvNavigation(
            child: Row(
              children: [
                TvFocusable(
                  label: 'A',
                  autofocus: true,
                  onActivate: () => a++,
                  child: const Text('A'),
                ),
                TvFocusable(
                  label: 'B',
                  onActivate: () => b++,
                  child: const Text('B'),
                ),
              ],
            ),
          ),
        ),
      );
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.select);
      expect(a, 1);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.select);
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await t.sendKeyUpEvent(LogicalKeyboardKey.select);
      expect(b, 1);
      expect(a, 1);
    },
  );
  testWidgets('player panel directions never seek and Back returns focus', (
    t,
  ) async {
    var toggles = 0, exits = 0;
    final seeks = <Duration>[];
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvPlayerSurface(
            video: const SizedBox(),
            title: 'TV',
            playing: true,
            busy: false,
            position: const Duration(seconds: 10),
            duration: const Duration(minutes: 1),
            toggle: () => toggles++,
            previous: () {},
            next: () {},
            exit: () => exits++,
            retry: () {},
            seek: seeks.add,
            episodeLabels: const ['第1集', '第2集'],
            episode: 0,
            selectEpisode: (_) {},
            quality: 'best',
            selectQuality: (_) {},
          ),
        ),
      ),
    );
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    expect(find.textContaining('预览 0:15'), findsOneWidget);
    expect(seeks, isEmpty);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(seeks, isEmpty);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.pump();
    expect(find.text('选集'), findsOneWidget);
    // Click only to set the panel state; subsequent control is remote-only.
    await t.tap(find.text('选集'));
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    expect(seeks, isEmpty);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(exits, 0);
    expect(find.text('选择分集'), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(exits, 1);
    expect(toggles, 0);
  });
  testWidgets(
    'remote alone activates next episode, progress and episode selection',
    (t) async {
      var next = 0;
      final selected = <int>[];
      final seeks = <Duration>[];
      await t.pumpWidget(
        MaterialApp(
          home: TvNavigation(
            child: Scaffold(
              body: TvPlayerSurface(
                video: const SizedBox(),
                title: 'TV',
                playing: true,
                busy: false,
                position: const Duration(seconds: 10),
                duration: const Duration(minutes: 2),
                toggle: () {},
                previous: () {},
                next: () => next++,
                exit: () {},
                retry: () {},
                seek: seeks.add,
                episodeLabels: const ['第1集', '第2集'],
                episode: 0,
                selectEpisode: selected.add,
                quality: 'best',
                selectQuality: (_) {},
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      Future<void> key(LogicalKeyboardKey k) async {
        await t.sendKeyEvent(k);
        await t.pumpAndSettle();
      }

      await key(LogicalKeyboardKey.arrowUp);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-play');
      await key(LogicalKeyboardKey.arrowRight);
      await key(LogicalKeyboardKey.select);
      expect(next, 1);
      await key(LogicalKeyboardKey.arrowRight);
      await key(LogicalKeyboardKey.select);
      expect(find.textContaining('预览'), findsOneWidget);
      await key(LogicalKeyboardKey.arrowRight);
      await key(LogicalKeyboardKey.select);
      expect(seeks, [const Duration(seconds: 15)]);
      await key(LogicalKeyboardKey.arrowUp);
      expect(find.text('选集'), findsNothing);
      await key(LogicalKeyboardKey.arrowUp);
      for (var i = 0; i < 3; i++) {
        await key(LogicalKeyboardKey.arrowRight);
      }
      await key(LogicalKeyboardKey.select);
      expect(find.text('选择分集'), findsOneWidget);
      await key(LogicalKeyboardKey.arrowRight);
      await key(LogicalKeyboardKey.select);
      expect(selected, [1]);
    },
  );
  testWidgets(
    'failed playback keeps episode selection and retry reachable by remote',
    (t) async {
      var retries = 0;
      await t.pumpWidget(
        MaterialApp(
          home: TvNavigation(
            child: Scaffold(
              body: TvPlayerSurface(
                video: const SizedBox(),
                title: 'TV',
                playing: false,
                busy: false,
                error: 'failure ' * 1000,
                position: Duration.zero,
                duration: Duration.zero,
                toggle: () {},
                previous: () {},
                next: () {},
                exit: () {},
                retry: () => retries++,
                seek: (_) {},
                episodeLabels: const ['第1集', '第2集'],
                episode: 0,
                selectEpisode: (_) {},
                quality: 'best',
                selectQuality: (_) {},
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.sendKeyEvent(LogicalKeyboardKey.select);
      await t.pumpAndSettle();
      // The video root opens the controls; confirming their retry invokes it.
      await t.sendKeyEvent(LogicalKeyboardKey.select);
      await t.pumpAndSettle();
      expect(retries, 1);
      for (var i = 0; i < 2; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await t.pumpAndSettle();
      }
      await t.sendKeyEvent(LogicalKeyboardKey.select);
      await t.pumpAndSettle();
      expect(find.text('选择分集'), findsOneWidget);
    },
  );
  testWidgets('text editor retains input without invoking a button', (t) async {
    final node = FocusNode();
    var pressed = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvNavigation(
            child: Column(
              children: [
                TextField(focusNode: node),
                TvFocusable(
                  label: 'go',
                  onActivate: () => pressed++,
                  child: const Text('go'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    node.requestFocus();
    await t.pump();
    await t.enterText(find.byType(TextField), '红果');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(pressed, 0);
    expect(node.hasFocus, isTrue);
    await t.pumpWidget(const SizedBox());
    node.dispose();
  });
}
