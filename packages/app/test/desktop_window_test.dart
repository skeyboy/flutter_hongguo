import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/platform/background/host_policy.dart';
import 'package:hongguo_app/platform/desktop_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final host in [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  ]) {
    test('$host 桌面窗口控制可用且缺 plugin 时不抛', () async {
      debugDefaultTargetPlatformOverride = host;
      expect(desktopHost, isTrue);
      expect(DesktopWindow.supported, isTrue);
      await DesktopWindow.minimize();
      await DesktopWindow.toggleMaximize();
      await DesktopWindow.hide();
      await DesktopWindow.show();
    });
  }

  test('移动端视为 no-op', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(desktopHost, isFalse);
    expect(DesktopWindow.supported, isFalse);
    await DesktopWindow.minimize();
    await DesktopWindow.toggleMaximize();
  });
}
