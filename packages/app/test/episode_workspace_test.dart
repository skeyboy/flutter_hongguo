import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/playback/episode_workspace.dart';

void main() {
  testWidgets(
    'Mac idle pointer hides unpinned panel and movement renews its clock',
    (tester) async {
      final key = GlobalKey<EpisodeWorkspaceState>();
      var activity = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EpisodeWorkspace(
              key: key,
              playing: true,
              busy: false,
              hideWhileHovering: true,
              hideAfter: const Duration(seconds: 3),
              onActivity: () => activity++,
              video: const ColoredBox(color: Colors.black),
              episodes: const Text('episodes'),
            ),
          ),
        ),
      );
      key.currentState!.toggle();
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byKey(const ValueKey('episode-panel')));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: rect.center);
      await mouse.moveTo(rect.center + const Offset(2, 0));
      await tester.pump(const Duration(seconds: 2));
      await mouse.moveTo(rect.center + const Offset(4, 0));
      await tester.pump(const Duration(seconds: 2));
      expect(key.currentState!.visible, isTrue);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(key.currentState!.visible, isFalse);
      expect(activity, greaterThan(1));
      await mouse.removePointer();
    },
  );
  late GlobalKey<EpisodeWorkspaceState> panel;
  late StateSetter update;
  bool playing = true, busy = false, accessible = false;
  bool settingsOpened = false;
  Future<void> mount(WidgetTester tester, Size size) async {
    panel = GlobalKey<EpisodeWorkspaceState>();
    playing = true;
    busy = false;
    accessible = false;
    settingsOpened = false;
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(accessibleNavigation: accessible),
              child: Scaffold(
                appBar: AppBar(
                  actions: [
                    IconButton(
                      tooltip: '选集入口',
                      onPressed: () => panel.currentState!.toggle(),
                      icon: const Icon(Icons.list),
                    ),
                  ],
                ),
                body: EpisodeWorkspace(
                  key: panel,
                  playing: playing,
                  busy: busy,
                  onSettings: () {
                    settingsOpened = true;
                    panel.currentState!.hide();
                  },
                  video: const ColoredBox(color: Colors.black),
                  episodes: ListView(
                    children: [
                      TextButton(
                        onPressed: () => panel.currentState!.selected(),
                        child: const Text('选择第 2 集'),
                      ),
                      const TextField(
                        decoration: InputDecoration(labelText: '定位集号'),
                      ),
                      const SizedBox(height: 1200),
                      const Text('最后一集'),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('settings lives inside the panel without resizing video', (
    tester,
  ) async {
    await mount(tester, const Size(740, 400));
    final picture = find.byKey(const ValueKey('player-picture'));
    final before = tester.getRect(picture);
    expect(find.byTooltip('播放设置'), findsNothing);
    await tester.tap(find.byTooltip('选集入口'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('播放设置'), findsOneWidget);
    expect(tester.getRect(picture), before);
    await tester.tap(find.byTooltip('播放设置'));
    await tester.pumpAndSettle();
    expect(settingsOpened, isTrue);
    expect(find.byKey(const ValueKey('episode-panel')), findsNothing);
    expect(tester.getRect(picture), before);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'wide desktop always keeps full picture; holding and hiding only affect the overlay',
    (tester) async {
      await mount(tester, const Size(1280, 900));
      expect(find.byKey(const ValueKey('episode-panel')), findsNothing);
      final picture = find.byKey(const ValueKey('player-picture'));
      final element = tester.element(picture);
      final fullRect = tester.getRect(picture);
      await tester.tap(find.byTooltip('选集入口'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('保持选集展开'));
      await tester.pumpAndSettle();
      expect(tester.getRect(picture), fullRect);
      await tester.pump(const Duration(seconds: 8));
      expect(find.byKey(const ValueKey('episode-panel')), findsOneWidget);
      await tester.tap(find.byTooltip('隐藏选集'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('episode-panel')), findsNothing);
      expect(tester.getRect(picture), fullRect);
      expect(tester.element(picture), same(element));
      await tester.tap(find.byTooltip('选集入口'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('恢复自动隐藏'), findsOneWidget);
      await tester.tap(find.text('选择第 2 集'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('episode-panel')), findsOneWidget);
    },
  );
  testWidgets(
    'medium overlay preserves picture rectangle; selection and outside clicks close it',
    (tester) async {
      await mount(tester, const Size(800, 600));
      final picture = find.byKey(const ValueKey('player-picture'));
      final before = tester.getRect(picture);
      expect(find.byKey(const ValueKey('episode-panel')), findsNothing);
      await tester.tap(find.byTooltip('选集入口'));
      await tester.pumpAndSettle();
      expect(tester.getRect(picture), before);
      await tester.tap(find.text('选择第 2 集'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('episode-panel')), findsNothing);
      await tester.tap(find.byTooltip('选集入口'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(20, 120));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('episode-panel')), findsNothing);
    },
  );
  testWidgets(
    'temporary panel hides after idle playback but not while paused, loading or using accessibility navigation',
    (tester) async {
      await mount(tester, const Size(800, 600));
      await tester.tap(find.byTooltip('选集入口'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
      expect(find.byKey(const ValueKey('episode-panel')), findsNothing);
      for (final reason in ['paused', 'loading', 'accessibility']) {
        update(() {
          playing = reason != 'paused';
          busy = reason == 'loading';
          accessible = reason == 'accessibility';
        });
        await tester.pump();
        await tester.tap(find.byTooltip('选集入口'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 8));
        expect(
          find.byKey(const ValueKey('episode-panel')),
          findsOneWidget,
          reason: reason,
        );
        await tester.tap(find.byTooltip('隐藏选集'));
        await tester.pumpAndSettle();
      }
    },
  );
  testWidgets(
    'hover suspends timer, leaving restarts it; keyboard dismiss and toggle work',
    (tester) async {
      await mount(tester, const Size(1280, 900));
      await tester.tap(find.byTooltip('选集入口'));
      await tester.pumpAndSettle();
      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: const Offset(0, 0));
      await pointer.moveTo(
        tester.getCenter(find.byKey(const ValueKey('episode-panel'))),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 8));
      expect(find.byKey(const ValueKey('episode-panel')), findsOneWidget);
      await pointer.moveTo(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      expect(find.byKey(const ValueKey('episode-panel')), findsNothing);
      await pointer.removePointer();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('episode-panel')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('episode-panel')), findsNothing);
    },
  );
  testWidgets('keyboard interaction prevents idle hide until focus leaves', (
    tester,
  ) async {
    await mount(tester, const Size(800, 600));
    await tester.tap(find.byTooltip('选集入口'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    expect(find.byKey(const ValueKey('episode-panel')), findsOneWidget);
    await tester.tap(find.byTooltip('选集入口'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('episode-panel')), findsNothing);
  });
  testWidgets(
    'small landscape scrolls options and resizing keeps hidden state',
    (tester) async {
      await mount(tester, const Size(600, 340));
      await tester.tap(find.byTooltip('选集入口'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -1300));
      await tester.pumpAndSettle();
      expect(find.text('最后一集').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('隐藏选集'));
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('episode-panel')), findsNothing);
    },
  );
  testWidgets('touch selection panel remains present while finger is down', (
    tester,
  ) async {
    await mount(tester, const Size(800, 600));
    await tester.tap(find.byTooltip('选集入口'));
    await tester.pumpAndSettle();
    final finger = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('episode-panel'))),
    );
    await tester.pump(const Duration(seconds: 8));
    expect(find.byKey(const ValueKey('episode-panel')), findsOneWidget);
    await finger.up();
    await tester.pump(const Duration(seconds: 6));
    expect(find.byKey(const ValueKey('episode-panel')), findsNothing);
  });
}
