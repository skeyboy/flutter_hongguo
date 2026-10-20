import 'package:flutter/foundation.dart';

bool get mobileHost =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);
bool get desktopHost => !kIsWeb && !mobileHost;
String get floatingDescription => kIsWeb
    ? '浏览器适配暂不提供此功能。'
    : defaultTargetPlatform == TargetPlatform.android
    ? '通过播放器按钮进入系统画中画，不申请任意应用悬浮窗权限。'
    : defaultTargetPlatform == TargetPlatform.iOS
    ? '将当前本地视频交给系统画中画，返回时同步播放进度。需设备与系统支持。'
    : '将当前播放窗口切为可拖动的置顶小窗，退出后恢复原窗口。';
String get backgroundDownloadDescription => mobileHost
    ? '交给系统下载并显示进度通知。iOS 解密与校验可能延后到返回 App；强制结束 App 不保证继续。'
    : '最小化或切换应用时继续准备缓存；退出 App 后不继续。';
