import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hongguo_app/features/tv/tv_library_page.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import '../test/fakes.dart';
import '../test/tv_feed_test.dart' show FeedCatalog;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('hardware sidebar auto-routes and remembers comic pane focus', (
    t,
  ) async {
    final catalog = FeedCatalog();
    final runtime = FakeRuntime(catalog);
    addTearDown(runtime.dispose);
    await t.pumpWidget(
      MaterialApp(
        builder: (_, child) =>
            TvEnvironment(enabled: true, child: TvNavigation(child: child!)),
        home: TvLibraryPage(runtime: runtime),
      ),
    );
    await t.pumpAndSettle();
    for (var i = 0; i < 50 && FocusManager.instance.primaryFocus == null; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    Future<void> key(int code) async {
      print('TV_SYSTEM_KEY=$code');
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await t.pumpAndSettle();
    }

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'nav-0');
    await key(20);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'nav-1');
    expect(catalog.calls.last.genre, 'comic_series');
    await key(22);
    await key(20);
    final card = FocusManager.instance.primaryFocus?.debugLabel;
    expect(card, 'tv-grid-comic_series-all-0');
    final columns =
        (t.widget<GridView>(find.byType(GridView)).gridDelegate
                as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount;
    for (var i = 1; i <= columns + 1; i++) {
      await key(22);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv-grid-comic_series-all-$i',
      );
      expect(catalog.calls.last.theme, isNull);
    }
    for (var i = columns; i >= 0; i--) {
      await key(21);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv-grid-comic_series-all-$i',
      );
    }
    final grid = t.state(find.byType(TvGrid));
    final requests = catalog.calls.length;
    for (var i = 0; i < 3; i++) {
      await key(21);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'nav-1');
      await key(22);
      expect(FocusManager.instance.primaryFocus?.debugLabel, card);
      expect(t.state(find.byType(TvGrid)), same(grid));
      expect(catalog.calls.length, requests);
    }
    print('TV_SCREENSHOT=sidebar-comic-focus');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await key(21);
    await key(20);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'nav-2');
    expect(catalog.calls.last.genre, 'ai_series');
    await key(19);
    await key(22);
    expect(FocusManager.instance.primaryFocus?.debugLabel, card);
    expect(t.state(find.byType(TvGrid)), same(grid));
    await key(21);
    await key(20);
    await key(20);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'nav-3');
    await key(20);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'nav-4');
    print('TV_SCREENSHOT=sidebar-my-route');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    print(
      'TV_SIDEBAR_NATIVE_PASS five_routes=true focus_selects=true comic_focus_restored=true lateral_switch_does_not_reload=true index_wrap_both_directions=true theme_unchanged=true',
    );
    await t.pumpWidget(const SizedBox());
  });
}
