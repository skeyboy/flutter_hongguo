// Development-only entry point. The normal application does not import this.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:hongguo_flutter/adapters/native/file_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final directory = await Directory.systemTemp.createTemp(
    'hongguo-player-smoke-',
  );
  final file = File('${directory.path}/fixture.mp4');
  await file.writeAsBytes(
    base64Decode(const String.fromEnvironment('HONGGUO_SMOKE_FIXTURE')),
  );
  decryptFile({
    'path': file.path,
    'spade': const String.fromEnvironment('HONGGUO_SMOKE_SPADE'),
  });
  final player = Player(configuration: const PlayerConfiguration(muted: true));
  final controller = VideoController(player);
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 640,
            height: 480,
            child: Video(controller: controller, controls: NoVideoControls),
          ),
        ),
      ),
    ),
  );
  final errors = <String>[];
  final subscription = player.stream.error.listen(errors.add);
  try {
    final duration = player.stream.duration
        .firstWhere((d) => d.inMilliseconds > 0)
        .timeout(const Duration(seconds: 15));
    await player.open(Media(file.path));
    final length = await duration;
    final tracks = await player.stream.tracks
        .firstWhere(
          (t) =>
              t.audio.any((a) => a.id != 'auto' && a.id != 'no') &&
              t.video.any((v) => v.id != 'auto' && v.id != 'no'),
        )
        .timeout(const Duration(seconds: 15));
    final positioned = player.stream.position
        .firstWhere((p) => p >= const Duration(seconds: 1))
        .timeout(const Duration(seconds: 15));
    await player.seek(const Duration(milliseconds: 1500));
    await positioned;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await player.pause();
    final frame = await player.screenshot(format: 'image/png');
    if (frame == null || frame.length < 100) {
      throw StateError('No decoded video frame');
    }
    if (errors.isNotEmpty) throw StateError(errors.join('\n'));
    final output = File('${directory.path}/decoded-frame.png');
    await output.writeAsBytes(frame);
    stdout.writeln(
      'HONGGUO_PLAYBACK_PASS duration_ms=${length.inMilliseconds} audio_tracks=${tracks.audio.length} video_tracks=${tracks.video.length} seek_ms=${player.state.position.inMilliseconds} frame_bytes=${frame.length}',
    );
    stdout.writeln('HONGGUO_FRAME_PATH=${output.path}');
  } catch (e, stack) {
    stderr.writeln('HONGGUO_PLAYBACK_FAIL $e\n$stack');
    exitCode = 1;
  } finally {
    await subscription.cancel();
    await player.dispose();
    await file.delete();
  }
  exit(exitCode);
}
