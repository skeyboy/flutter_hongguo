import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/tv/tv_detail_page.dart';
import 'package:hongguo_app/playback/tv_video_view.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_tv/hongguo_tv.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

import 'tv_remote_test.dart' show TvPlaybackFixtureRuntime;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  testWidgets(
    'hardware Up hides controls and 30s idle returns to paused picture',
    (t) async {
      final bytes = await rootBundle.load('assets/verification.cenc.mp4');
      final runtime = TvPlaybackFixtureRuntime(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        await Directory.systemTemp.createTemp('tv-controls-idle-'),
        settings: const AppSettings(autoNext: false, prefetchEnabled: false),
      );
      addTearDown(runtime.dispose);
      final detail = await runtime.catalog.detail('123');
      await t.pumpWidget(
        TvBackDispatcher(
          builder: (_, key) => MaterialApp(
            navigatorKey: key,
            builder: (_, child) => TvEnvironment(
              enabled: true,
              child: TvNavigation(child: child!),
            ),
            home: TvDetailPage(runtime: runtime, initial: detail.drama),
          ),
        ),
      );
      await t.pumpAndSettle();
      for (
        var i = 0;
        i < 50 &&
            FocusManager.instance.primaryFocus?.debugLabel != 'tv-detail-play';
        i++
      ) {
        await t.pump(const Duration(milliseconds: 100));
      }
      Future<void> key(int code) async {
        print('TV_SYSTEM_KEY=$code');
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await t.pump();
      }

      await key(23);
      for (var i = 0; i < 150; i++) {
        await t.pump(const Duration(milliseconds: 100));
        if (find.byType(TvPlayerSurface).evaluate().isNotEmpty &&
            !t.widget<TvPlayerSurface>(find.byType(TvPlayerSurface)).busy) {
          break;
        }
      }
      TvPlaybackController player() =>
          t.widget<TvVideoView>(find.byType(TvVideoView)).controller;
      await player().pause();
      await key(19);
      expect(find.text('选集'), findsOneWidget);
      await key(19);
      await t.pumpAndSettle();
      expect(find.text('选集'), findsNothing);
      expect(player().playing, isFalse);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-video');
      await key(20);
      expect(find.text('选集'), findsOneWidget);
      final position = player().position;
      for (var seconds = 1; seconds <= 31; seconds++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        await t.pump();
        if (seconds == 28) expect(find.text('选集'), findsOneWidget);
      }
      await t.pumpAndSettle();
      expect(find.text('选集'), findsNothing);
      expect(find.byType(TvPlayerSurface), findsOneWidget);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-video');
      expect(player().playing, isFalse);
      expect(
        (player().position - position).inMilliseconds.abs(),
        lessThan(150),
      );
      print(
        'TV_CONTROLS_IDLE_PASS hardware_up=true idle_30s=true route_preserved=true paused_position_preserved=true',
      );
    },
  );
}
