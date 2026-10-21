import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/platform/background/playback_platform_native.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:media_kit/media_kit.dart';

class _Player extends Fake implements Player {
  @override
  PlayerState state = const PlayerState(
    playing: true,
    position: Duration(seconds: 12),
    rate: 1.5,
    volume: 50,
  );
  @override
  Future<void> play() async => state = state.copyWith(playing: true);
  @override
  Future<void> pause() async => state = state.copyWith(playing: false);
  @override
  Future<void> seek(Duration value) async =>
      state = state.copyWith(position: value);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('hongguo/platform-playback');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<void> event(String method, Object? data) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, data)),
      (_) {},
    );
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('Mac handoff encodes file paths and restores native position and paused state', () async {
    if (!Platform.isMacOS) return;
    final player = _Player();
    final platform = PlaybackPlatform();
    Map<dynamic, dynamic>? args;
    var progress = 0;
    platform.onExternalProgress = () => progress++;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'enter') {
        args = call.arguments as Map;
        return true;
      }
      return null;
    });
    await platform.configure(
      player,
      const AppSettings(floatingPlayback: true),
      'test',
      step: (_) async {},
    );
    await platform.enter(player, '/tmp/a video/episode.mp4');
    expect(args!['source'], 'file:///tmp/a%20video/episode.mp4');
    expect(args!['position'], 12000);
    expect(args!['rate'], 1.5);
    expect(args!['volume'], .5);
    expect(player.state.playing, isFalse);
    expect(platform.platformPip.value, isTrue);
    await event('progress', {'position': 19000, 'playing': true});
    expect(platform.externalPosition, const Duration(seconds: 19));
    expect(progress, 1);
    await event('restore', {
      'position': 21000,
      'playing': false,
      'ended': false,
    });
    expect(player.state.position, const Duration(seconds: 21));
    expect(player.state.playing, isFalse);
    expect(platform.platformPip.value, isFalse);
    expect(platform.externalPosition, isNull);
    await platform.dispose(player);
  });

  test(
    'Mac PiP failure restores original playing state without mobile opt in',
    () async {
      if (!Platform.isMacOS) return;
      final player = _Player();
      final platform = PlaybackPlatform();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'enter') {
          throw PlatformException(code: 'pip_unavailable');
        }
        return null;
      });
      await platform.configure(
        player,
        const AppSettings(floatingPlayback: true),
        'test',
        step: (_) async {},
      );
      await expectLater(
        platform.enter(player, '/tmp/episode.mp4'),
        throwsA(isA<PlatformException>()),
      );
      expect(player.state.playing, isTrue);
      expect(platform.floating.value, isFalse);
      expect(platform.platformPip.value, isFalse);
      await player.pause();
      await expectLater(
        platform.enter(player, '/tmp/episode.mp4'),
        throwsA(isA<PlatformException>()),
      );
      expect(player.state.playing, isFalse);
      await platform.dispose(player);
    },
  );
}
