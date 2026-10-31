import 'dart:async';

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

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'canInstall':
        return granted;
      case 'askPermission':
        return hasSettingsScreen;
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

final _apk = DownloadedRelease(
  path: '/data/user/0/com.example.hongguo_app/files/updates/Hongguo-9.9.9-android-arm64-v8a.apk',
  bytes: 36447668,
  sha256: 'ab' * 32,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAndroid android;
  late AndroidInstaller installer;
  setUp(() {
    android = _FakeAndroid();
    installer = AndroidInstaller();
  });
  tearDown(() => android.dispose());

  test('granted means the APK goes straight to a session', () async {
    android.granted = true;
    final plan = await installer.install(_apk);
    expect(android.calls, ['canInstall', 'install']);
    expect(android.sessions, [_apk.path]);
    expect(plan.message, android.sessionAnswer);
  });

  test('without the permission no session is opened, and settings is shown', () async {
    android.granted = false;
    final plan = await installer.install(_apk);
    // The bug this guards: a session committed without the switch never reaches
    // the installer, so the old code reported a handoff that opened nothing.
    expect(android.sessions, isEmpty);
    expect(android.calls, ['canInstall', 'askPermission']);
    expect(plan.message, contains('安装未知应用'));
    expect(plan.message, contains('回到应用后会继续安装'));
  });

  test('a device with no settings row says which switch to turn on', () async {
    android.granted = false;
    android.hasSettingsScreen = false;
    final plan = await installer.install(_apk);
    expect(plan.message, contains('系统设置'));
    expect(plan.message, contains('立即更新'));
  });

  test(
    'coming back still ungranted keeps the APK parked, not installed',
    () async {
      await installer.install(_apk);
      android.calls.clear();
      expect(await installer.resume(), isNull);
      expect(android.calls, ['canInstall']);
      expect(android.sessions, isEmpty);
    },
  );

  test('coming back granted installs the parked APK', () async {
    await installer.install(_apk);
    android.granted = true;
    android.calls.clear();
    expect(await installer.resume(), android.sessionAnswer);
    expect(android.calls, ['canInstall', 'install']);
    expect(android.sessions, [_apk.path]);
    // And it is spent: a second return must not open a second session.
    expect(await installer.resume(), isNull);
    expect(android.sessions, [_apk.path]);
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
