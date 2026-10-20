import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player/video_player.dart';

/// Device-only diagnosis. Input files are copied into the app sandbox separately;
/// no online request or downloaded asset is part of this test/build.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'compare HEVC/H264 and texture/platform rendering on the same device',
    (t) async {
      for (final codec in ['hevc', 'h264']) {
        for (final mode in [
          VideoViewType.textureView,
          VideoViewType.platformView,
        ]) {
          final video = VideoPlayerController.networkUrl(
            Uri.file(
              '/data/user/0/com.example.hongguo_app.tv/files/tv-green-$codec.mp4',
            ),
            viewType: mode,
          );
          await video.initialize();
          await t.pumpWidget(
            MaterialApp(
              home: Scaffold(
                backgroundColor: Colors.black,
                body: Center(
                  child: AspectRatio(
                    aspectRatio: video.value.aspectRatio,
                    child: VideoPlayer(video),
                  ),
                ),
              ),
            ),
          );
          await video.seekTo(const Duration(seconds: 5));
          await video.play();
          await Future<void>.delayed(const Duration(milliseconds: 800));
          await t.pump();
          await video.pause();
          await t.pumpAndSettle();
          expect(video.value.hasError, isFalse);
          print(
            'TV_GREEN_SAMPLE codec=$codec view=${mode.name} size=${video.value.size} position_ms=${video.value.position.inMilliseconds}',
          );
          print(
            'TV_SCREENSHOT=green-$codec-${mode.name.replaceAll('View', '')}',
          );
          await Future<void>.delayed(const Duration(milliseconds: 500));
          await t.pumpWidget(const SizedBox());
          await video.dispose();
          await t.pumpAndSettle();
        }
      }
    },
    skip:
        !File('/data/user/0/com.example.hongguo_app.tv/files/tv-green-hevc.mp4')
            .existsSync() ||
        !File('/data/user/0/com.example.hongguo_app.tv/files/tv-green-h264.mp4')
            .existsSync(),
  );
}
