import 'package:flutter/foundation.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:media_kit/media_kit.dart';

class PlaybackPlatform {
  final nativeFullscreen = ValueNotifier<bool?>(null);
  final floating = ValueNotifier(false);
  final platformPip = ValueNotifier(false);
  VoidCallback? onWindowFocused;
  Duration? externalPosition;
  bool? externalPlaying;
  VoidCallback? onExternalProgress;
  final bool mobile = false;
  final bool transitioning = false;
  Future<bool> supportsFloating() async => false;
  final bool restoringPip = false;
  VoidCallback? onExternalCompleted;
  Future<void> configure(
    Player player,
    AppSettings settings,
    String title, {
    required Future<void> Function(int) step,
    bool foregroundMedia = false,
  }) async {}
  Future<void> enter(Player player, String source) async =>
      throw UnsupportedError('当前平台不支持悬浮播放');
  Future<bool> replaceFloating(
    Player player,
    String source, {
    required Duration offset,
    required bool play,
  }) async => false;
  Future<void> get fullscreenUpdates => Future.value();
  Future<void> setDesktopFullscreen(bool value) async {}
  Future<void> exit(Player player) async {}
  Future<void> dispose(Player player) async {
    nativeFullscreen.dispose();
    floating.dispose();
    platformPip.dispose();
  }
}
