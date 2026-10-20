import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/settings_page.dart';

import 'fakes.dart';

void main() {
  testWidgets(
    'mobile confirms each switch immediately and commits only that switch',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.binding.setSurfaceSize(const Size(390, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final runtime = FakeRuntime();
      await tester.pumpWidget(
        MaterialApp(home: SettingsPage(runtime: runtime, embedded: true)),
      );
      await tester.pumpAndSettle();
      final playback = find.widgetWithText(SwitchListTile, '后台播放');
      await tester.tap(playback);
      await tester.pumpAndSettle();
      expect(find.text('开启后台播放？'), findsOneWidget);
      expect(runtime.saves, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(runtime.settings.backgroundPlayback, isFalse);
      expect(tester.widget<SwitchListTile>(playback).value, isFalse);
      // A separate unsaved preference must not be persisted by this action.
      final prefetch = find.widgetWithText(SwitchListTile, '提前缓存后续剧集');
      await tester.ensureVisible(prefetch);
      await tester.pumpAndSettle();
      await tester.tap(prefetch);
      await tester.pumpAndSettle();
      await tester.ensureVisible(playback);
      await tester.pumpAndSettle();
      await tester.tap(playback);
      await tester.pumpAndSettle();
      await tester.tap(find.text('开启并生效'));
      await tester.pumpAndSettle();
      expect(runtime.settings.backgroundPlayback, isTrue);
      expect(runtime.settings.backgroundPlaybackPrompted, isTrue);
      expect(runtime.settings.prefetchEnabled, isTrue);
      expect(runtime.saves, 1);
      await tester.tap(playback);
      await tester.pumpAndSettle();
      expect(find.text('关闭后台播放？'), findsOneWidget);
      await tester.tap(find.text('关闭并生效'));
      await tester.pumpAndSettle();
      expect(runtime.settings.backgroundPlayback, isFalse);
      expect(runtime.saves, 2);
      final downloads = find.widgetWithText(SwitchListTile, '后台下载');
      await tester.tap(downloads);
      await tester.pumpAndSettle();
      expect(find.text('开启后台下载？'), findsOneWidget);
      await tester.tap(find.text('开启并生效'));
      await tester.pumpAndSettle();
      expect(runtime.settings.backgroundDownloads, isTrue);
      expect(runtime.settings.prefetchEnabled, isTrue);
      await tester.tap(downloads);
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(runtime.settings.backgroundDownloads, isTrue);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('desktop keeps explicit save without mobile reminders', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final runtime = FakeRuntime();
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(runtime: runtime, embedded: true)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, '悬浮播放'));
    expect(runtime.settings.floatingPlayback, isFalse);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(runtime.settings.floatingPlayback, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
