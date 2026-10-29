import 'dart:io';

import 'package:hongguo_update/hongguo_update.dart';

import 'android_update_channel.dart';

/// What the app did with a release file whose bytes already matched, and what it
/// still owes the user.
class InstallPlan {
  final String message;

  /// Windows installs over a running executable, so the app has to leave first;
  /// the UI says goodbye instead of pretending it is still there.
  final bool appWillExit;

  /// Nothing this platform can install -- show the release page instead.
  final String? releaseUrl;

  const InstallPlan({
    required this.message,
    this.appWillExit = false,
    this.releaseUrl,
  });
}

/// The Dart build tag carries the architecture: `… on "macos_arm64"`. Reading it
/// beats a subprocess and a plugin for choosing which image to install.
String _archTag() {
  final target = RegExp(r'on "([^"]+)"').firstMatch(Platform.version)?.group(1);
  if (target == null) return '';
  final parts = target.split('_');
  return parts.length >= 2 ? parts.last : '';
}

/// Which attachment belongs to this device, with the Android ABIs the caller
/// read from the platform channel.
UpdateTarget currentUpdateTarget({List<String> abis = const []}) {
  const arches = {'arm64', 'x64'};
  final raw = _archTag();
  return UpdateTarget(
    platform: switch (Platform.operatingSystem) {
      'windows' => ReleasePlatform.windows,
      'macos' => ReleasePlatform.macOS,
      'linux' => ReleasePlatform.linux,
      'android' => ReleasePlatform.android,
      'ios' => ReleasePlatform.iOS,
      _ => ReleasePlatform.iOS,
    },
    arch: arches.contains(raw) ? raw : '',
    abis: abis,
  );
}

/// What pressing 立即更新 will do here, said before the user presses it: the
/// platforms differ enough that a shared sentence would promise too much.
String get updateHandoffDescription => switch (Platform.operatingSystem) {
  'windows' => '下载并校验后静默运行安装程序替换本应用，随后自动退出。',
  'macos' => '下载并校验后打开磁盘映像，把新的 Hongguo 拖进「应用程序」替换旧版本。',
  'linux' => '下载并校验后交给系统打开安装包。',
  'android' => '下载并校验后交给系统安装器，请在系统弹窗中确认安装。',
  'ios' => 'iOS 不允许应用自行安装，检查到新版本只会给出发布页地址。',
  _ => '下载并校验后按本机方式安装。',
};

/// Hands a verified file to the operating system. Every branch says in the
/// user's words what actually has to happen next -- none of them claims an
/// installation this app cannot perform.
Future<InstallPlan> handOff(DownloadedRelease file, ReleaseInfo release) async {
  switch (Platform.operatingSystem) {
    case 'windows':
      return _runWindowsInstaller(file.path);
    case 'macos':
      return _openOnMac(file.path);
    case 'linux':
      return _openOnLinux(file);
    case 'android':
      final message = await AndroidUpdate.installApk(file.path);
      return InstallPlan(message: message);
    default:
      return InstallPlan(
        message: '这个平台不能自行安装更新，请打开发布页下载。',
        releaseUrl: release.htmlUrl,
      );
  }
}

/// Silent upgrade of the per-user install (`tool/ci/windows-installer.iss` is
/// `PrivilegesRequired=lowest` under `{localappdata}`), launched by a helper the
/// running process cannot block: our own exe is the file being replaced, so the
/// helper waits for us to exit and then removes itself.
Future<InstallPlan> _runWindowsInstaller(String setupPath) async {
  final script = File(
    '${File(setupPath).parent.path}${Platform.pathSeparator}hongguo-update.cmd',
  );
  await script.writeAsString(
    '@echo off\r\n'
    'start "" /wait "$setupPath" /VERYSILENT /NORESTART /SUPPRESSMSGBOXES\r\n'
    'del "%~f0"\r\n',
  );
  await Process.start('cmd.exe', [
    '/c',
    script.path,
  ], mode: ProcessStartMode.detached);
  return const InstallPlan(
    message: '安装程序已在后台启动，应用即将退出以替换文件。',
    appWillExit: true,
  );
}

Future<InstallPlan> _openOnMac(String path) async {
  if (await Process.run('open', [path]).then((r) => r.exitCode) == 0) {
    return const InstallPlan(message: '镜像已打开：把新的 Hongguo 拖进「应用程序」替换旧版本即可。');
  }
  // The shipped build is sandboxed, so the system may refuse to mount a file
  // the app downloaded; pointing at it in Finder is the honest remaining step.
  final revealed = await Process.run('open', ['-R', path]);
  return InstallPlan(
    message: revealed.exitCode == 0
        ? '镜像已校验完成并在访达中选中，请双击打开后把 Hongguo 拖进「应用程序」。'
        : '镜像已校验完成，位于 $path，请手动打开。',
  );
}

Future<InstallPlan> _openOnLinux(DownloadedRelease file) async {
  final isPackage = file.path.endsWith('.deb');
  if (await Process.run('xdg-open', [file.path]).then((r) => r.exitCode) == 0) {
    return InstallPlan(
      message: isPackage
          ? '已交给系统包管理器，请在其中确认安装。'
          : '压缩包已下载到 ${file.path}，请照现有方式替换应用文件。',
    );
  }
  return InstallPlan(message: '更新文件已校验完成，位于 ${file.path}，请手动安装。');
}
