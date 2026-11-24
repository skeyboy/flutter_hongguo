import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'background/host_policy.dart';
import 'macos_window.dart';

/// 一处封装桌面窗口动作：macOS 走自绘 caption 的原生 channel，
/// Windows/Linux 走 window_manager。移动端与 Web 是 no-op，避免调用方散布
/// 平台判断；plugin/原生窗口缺失时吞掉异常，widget 测试可直接点按钮。
abstract final class DesktopWindow {
  static Future<void> _windows(
    Future<void> Function() action, {
    required bool available,
  }) async {
    if (!available) return;
    try {
      await windowManager.ensureInitialized();
      await action();
    } on MissingPluginException {
      // 无原生窗口的测试环境。
    } on PlatformException {
      // 窗口可能已经关闭。
    }
  }

  static bool get supported => desktopHost;

  static Future<void> minimize() {
    if (macHost) return MacWindow.invoke('minimize');
    // 惰性闭包： tear-off 会在传参时就取一次 windowManager，触发插件初始化，
    // 即使桌面不可用（移动/Web、纯 widget 测试）也不该发生。
    return _windows(() => windowManager.minimize(), available: desktopHost);
  }

  /// 最大化/还原。macOS 的绿键语义是 zoom（原生 `performZoom`），
  /// 与全屏切换分开，避免和播放器的沉浸式全屏抢状态。
  static Future<void> toggleMaximize() {
    if (macHost) return MacWindow.invoke('zoom');
    return _windows(() async {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    }, available: desktopHost);
  }

  /// 隐藏窗口但不退出：Windows 已由原生托盘接管，macOS 保留播放引擎。
  static Future<void> hide() {
    if (macHost) return MacWindow.invoke('hide');
    return _windows(() => windowManager.hide(), available: desktopHost);
  }

  static Future<void> show() {
    if (macHost) return MacWindow.invoke('show');
    return _windows(() => windowManager.show(), available: desktopHost);
  }
}
