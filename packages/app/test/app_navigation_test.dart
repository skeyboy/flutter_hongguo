import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_app/features/library_page.dart';
import 'package:hongguo_app/features/detail_page.dart';
import 'package:hongguo_app/features/settings_page.dart';
import 'package:hongguo_app/navigation/app_navigation.dart';

import 'fakes.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(1280, 900)]) {
    testWidgets('auto_route owns detail/settings and restores root at $size', (
      tester,
    ) async {
      final runtime = FakeRuntime();
      addTearDown(runtime.dispose);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [runtimeProvider.overrideWith((_) async => runtime)],
          child: const HongguoApp(),
        ),
      );
      await tester.pumpAndSettle();
      final root = tester.state(find.byType(LibraryPage));
      final router = AppNavigation.maybeOf(
        tester.element(find.byType(LibraryPage)),
      )!.router;
      expect(router.current.name, 'Catalog');
      await tester.tap(find.text('山海之间').last);
      await tester.pumpAndSettle();
      expect(router.current.name, AppScreen.detail.routeName);
      expect(find.byType(DetailPage), findsOneWidget);
      if (size.width >= 720) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      } else {
        await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
      expect(router.current.name, 'Catalog');
      expect(tester.state(find.byType(LibraryPage)), same(root));
      await tester.tap(
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '我的'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('my-settings')));
      await tester.pumpAndSettle();
      expect(router.current.name, AppScreen.settings.routeName);
      expect(find.byType(SettingsPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(router.current.name, 'Catalog');
      expect(find.byKey(const ValueKey('my-settings')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('push and pop slide horizontally instead of fading', (
    tester,
  ) async {
    final runtime = FakeRuntime();
    addTearDown(runtime.dispose);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [runtimeProvider.overrideWith((_) async => runtime)],
        child: const HongguoApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('山海之间').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    // Measured where the pages actually paint: the new one is still off to the
    // right, the old one has slid left, and neither moved vertically.
    final entering = tester.getRect(find.byType(DetailPage));
    final covered = tester.getRect(find.byType(LibraryPage));
    expect(entering.left, inInclusiveRange(20, 370));
    expect(entering.top, 0);
    expect(covered.left, inInclusiveRange(-370, -20));
    expect(covered.top, 0);

    await tester.binding.handlePopRoute();
    final leaving = <Rect>[];
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      leaving.add(tester.getRect(find.byType(DetailPage)));
    }
    // Reversing the same tween walks the page back out to the right.
    expect(leaving.first.left, inInclusiveRange(20, 370));
    expect(leaving[1].left, greaterThan(leaving[0].left));
    expect(leaving[2].left, greaterThan(leaving[1].left));
    expect(leaving.every((r) => r.top == 0), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(DetailPage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
