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

  test(
    'Mac native completion and item replacement preserve PiP ownership',
    () async {
      if (!Platform.isMacOS) return;
      final player = _Player();
      final platform = PlaybackPlatform();
      var completions = 0;
      Map<dynamic, dynamic>? replacement;
      platform.onExternalCompleted = () => completions++;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'replace') replacement = call.arguments as Map;
        return true;
      });
      await platform.configure(
        player,
        const AppSettings(floatingPlayback: true),
        'test',
        step: (_) async {},
      );
      await platform.enter(player, '/tmp/first.mp4');
      await event('completed', {'source': 'file:///tmp/first.mp4'});
      expect(completions, 1);
      expect(platform.platformPip.value, isTrue);
      expect(
        await platform.replaceFloating(
          player,
          '/tmp/second.mp4',
          offset: Duration.zero,
          play: true,
        ),
        isTrue,
      );
      expect(replacement!['source'], 'file:///tmp/second.mp4');
      expect(platform.externalPlaying, isTrue);
      expect(platform.externalPosition, Duration.zero);
      await event('completed', {'source': 'file:///tmp/first.mp4'});
      expect(completions, 1);
      await event('progress', {
        'source': 'file:///tmp/first.mp4',
        'position': 90000,
        'playing': false,
      });
      expect(platform.externalPosition, Duration.zero);
      await event('completed', {'source': 'file:///tmp/second.mp4'});
      expect(completions, 2);
      expect(player.state.playing, isFalse);
      await platform.dispose(player);
    },
  );
  test(
    'closing old PiP during a new episode cannot restore its old offset',
    () async {
      if (!Platform.isMacOS) return;
      final player = _Player();
      final platform = PlaybackPlatform();
      messenger.setMockMethodCallHandler(channel, (_) async => true);
      await platform.configure(
        player,
        const AppSettings(floatingPlayback: true),
        'test',
        step: (_) async {},
      );
      await platform.enter(player, '/tmp/first.mp4');
      player.state = player.state.copyWith(
        playlist: Playlist([Media('/tmp/second.mp4')]),
        position: const Duration(seconds: 3),
      );
      var completions = 0;
      platform.onExternalCompleted = () => completions++;
      await event('restore', {
        'source': 'file:///tmp/first.mp4',
        'position': 90000,
        'playing': true,
        'ended': true,
      });
      expect(player.state.position, const Duration(seconds: 3));
      expect(player.state.playing, isFalse);
      expect(completions, 0);
      expect(platform.floating.value, isFalse);
      await platform.dispose(player);
    },
  );
  test('Mac fullscreen exit waits for native enter completion', () async {
    if (!Platform.isMacOS) return;
    const windowChannel = MethodChannel('window_manager');
    final calls = <bool>[];
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      if (call.method == 'isFullScreen') return false;
      if (call.method == 'setFullScreen') {
        calls.add((call.arguments as Map)['isFullScreen'] as bool);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(windowChannel, null));
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    final platform = PlaybackPlatform(), player = _Player();
    final entering = platform.setDesktopFullscreen(true);
    final exiting = platform.setDesktopFullscreen(false);
    for (var i = 0; i < 20 && calls.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(calls, [true]);
    platform.onWindowEnterFullScreen();
    await entering;
    for (var i = 0; i < 20 && calls.length == 1; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(calls, [true, false]);
    platform.onWindowLeaveFullScreen();
    await exiting;
    expect(platform.nativeFullscreen.value, isFalse);
    await platform.dispose(player);
  });
  test('an older player cannot detach the new native event handler', () async {
    if (!Platform.isMacOS) return;
    messenger.setMockMethodCallHandler(channel, (_) async => true);
    final oldPlatform = PlaybackPlatform();
    final platform = PlaybackPlatform(), player = _Player();
    await platform.configure(
      player,
      const AppSettings(floatingPlayback: true),
      'new',
      step: (_) async {},
    );
    await platform.enter(player, '/tmp/new.mp4');
    await oldPlatform.dispose(_Player());
    await event('progress', {
      'source': 'file:///tmp/new.mp4',
      'position': 1234,
      'playing': true,
    });
    expect(platform.externalPosition, const Duration(milliseconds: 1234));
    await platform.dispose(player);
  });
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
