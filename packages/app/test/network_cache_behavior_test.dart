import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/features/library_page.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'interaction_cache_test.dart'
    show ControlledCatalog, CacheRuntime, mount;

class ScopedCatalog extends ControlledCatalog {
  final scopes = <CatalogRequestScope?>[];
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) {
    scopes.add(CatalogRequestScope.current);
    return super.browse(
      genre: genre,
      sort: sort,
      theme: theme,
      cursor: cursor,
      seen: seen,
    );
  }
}

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'fresh cache skips refresh and explicit refresh retains data on failure at $width',
      (t) async {
        final catalog = ControlledCatalog();
        final runtime = CacheRuntime(catalog)
          ..settings = const AppSettings(autoLoadMore: false);
        addTearDown(runtime.dispose);
        await mount(t, runtime, Size(width, 900));
        catalog.pending[0].complete(
          const CatalogPage([Drama(id: '1', title: '已缓存发现')]),
        );
        await t.pumpAndSettle();
        await t.tap(find.text('分类').first);
        await t.pump(const Duration(milliseconds: 300));
        catalog.pending[1].complete(
          const CatalogPage([Drama(id: '2', title: '已缓存分类')]),
        );
        await t.pumpAndSettle();
        // Swiping back to a page the viewer already loaded keeps its rows on
        // screen and asks for them again in the background -- the same promise
        // a kept theme makes.
        await t.tap(find.text('发现').first);
        await t.pump(const Duration(milliseconds: 300));
        await t.pump(const Duration(milliseconds: 300));
        expect(catalog.pending, hasLength(3));
        expect(find.text('已缓存发现'), findsWidgets);
        final dynamic state = t.state(find.byType(LibraryPage));
        expect(state.feed.refreshing, isTrue);
        catalog.pending[2].completeError(const CatalogError('offline'));
        await t.pumpAndSettle();
        expect(find.text('已缓存发现'), findsWidgets);
        expect(find.text('网络刷新失败，仍显示上次结果。'), findsOneWidget);
        // 刷新 is the explicit path: it reads the stored page back first, so a
        // failure still leaves the cached rows and their message on screen.
        await t.tap(find.text('重试刷新'));
        await t.pump();
        await t.pump();
        expect(catalog.pending, hasLength(4));
        expect(find.text('已缓存发现'), findsWidgets);
        catalog.pending.last.completeError(const CatalogError('offline'));
        await t.pumpAndSettle();
        expect(find.text('已缓存发现'), findsWidgets);
        expect(find.text('网络刷新失败，正在显示本地缓存。'), findsOneWidget);
      },
    );
    testWidgets('switch and dispose cancel caller scopes at $width', (t) async {
      final catalog = ScopedCatalog();
      final runtime = CacheRuntime(catalog)
        ..settings = const AppSettings(autoLoadMore: false);
      addTearDown(runtime.dispose);
      await mount(t, runtime, Size(width, 900));
      expect(catalog.scopes.first, isNotNull);
      await t.tap(find.text('分类').first);
      await t.pump(const Duration(milliseconds: 300));
      expect(catalog.scopes.first!.isCancelled, isTrue);
      expect(catalog.scopes.last!.isCancelled, isFalse);
      catalog.pending.last.complete(
        const CatalogPage([Drama(id: '2', title: '当前内容')]),
      );
      catalog.pending.first.complete(
        const CatalogPage([Drama(id: '1', title: '旧内容')]),
      );
      await t.pumpAndSettle();
      expect(find.text('当前内容'), findsWidgets);
      expect(find.text('旧内容'), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
      expect(catalog.scopes.last!.isCancelled, isTrue);
    });
  }
}
