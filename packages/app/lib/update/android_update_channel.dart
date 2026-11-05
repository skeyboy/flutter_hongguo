import 'package:flutter/services.dart';
import 'package:flutter_app_installer/flutter_app_installer.dart';
import 'package:permission_handler/permission_handler.dart';

/// The Android half of updating: which ABIs this device runs, and the two plugin
/// channels the install flow is built on -- `permission_handler` decides whether
/// the app may install at all, `flutter_app_installer` opens the system installer
/// for the verified APK.
///
/// `hongguo/update` carries only `abi` today; the desktop builds have no handler
/// for it, so the ABI question degrades to 「没有 Android ABI」 rather than throwing.
class AndroidUpdate {
  static const MethodChannel channel = MethodChannel('hongguo/update');

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
}

/// The install-facing slice of the two plugins, in the words the update flow
/// speaks: one seam so the suite can answer the permission question with a mock
/// and hand a staged path to the installer, and so `install_strategy.dart` never
/// has to fake a plugin type of its own.
class AndroidInstallerGateway {
  /// `permission_handler`'s method channel -- `Permission.status` and
  /// `Permission.request` travel through it before the plugin's own Dart layer
  /// turns the raw ints back into `PermissionStatus`.
  static const MethodChannel permissions = MethodChannel(
    'flutter.baseflow.com/permissions/methods',
  );

  /// Android 8 moved 「安装未知应用」 out of the runtime dialog and into a per-app
  /// setting the viewer has to turn on, so a handoff committed without it never
  /// reaches the installer -- asking first is the only way to explain that
  /// rather than reporting a handoff that silently did nothing.
  Future<bool> canInstall() async {
    final status = await Permission.requestInstallPackages.status;
    return status == PermissionStatus.granted;
  }

  /// Sends the viewer to this app's 「安装未知应用」 settings row on Android 8+, or
  /// the runtime dialog below it. Whether the switch ended up on is a later
  /// question -- read [canInstall] again when the app is back.
  Future<void> requestPermission() =>
      Permission.requestInstallPackages.request();

  /// Hands a downloaded-and-checked APK to `flutter_app_installer`, which turns
  /// the path into a URI through the FileProvider this app declares as
  /// `${applicationId}.fileProvider` and opens the system installer with an
  /// `ACTION_VIEW` intent. The answer is whether the intent left this app --
  /// never whether the install happened: the system dialog decides that, and
  /// the plugin hears nothing back from it.
  Future<String> installApk(String path) async {
    try {
      final opened = await FlutterAppInstaller().installApk(filePath: path);
      return opened ? '已交给系统安装器，请在弹窗中确认安装。' : '安装包没能交给系统安装器，请重新点「立即更新」下载。';
    } on PlatformException {
      return '安装包没能交给系统安装器，请重新点「立即更新」下载。';
    } on MissingPluginException {
      return '这台设备的安装通道不可用，请稍后在系统设置中更新。';
    }
  }
}
