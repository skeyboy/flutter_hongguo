import 'dart:async';

import 'package:flutter/services.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:window_manager/window_manager.dart';

import 'background/host_policy.dart';
import 'macos_window.dart';
import 'windows_window.dart';

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
  /// 与关闭按钮的偏好裁决无关——这是明确的「先藏起来」动作。
  static Future<void> hide() {
    if (macHost) return MacWindow.invoke('hide');
    return _windows(() => windowManager.hide(), available: desktopHost);
  }

  static Future<void> show() {
    if (macHost) return MacWindow.invoke('show');
    return _windows(() => windowManager.show(), available: desktopHost);
  }

  /// 退出程序：窗口行为偏好里的显式退出，与托盘右键「退出」同语义。
  static Future<void> quit() {
    if (macHost) return MacWindow.invoke('quit');
    return _windows(() => WindowsWindow.invoke('quit'), available: desktopHost);
  }

  /// 把「窗口行为」偏好下发给原生：macOS 控制关闭分派与 frame autosave；
  /// Windows 关闭由原生转发给 Dart 裁决，几何记忆由 [trackWindowState] 承担。
  static Future<void> applyPreferences({
    required WindowCloseBehavior closeBehavior,
    required bool rememberWindowState,
  }) async {
    if (macHost) {
      await MacWindow.invoke('setCloseBehavior', closeBehavior.name);
      return MacWindow.invoke('setRememberFrame', rememberWindowState);
    }
    if (!desktopHost) return;
    await WindowsWindow.invoke('setCloseBehavior', closeBehavior.name);
    await WindowsWindow.invoke('setRememberFrame', rememberWindowState);
  }

  /// Windows 启动时按上次记录恢复窗口几何；macOS 由 AppKit autosave 承担。
  static Future<void> restoreWindowState(AppSettings settings) async {
    if (macHost || !desktopHost || !settings.rememberWindowState) return;
    if (settings.windowMaximized) {
      return _windows(() => windowManager.maximize(), available: desktopHost);
    }
    final parts = settings.windowBounds.split(',').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((value) => value == null)) return;
    final x = parts[0]!, y = parts[1]!, width = parts[2]!, height = parts[3]!;
    // 设置校验过的下限；屏外位置交给 window_manager/系统自行收敛。
    if (width < 400 || height < 300) return;
    return _windows(
      () => windowManager.setBounds(
        Rect.fromLTWH(
          x.toDouble(),
          y.toDouble(),
          width.toDouble(),
          height.toDouble(),
        ),
      ),
      available: desktopHost,
    );
  }

  static Timer? _geometryDebounce;
  static _GeometryListener? _geometryListener;

  /// 窗口几何持久化回调：由 [WindowCloseGate] 注入（读设置 → 合并写回）。
  static Future<void> Function(String bounds, bool maximized)?
  onGeometryPersist;

  /// 开关 Windows 端的几何监听：移动/缩放/最大化变化结束后防抖 500ms 写回。
  static void trackWindowState(bool enabled) {
    if (macHost || !desktopHost) return;
    if (!enabled) {
      _geometryDebounce?.cancel();
      _geometryDebounce = null;
      if (_geometryListener != null) {
        windowManager.removeListener(_geometryListener!);
        _geometryListener = null;
      }
      return;
    }
    if (_geometryListener != null) return;
    _geometryListener = _GeometryListener();
    _windows(() async {
      windowManager.addListener(_geometryListener!);
    }, available: desktopHost);
  }

  static void _persistGeometrySoon() {
    _geometryDebounce?.cancel();
    _geometryDebounce = Timer(const Duration(milliseconds: 500), () async {
      try {
        final bounds = await windowManager.getBounds();
        final maximized = await windowManager.isMaximized();
        await onGeometryPersist?.call(
          '${bounds.left.round()},${bounds.top.round()},'
          '${bounds.width.round()},${bounds.height.round()}',
          maximized,
        );
      } on MissingPluginException {
        // 测试环境。
      } on PlatformException {
        // 窗口可能已销毁。
      }
    });
  }
}

class _GeometryListener extends WindowListener {
  @override
  void onWindowMoved() => DesktopWindow._persistGeometrySoon();

  @override
  void onWindowResized() => DesktopWindow._persistGeometrySoon();

  @override
  void onWindowMaximize() => DesktopWindow._persistGeometrySoon();

  @override
  void onWindowUnmaximize() => DesktopWindow._persistGeometrySoon();
}
