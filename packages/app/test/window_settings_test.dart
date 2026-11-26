import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/settings_page.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('桌面端窗口行为分区可见且关闭行为即时保存', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(1280, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final runtime = FakeRuntime();
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(runtime: runtime, embedded: true)),
    );
    await tester.pumpAndSettle();

    // 「窗口行为」同时出现在导航锚点与分区标题中。
    expect(find.text('窗口行为'), findsNWidgets(2));
    expect(find.text('关闭按钮行为'), findsOneWidget);
    expect(find.text('记住窗口位置和大小'), findsOneWidget);
    expect(runtime.settings.windowCloseBehavior, WindowCloseBehavior.ask);

    // 切换为退出程序：即时保存（不进统一保存事务）。
    final dropdown = find.byKey(const ValueKey('window-close-behavior'));
    await tester.ensureVisible(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出程序').last);
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
    expect(runtime.settings.windowCloseBehavior, WindowCloseBehavior.exit);
    expect(runtime.settings.rememberWindowState, isTrue);
  });

  testWidgets('记住窗口位置开关即时保存', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(1280, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final runtime = FakeRuntime();
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(runtime: runtime, embedded: true)),
    );
    await tester.pumpAndSettle();

    final rememberSwitch = find.widgetWithText(SwitchListTile, '记住窗口位置和大小');
    await tester.ensureVisible(rememberSwitch);
    await tester.pumpAndSettle();
    await tester.tap(rememberSwitch);
    await tester.pumpAndSettle();
    expect(runtime.settings.rememberWindowState, isFalse);
    expect(runtime.settings.windowCloseBehavior, WindowCloseBehavior.ask);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
