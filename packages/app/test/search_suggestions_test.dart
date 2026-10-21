import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_app/search/search_history.dart';
import 'package:hongguo_app/settings/settings_store.dart';

import 'fakes.dart';

/// Lets a test say what each board returns, so the marks on the rows can be
/// checked against the request that produced them.
class BoardsCatalog extends FakeCatalog {
  final Map<String, List<Drama>> boards = {};

  /// Only the recommendation boards go down; the feed keeps working, which is
  /// what the panel must survive.
  bool boardsDown = false;

  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) {
    final rows = cursor == null ? boards[sort] : null;
    if (rows != null) {
      lastGenre = genre;
      lastSort = sort;
      browseCalls++;
      if (boardsDown) throw const CatalogError('上游暂时不可用');
      return Future.value(CatalogPage(rows));
    }
    return super.browse(
      genre: genre,
      sort: sort,
      theme: theme,
      cursor: cursor,
      seen: seen,
    );
  }
}

const newest = [
  Drama(id: 'n1', title: '新剧一', episodeCount: 2),
  Drama(id: 'n2', title: '新剧二', episodeCount: 4),
];

/// A runtime whose history only exists on disk, so the first focus has to read
/// it rather than inherit it from a search in this session.
class SeededRuntime extends FakeRuntime implements SearchHistoryRuntime {
  SeededRuntime(super.catalog, this.searchHistory);
  @override
  final SearchHistory searchHistory;
}

class SeededBackend implements PreferencesBackend {
  SeededBackend(this.data);
  final Map<String, dynamic> data;

  @override
  Future<Map<String, dynamic>?> read() async => data;

  @override
  Future<void> write(Map<String, dynamic> value) async {}
}

const hot = [
  Drama(id: 'h1', title: '热门一', episodeCount: 9),
  Drama(id: 'n1', title: '新剧一', episodeCount: 2),
];

void main() {
  Future<void> mount(
    WidgetTester tester,
    FakeRuntime runtime, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.resetPhysicalSize();
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

  Future<void> searched(
    WidgetTester tester,
    FakeRuntime runtime,
    List<String> terms,
  ) async {
    for (final term in terms) {
      await tester.enterText(find.byType(TextField), term);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
    }
    expect(runtime.catalog.lastQuery, terms.last);
  }

  Future<void> openDropdown(WidgetTester tester) async {
    if (find.text('清除搜索').evaluate().isNotEmpty) {
      await tester.tap(find.text('清除搜索'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
  }

  BoardsCatalog boards() =>
      BoardsCatalog()..boards.addAll({'online_time': newest, 'hot_score': hot});

  testWidgets('focus pops recent searches beside board rows', (tester) async {
    final runtime = FakeRuntime(boards());
    await mount(tester, runtime);
    await searched(tester, runtime, ['第一个', '第二个', '第三个', '第四个']);
    await openDropdown(tester);

    expect(find.byKey(const ValueKey('search-suggestions')), findsOneWidget);
    // Three most recent, and the oldest one stays out of the panel.
    expect(find.byKey(const ValueKey('search-history-第四个')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-history-第二个')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-history-第一个')), findsNothing);
    // One row per drama, marked by the board it was read from.
    expect(find.byKey(const ValueKey('search-suggest-n1')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-suggest-h1')), findsOneWidget);
    expect(find.byIcon(Icons.fiber_new_rounded), findsNWidgets(2));
    expect(find.byIcon(Icons.local_fire_department_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a recent row searches and deletes without closing the panel', (
    tester,
  ) async {
    final runtime = FakeRuntime(boards());
    await mount(tester, runtime);
    await searched(tester, runtime, ['留在面板', '立即删除']);
    await openDropdown(tester);

    await tester.tap(find.byKey(const ValueKey('search-history-remove-立即删除')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('search-history-remove-立即删除')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('search-history-留在面板')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-suggestions')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search-history-留在面板')));
    await tester.pumpAndSettle();
    expect(find.text('留在面板'), findsWidgets);
    expect(find.byKey(const ValueKey('search-suggestions')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a board row opens the series without searching', (tester) async {
    final runtime = FakeRuntime(boards());
    await mount(tester, runtime);
    await openDropdown(tester);
    final before = runtime.catalog.lastQuery;

    await tester.tap(find.byKey(const ValueKey('search-suggest-h1')));
    await tester.pumpAndSettle();
    expect(find.text('选择剧集'), findsOneWidget);
    expect(runtime.catalog.lastQuery, before);
    expect(find.byKey(const ValueKey('search-suggestions')), findsNothing);
  });

  testWidgets('tapping away closes the dropdown and the boards stay cached', (
    tester,
  ) async {
    final runtime = FakeRuntime(boards());
    await mount(tester, runtime);
    await openDropdown(tester);
    final calls = runtime.catalog.browseCalls;

    await tester.tap(find.byKey(const ValueKey('search-suggestions-dismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-suggestions')), findsNothing);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-suggestions')), findsOneWidget);
    expect(runtime.catalog.browseCalls, calls);
  });

  testWidgets('an unreachable board leaves the recent searches usable', (
    tester,
  ) async {
    final catalog = boards()..boardsDown = true;
    final runtime = FakeRuntime(catalog);
    await mount(tester, runtime);
    await searched(tester, runtime, ['离线可用']);
    await openDropdown(tester);

    expect(find.byKey(const ValueKey('search-suggestions')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-history-离线可用')), findsOneWidget);
    expect(find.byIcon(Icons.fiber_new_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the first focus shows what the last session saved', (
    tester,
  ) async {
    final store = SearchHistory(
      backend: SeededBackend({
        'version': 1,
        'queries': ['上个会话留下的词'],
      }),
    );
    await mount(tester, SeededRuntime(boards(), store));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('search-history-上个会话留下的词')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.fiber_new_rounded), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unreadable history file still leaves the boards', (
    tester,
  ) async {
    final store = SearchHistory(
      backend: SeededBackend({
        'version': 2,
        'queries': ['旧'],
      }),
    );
    await mount(tester, SeededRuntime(boards(), store));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-suggestions')), findsOneWidget);
    expect(find.byIcon(Icons.fiber_new_rounded), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
