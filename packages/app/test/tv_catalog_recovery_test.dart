import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/features/tv/tv_library_page.dart';
import 'package:hongguo_app/features/tv/tv_feed_page.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import 'fakes.dart';

class RecoveringCatalog extends FakeCatalog {
  Completer<List<CatalogFilter>>? themeGate;
  bool failThemes = false;
  int themeCalls = 0;
  @override
  Future<List<CatalogFilter>> themes(String genre) async {
    themeCalls++;
    if (themeGate != null) return themeGate!.future;
    if (failThemes) throw const CatalogError('网络暂不可用');
    return const [CatalogFilter('都市', 'city')];
  }
}

Future<void> mount(WidgetTester t, RecoveringCatalog catalog) async {
  final runtime = FakeRuntime(catalog);
  addTearDown(runtime.dispose);
  await t.binding.setSurfaceSize(const Size(1280, 720));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      builder: (_, child) =>
          TvEnvironment(enabled: true, child: TvNavigation(child: child!)),
      home: TvLibraryPage(runtime: runtime),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'slow themes do not block resources and late themes retain the feed page',
    (t) async {
      final catalog = RecoveringCatalog()..themeGate = Completer();
      await mount(t, catalog);
      expect(find.text(FakeCatalog.demo.title), findsWidgets);
      expect(find.textContaining('题材加载中'), findsOneWidget);
      final page = t.state(find.byType(TvFeedPage));
      final calls = catalog.browseCalls;
      catalog.themeGate!.complete(const [CatalogFilter('都市', 'city')]);
      await t.pumpAndSettle();
      expect(find.text('都市'), findsOneWidget);
      expect(t.state(find.byType(TvFeedPage)), same(page));
      expect(catalog.browseCalls, calls);
    },
  );
  testWidgets(
    'exhausted theme error stays visible and retry restores choices without replacing list',
    (t) async {
      final catalog = RecoveringCatalog()..failThemes = true;
      await mount(t, catalog);
      expect(find.text('题材加载失败 · 重试题材'), findsOneWidget);
      expect(find.text(FakeCatalog.demo.title), findsWidgets);
      final page = t.state(find.byType(TvFeedPage));
      catalog.failThemes = false;
      final retry = t.widget<TvFocusable>(
        find.byWidgetPredicate((w) => w is TvFocusable && w.label == '重试题材'),
      );
      retry.onActivate!();
      await t.pumpAndSettle();
      expect(catalog.themeCalls, 2);
      expect(find.text('都市'), findsOneWidget);
      expect(find.text('题材加载失败 · 重试题材'), findsNothing);
      expect(t.state(find.byType(TvFeedPage)), same(page));
    },
  );
  testWidgets('late theme routes preserve an active search page and query', (
    t,
  ) async {
    final catalog = RecoveringCatalog()..themeGate = Completer();
    await mount(t, catalog);
    final search = t.widget<TvFocusable>(
      find.byWidgetPredicate((w) => w is TvFocusable && w.label == '搜索'),
    );
    search.onActivate!();
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '测试');
    await t.tap(find.widgetWithText(FilledButton, '搜索'));
    await t.pumpAndSettle();
    expect(find.text('搜索命中'), findsWidgets);
    final page = t.state(find.byType(TvFeedPage));
    catalog.themeGate!.complete(const [CatalogFilter('都市', 'city')]);
    await t.pumpAndSettle();
    expect(find.text('搜索命中'), findsWidgets);
    expect(find.text('搜索：测试'), findsOneWidget);
    expect(t.state(find.byType(TvFeedPage)), same(page));
  });
}
