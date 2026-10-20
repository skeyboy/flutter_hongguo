import 'package:flutter/material.dart';
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
      await tester.pump();
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
    expect(
      find.byKey(const ValueKey('compact-playback-controls')),
      findsNothing,
    );
  });
}
