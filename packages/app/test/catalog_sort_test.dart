import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/library_page.dart';

import 'fakes.dart';

void main() {
  testWidgets(
    'PC uses saved global sort for all genres without page sort controls',
    (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final runtime = FakeRuntime();
      addTearDown(runtime.dispose);
      await t.pumpWidget(MaterialApp(home: LibraryPage(runtime: runtime)));
      await t.pumpAndSettle();
      expect(runtime.catalog.lastSort, 'hot_score');
      await runtime.saveSettings(
        runtime.settings.copyWith(catalogSort: 'hot_collect'),
      );
      await t.pumpAndSettle();
      expect(runtime.catalog.lastSort, 'hot_collect');
      expect(find.byKey(const ValueKey('sticky-sort')), findsNothing);
      for (final genre in ['comic_series', 'ai_series']) {
        await t.tap(find.byKey(const ValueKey('sticky-genre')));
        await t.pumpAndSettle();
        await t.tap(find.byKey(ValueKey('filter-genre-$genre')));
        await t.pump(const Duration(milliseconds: 300));
        await t.pumpAndSettle();
        expect(runtime.catalog.lastGenre, genre);
        expect(runtime.catalog.lastSort, 'hot_collect');
        expect(
          find.byKey(const ValueKey('filter-sort-hot_collect')),
          findsNothing,
        );
        await t.tap(find.text('收起筛选'));
        await t.pumpAndSettle();
      }
    },
  );
}
