import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/library_page.dart';

// `sort-menu` and `sort-$档` answer on either family, so the L3 排序 this page
// reaches for is asked for through the same helper the desktop suite uses --
// the touch family opens it as a bottom sheet, the mouse family as a dropdown,
// but 「一档 chosen on the page」 is the one gesture both shapes offer.
import 'desktop_fakes.dart' show openSort, sortTo;
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
        await t.tap(find.byKey(ValueKey('filter-genre-discover-$genre')));
        await t.pump(const Duration(milliseconds: 300));
        await t.pumpAndSettle();
        expect(runtime.catalog.lastGenre, genre);
        expect(runtime.catalog.lastSort, 'hot_collect');
        // 排序 is global precisely because the page draws no inline 档 chip of
        // its own: the 档 it holds comes from 设置, and the row that lets the
        // viewer overrule it for this page alone is the tail `sort-menu`, not a
        // `filter-sort-*` chip bolted under the type.
        expect(
          find.byKey(const ValueKey('filter-sort-hot_collect')),
          findsNothing,
        );
      }
      // 一档 chosen on the page reaches the request. What the deleted 最新 chip
      // meant was `sort = online_time`, so that is what L3 asks for now -- open
      // the row's tail 排序 and pick the 最新上架 档.
      await sortTo(t, 'online_time');
      expect(runtime.catalog.lastSort, 'online_time');
      // And the switch did not cost the page it was made on: the type it landed
      // on is still the one lit in the first row, and the list under the row is
      // still the same page -- 「换档」 narrows this page's request rather than
      // turning it, which is the whole reason 排序 is L3 and not a 换页 chip.
      expect(
        t
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('filter-genre-discover-ai_series')),
            )
            .selected,
        isTrue,
      );
      // Back to the default 档 costs no request: the answer that came under
      // `hot_collect` is kept alive under its own feed key -- a key that now
      // carries 排序 but no longer a `view` -- so the row reads that record
      // straight back instead of asking upstream for the page it already holds.
      final calls = runtime.catalog.browseCalls;
      await openSort(t);
      await t.tap(find.byKey(const ValueKey('sort-hot_collect')));
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      expect(runtime.catalog.browseCalls, calls);
      // The readback is the row, not the request: nothing was asked for, so the
      // fake's last 档 is still the one the 最新上架 page left behind -- which is
      // precisely the evidence that this switch cost no round trip.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('sort-menu')),
          matching: find.text('排序 · 最高收藏'),
        ),
        findsOneWidget,
      );
      // 推荐 is not a sort upstream publishes, so the chip that used to stand
      // for "no 档 chosen" is gone from this row: the default is the 档 the page
      // reads off 设置, and the heading it writes says so, not 「推荐」.
      expect(find.byKey(const ValueKey('filter-view-recommend')), findsNothing);
      expect(find.textContaining('为你发现'), findsWidgets);
    },
  );
}
