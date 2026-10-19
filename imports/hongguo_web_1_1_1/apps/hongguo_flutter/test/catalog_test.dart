import 'package:flutter/material.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_flutter/adapters/backend.dart';
import 'package:hongguo_flutter/features/catalog/catalog_page.dart';
import 'package:hongguo_flutter/features/library/library_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeRepository implements CatalogRepository, PlaybackRepository {
  final queries = <String>[];
  @override
  Future<Page<Series>> browse({
    String genre = 'short_play',
    int offset = 0,
    int limit = 20,
    Set<String> seen = const {},
  }) async => Page([Series(id: '123', title: '本地测试 $genre', episodeCount: 12)]);
  @override
  Future<Page<Series>> search(
    String query, {
    int offset = 0,
    int limit = 20,
  }) async {
    queries.add(query);
    return Page([Series(id: '456', title: '搜索结果 $query')]);
  }

  @override
  Future<SeriesDetail> detail(String id) async =>
      SeriesDetail(Series(id: id, title: '测试'), []);
  @override
  Future<MediaSource> prepare(
    String vid, {
    String quality = 'best',
    CancellationToken? cancellation,
    void Function(PreparationState)? onState,
  }) async => const MediaSource('');
}

void main() {
  testWidgets(
    'Browse genres, search, favorites and history use shared repository',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final library = LibraryStore(await SharedPreferences.getInstance()),
          repo = FakeRepository();
      final backend = Backend(repo, repo, label: '本地 Dart 核心', close: () {});
      await tester.pumpWidget(
        MaterialApp(
          home: CatalogPage(backend: backend, library: library),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('本地测试 short_play'), findsOneWidget);
      await tester.tap(find.text('AI短剧'));
      await tester.pumpAndSettle();
      expect(find.text('本地测试 ai_series'), findsOneWidget);
      await tester.enterText(find.byType(SearchBar), '关键词');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(repo.queries, ['关键词']);
      expect(find.text('搜索结果 关键词'), findsOneWidget);
      await library.toggle(const Series(id: '999', title: '已收藏'));
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      expect(find.text('已收藏'), findsOneWidget);
      await library.record(
        const Series(id: '888', title: '看过的剧'),
        3,
        const Duration(seconds: 15),
      );
      await tester.tap(find.text('历史'));
      await tester.pumpAndSettle();
      expect(find.text('看过的剧'), findsOneWidget);
      final restored = LibraryStore(await SharedPreferences.getInstance());
      expect(restored.favorites['999']?.title, '已收藏');
      expect(restored.history['888']?.episode, 3);
      expect(restored.history['888']?.positionMs, 15000);
      await tester.pumpWidget(const SizedBox());
      library.dispose();
      restored.dispose();
    },
  );
}
