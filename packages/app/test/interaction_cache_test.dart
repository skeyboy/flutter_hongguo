import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/catalog/library_cache.dart';
import 'package:hongguo_app/features/library_page.dart';
import 'package:hongguo_app/features/local_cache_page.dart';
import 'package:hongguo_app/features/cache_metadata_page.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'fakes.dart';

class ControlledCatalog extends FakeCatalog {
  final pending = <Completer<CatalogPage>>[];
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) {
    lastGenre = genre;
    lastTheme = theme;
    final result = Completer<CatalogPage>();
    pending.add(result);
    return result.future;
  }
}

class CacheRuntime extends FakeRuntime
    implements LibraryCacheRuntime, LocalMediaRuntime {
  @override
  final libraryCache = LibraryCache();
  List<LocalEpisode> files = [];
  bool rejectSave = false;
  CacheRuntime([super.catalog]);
  @override
  Future<void> saveSettings(
    AppSettings value, {
    SessionCredentials? credentials,
  }) async {
    if (rejectSave) throw StateError('write failed');
    await super.saveSettings(value, credentials: credentials);
  }

  @override
  Future<List<LocalEpisode>> localEpisodes() async => Future.wait(
    files.map(
      (e) async => LocalEpisode(
        vid: e.vid,
        quality: e.quality,
        bytes: e.bytes,
        modified: e.modified,
        inUse: e.inUse,
        detail: await libraryCache.detailForVideo(e.vid) ?? e.detail,
      ),
    ),
  );

  @override
  PlaybackJob prepareLocal(String vid, {String quality = 'best'}) =>
      throw UnimplementedError();
  @override
  Future<void> evict(String vid, {String quality = 'best'}) async {
    files = files.where((e) => e.vid != vid || e.inUse).toList();
  }
}

class MetadataCatalog extends FakeCatalog {
  bool match = false;
  @override
  Future<CatalogPage> search(String query, {String? cursor}) async =>
      const CatalogPage([
        Drama(id: '222', title: '正确剧名', cover: 'https://img.example/poster'),
      ]);
  @override
  Future<DramaDetail> detail(String id) async => DramaDetail(
    Drama(id: id, title: ''),
    [Episode(vid: match ? '11' : '999', index: 3, title: '第三集标题')],
  );
}

Future<void> mount(WidgetTester tester, FakeRuntime runtime, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [runtimeProvider.overrideWith((ref) async => runtime)],
      child: const HongguoApp(),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets('filters remain interactive after long scroll at $width', (
      tester,
    ) async {
      final catalog = ControlledCatalog();
      await mount(tester, CacheRuntime(catalog), Size(width, 900));
      catalog.pending.first.complete(
        CatalogPage(List.generate(90, (i) => Drama(id: '$i', title: '故事$i'))),
      );
      await tester.pumpAndSettle();
      for (final destination in ['发现', '分类']) {
        if (destination == '分类') {
          await tester.tap(find.text('分类').first);
          await tester.pump();
          catalog.pending.last.complete(
            CatalogPage(
              List.generate(90, (i) => Drama(id: '$i', title: '故事$i')),
            ),
          );
          await tester.pumpAndSettle();
        }
        await tester.drag(
          find.byType(CustomScrollView),
          const Offset(0, -2500),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('sticky-genre')).hitTestable(),
          findsOneWidget,
        );
        if (width < 720) {
          await tester.tap(find.byKey(const ValueKey('sticky-sort')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('horizontal-filter-panel')),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const ValueKey('filter-theme-cate_7')));
        } else {
          await tester.tap(find.byKey(const ValueKey('sticky-theme')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('filter-theme-cate_7')));
        }
        await tester.pump(const Duration(milliseconds: 300));
        expect(catalog.lastTheme, 'cate_7');
        catalog.pending.last.complete(const CatalogPage([]));
        await tester.pumpAndSettle();
        await tester.tap(find.text('收起筛选'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }
  testWidgets(
    'cached list appears before network; failure retains it and refresh replaces cursor',
    (tester) async {
      final catalog = ControlledCatalog();
      final runtime = CacheRuntime(catalog)
        ..settings = const AppSettings(autoLoadMore: false);
      await mount(tester, runtime, const Size(390, 900));
      final dynamic state = tester.state(find.byType(LibraryPage));
      final key = state.feedKey as String;
      catalog.pending.first.complete(
        const CatalogPage([Drama(id: '1', title: '旧缓存')]),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('分类').first);
      await tester.pump();
      catalog.pending.last.complete(
        const CatalogPage([Drama(id: '2', title: '分类内容')]),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('发现').first);
      await tester.pump();
      await tester.pump();
      expect(find.text('旧缓存'), findsWidgets);
      expect(state.refreshing, isTrue);
      catalog.pending.last.completeError(const CatalogError('offline'));
      await tester.pumpAndSettle();
      expect(find.text('旧缓存'), findsWidgets);
      expect(find.text('网络刷新失败，正在显示本地缓存。'), findsOneWidget);
      await tester.tap(find.text('刷新'));
      await tester.pump();
      await tester.pump();
      catalog.pending.last.complete(
        const CatalogPage([
          Drama(id: '3', title: '最新内容'),
        ], nextCursor: 'new-cursor'),
      );
      await tester.pumpAndSettle();
      expect(find.text('最新内容'), findsWidgets);
      expect(find.text('旧缓存'), findsNothing);
      expect(
        (await runtime.libraryCache.readFeed(key))!.page.nextCursor,
        'new-cursor',
      );
    },
  );
  testWidgets('old response cannot overwrite switched list', (tester) async {
    final catalog = ControlledCatalog();
    await mount(tester, CacheRuntime(catalog), const Size(390, 900));
    await tester.tap(find.text('分类').first);
    await tester.pump();
    catalog.pending.last.complete(
      const CatalogPage([Drama(id: '2', title: '当前分类')]),
    );
    await tester.pumpAndSettle();
    catalog.pending.first.complete(
      const CatalogPage([Drama(id: '1', title: '过期结果')]),
    );
    await tester.pumpAndSettle();
    expect(find.text('当前分类'), findsWidgets);
    expect(find.text('过期结果'), findsNothing);
  });
  testWidgets(
    'theme applies immediately, preserves draft and rolls back failed save',
    (tester) async {
      final runtime = CacheRuntime();
      await mount(tester, runtime, const Size(390, 900));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('3 集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5 集').last);
      await tester.pumpAndSettle();
      Future<void> choose(String current, String next) async {
        await tester.ensureVisible(find.text(current));
        await tester.pumpAndSettle();
        await tester.tap(find.text(current));
        await tester.pumpAndSettle();
        await tester.tap(find.text(next).last);
        await tester.pumpAndSettle();
      }

      await choose('浅色', '深色');
      final settingsContext = tester.element(find.byType(NavigationBar));
      expect(Theme.of(settingsContext).brightness, Brightness.dark);
      expect(runtime.settings.themeMode, 'dark');
      expect(runtime.settings.prefetchEpisodes, 3);
      runtime.rejectSave = true;
      await choose('深色', '浅色');
      expect(Theme.of(settingsContext).brightness, Brightness.dark);
      expect(runtime.settings.themeMode, 'dark');
      expect(find.text('深色'), findsOneWidget);
      runtime.rejectSave = false;
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(runtime.settings.prefetchEpisodes, 5);
      await choose('深色', '跟随系统');
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(Theme.of(settingsContext).brightness, Brightness.light);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(Theme.of(settingsContext).brightness, Brightness.dark);
      tester.platformDispatcher.clearPlatformBrightnessTestValue();
    },
  );
  testWidgets(
    'settings lists local episodes, protects used file and supports deletion',
    (tester) async {
      final runtime = CacheRuntime()
        ..files = [
          LocalEpisode(
            vid: '11',
            quality: '720p',
            bytes: 1024,
            modified: DateTime(2026),
            inUse: false,
            detail: const DramaDetail(Drama(id: '1', title: '已缓存故事'), [
              Episode(vid: '11', index: 3),
            ]),
          ),
          LocalEpisode(
            vid: '12',
            quality: 'best',
            bytes: 1024,
            modified: DateTime(2026),
            inUse: true,
          ),
        ];
      await mount(tester, runtime, const Size(390, 900));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('本地缓存剧集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地缓存剧集'));
      await tester.pumpAndSettle();
      expect(find.byType(LocalCachePage), findsOneWidget);
      expect(find.byKey(const ValueKey('local-drama-1')), findsOneWidget);
      expect(find.text('待识别视频'), findsWidgets);
      await tester.tap(
        find.byKey(const ValueKey('local-drama-__unidentified__')),
      );
      await tester.pumpAndSettle();
      expect(find.text('视频 12'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '使用中，无法删除',
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local-drama-1')));
      await tester.pumpAndSettle();
      expect(find.byType(LocalEpisodesPage), findsOneWidget);
      expect(find.text('第 3 集'), findsOneWidget);
      await tester.tap(find.byTooltip('删除缓存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('第 3 集'), findsNothing);
      expect(runtime.files.single.vid, '12');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('local-drama-1')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'cache and playback switches and limits save; disabled auto paging stays manual',
    (tester) async {
      final runtime = CacheRuntime();
      await mount(tester, runtime, const Size(390, 900));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      for (final title in ['提前缓存后续剧集', '自动连播', '自动加载下一页']) {
        final control = find.widgetWithText(SwitchListTile, title);
        await tester.ensureVisible(control);
        await tester.pumpAndSettle();
        await tester.tap(control);
        await tester.pumpAndSettle();
      }
      Future<void> number(String current, String next) async {
        await tester.ensureVisible(find.text(current));
        await tester.pumpAndSettle();
        await tester.tap(find.text(current));
        await tester.pumpAndSettle();
        await tester.tap(find.text(next).last);
        await tester.pumpAndSettle();
      }

      await number('30 集', '20 集');
      await number('512 MB', '256 MB');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(runtime.settings.prefetchEnabled, isFalse);
      expect(runtime.settings.autoNext, isFalse);
      expect(runtime.settings.autoLoadMore, isFalse);
      expect(runtime.settings.maxCacheFiles, 20);
      expect(runtime.settings.maxCacheMb, 256);
      await tester.ensureVisible(find.text('清理未在使用的缓存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清理未在使用的缓存'));
      await tester.pumpAndSettle();
      expect(runtime.clears, 1);
      await tester.tap(find.text('发现').last);
      await tester.pumpAndSettle();
      final calls = runtime.catalog.browseCalls;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
      await tester.pumpAndSettle();
      expect(runtime.catalog.browseCalls, calls);
      expect(find.text('加载更多'), findsOneWidget);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(runtime.catalog.browseCalls, calls + 1);
    },
  );
  testWidgets('detail saves merged title before any video starts', (
    tester,
  ) async {
    final catalog = MetadataCatalog()..match = true;
    final runtime = CacheRuntime(catalog);
    await mount(tester, runtime, const Size(390, 900));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sticky-genre')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收起筛选'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('山海之间').last);
    await tester.tap(find.text('山海之间').last);
    await tester.pumpAndSettle();
    expect(find.text('开始观看'), findsOneWidget);
    final detail = (await runtime.libraryCache.readDetail('123'))!;
    expect(detail.drama.title, '山海之间');
    expect(detail.episodes.single.title, '第三集标题');
  });
  testWidgets(
    'metadata repair rejects mismatching IDs and groups verified matches',
    (tester) async {
      final catalog = MetadataCatalog();
      final runtime = CacheRuntime(catalog)
        ..files = [
          LocalEpisode(
            vid: '11',
            quality: 'best',
            bytes: 1024,
            modified: DateTime(2026),
            inUse: false,
          ),
        ];
      await tester.binding.setSurfaceSize(const Size(390, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(home: LocalCachePage(runtime: runtime)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('补全剧目信息'));
      await tester.pumpAndSettle();
      expect(find.byType(CacheMetadataPage), findsOneWidget);
      await tester.enterText(find.byType(TextField), '正确剧名');
      await tester.tap(find.byTooltip('搜索剧目'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '正确剧名'));
      await tester.pumpAndSettle();
      expect(find.text('该剧没有匹配的本地视频，请选择正确的剧目。'), findsOneWidget);
      expect(await runtime.libraryCache.detailForVideo('11'), isNull);
      catalog.match = true;
      await tester.tap(find.widgetWithText(ListTile, '正确剧名'));
      await tester.pumpAndSettle();
      expect(find.byType(CacheMetadataPage), findsNothing);
      expect(find.byKey(const ValueKey('local-drama-222')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('local-drama-__unidentified__')),
        findsNothing,
      );
      final saved = (await runtime.libraryCache.detailForVideo('11'))!;
      expect(saved.drama.title, '正确剧名');
      expect(saved.drama.cover, 'https://img.example/poster');
      expect(tester.takeException(), isNull);
    },
  );
}
