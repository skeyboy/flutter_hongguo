import 'package:flutter/foundation.dart';

bool get mobileHost =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);
bool get desktopHost => !kIsWeb && !mobileHost;
bool get macHost => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// Occlusion is a desktop window state, not mobile background suspension.
bool allowBackgroundPlayback({required bool tv, required bool enabled}) =>
    !tv && (desktopHost || enabled);
bool allowBackgroundPreparation({required bool tv, required bool enabled}) =>
    !tv && (desktopHost || enabled);

/// Handing a transfer to the operating system only pays for itself where the
/// system suspends the app, so desktop hosts keep the in-app download lane.
bool useSystemTransferLane({required bool enabled}) => mobileHost && enabled;

String get floatingDescription => kIsWeb
    ? '浏览器适配暂不提供此功能。'
    : defaultTargetPlatform == TargetPlatform.android
    ? '通过播放器按钮进入系统画中画，不申请任意应用悬浮窗权限。'
    : defaultTargetPlatform == TargetPlatform.iOS
    ? '将当前本地视频交给系统画中画，返回时同步播放进度。需设备与系统支持。'
    : macHost
    ? '播放页可直接开启系统画中画，退出时同步进度并恢复原播放器。'
    : '将当前播放窗口按片源比例缩小，置顶到屏幕角落，退出后恢复原窗口。';
String get backgroundDownloadDescription => mobileHost
    ? '交给系统下载并显示进度通知。iOS 解密与校验可能延后到返回 App；强制结束 App 不保证继续。'
    : '最小化或切换应用时继续准备缓存；退出 App 后不继续。';
