import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_app/catalog/library_cache.dart';
import 'package:hongguo_app/features/detail_page.dart';
import 'package:hongguo_app/platform/runtime.dart';

import 'fakes.dart';

class _Catalog extends FakeCatalog {
  bool failDetails = true, failThemes = true;
  @override
  Future<DramaDetail> detail(String id) async {
    if (failDetails) throw StateError('offline');
    return const DramaDetail(
      Drama(id: '123', title: '更新的剧集', episodeCount: 1),
      [Episode(vid: '11', index: 1)],
    );
  }

  @override
  Future<List<CatalogFilter>> themes(String genre) async {
    if (failThemes) throw StateError('offline');
    return super.themes(genre);
  }
}

class _Runtime extends FakeRuntime implements LibraryCacheRuntime {
  @override
  final libraryCache = LibraryCache();
  _Runtime(super.catalog);
}

void main() {
  testWidgets(
    'failed detail keeps saved metadata and manual retry replaces it',
    (tester) async {
      final catalog = _Catalog();
      final runtime = _Runtime(catalog);
      addTearDown(runtime.dispose);
      await runtime.libraryCache.rememberDetail(
        const DramaDetail(FakeCatalog.demo, [Episode(vid: '11', index: 1)]),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(runtime: runtime, initial: FakeCatalog.demo),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('正在显示已保存的剧集信息'), findsOneWidget);
      expect(find.text('开始观看'), findsOneWidget);
      catalog.failDetails = false;
      await tester.tap(find.text('重试刷新'));
      await tester.pumpAndSettle();
      expect(find.textContaining('正在显示已保存的剧集信息'), findsNothing);
      expect(find.text('更新的剧集'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('themes fail independently and retry without blocking feed', (
    tester,
  ) async {
    final catalog = _Catalog();
    final runtime = _Runtime(catalog);
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [runtimeProvider.overrideWith((_) async => runtime)],
        child: const HongguoApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('山海之间'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('sticky-theme')));
    await tester.pumpAndSettle();
    expect(find.text('题材加载失败，重试'), findsOneWidget);
    catalog.failThemes = false;
    await tester.tap(find.text('题材加载失败，重试'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-theme-cate_7')), findsOneWidget);
    expect(find.text('山海之间'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
