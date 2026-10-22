import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/settings_page.dart';

import 'fakes.dart';

/// The download budget is the only throttle the service sees, so the choice
/// list is a product contract: one at a time by default, up to five.
void main() {
  testWidgets('同时下载数量 offers 1 to 5 and persists the pick', (t) async {
    final runtime = FakeRuntime();
    addTearDown(runtime.dispose);
    await t.pumpWidget(MaterialApp(home: SettingsPage(runtime: runtime)));
    await t.pumpAndSettle();
    expect(runtime.settings.downloadConcurrent, 1);
    final picker = find.byKey(const ValueKey('download-concurrent-setting'));
    await t.ensureVisible(picker);
    await t.pumpAndSettle();
    await t.tap(picker);
    await t.pumpAndSettle();
    expect(find.text('4 个'), findsOneWidget);
    expect(find.text('5 个'), findsOneWidget);
    await t.tap(find.text('5 个').last);
    await t.pumpAndSettle();
    await t.tap(find.text('保存').first);
    await t.pumpAndSettle();
    expect(runtime.settings.downloadConcurrent, 5);
    expect(() => runtime.settings.validate(), returnsNormally);
  });
}
