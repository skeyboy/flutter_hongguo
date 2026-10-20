import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/my_page.dart';
import 'package:hongguo_app/features/settings_page.dart';
import 'package:hongguo_app/personal/favorite_button.dart';
import 'package:hongguo_app/personal/personal_library.dart';
import 'package:hongguo_app/platform/runtime.dart';

import 'fakes.dart';

void main() {
  for (final size in [
    const Size(390, 844),
    const Size(1280, 900),
    const Size(740, 400),
  ]) {
    testWidgets('My library and settings route adapt at $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final runtime = FakeRuntime();
      final library = personalLibraryFor(runtime);
      await library.toggleFavorite(FakeCatalog.demo);
      await library.record(
        WatchRecord(
          drama: FakeCatalog.demo,
          vid: '11',
          episode: 1,
          positionMs: 42000,
          durationMs: 120000,
          updated: DateTime.now(),
        ),
      );
      await tester.pumpWidget(MaterialApp(home: MyPage(runtime: runtime)));
      await tester.pumpAndSettle();
      expect(find.textContaining('观看至 0:42'), findsOneWidget);
      await tester.tap(find.text('收藏').first);
      await tester.pumpAndSettle();
      expect(find.text('山海之间'), findsWidgets);
      await tester.tap(find.byTooltip('取消收藏'));
      await tester.pumpAndSettle();
      expect(library.favorites, isEmpty);
      await tester.tap(find.byKey(const ValueKey('my-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(MyPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'favorite action updates My library without creating watch history',
    (tester) async {
      final runtime = FakeRuntime();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FavoriteButton(runtime: runtime, drama: FakeCatalog.demo),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('收藏剧集'));
      await tester.pumpAndSettle();
      expect(personalLibraryFor(runtime).favorites.single.id, '123');
      expect(personalLibraryFor(runtime).history, isEmpty);
      await tester.tap(find.byTooltip('取消收藏'));
      await tester.pumpAndSettle();
      expect(personalLibraryFor(runtime).favorites, isEmpty);
    },
  );
}
