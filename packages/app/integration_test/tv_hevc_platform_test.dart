import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/tv/tv_detail_page.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_app/playback/tv_video_view.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_tv/hongguo_tv.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:video_player/video_player.dart';

import '../test/fakes.dart';

const source =
    '/data/user/0/com.example.hongguo_app.tv/files/tv-green-hevc.mp4';

class _Runtime extends FakeRuntime {
  _Runtime() {
    settings = const AppSettings(autoNext: false, prefetchEnabled: false);
  }
  @override
  PlaybackJob prepare(
    String vid, {
    String quality = 'best',
    void Function(PreparationProgress)? onProgress,
    bool background = false,
  }) => _Job();
}

class _Job implements PlaybackJob {
  @override
  Future<String> get source async => Uri.file(
    '/data/user/0/com.example.hongguo_app.tv/files/tv-green-hevc.mp4',
  ).toString();
  @override
  void cancel() {}
  @override
  void release() {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  testWidgets(
    'production TV HEVC surface preserves overlays and background return',
    (t) async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      await t.pumpWidget(
        TvBackDispatcher(
          builder: (_, key) => MaterialApp(
            navigatorKey: key,
            builder: (_, child) => TvEnvironment(
              enabled: true,
              child: TvNavigation(child: child!),
            ),
            home: TvDetailPage(runtime: runtime, initial: FakeCatalog.demo),
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
        await t.pumpAndSettle();
      }

      await key(23);
      for (var i = 0; i < 150; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await t.pump();
        if (find.byType(AndroidViewSurface).evaluate().isNotEmpty &&
            !t.widget<TvPlayerSurface>(find.byType(TvPlayerSurface)).busy &&
            t.widget<TvPlayerSurface>(find.byType(TvPlayerSurface)).duration >
                Duration.zero) {
          break;
        }
      }
      expect(
        t.widget<TvPlayerSurface>(find.byType(TvPlayerSurface)).busy,
        isFalse,
      );
      await t.pumpAndSettle();
      TvPlaybackController player() =>
          t.widget<TvVideoView>(find.byType(TvVideoView)).controller;
      expect(player().video!.viewType, VideoViewType.platformView);
      expect(player().video!.value.size, const Size(1080, 1920));
      await player().seek(const Duration(seconds: 5));
      await player().video!.play();
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await t.pump();
      }
      await player().pause();
      await t.pumpAndSettle();
      print('TV_SCREENSHOT=hevc-fixed-frame');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      print(
        'TV_HEVC_FOCUS before=${FocusManager.instance.primaryFocus?.debugLabel} busy=${t.widget<TvPlayerSurface>(find.byType(TvPlayerSurface)).busy}',
      );
      await key(19);
      print(
        'TV_HEVC_FOCUS after=${FocusManager.instance.primaryFocus?.debugLabel}',
      );
      expect(find.text('选集'), findsOneWidget);
      print('TV_SCREENSHOT=hevc-fixed-controls');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await key(19);
      expect(find.text('选集'), findsNothing);
      final position = player().position;
      print('TV_HEVC_BACKGROUND_READY');
      // The host sends Home and resumes this Activity to exercise real Surface loss.
      for (
        var i = 0;
        i < 600 && t.binding.lifecycleState == AppLifecycleState.resumed;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(t.binding.lifecycleState, isNot(AppLifecycleState.resumed));
      print('TV_HEVC_RESUME_READY');
      for (
        var i = 0;
        i < 600 && t.binding.lifecycleState != AppLifecycleState.resumed;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(t.binding.lifecycleState, AppLifecycleState.resumed);
      await t.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await t.pumpAndSettle();
      expect(player().playing, isFalse);
      expect(
        (player().position - position).inMilliseconds.abs(),
        lessThan(150),
      );
      expect(player().error, isNull);
      print('TV_SCREENSHOT=hevc-fixed-after-resume');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await key(4);
      expect(find.text('▶ 开始观看'), findsOneWidget);
      print('TV_SCREENSHOT=hevc-fixed-back-to-detail');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      print(
        'TV_HEVC_PLATFORM_PASS production_controller=true menu_overlay=true background_resume=true progress_preserved=true back_to_detail=true',
      );
    },
    skip: !File(source).existsSync(),
  );
}
