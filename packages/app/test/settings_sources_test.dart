import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/settings_page.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'fakes.dart';

/// 设置页「片源」分区：内置源开关与自定义源 CRUD 都由设置/注册表派生，
/// 这里用假运行时锁住派生行为与保存路径。
void main() {
  FakeRuntime pumpRuntime({SourceSettings sources = const SourceSettings()}) =>
      FakeRuntime()
        ..settings = AppSettings(themeMode: 'light', sources: sources);

  Future<void> pumpPage(WidgetTester tester, FakeRuntime runtime) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: const ColorScheme.light()),
        home: SettingsPage(runtime: runtime),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('片源分区渲染内置源开关与红果固定说明', (tester) async {
    await pumpPage(tester, pumpRuntime());
    // 分区标题 + 页面锚点各出现一次。
    expect(find.text('片源'), findsNWidgets(2));
    expect(find.text('已启用 3 个来源；红果为内置来源，始终启用。'), findsOneWidget);
    expect(find.text('国内源 · 搜索结果中混入该源内容。'), findsNWidgets(2));
    // 默认开的国内源显示开关；海外源同样出现（默认关）。
    expect(find.text('西饭'), findsOneWidget);
    expect(find.text('河马'), findsOneWidget);
    expect(find.text('DramaBox（海外）'), findsOneWidget);
    expect(find.text('ReelShort（海外）'), findsOneWidget);
    expect(find.text('添加自定义片源'), findsOneWidget);
  });

  testWidgets('关闭西饭开关，draft 落到 sources.builtin 并随保存持久化', (tester) async {
    final runtime = pumpRuntime();
    await pumpPage(tester, runtime);
    final tile = find.widgetWithText(SwitchListTile, '西饭').first;
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pump();
    expect(runtime.settings.sources.isEnabled('xifan'), isTrue);

    // 页面右上角的 保存 按钮提交整个 draft（非 TV 布局为 TextButton）。
    await tester.tap(find.widgetWithText(TextButton, '保存').last);
    await tester.pumpAndSettle();
    expect(runtime.saves, greaterThan(0));
    expect(runtime.settings.sources.isEnabled('xifan'), isFalse);
    expect(runtime.settings.sources.isEnabled('hema'), isTrue);
    expect(runtime.settings.sources.isEnabled('hongguo'), isTrue);
  });

  testWidgets('自定义片源删除按钮移除该条目', (tester) async {
    const uuid = '123e4567-e89b-42d3-a456-426614174000';
    final runtime = pumpRuntime(
      sources: const SourceSettings().upsertCustom(
        CustomSourceConfig(
          uuid: uuid,
          name: '测试源',
          url: 'https://api.example.com/api.php/provide/vod/',
          enabled: true,
        ),
      ),
    );
    await pumpPage(tester, runtime);

    expect(find.text('测试源'), findsOneWidget);
    final delete = find.byTooltip('删除该片源');
    await tester.ensureVisible(delete);
    await tester.pumpAndSettle();
    await tester.tap(delete);
    await tester.pump();
    expect(find.text('测试源'), findsNothing);
  });
}
