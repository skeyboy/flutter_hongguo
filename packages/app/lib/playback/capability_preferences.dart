import 'package:flutter/material.dart';
import 'package:hongguo_core/hongguo_core.dart';

import '../platform/background/host_policy.dart';

enum PlaybackCapability {
  backgroundPlayback,
  backgroundDownloads,
  floatingPlayback;

  String get title => switch (this) {
    backgroundPlayback => '后台播放',
    backgroundDownloads => '后台下载',
    floatingPlayback => '悬浮播放',
  };
  bool enabled(AppSettings settings) => switch (this) {
    backgroundPlayback => settings.backgroundPlayback,
    backgroundDownloads => settings.backgroundDownloads,
    floatingPlayback => settings.floatingPlayback,
  };
  AppSettings apply(AppSettings settings, bool value) => switch (this) {
    backgroundPlayback => settings.copyWith(
      backgroundPlayback: value,
      backgroundPlaybackPrompted: true,
    ),
    backgroundDownloads => settings.copyWith(backgroundDownloads: value),
    floatingPlayback => settings.copyWith(
      floatingPlayback: value,
      floatingPlaybackPrompted: true,
    ),
  };
  String description(bool enable) => switch (this) {
    backgroundPlayback =>
      enable
          ? '切到其他应用或锁屏后继续声音播放，并提供系统媒体控制。播放可能增加耗电；关闭播放页仍会停止。'
          : '关闭后，切到其他应用或锁屏会暂停播放，并退出系统媒体控制。',
    backgroundDownloads =>
      enable
          ? '交给系统下载，并按系统授权显示进度通知。可能增加耗电和流量；默认仅 Wi-Fi。iOS 解密可能需返回 App，强制结束应用不保证继续。'
          : '关闭后取消正在执行的系统下载任务；已完成的缓存保留。',
    floatingPlayback =>
      enable ? floatingDescription : '关闭后将退出当前悬浮播放，并隐藏播放器的悬浮入口。',
  };
}

Future<bool> confirmPlaybackCapability(
  BuildContext context,
  PlaybackCapability capability,
  bool enable, {
  bool recommendation = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(
          recommendation
              ? '试试${capability.title}？'
              : '${enable ? '开启' : '关闭'}${capability.title}？',
        ),
        content: Text(capability.description(enable)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(recommendation ? '暂不开启' : '取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(enable ? '开启并生效' : '关闭并生效'),
          ),
        ],
      ),
    ) ==
    true;

/// One recommendation per actual return, with durable decisions and a cooldown.
class PlaybackReturnRecommendations {
  DateTime? lastShown;
  final DateTime Function() now;
  PlaybackReturnRecommendations({DateTime Function()? now})
    : now = now ?? DateTime.now;
  PlaybackCapability? next(AppSettings settings) {
    if (lastShown != null &&
        now().difference(lastShown!) < const Duration(minutes: 1)) {
      return null;
    }
    if (!settings.backgroundPlayback && !settings.backgroundPlaybackPrompted) {
      return PlaybackCapability.backgroundPlayback;
    }
    if (!settings.floatingPlayback && !settings.floatingPlaybackPrompted) {
      return PlaybackCapability.floatingPlayback;
    }
    return null;
  }

  AppSettings markAsked(AppSettings settings, PlaybackCapability capability) {
    lastShown = now();
    return capability == PlaybackCapability.backgroundPlayback
        ? settings.copyWith(backgroundPlaybackPrompted: true)
        : settings.copyWith(floatingPlaybackPrompted: true);
  }
}
