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

  /// Hands a downloaded-and-checked APK to `PackageInstaller`. The answer is
  /// always something the user can act on, because the system dialog -- not
  /// this app -- decides whether the install happens.
  static Future<String> installApk(String path) async {
    try {
      final message = await channel.invokeMethod<String>('install', {
        'path': path,
      });
      return message ?? '已交给系统安装器，请在弹窗中确认安装。';
    } on PlatformException catch (error) {
      return error.message ?? '系统没有接受这次安装（${error.code}）。';
    } on MissingPluginException {
      return '这台设备的安装通道不可用，请稍后在系统设置中更新。';
    }
  }
}
