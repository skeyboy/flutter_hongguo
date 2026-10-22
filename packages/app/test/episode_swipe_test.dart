import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/playback/episode_swipe.dart';

const _hint = '上滑下一集 · 下滑上一集';
const _picture = ValueKey('episode-swipe-picture');

void main() {
  Widget area({
    bool Function()? blocked,
    ValueChanged<int>? onStep,
    ValueChanged<int>? onBlocked,
    String? hintText,
    VoidCallback? onHintSeen,
    bool reduceMotion = false,
  }) => MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: Scaffold(
          body: EpisodeSwipeArea(
            blocked: blocked ?? () => false,
            onStep: onStep ?? (_) {},
            onBlocked: onBlocked,
            hintText: hintText,
            onHintSeen: onHintSeen,
            child: const ColoredBox(key: _picture, color: Colors.black),
          ),
        ),
      ),
    ),
  );

  test('only fingers are allowed to switch episodes', () {
    expect(EpisodeSwipeArea.fromFinger(PointerDeviceKind.touch), isTrue);
    expect(EpisodeSwipeArea.fromFinger(PointerDeviceKind.stylus), isTrue);
    expect(EpisodeSwipeArea.fromFinger(PointerDeviceKind.mouse), isFalse);
    expect(EpisodeSwipeArea.fromFinger(PointerDeviceKind.trackpad), isFalse);
    expect(EpisodeSwipeArea.fromFinger(PointerDeviceKind.unknown), isFalse);
    expect(EpisodeSwipeArea.fromFinger(null), isFalse);
  });

  testWidgets('vertical touch drag switches, horizontal one does not', (
    tester,
  ) async {
    final steps = <int>[];
    await tester.pumpWidget(area(onStep: steps.add));
    final picture = find.byKey(_picture);
    await tester.drag(picture, const Offset(0, -120));
    expect(steps, [1]);
    await tester.drag(picture, const Offset(0, 120));
    expect(steps, [1, -1]);
    await tester.drag(picture, const Offset(-200, 0));
    expect(steps, [1, -1]);
  });

  /// flutter_test timestamps are absolute, so a synthetic fling has to carry
  /// its own clock forward — otherwise the velocity estimate is always zero.
  Future<void> flick(WidgetTester tester, double dy, {required int ms}) async {
    final finger = await tester.startGesture(const Offset(180, 300));
    final half = Duration(milliseconds: ms ~/ 2);
    final end = Duration(milliseconds: ms);
    await finger.moveBy(Offset(0, dy / 2), timeStamp: half);
    await finger.moveBy(Offset(0, dy / 2), timeStamp: end);
    await finger.up(timeStamp: end + const Duration(milliseconds: 8));
    await tester.pump();
  }

  testWidgets('a short flick switches on velocity alone', (tester) async {
    final steps = <int>[];
    await tester.pumpWidget(area(onStep: steps.add));
    // 40px stays under the 80px distance threshold, so only the fling speed of
    // 2500px/s can make this a switch.
    await flick(tester, -40, ms: 16);
    expect(steps, [1]);
  });

  testWidgets('a slow short drag crosses neither threshold', (tester) async {
    final steps = <int>[];
    await tester.pumpWidget(area(onStep: steps.add));
    await flick(tester, -40, ms: 400);
    expect(steps, isEmpty);
  });

  testWidgets('mouse drag over the picture is not a switch command', (
    tester,
  ) async {
    final steps = <int>[];
    await tester.pumpWidget(area(onStep: steps.add));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(180, 300));
    await mouse.down(const Offset(180, 300));
    await tester.pump(const Duration(milliseconds: 20));
    await mouse.moveTo(const Offset(180, 90));
    await tester.pump(const Duration(milliseconds: 20));
    await mouse.up();
    await mouse.removePointer();
    await tester.pumpAndSettle();
    expect(steps, isEmpty);
  });

  testWidgets('a blocked state drops the swipe and reports the direction', (
    tester,
  ) async {
    final steps = <int>[];
    final dropped = <int>[];
    await tester.pumpWidget(
      area(blocked: () => true, onStep: steps.add, onBlocked: dropped.add),
    );
    await tester.drag(find.byKey(_picture), const Offset(0, -120));
    expect(steps, isEmpty);
    expect(dropped, [1]);
  });

  testWidgets('the hint waits for playback and reports being seen', (
    tester,
  ) async {
    var seen = 0;
    await tester.pumpWidget(area(hintText: null, onHintSeen: () => seen++));
    expect(find.text(_hint), findsNothing);
    await tester.pumpWidget(area(hintText: _hint, onHintSeen: () => seen++));
    expect(find.text(_hint), findsOneWidget);
    expect(seen, 0);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text(_hint), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    // Still mounted while it fades, so the hint does not blink out.
    expect(find.text(_hint), findsOneWidget);
    expect(seen, 0);
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text(_hint), findsNothing);
    expect(seen, 1);
  });

  testWidgets('a hint taken away mid-flight is spent and never replays', (
    tester,
  ) async {
    var seen = 0;
    await tester.pumpWidget(area(hintText: _hint, onHintSeen: () => seen++));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(area(hintText: null, onHintSeen: () => seen++));
    expect(find.text(_hint), findsNothing);
    expect(seen, 1);
    // The picture becomes swipeable again; a second pop-up would look broken.
    await tester.pumpWidget(area(hintText: _hint, onHintSeen: () => seen++));
    await tester.pump();
    expect(find.text(_hint), findsNothing);
    expect(seen, 1);
  });

  testWidgets('the first swipe consumes the hint immediately', (tester) async {
    var seen = 0;
    final steps = <int>[];
    await tester.pumpWidget(
      area(onStep: steps.add, hintText: _hint, onHintSeen: () => seen++),
    );
    await tester.drag(find.byKey(_picture), const Offset(0, -120));
    expect(steps, [1]);
    expect(seen, 1);
    await tester.pumpAndSettle();
    expect(find.text(_hint), findsNothing);
  });

  testWidgets('reduce motion removes the hint without a fade', (tester) async {
    var seen = 0;
    await tester.pumpWidget(
      area(hintText: _hint, onHintSeen: () => seen++, reduceMotion: true),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(find.text(_hint), findsNothing);
    expect(seen, 1);
  });

  testWidgets('the hint stays readable while the chrome is hidden', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(area(hintText: _hint));
    expect(find.bySemanticsLabel(_hint), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a swipe that never crosses the threshold keeps the hint', (
    tester,
  ) async {
    var seen = 0;
    await tester.pumpWidget(area(hintText: _hint, onHintSeen: () => seen++));
    await flick(tester, -40, ms: 400);
    expect(find.text(_hint), findsOneWidget);
    expect(seen, 0);
  });
}
