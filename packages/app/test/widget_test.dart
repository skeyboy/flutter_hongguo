import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/main.dart';

import 'fakes.dart';

void main() {
  Future<void> mount(
    WidgetTester tester,
    FakeRuntime runtime, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.resetPhysicalSize();
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [runtimeProvider.overrideWith((ref) async => runtime)],
        child: const HongguoApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('mobile catalog → series → episodes without layout exceptions', (
    tester,
  ) async {
    await mount(tester, FakeRuntime());
    expect(find.text('山海之间'), findsWidgets);
    await tester.ensureVisible(find.text('山海之间').last);
    await tester.tap(find.text('山海之间').last);
    await tester.pumpAndSettle();
    expect(find.text('选择剧集'), findsOneWidget);
    expect(find.text('开始观看'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('category and search use the shared repository', (tester) async {
    final runtime = FakeRuntime();
    await mount(tester, runtime);
    await tester.tap(find.byKey(const ValueKey('sticky-genre')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter-genre-ai_series')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('收起筛选'));
    await tester.pumpAndSettle();
    expect(runtime.catalog.lastGenre, 'ai_series');
    await tester.enterText(find.byType(TextField), '玄幻故事');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(runtime.catalog.lastQuery, '玄幻故事');
    expect(find.text('搜索命中'), findsWidgets);
  });
  testWidgets('error retry can recover and diagnostics remain available', (
    tester,
  ) async {
    final catalog = FakeCatalog()..fail = true;
    await mount(tester, FakeRuntime(catalog));
    expect(find.text('上游暂时不可用'), findsOneWidget);
    catalog.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('山海之间'), findsWidgets);
    await tester.tap(find.byTooltip('离线检查'));
    await tester.pumpAndSettle();
    expect(find.text('Six-header Node parity'), findsOneWidget);
  });
  testWidgets('desktop catalog and pagination stay responsive', (tester) async {
    await mount(tester, FakeRuntime(), size: const Size(1200, 850));
    await tester.pumpAndSettle();
    expect(find.text('第二个故事'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
