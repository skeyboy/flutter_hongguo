import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/update/android_update_channel.dart';
import 'package:hongguo_app/update/install_strategy.dart';
import 'package:hongguo_update/hongguo_update.dart';

/// The `hongguo/update` half of an install: whether 「安装未知应用」 is on, and the
/// session the system installer is handed. Answers come from a mock, so the
/// suite never needs a phone to prove the order is right.
class _FakeAndroid {
  _FakeAndroid() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidUpdate.channel, _handle);
  }

  /// The switch the viewer controls. Tests flip it to play the return from
  /// settings.
  bool granted = false;

  /// Whether this device even has the 「安装未知应用」 row to open.
  bool hasSettingsScreen = true;

  final List<String> calls = [];
  final List<String> sessions = [];
  String sessionAnswer = '已交给系统安装器，请在弹窗中确认安装。';

  /// A device that commits and never reports back -- the shape a killed activity
  /// leaves behind -- must still answer in words rather than pin the button.
  bool silenceInstall = false;
  final _never = Completer<String>();

  /// The words an install this process never asked for left behind: the system
  /// installer woke the app in its own process, so nobody was listening. Reading
  /// it consumes it, the way the file beside the session does.
  String? installResult;

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'canInstall':
        return granted;
      case 'askPermission':
        return hasSettingsScreen;
      case 'installResult':
        final answer = installResult;
        installResult = null;
        return answer;
      case 'install':
        if (silenceInstall) return _never.future;
        sessions.add(((call.arguments as Map?)?['path'] ?? '') as String);
        return sessionAnswer;
      default:
        return null;
    }
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidUpdate.channel, null);
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

  late _FakeAndroid android;
  late Directory stage;
  late AndroidInstaller installer;
  late DownloadedRelease apk;
  late File note;
  setUp(() async {
    android = _FakeAndroid();
    stage = await Directory.systemTemp.createTemp('hongguo-update-stage');
    apk = _stageApk(stage);
    note = File(
      '${stage.path}${Platform.pathSeparator}hongguo-pending-install.json',
    );
    installer = AndroidInstaller(stageDirectory: () async => stage.path);
  });
  tearDown(() async {
    android.dispose();
    if (stage.existsSync()) await stage.delete(recursive: true);
  });

  /// A launch is a new object over the same folder, which is the whole point of
  /// writing an owed install down.
  AndroidInstaller relaunched() =>
      AndroidInstaller(stageDirectory: () async => stage.path);

  test('granted means the APK goes straight to a session', () async {
    android.granted = true;
    final plan = await installer.install(apk);
    expect(android.calls, ['canInstall', 'install']);
    expect(android.sessions, [apk.path]);
    expect(plan.message, android.sessionAnswer);
    expect(plan.owesInstall, isFalse);
    expect(note.existsSync(), isFalse);
    expect(await installer.hasOwedInstall(), isFalse);
  });

  test('without the permission no session is opened, and settings is shown', () async {
    android.granted = false;
    final plan = await installer.install(apk);
    // The bug this guards: a session committed without the switch never reaches
    // the installer, so the old code reported a handoff that opened nothing.
    expect(android.sessions, isEmpty);
    expect(android.calls, ['canInstall', 'askPermission']);
    expect(plan.message, contains('安装未知应用'));
    expect(plan.message, contains('自动继续安装'));
    // And the prompt may not treat that as a finished handoff.
    expect(plan.owesInstall, isTrue);
    expect(await installer.hasOwedInstall(), isTrue);
    expect(note.existsSync(), isTrue);
  });

  test('a device with no settings row says which switch to turn on', () async {
    android.granted = false;
    android.hasSettingsScreen = false;
    final plan = await installer.install(apk);
    expect(plan.message, contains('系统设置'));
    expect(plan.message, contains('自动继续安装'));
    expect(plan.owesInstall, isTrue);
  });

  test('coming back still ungranted keeps the APK owed, and says so', () async {
    await installer.install(apk);
    android.calls.clear();
    // Silence was the defect: the viewer comes back from 系统设置 without having
    // turned the switch and had nothing on screen telling them the update is
    // still waiting -- the prompt had already closed on the way out.
    final word = await installer.resume();
    expect(word, contains('还欠着一次更新安装'));
    expect(word, contains('安装未知应用'));
    expect(android.calls, ['canInstall']);
    expect(android.sessions, isEmpty);
    expect(note.existsSync(), isTrue);
    expect(await installer.hasOwedInstall(), isTrue);
  });

  test('coming back granted installs the owed APK', () async {
    await installer.install(apk);
    expect(await installer.hasOwedInstall(), isTrue);
    android.granted = true;
    android.calls.clear();
    expect(await installer.resume(), android.sessionAnswer);
    expect(android.calls, ['canInstall', 'install']);
    expect(android.sessions, [apk.path]);
    // Paying is what settles the debt, so nothing is still owed afterwards --
    // this is the answer `UpdateController.installOwed` reads on the next return.
    expect(await installer.hasOwedInstall(), isFalse);
    // And it is spent: a second return must not open a second session.
    expect(await installer.resume(), isNull);
    expect(android.sessions, [apk.path]);
  });

  test(
    'a launch after the settings screen installs without a second press',
    () async {
      // The trip to 「安装未知应用」 leaves this app behind, and Android takes the process
      // while it is gone: the handover has to survive a cold start, not only a
      // resumed one.
      await installer.install(apk);
      android.granted = true;
      android.calls.clear();
      expect(await relaunched().resume(), android.sessionAnswer);
      expect(android.sessions, [apk.path]);
      expect(note.existsSync(), isFalse);
    },
  );

  test('an APK the system cleaned up is not installed, and says so', () async {
    await installer.install(apk);
    File(apk.path).deleteSync();
    android.granted = true;
    android.calls.clear();
    final word = await relaunched().resume();
    expect(android.sessions, isEmpty);
    expect(word, contains('立即更新'));
    expect(note.existsSync(), isFalse);
  });

  test(
    'a handoff that opened a session leaves nothing for the next launch',
    () async {
      // The note is a promise about one file, so a device that has already been
      // handed its APK must not be asked to install it again on a later return.
      note.writeAsStringSync(
        jsonEncode({'path': apk.path, 'bytes': apk.bytes}),
      );
      android.granted = true;
      final plan = await installer.install(apk);
      expect(plan.message, android.sessionAnswer);
      expect(android.sessions, [apk.path]);
      expect(note.existsSync(), isFalse);
      expect(await relaunched().resume(), isNull);
    },
  );

  test(
    'a return with nothing owed reads what the installer itself left behind',
    () async {
      // The defect this closes: the system installer woke the app in a process that
      // had asked for no session, so its answer had nowhere to go and the next
      // foreground said 「没有回话」 over an install that had actually finished.
      android.installResult = '安装完成，重启应用后生效。';
      expect(await installer.resume(), '安装完成，重启应用后生效。');
      expect(android.calls, ['installResult']);
      // And once: the same success is not announced again on the next return.
      expect(await installer.resume(), isNull);
      expect(android.calls, ['installResult', 'installResult']);
    },
  );

  test('a debt is paid before any leftover word is read', () async {
    await installer.install(apk);
    android.granted = true;
    android.installResult = '上一次安装已完成。';
    android.calls.clear();
    expect(await relaunched().resume(), android.sessionAnswer);
    expect(android.sessions, [apk.path]);
    // The APK this app owes outranks a note from an install it never started.
    expect(android.calls, ['canInstall', 'install']);
  });

  test('a desktop with no handler is not blocked by the gate', () async {
    // `hongguo/update` exists only on Android; every other build answers the gate
    // as allowed so its own handoff stays in charge instead of failing.
    android.dispose();
    expect(await AndroidUpdate.canInstallPackages(), isTrue);
    expect(await AndroidUpdate.openInstallPermissionSettings(), isFalse);
    expect(await AndroidUpdate.installApk('/nope.apk'), contains('安装通道不可用'));
  });

  testWidgets('a session the system never reports on still says what to do', (
    tester,
  ) async {
    final blocked = _FakeAndroid()..silenceInstall = true;
    addTearDown(blocked.dispose);
    final answer = AndroidUpdate.installApk('/parked.apk');
    await tester.pump(const Duration(seconds: 61));
    expect(await answer, allOf(contains('系统安装器没有回话'), contains('安装未知应用')));
  });
}
