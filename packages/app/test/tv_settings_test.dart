import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/settings_page.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import 'fakes.dart';

/// The `--dart-define=HONGGUO_TV=true` preview of the tv flavor: here the
/// compile-time flag, not an `TvEnvironment` ancestor, is what hides the phone
/// features and turns every control into a spinner row. `tv_settings_surfaces_test.dart`
/// covers the same page driven by real key events; this file keeps the promise
/// the flavor makes about the persisted schema.
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
      // A TV row is one target that reports its own state in its label, so the
      // test cycles it the way the confirm key does instead of opening a menu.
      expect(
        _tvRowLabel(t, const ValueKey('catalog-sort-setting')),
        startsWith('全局排序'),
      );
      await _cycleUntil(t, const ValueKey('catalog-sort-setting'), '全局排序 收藏最多');
      await _cycleUntil(t, const ValueKey('tv-page-size-setting'), '50 条');
      await t.tap(find.byKey(const Key('设置保存')));
      await t.pumpAndSettle();
      expect(runtime.saves, 1);
      expect(runtime.settings.catalogSort, 'hot_collect');
      expect(runtime.settings.tvPageSize, 50);
      expect(runtime.settings.prefetchEpisodes, greaterThanOrEqualTo(3));
      // Runtime/prefetch adapters clamp the effective TV budget, without corrupting settings.
      expect(runtime.settings.backgroundPlayback, isFalse);
      expect(runtime.settings.concurrentPreparations, 1);
      expect(runtime.settings.downloadConcurrent, 1);
    },
    skip: !tvBuild,
  );
}

String? _tvRowLabel(WidgetTester t, Key key) =>
    t.widget<TvFocusable>(find.byKey(key)).label;

Future<void> _cycleUntil(WidgetTester t, Key key, String wanted) async {
  await t.ensureVisible(find.byKey(key));
  await t.pumpAndSettle();
  for (var attempt = 0; attempt < 6; attempt++) {
    if (_tvRowLabel(t, key)!.contains(wanted)) return;
    await t.tap(find.byKey(key));
    await t.pumpAndSettle();
  }
  throw StateError(
    'row $key never cycled to $wanted; last label was ${_tvRowLabel(t, key)}',
  );
}
