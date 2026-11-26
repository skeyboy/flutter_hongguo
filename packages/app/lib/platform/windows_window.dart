import 'package:flutter/services.dart';

import 'background/host_policy.dart';

/// Windows 原生 runner 的窗口通道。原生 `WM_CLOSE` 不再自行裁决，而是把
/// `closeRequested` 转发到这里，由 Dart 按窗口行为偏好处理；`hide` / `quit`
/// 是 Dart 执行「最小化到托盘 / 退出」的出口。
abstract final class WindowsWindow {
  static const channel = MethodChannel('hongguo/windows-window');

  /// 原生关闭按钮转发的请求。由 [WindowCloseGate] 注册裁决器。
  static Future<void> Function()? onCloseRequest;

  static bool _inboundRegistered = false;

  static void ensureInbound() {
    if (_inboundRegistered || !desktopHost) return;
    _inboundRegistered = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'closeRequested') await onCloseRequest?.call();
    });
  }

  static Future<void> invoke(String method, [Object? arguments]) async {
    if (!desktopHost) return;
    try {
      await channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Widget 测试等无原生 runner 的环境。
    } on PlatformException {
      // 窗口可能已经销毁。
    }
  }
}
