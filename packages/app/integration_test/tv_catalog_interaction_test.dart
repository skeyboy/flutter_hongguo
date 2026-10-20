import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_tv/hongguo_tv.dart';
import 'package:hongguo_app/features/tv/tv_library_page.dart';

import '../test/fakes.dart';

class TvFeedFixture extends FakeCatalog {
  final calls = <({String? theme, String? cursor})>[];
  @override
  Future<List<CatalogFilter>> themes(String genre) async => [
    for (var i = 0; i < 24; i++) CatalogFilter('电视题材 $i', 't$i'),
  ];
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) async {
    calls.add((theme: theme, cursor: cursor));
    final offset = cursor == null ? 0 : 30;
    return CatalogPage([
      for (var i = offset; i < offset + 30; i++)
        Drama(id: '${theme ?? 'all'}-$i', title: '$genre ${theme ?? '全部'} $i'),
    ], nextCursor: cursor == null ? '30' : null);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'hardware D-pad selects horizontal TV themes, keeps them visible and auto-pages',
    (t) async {
      final fixture = TvFeedFixture();
      final appRuntime = FakeRuntime(fixture);
      addTearDown(appRuntime.dispose);
      await t.pumpWidget(
        MaterialApp(
          builder: (_, child) =>
              TvEnvironment(enabled: true, child: TvNavigation(child: child!)),
          home: TvLibraryPage(runtime: appRuntime),
        ),
      );
      await t.pumpAndSettle();
      for (
        var i = 0;
        i < 50 && FocusManager.instance.primaryFocus == null;
        i++
      ) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'nav-0');
      final initialGrid = t.getRect(find.byType(GridView));
      final media = MediaQuery.of(t.element(find.byType(GridView)));
      expect(
        initialGrid.bottom,
        closeTo(media.size.height - media.padding.bottom - 12, 1),
      );
      expect(find.byKey(const ValueKey('tv-feed-status')), findsNothing);
      expect(find.text('正在更新'), findsNothing);
      Future<void> key(int code) async {
        print('TV_SYSTEM_KEY=$code');
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        await t.pumpAndSettle();
      }

      await key(22);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-theme-');
      for (var i = 0; i < 12; i++) {
        await key(22);
        expect(fixture.calls.last.theme, 't$i');
        final view = t.getRect(find.byKey(const ValueKey('tv-theme-scroll'))),
            choice = t.getRect(find.byKey(ValueKey('tv-theme-t$i')));
        expect(choice.left, greaterThanOrEqualTo(view.left - 1));
        expect(choice.right, lessThanOrEqualTo(view.right + 1));
      }
      print('TV_SCREENSHOT=topic-rail');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await key(20);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        startsWith('tv-grid-t11-'),
      );
      for (var i = 0; i < 8; i++) {
        await key(20);
      }
      expect(
        fixture.calls.where((c) => c.theme == 't11' && c.cursor == '30').length,
        1,
      );
      expect(find.text('加载更多'), findsNothing);
      expect(find.text('暂无更多内容'), findsNothing);
      expect(find.byKey(const ValueKey('tv-feed-status')), findsNothing);
      expect(t.getRect(find.byType(GridView)), initialGrid);
      print('TV_SCREENSHOT=automatic-page');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      print(
        'TV_FEED_NATIVE_PASS focus_selects_without_ok=true themes=12 label_visible=true automatic_page=true compact_bottom=true silent_loading=true',
      );
      await t.pumpWidget(const SizedBox());
    },
  );
}
