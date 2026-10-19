import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_app/features/library_page.dart';
import 'package:hongguo_app/features/settings_page.dart';

import 'fakes.dart';

class PagedCatalog extends FakeCatalog {
  int calls = 0;
  bool stuck = false, failPage = false;
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) async {
    calls++;
    if (cursor == null) {
      return CatalogPage(
        List.generate(
          12,
          (i) => Drama(id: '${i + 100}', title: '首屏$i', episodeCount: 3),
        ),
        nextCursor: 'page1',
      );
    }
    if (failPage) throw const CatalogError('分页暂时失败');
    if (stuck) return const CatalogPage([], nextCursor: 'page1');
    return CatalogPage(
      List.generate(
        12,
        (i) => Drama(id: '${i + 200}', title: '续页$i', episodeCount: 3),
      ),
    );
  }
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    FakeRuntime runtime,
    Size size,
  ) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [runtimeProvider.overrideWith((ref) async => runtime)],
        child: const HongguoApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final size in [
    const Size(390, 844),
    const Size(800, 900),
    const Size(1280, 900),
  ]) {
    testWidgets('navigation adapts at ${size.width} without overflow', (
      tester,
    ) async {
      await mount(tester, FakeRuntime(), size);
      expect(
        find.byType(NavigationBar),
        size.width < 720 ? findsOneWidget : findsNothing,
      );
      expect(
        find.byType(NavigationRail),
        size.width >= 720 && size.width < 1100 ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'scroll proximity loads one next page without pressing a button',
    (tester) async {
      final catalog = PagedCatalog();
      await mount(tester, FakeRuntime(catalog), const Size(390, 844));
      expect(catalog.calls, 1);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
      await tester.pumpAndSettle();
      expect(catalog.calls, 2);
      final dynamic state = tester.state(find.byType(LibraryPage));
      expect(state.items.length, 24);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
      await tester.pumpAndSettle();
      expect(catalog.calls, 2);
    },
  );
  testWidgets('stuck cursor and page errors pause automatic retries', (
    tester,
  ) async {
    final catalog = PagedCatalog()..stuck = true;
    await mount(tester, FakeRuntime(catalog), const Size(390, 844));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(catalog.calls, 2);
    final dynamic state = tester.state(find.byType(LibraryPage));
    expect(state.autoPaused, isTrue);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(catalog.calls, 2);
    catalog.stuck = false;
    catalog.failPage = true;
    await tester.ensureVisible(find.text('重试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(catalog.calls, 3);
    expect(find.text('分页暂时失败'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(catalog.calls, 3);
  });
  testWidgets(
    'mobile category sheet applies theme, desktop keeps inline filters',
    (tester) async {
      final runtime = FakeRuntime();
      await mount(tester, runtime, const Size(390, 844));
      await tester.tap(find.text('分类'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sticky-sort')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('horizontal-filter-panel')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('filter-theme-cate_7')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(runtime.catalog.lastTheme, 'cate_7');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'settings save 5-episode lookahead and render in mobile navigation',
    (tester) async {
      final runtime = FakeRuntime();
      await mount(tester, runtime, const Size(390, 844));
      await tester.tap(
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '设置'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      await tester.tap(find.text('3 集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5 集').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('浅色'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('浅色'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('深色').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      expect(runtime.settings.prefetchEpisodes, 5);
      expect(runtime.saves, 2);
      expect(find.text('设置已保存'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'session fields are masked, saved explicitly, and signing refresh is independent',
    (tester) async {
      final runtime = FakeRuntime();
      await mount(tester, runtime, const Size(1280, 900));
      await tester.tap(
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '设置'),
      );
      await tester.pumpAndSettle();
      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Cookie',
      );
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).obscureText, isTrue);
      await tester.enterText(field, 'test-cookie-only');
      expect(runtime.credentials.cookie, isEmpty);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(runtime.credentials.cookie, 'test-cookie-only');
      final refresh = find.text('刷新签名状态');
      await tester.ensureVisible(refresh);
      await tester.pumpAndSettle();
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(runtime.signRefreshes, 1);
      expect(runtime.credentials.cookie, 'test-cookie-only');
      expect(tester.takeException(), isNull);
    },
  );
}
