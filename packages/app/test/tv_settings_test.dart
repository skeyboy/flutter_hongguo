import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/settings_page.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import 'fakes.dart';

void main() {
  testWidgets(
    'TV policy settings remain valid for the shared persisted schema',
    (t) async {
      final runtime = FakeRuntime();
      addTearDown(runtime.dispose);
      await t.pumpWidget(MaterialApp(home: SettingsPage(runtime: runtime)));
      await t.pumpAndSettle();
      expect(find.textContaining('TV 模式：'), findsOneWidget);
      expect(find.text('后台与悬浮播放'), findsNothing);
      final sort = find.byKey(const ValueKey('catalog-sort-setting'));
      await t.ensureVisible(sort);
      await t.pumpAndSettle();
      await t.tap(sort);
      await t.pumpAndSettle();
      await t.tap(find.text('收藏最多').last);
      await t.pumpAndSettle();
      final size = find.byKey(const ValueKey('tv-page-size-setting'));
      await t.ensureVisible(size);
      await t.pumpAndSettle();
      await t.tap(size);
      await t.pumpAndSettle();
      await t.tap(find.text('50 条').last);
      await t.pumpAndSettle();
      await t.tap(find.text('保存').first);
      await t.pumpAndSettle();
      expect(runtime.saves, 1);
      expect(runtime.settings.catalogSort, 'hot_collect');
      expect(runtime.settings.tvPageSize, 50);
      expect(runtime.settings.prefetchEpisodes, greaterThanOrEqualTo(3));
      // Runtime/prefetch adapters clamp the effective TV budget, without corrupting settings.
      expect(runtime.settings.backgroundPlayback, isFalse);
      expect(runtime.settings.concurrentPreparations, 1);
    },
    skip: !tvBuild,
  );
}
