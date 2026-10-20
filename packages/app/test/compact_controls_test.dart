import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/playback/compact_controls.dart';

void main() {
  testWidgets(
    'mobile controls overlay leaves video rectangle unchanged and touch brings it back',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final key = GlobalKey<CompactControlsState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CompactControls(
              key: key,
              playing: true,
              busy: false,
              video: const ColoredBox(color: Colors.black),
              controls: const SizedBox(height: 100, child: Text('播放操作')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final picture = find.byKey(const ValueKey('compact-player-picture'));
      final rect = tester.getRect(picture);
      expect(rect.height, 700);
      await tester.tap(find.byTooltip('隐藏播放操作'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('compact-playback-controls')),
        findsNothing,
      );
      expect(tester.getRect(picture), rect);
      await tester.tapAt(const Offset(20, 100));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('compact-playback-controls')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('compact-playback-controls')),
        findsNothing,
      );
      expect(tester.getRect(picture), rect);
    },
  );
  testWidgets(
    'paused, loading and accessibility modes keep mobile actions visible',
    (tester) async {
      for (final mode in ['paused', 'loading', 'accessibility']) {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                accessibleNavigation: mode == 'accessibility',
              ),
              child: Scaffold(
                body: CompactControls(
                  key: ValueKey(mode),
                  playing: mode != 'paused',
                  busy: mode == 'loading',
                  video: const ColoredBox(color: Colors.black),
                  controls: const SizedBox(height: 100),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 8));
        expect(
          find.byKey(const ValueKey('compact-playback-controls')),
          findsOneWidget,
          reason: mode,
        );
      }
    },
  );
  testWidgets('touch held on video keeps controls present until release', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CompactControls(
            playing: true,
            busy: false,
            video: ColoredBox(color: Colors.black),
            controls: SizedBox(height: 100),
          ),
        ),
      ),
    );
    await tester.pump();
    final finger = await tester.startGesture(const Offset(30, 60));
    await tester.pump(const Duration(seconds: 8));
    expect(
      find.byKey(const ValueKey('compact-playback-controls')),
      findsOneWidget,
    );
    await finger.up();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('compact-playback-controls')),
      findsNothing,
    );
  });
  testWidgets(
    'desktop mouse reveals title and exit without reserving picture space; pause restores them',
    (tester) async {
      final chrome = GlobalKey<CompactControlsState>();
      late StateSetter update;
      var playing = true;
      var exits = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Scaffold(
                body: CompactControls(
                  key: chrome,
                  playing: playing,
                  busy: false,
                  video: const ColoredBox(color: Colors.black),
                  header: Row(
                    children: [
                      IconButton(
                        key: const ValueKey('exit'),
                        onPressed: () => exits++,
                        icon: const Icon(Icons.arrow_back),
                      ),
                      const Text('影片标题'),
                    ],
                  ),
                  controls: const SizedBox(height: 80, child: Text('操作栏')),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rect = tester.getRect(
        find.byKey(const ValueKey('compact-player-picture')),
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('exit')), findsNothing);
      expect(find.text('操作栏'), findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(-1, -1));
      await mouse.moveTo(const Offset(90, 120));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('exit')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('exit')));
      await tester.pumpAndSettle();
      expect(exits, 1);
      expect(
        tester.getRect(find.byKey(const ValueKey('compact-player-picture'))),
        rect,
      );
      await mouse.removePointer();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      update(() => playing = false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('exit')), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(find.text('影片标题'), findsOneWidget);
    },
  );

  testWidgets(
    'keyboard Tab reveals hidden exit and holds it for keyboard navigation',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CompactControls(
              playing: true,
              busy: false,
              video: ColoredBox(color: Colors.black),
              header: BackButton(),
              controls: SizedBox(height: 60),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
    },
  );
}
