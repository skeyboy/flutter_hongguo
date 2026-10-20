import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/settings_page.dart';

import 'fakes.dart';

void main() {
  testWidgets('mobile capability toggles require reminder and explicit save', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(390, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final runtime = FakeRuntime();
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(runtime: runtime, embedded: true)),
    );
    await tester.pumpAndSettle();
    for (final title in ['后台播放', '后台下载', '悬浮播放']) {
      final control = find.widgetWithText(SwitchListTile, title);
      await tester.ensureVisible(control);
      await tester.pumpAndSettle();
      await tester.tap(control);
      await tester.pumpAndSettle();
    }
    expect(runtime.settings.backgroundPlayback, isFalse);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('开启后台能力'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(runtime.saves, 0);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开启并保存'));
    await tester.pumpAndSettle();
    expect(runtime.settings.backgroundPlayback, isTrue);
    expect(runtime.settings.backgroundDownloads, isTrue);
    expect(runtime.settings.floatingPlayback, isTrue);
    expect(runtime.settings.backgroundWifiOnly, isTrue);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets(
    'desktop explains native floating window and does not show mobile reminder',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final runtime = FakeRuntime();
      await tester.pumpWidget(
        MaterialApp(home: SettingsPage(runtime: runtime, embedded: true)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('置顶小窗'), findsOneWidget);
      await tester.tap(find.widgetWithText(SwitchListTile, '悬浮播放'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('开启后台能力'), findsNothing);
      expect(runtime.settings.floatingPlayback, isTrue);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
