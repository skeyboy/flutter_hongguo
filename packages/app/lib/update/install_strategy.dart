import 'dart:convert';
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

  /// The handoff installed nothing and left a verified APK owed to a later
  /// return, so the trip to 系统设置 is still ahead of the viewer. The prompt keeps
  /// itself open on this plan: closing it on a handoff that installed nothing is
  /// how 「按下 立即更新 后什么都没有」 reads from the outside.
  final bool owesInstall;

  const InstallPlan({
    required this.message,
    this.appWillExit = false,
    this.releaseUrl,
    this.owesInstall = false,
  });
}

/// The note that a verified APK is still owed an install, written in the stage
/// directory beside the file it names.
class _PendingApk {
  const _PendingApk({required this.path, required this.bytes});

  final String path;
  final int bytes;

  Map<String, Object> toJson() => {'path': path, 'bytes': bytes};

  static _PendingApk? fromJson(Object? value) {
    if (value is! Map) return null;
    final path = value['path'], bytes = value['bytes'];
    if (path is! String || path.isEmpty || bytes is! int) return null;
    return _PendingApk(path: path, bytes: bytes);
  }
}

/// Android cannot finish an install inside one call: 「安装未知应用」 is a switch that
/// lives in a settings screen the viewer has to leave the app for -- and leaving
/// it is exactly when Android takes this process away. So the verified APK is
/// written down as owed, and [resume] pays it on the next return, whichever
/// return that is: from the settings screen, or a launch the system started.
///
/// The permission question and the install itself are the two plugins' --
/// `permission_handler` answers 「may this app install at all」 and
/// `flutter_app_installer` opens the system installer over the verified APK.
/// What the plugin cannot give back is the install's outcome: the intent is
/// fire-and-forget, so the app reports the handoff, never a 已安装 it did not see.
class AndroidInstaller {
  AndroidInstaller({
    required this.stageDirectory,
    AndroidInstallerGateway? gateway,
  }) : gateway = gateway ?? AndroidInstallerGateway();

  /// The directory the release downloader wrote into, so a later launch finds the
  /// APK and its note under the same names.
  final Future<String> Function() stageDirectory;

  /// Injectable because the suite has neither plugin to hand an install to, and
  /// the order of the questions -- permission first, intent second -- is the
  /// thing under test.
  final AndroidInstallerGateway gateway;

  Future<File> _markerFile() async => File(
    '${await stageDirectory()}${Platform.pathSeparator}hongguo-pending-install.json',
  );

  Future<InstallPlan> install(DownloadedRelease file) async {
    if (await gateway.canInstall()) {
      await _forget();
      return InstallPlan(message: await gateway.installApk(file.path));
    }
    await gateway.requestPermission();
    final marker = await _markerFile();
    await marker.writeAsString(
      jsonEncode(_PendingApk(path: file.path, bytes: file.bytes).toJson()),
    );
    return const InstallPlan(
      message: '需要先允许本应用安装未知应用：请在设置中打开该权限，回到应用后会自动继续安装。',
      owesInstall: true,
    );
  }

  /// A return to the app, and what it has to say about the install it found
  /// owed. Null means this app owed nothing -- the common case on every platform
  /// without an installer path, and on Android once the note has been paid.
  ///
  /// A debt that is still unpaid answers in words. Staying silent here was the
  /// hole a viewer lands in most often: they press 立即更新, Android takes the app to
  /// the settings screen, they come back without turning the switch -- and
  /// nothing on screen says the update is still waiting, because the prompt
  /// closed on the way out and the only trace was a file nobody reads.
  Future<String?> resume() async {
    final pending = await _read();
    if (pending == null) return null;
    if (!await gateway.canInstall()) {
      return '还欠着一次更新安装：本应用仍未被允许安装未知应用。在系统设置里打开该权限后回到应用会自动继续，不需要再点一次。';
    }
    if (!await _intact(pending)) {
      await _forget();
      return '安装包已经不完整或被系统清理，请重新点「立即更新」下载。';
    }
    // Spent before the installer opens: the system dialog that follows can sit
    // on the screen while the viewer decides, and a return inside that window
    // must not hand the same APK over a second time.
    await _forget();
    return gateway.installApk(pending.path);
  }

  /// Whether an install is owed right now, which is the note's existence rather
  /// than anything held in memory: paying it deletes the note, so this is also
  /// how the app knows a debt was settled while its process was gone.
  Future<bool> hasOwedInstall() async => await _read() != null;

  /// A folder this app cannot read, and a note a killed process left half-written,
  /// both answer as nothing owed: the APK stays on disk and the next 立即更新 writes
  /// a fresh note.
  Future<_PendingApk?> _read() async {
    try {
      final marker = await _markerFile();
      if (!await marker.exists()) return null;
      return _PendingApk.fromJson(jsonDecode(await marker.readAsString()));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _forget() async {
    try {
      final marker = await _markerFile();
      await marker.delete();
    } on FileSystemException {
      // No note there means nothing was owed.
    }
  }

  /// Whether the APK is still the file the downloader verified. Storage cleanup
  /// can take it between the handoff and the return, and a session must not be
  /// opened on something that no longer has the size its own note recorded.
  Future<bool> _intact(_PendingApk pending) async {
    try {
      final stat = await File(pending.path).stat();
      return stat.type == FileSystemEntityType.file &&
          stat.size == pending.bytes;
    } on FileSystemException {
      return false;
    }
  }
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
  'android' =>
    '下载并校验后交给系统安装器；若还没允许本应用安装未知应用，会先带你到系统设置开启，权限一开回到应用就自动继续安装，不需要再点一次。',
  'ios' => 'iOS 不允许应用自行安装，检查到新版本只会给出发布页地址。',
  _ => '下载并校验后按本机方式安装。',
};

/// Hands a verified file to the operating system. Every branch says in the
/// user's words what actually has to happen next -- none of them claims an
/// installation this app cannot perform.
Future<InstallPlan> handOff(
  DownloadedRelease file,
  ReleaseInfo release, {
  required AndroidInstaller android,
}) async {
  switch (Platform.operatingSystem) {
    case 'windows':
      return _runWindowsInstaller(file.path);
    case 'macos':
      return _openOnMac(file.path);
    case 'linux':
      return _openOnLinux(file);
    case 'android':
      // The bytes are verified; whether the system will accept them is a
      // per-app setting the viewer controls, so ask before opening a session
      // that would be dropped without a word.
      return android.install(file);
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
