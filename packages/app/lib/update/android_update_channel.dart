import 'dart:async';

import 'package:flutter/services.dart';

/// The Android half of updating: where a verified APK may sit and the system
/// installer that takes it. Implemented by `hongguo/update` in
/// `android/app/src/main/kotlin/.../MainActivity.kt`, so the desktop builds --
/// which have no such handler -- degrade to the file being described instead of
/// throwing.
class AndroidUpdate {
  static const MethodChannel channel = MethodChannel('hongguo/update');

  /// The app-private folder the installer is allowed to read. The native side
  /// creates it, because only it knows what is legal for a provider to serve.
  static Future<String?> stageDirectory() async {
    try {
      return await channel.invokeMethod<String>('stageDir');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// ABIs in the order the device itself prefers, for choosing the APK.
  static Future<List<String>> supportedAbis() async {
    try {
      final value = await channel.invokeMethod<List<Object?>>('abi');
      return value?.whereType<String>().toList() ?? const [];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Whether the system will take an APK from this app at all. Android 8 moved
  /// 「安装未知应用」 out of the runtime dialog and into a per-app setting the viewer
  /// has to turn on, so a session committed without it never reaches the
  /// installer -- asking first is the only way to explain that rather than
  /// reporting a handoff that silently did nothing.
  ///
  /// A device with no handler for this channel -- every desktop build -- is not
  /// installing through this path at all, so it answers 已允许 and the platform's own
  /// handoff stays in charge.
  static Future<bool> canInstallPackages() async {
    try {
      return await channel.invokeMethod<bool>('canInstall') ?? true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  /// Sends the viewer to this app's 「安装未知应用」 row. A false answer means there
  /// was no screen to open, so the words have to name the setting instead of
  /// waiting for a return that will not happen.
  static Future<bool> openInstallPermissionSettings() async {
    try {
      return await channel.invokeMethod<bool>('askPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Hands a downloaded-and-checked APK to `PackageInstaller`. The answer is
  /// always something the user can act on, because the system dialog -- not
  /// this app -- decides whether the install happens: the native side holds the
  /// call open until the system reports on the session, including the case where
  /// it only asks the user to confirm.
  ///
  /// The wait is capped so a status that never arrives cannot leave the dialog's
  /// button pinned at 正在下载 forever -- but a slow reader still has that dialog
  /// open, so the capped answer says both halves instead of declaring a failure
  /// this app did not see.
  static Future<String> installApk(String path) async {
    try {
      final message = await channel
          .invokeMethod<String>('install', {'path': path})
          .timeout(
            const Duration(seconds: 60),
            onTimeout: () =>
                '系统安装器没有回话：弹窗已出现请在其中确认安装，没有弹窗请在系统设置里允许本应用安装未知应用后重试。',
          );
      return message ?? '已交给系统安装器，请在弹窗中确认安装。';
    } on PlatformException catch (error) {
      return error.message ?? '系统没有接受这次安装（${error.code}）。';
    } on MissingPluginException {
      return '这台设备的安装通道不可用，请稍后在系统设置中更新。';
    }
  }
}
