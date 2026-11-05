import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/update/android_update_channel.dart';
import 'package:hongguo_app/update/install_strategy.dart';
import 'package:hongguo_update/hongguo_update.dart';

/// The two plugin channels the install flow is built on, answered by mocks:
/// `permission_handler`'s channel stands in for 「安装未知应用」 and
/// `flutter_app_installer`'s for the ACTION_VIEW handoff, so the suite proves
/// the order of the questions without a phone and without either plugin.
class _FakePlugins {
  _FakePlugins() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      AndroidInstallerGateway.permissions,
      _permissionCall,
    );
    messenger.setMockMethodCallHandler(_installerChannel, _installerCall);
  }

  /// `flutter_app_installer`'s own channel. The production code goes through the
  /// plugin's Dart layer, so mocking here proves that layer reaches the
  /// `installApk` contract with the arguments the native side expects.
  static const _installerChannel = MethodChannel('flutter_app_installer');

  /// The switch the viewer controls. Tests flip it to play the return from
  /// settings.
  bool granted = false;

  /// Whether the installer intent leaves this app -- false is the plugin's own
  /// answer for 「the staged file is gone」.
  bool intentOpens = true;

  final List<String> calls = [];
  final List<String> sessions = [];

  /// `permission_handler` moves `Permission.requestInstallPackages` as the int
  /// its table carries (group 24), and answers statuses as raw ints: 0 denied,
  /// 1 granted.
  static const _granted = 1;
  static const _denied = 0;

  Future<Object?> _permissionCall(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'checkPermissionStatus':
        return granted ? _granted : _denied;
      case 'requestPermissions':
        final permissions = (call.arguments as List<Object?>).cast<int>();
        return {
          for (final permission in permissions)
            permission: granted ? _granted : _denied,
        };
      default:
        return null;
    }
  }

  Future<Object?> _installerCall(MethodCall call) async {
    calls.add(call.method);
    if (call.method == 'installApk') {
      sessions.add(((call.arguments as Map?)?['filePath'] ?? '') as String);
      return intentOpens;
    }
    return null;
  }

  void dispose() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      AndroidInstallerGateway.permissions,
      null,
    );
    messenger.setMockMethodCallHandler(_installerChannel, null);
  }
}

/// A staged APK whose bytes were already checked, written for real: paying an
/// install that was owed is a claim about the file on the device, so the suite
/// puts one there rather than trusting a path nobody can open.
DownloadedRelease _stageApk(Directory stage, {int bytes = 4096}) {
  final file = File(
    '${stage.path}${Platform.pathSeparator}Hongguo-9.9.9-android-arm64-v8a.apk',
  );
  file.writeAsBytesSync(List.filled(bytes, 7));
  return DownloadedRelease(path: file.path, bytes: bytes, sha256: 'ab' * 32);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePlugins plugins;
  late Directory stage;
  late AndroidInstaller installer;
  late DownloadedRelease apk;
  late File note;
  setUp(() async {
    plugins = _FakePlugins();
    stage = await Directory.systemTemp.createTemp('hongguo-update-stage');
    apk = _stageApk(stage);
    note = File(
      '${stage.path}${Platform.pathSeparator}hongguo-pending-install.json',
    );
    installer = AndroidInstaller(stageDirectory: () async => stage.path);
  });
  tearDown(() async {
    plugins.dispose();
    if (stage.existsSync()) await stage.delete(recursive: true);
  });

  /// A launch is a new object over the same folder, which is the whole point of
  /// writing an owed install down.
  AndroidInstaller relaunched() =>
      AndroidInstaller(stageDirectory: () async => stage.path);

  test('granted means the APK goes straight to the installer intent', () async {
    plugins.granted = true;
    final plan = await installer.install(apk);
    expect(plugins.calls, ['checkPermissionStatus', 'installApk']);
    expect(plugins.sessions, [apk.path]);
    expect(plan.message, '已交给系统安装器，请在弹窗中确认安装。');
    expect(plan.owesInstall, isFalse);
    expect(note.existsSync(), isFalse);
    expect(await installer.hasOwedInstall(), isFalse);
  });

  test(
    'without the permission no intent is opened, and the ask goes out',
    () async {
      plugins.granted = false;
      final plan = await installer.install(apk);
      // The bug this guards: an intent fired without the switch lands on an
      // installer that drops it without a word, so the handoff must not be
      // reported as done.
      expect(plugins.sessions, isEmpty);
      expect(plugins.calls, ['checkPermissionStatus', 'requestPermissions']);
      expect(plan.message, contains('安装未知应用'));
      expect(plan.message, contains('自动继续安装'));
      // And the prompt may not treat that as a finished handoff.
      expect(plan.owesInstall, isTrue);
      expect(await installer.hasOwedInstall(), isTrue);
      expect(note.existsSync(), isTrue);
    },
  );

  test('coming back still ungranted keeps the APK owed, and says so', () async {
    await installer.install(apk);
    plugins.calls.clear();
    // Silence was the defect: the viewer comes back from 系统设置 without having
    // turned the switch and had nothing on screen telling them the update is
    // still waiting -- the prompt had already closed on the way out.
    final word = await installer.resume();
    expect(word, contains('还欠着一次更新安装'));
    expect(word, contains('安装未知应用'));
    expect(plugins.calls, ['checkPermissionStatus']);
    expect(plugins.sessions, isEmpty);
    expect(note.existsSync(), isTrue);
    expect(await installer.hasOwedInstall(), isTrue);
  });

  test('coming back granted installs the owed APK', () async {
    await installer.install(apk);
    expect(await installer.hasOwedInstall(), isTrue);
    plugins.granted = true;
    plugins.calls.clear();
    expect(await installer.resume(), '已交给系统安装器，请在弹窗中确认安装。');
    expect(plugins.calls, ['checkPermissionStatus', 'installApk']);
    expect(plugins.sessions, [apk.path]);
    // Paying is what settles the debt, so nothing is still owed afterwards --
    // this is the answer `UpdateController._returnToForeground` reads.
    expect(await installer.hasOwedInstall(), isFalse);
    // And it is spent: a second return must not open a second intent.
    expect(await installer.resume(), isNull);
    expect(plugins.sessions, [apk.path]);
  });

  test(
    'a launch after the settings screen installs without a second press',
    () async {
      // The trip to 「安装未知应用」 leaves this app behind, and Android takes the
      // process while it is gone: the handover has to survive a cold start, not
      // only a resumed one.
      await installer.install(apk);
      plugins.granted = true;
      plugins.calls.clear();
      expect(await relaunched().resume(), '已交给系统安装器，请在弹窗中确认安装。');
      expect(plugins.sessions, [apk.path]);
      expect(note.existsSync(), isFalse);
    },
  );

  test('an APK the system cleaned up is not installed, and says so', () async {
    await installer.install(apk);
    File(apk.path).deleteSync();
    plugins.granted = true;
    plugins.calls.clear();
    final word = await relaunched().resume();
    expect(plugins.sessions, isEmpty);
    expect(word, contains('立即更新'));
    expect(note.existsSync(), isFalse);
  });

  test(
    'a handoff that opened the intent leaves nothing for the next launch',
    () async {
      // The note is a promise about one file, so a device that has already been
      // handed its APK must not be asked to install it again on a later return.
      note.writeAsStringSync(
        jsonEncode({'path': apk.path, 'bytes': apk.bytes}),
      );
      plugins.granted = true;
      final plan = await installer.install(apk);
      expect(plan.message, '已交给系统安装器，请在弹窗中确认安装。');
      expect(plugins.sessions, [apk.path]);
      expect(note.existsSync(), isFalse);
      expect(await relaunched().resume(), isNull);
    },
  );

  test('an intent the plugin could not open says so', () async {
    plugins.granted = true;
    plugins.intentOpens = false;
    final plan = await installer.install(apk);
    expect(plan.message, contains('没能交给系统安装器'));
    // The note is forgotten before the handoff, so a failed intent leaves no
    // debt: the honest next step is a fresh 立即更新, not a silent retry.
    expect(await installer.hasOwedInstall(), isFalse);
  });

  test('a debt outranks any other word a return could say', () async {
    await installer.install(apk);
    plugins.granted = true;
    plugins.calls.clear();
    expect(await relaunched().resume(), '已交给系统安装器，请在弹窗中确认安装。');
    expect(plugins.sessions, [apk.path]);
    expect(plugins.calls, ['checkPermissionStatus', 'installApk']);
  });

  test('a desktop with no handler degrades to no ABIs, not a crash', () async {
    // `hongguo/update` answers only the ABI question now; with no handler --
    // every desktop build -- the APK choice degrades to 「没有 Android ABI」.
    plugins.dispose();
    expect(await AndroidUpdate.supportedAbis(), isEmpty);
  });
}
