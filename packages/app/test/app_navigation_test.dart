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
}
