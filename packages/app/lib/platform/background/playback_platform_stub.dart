import 'package:flutter/foundation.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:media_kit/media_kit.dart';

class PlaybackPlatform {
  final floating = ValueNotifier(false);
  final platformPip = ValueNotifier(false);
  final bool mobile = false;
  final bool restoringPip = false;
  VoidCallback? onExternalCompleted;
  Future<void> configure(
    Player player,
    AppSettings settings,
    String title, {
    required Future<void> Function(int) step,
  }) async {}
  Future<void> enter(Player player, String source) async =>
      throw UnsupportedError('当前平台不支持悬浮播放');
  Future<void> exit(Player player) async {}
  Future<void> dispose(Player player) async {
    floating.dispose();
    platformPip.dispose();
  }
}
