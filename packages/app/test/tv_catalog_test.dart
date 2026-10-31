import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_tv/hongguo_tv.dart';
import 'package:hongguo_app/features/tv/tv_library_page.dart';
import 'package:hongguo_app/platform/runtime.dart';

class TvCatalog implements CatalogRepository {
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) async => CatalogPage([
    for (var i = 0; i < 20; i++)
      Drama(id: '$i', title: '剧集 $i', episodeCount: 2),
  ]);
  @override
  Future<CatalogPage> search(String q, {String? cursor}) async =>
      CatalogPage([Drama(id: '99', title: '搜索 $q')]);
  @override
  Future<DramaDetail> detail(String id) async => DramaDetail(
    Drama(id: id, title: '剧集 $id'),
    [const Episode(vid: '10', index: 1), const Episode(vid: '11', index: 2)],
  );
  @override
  Future<List<CatalogFilter>> themes(String genre) async => [];
}

class TvRuntime implements AppRuntime {
  @override
  final catalog = TvCatalog();
  @override
  Future<void> dispose() async {}
  @override
  Future<void> clearCache() async {}
  @override
  Future<int> cacheBytes() async => 0;
  @override
  Future<void> evict(String vid, {String quality = 'best'}) async {}
  @override
  PlaybackJob prepare(
    String vid, {
    String quality = 'best',
    void Function(PreparationProgress)? onProgress,
    bool background = false,
  }) => throw UnimplementedError();
}

void main() {
  testWidgets(
    'TV shell enters detail with D-pad only and restores card focus',
    (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              TvEnvironment(enabled: true, child: TvNavigation(child: child!)),
          home: TvLibraryPage(runtime: TvRuntime()),
        ),
      );
      await t.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'nav-0');
      // Enter content from navigation, then search down to cards.
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pumpAndSettle();
      for (
        var n = 0;
        n < 5 &&
            FocusManager.instance.primaryFocus?.debugLabel?.startsWith(
                  'tv-grid-',
                ) !=
                true;
        n++
      ) {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await t.pumpAndSettle();
      }
      final previousCard = FocusManager.instance.primaryFocus?.debugLabel;
      expect(previousCard, startsWith('tv-grid-'));
      await t.sendKeyEvent(LogicalKeyboardKey.select);
      await t.pumpAndSettle();
      expect(find.text('▶ 开始观看'), findsOneWidget);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-detail-play');
      // The detail route has no AppBar arrow on TV: 返回 is the remote's Back key
      // (Android keycode 4, which the integration remotes send as `escape`), or
      // the page's own 返回目录 target. Tapping a touch affordance would prove
      // nothing about the hardware path.
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, previousCard);
      await t.pumpWidget(const SizedBox());
    },
  );
}
