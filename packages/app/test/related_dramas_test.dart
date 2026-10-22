import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/platform/runtime_contract.dart';
import 'package:hongguo_app/recommendations/related_dramas.dart';

class FakeCatalog implements CatalogRepository {
  int themesCalls = 0;
  int browseCalls = 0;
  String? lastTheme;
  String? lastSort;
  List<CatalogFilter> themeList = const [
    CatalogFilter('都市', 'cate_7'),
    CatalogFilter('古装', 'cate_3'),
  ];
  List<Drama> browseItems = const [];
  Object? themesError;
  Object? browseError;

  @override
  Future<List<CatalogFilter>> themes(String genre) async {
    themesCalls++;
    if (themesError != null) throw themesError!;
    return themeList;
  }

  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) async {
    browseCalls++;
    lastTheme = theme;
    lastSort = sort;
    if (browseError != null) throw browseError!;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return CatalogPage(browseItems);
  }

  @override
  Future<CatalogPage> search(String query, {String? cursor}) async =>
      throw UnimplementedError();

  @override
  Future<DramaDetail> detail(String id) async => throw UnimplementedError();
}

class FakeCatalogRuntime implements AppRuntime {
  FakeCatalogRuntime(this.catalog);

  /// The field getter already satisfies `AppRuntime.catalog` (covariant).
  @override
  final FakeCatalog catalog;

  @override
  PlaybackJob prepare(
    String vid, {
    String quality = 'best',
    void Function(PreparationProgress)? onProgress,
    bool background = false,
  }) => throw UnimplementedError();

  @override
  Future<void> evict(String vid, {String quality = 'best'}) async =>
      throw UnimplementedError();

  @override
  Future<int> cacheBytes() async => 0;

  @override
  Future<void> clearCache() async {}

  @override
  Future<void> dispose() async {}
}

Drama drama(String id, {List<String> tags = const []}) =>
    Drama(id: id, title: '剧 $id', tagNames: tags);

DramaDetail currentDrama({List<String> tags = const ['都市']}) =>
    DramaDetail(drama('cur', tags: tags), const []);

void main() {
  late FakeCatalog catalog;
  late FakeCatalogRuntime runtime;
  late DateTime clock;
  late RelatedDramaLoader loader;

  setUp(() {
    catalog = FakeCatalog();
    runtime = FakeCatalogRuntime(catalog);
    clock = DateTime(2026, 10, 22, 12);
    loader = RelatedDramaLoader(now: () => clock);
  });

  test(
    'maps the first hit tag to its theme and excludes the current drama',
    () async {
      catalog.browseItems = [drama('cur'), drama(''), drama('a'), drama('b')];
      final result = await loader.load(runtime, currentDrama());
      expect(catalog.lastTheme, 'cate_7');
      expect(result.themeName, '都市');
      expect(result.items.map((d) => d.id), ['a', 'b']);
    },
  );

  test('caps the row at 12 after excluding the current drama', () async {
    catalog.browseItems = [
      drama('cur'),
      for (var i = 0; i < 15; i++) drama('p$i'),
      for (var i = 0; i < 15; i++) drama('q$i'),
    ];
    final result = await loader.load(
      runtime,
      currentDrama(tags: const ['古装', '都市']),
    );
    expect(catalog.lastTheme, 'cate_3');
    expect(result.themeName, '古装');
    expect(result.items, hasLength(12));
    expect(result.items.map((d) => d.id), [for (var i = 0; i < 12; i++) 'p$i']);
  });

  test('no genre names skips the panel and reads the hot board', () async {
    catalog.browseItems = [drama('cur'), drama('a')];
    final result = await loader.load(runtime, currentDrama(tags: const []));
    expect(catalog.themesCalls, 0);
    expect(catalog.browseCalls, 1);
    expect(catalog.lastSort, 'hot_score');
    expect(catalog.lastTheme, isNull);
    expect(result.relation, '平台热门');
    expect(result.themeName, isEmpty);
    expect(result.items.map((d) => d.id), ['a']);
  });

  test('a genre absent from the panel falls back to the hot board', () async {
    catalog.browseItems = [drama('b')];
    final result = await loader.load(runtime, currentDrama(tags: ['科幻']));
    expect(catalog.themesCalls, 1);
    expect(catalog.lastSort, 'hot_score');
    expect(result.relation, '平台热门');
    expect(result.items.map((d) => d.id), ['b']);
  });

  test(
    'themes or browse failures return an empty row without throwing',
    () async {
      catalog.themesError = const CatalogError('题材挂了');
      expect((await loader.load(runtime, currentDrama())).items, isEmpty);

      loader = RelatedDramaLoader(now: () => clock);
      catalog.themesError = null;
      catalog.browseError = const CatalogError('列表挂了');
      expect((await loader.load(runtime, currentDrama())).items, isEmpty);

      loader = RelatedDramaLoader(now: () => clock);
      catalog.browseError = null;
      catalog.browseItems = const [];
      final empty = await loader.load(runtime, currentDrama());
      expect(empty.items, isEmpty);
    },
  );

  test('second call inside 10 minutes is cached; after it refetches', () async {
    catalog.browseItems = [drama('a')];
    await loader.load(runtime, currentDrama());
    clock = clock.add(const Duration(minutes: 9, seconds: 59));
    final again = await loader.load(runtime, currentDrama());
    expect(catalog.themesCalls, 1);
    expect(catalog.browseCalls, 1);
    expect(again.items.map((d) => d.id), ['a']);

    clock = clock.add(const Duration(minutes: 1));
    await loader.load(runtime, currentDrama());
    expect(catalog.themesCalls, 2);
    expect(catalog.browseCalls, 2);
  });

  test('concurrent calls for one drama share a single flight', () async {
    catalog.browseItems = [drama('a')];
    final first = loader.load(runtime, currentDrama());
    final second = loader.load(runtime, currentDrama());
    expect(await first, same(await second));
    expect(catalog.themesCalls, 1);
    expect(catalog.browseCalls, 1);
  });

  test('an empty page caches nothing, so the next visit refetches', () async {
    catalog.browseItems = const [];
    expect((await loader.load(runtime, currentDrama())).items, isEmpty);

    catalog.browseItems = [drama('a')];
    final retry = await loader.load(runtime, currentDrama());
    expect(catalog.browseCalls, 2);
    expect(retry.items.map((d) => d.id), ['a']);
  });
}
