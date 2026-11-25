import 'dart:async';

import 'package:hongguo_api/hongguo_api.dart';
import 'package:test/test.dart';

/// 假门面：按源返回预置结果；detail 走通用映射。
class FakeFacade implements SourceSearchFacade {
  FakeFacade(this.adapters, {this.searchResults = const {}, this.failFor = const []});

  final List<SourceAdapter> adapters;
  final Map<String, CatalogPage> searchResults;
  final List<String> failFor;
  final searches = <(String, String)>[];

  @override
  List<SourceAdapter> get sources => adapters;

  @override
  Future<CatalogPage> searchFrom(
    String sourceId,
    String query, {
    String? cursor,
  }) async {
    searches.add((sourceId, query));
    if (failFor.contains(sourceId)) {
      throw SourceUnavailable(sourceId, '网络不可达');
    }
    return searchResults[sourceId] ?? const CatalogPage([]);
  }

  @override
  Future<DramaDetail> detail(String id) async {
    final index = int.tryParse(id.split(':').last) ?? 1;
    return DramaDetail(
      Drama(id: id, title: '剧 $id'),
      [Episode(vid: id, index: index, title: '第 $index 集')],
    );
  }
}

/// 可控的假源：搜索结果由回调决定。
class StubAdapter implements SourceAdapter {
  StubAdapter(this.id, {this.catalog});

  final CatalogPage? Function()? catalog;

  @override
  final String id;
  @override
  String get label => '源 $id';
  @override
  SourceKind get kind => SourceKind.builtin;
  @override
  bool matches(String mediaId) => mediaId.startsWith('$id:');
  @override
  bool enabled(_) => true;
  @override
  Future<CatalogPage> browse({
    String genre = '',
    String? cursor,
    String? sort,
  }) async => const CatalogPage([]);
  @override
  Future<CatalogPage> search(String query, {String? cursor}) async =>
      catalog?.call() ?? const CatalogPage([]);
  @override
  Future<DramaDetail> detail(String seriesId) async =>
      DramaDetail(Drama(id: seriesId, title: seriesId), const []);
  @override
  Future<VideoTrack> fetchTrack(String mediaId, {String quality = 'best'}) =>
      throw UnimplementedError();
}

Drama drama(String id, String title) =>
    Drama(id: id, title: title, episodeCount: 12);

void main() {
  test('精确匹配优先于包含匹配，且按候选顺序取第一个命中源', () async {
    final hybrid = FakeFacade([
      StubAdapter('xifan'),
      StubAdapter('hema'),
    ], searchResults: {
      'xifan': CatalogPage([drama('xifan:1', '我家娘子是拽姐第三季')]),
      'hema': CatalogPage([drama('hema:1', '我家娘子是拽姐')]),
    });
    final match = await SourceResolver(hybrid).resolve(
      title: '我家娘子是拽姐',
      excludeId: 'hongguo',
    );
    expect(match, isNotNull);
    expect(match!.sourceId, 'hema'); // xifan 只是包含，hema 精确命中
    expect(match.episodeAt(1)!.index, 1); // 假详情只有第 1 集
    expect(hybrid.searches.first.$1, 'xifan'); // 顺序保持注册表顺序
  });

  test('单源失败静默跳过，下一个源命中', () async {
    final facade = FakeFacade([StubAdapter('xifan'), StubAdapter('hema')],
        searchResults: {
          'hema': CatalogPage([drama('hema:9', '我家娘子是拽姐')]),
        },
        failFor: ['xifan']);
    final match = await SourceResolver(facade).resolve(
      title: '我家娘子是拽姐',
      excludeId: 'hongguo',
    );
    expect(match!.sourceId, 'hema');
    expect(facade.searches.map((s) => s.$1), ['xifan', 'hema']);
  });

  test('excludeIds 排除已试过的源，自动跨源不回切造成来回横跳', () async {
    final facade = FakeFacade([StubAdapter('xifan'), StubAdapter('hema')],
        searchResults: {
          'xifan': CatalogPage([drama('xifan:1', '我家娘子是拽姐')]),
          'hema': CatalogPage([drama('hema:1', '我家娘子是拽姐')]),
        });
    final match = await SourceResolver(facade).resolve(
      title: '我家娘子是拽姐',
      excludeId: 'hongguo',
      excludeIds: {'xifan'},
    );
    expect(match!.sourceId, 'hema');
    expect(facade.searches.map((s) => s.$1), ['hema']);
  });

  test('全部无命中返回 null', () async {
    final facade = FakeFacade([StubAdapter('xifan')]);
    final match = await SourceResolver(facade, budget: Duration.zero).resolve(
      title: '不存在的剧',
      excludeId: 'hongguo',
    );
    expect(match, isNull);
  });

  test('预算耗尽立即停止：budget=0 时不发起任何搜索', () async {
    final facade = FakeFacade([StubAdapter('xifan')], searchResults: {
      'xifan': CatalogPage([drama('xifan:1', '我家娘子是拽姐')]),
    });
    final match = await SourceResolver(facade, budget: Duration.zero).resolve(
      title: '我家娘子是拽姐',
      excludeId: 'hongguo',
    );
    expect(match, isNull);
    expect(facade.searches, isEmpty);
  });

  test('alternatives 排除当前源，currentSourceId 按前缀归属', () {
    final facade = FakeFacade([
      StubAdapter('hongguo'),
      StubAdapter('xifan'),
      StubAdapter('hema'),
    ]);
    final resolver = SourceResolver(facade);
    expect(
      resolver.alternatives('xifan').map((a) => a.id),
      ['hongguo', 'hema'],
    );
    expect(resolver.currentSourceId('hema:7:3'), 'hema');
    expect(resolver.currentSourceId('12345'), 'hongguo');
  });

  test('episodeAt 越界回退最后一集，空集列表 + episodeIndex 时整源跳过',
      () async {
    final facade = FakeFacade([StubAdapter('xifan')], searchResults: {
      'xifan': CatalogPage([drama('xifan:1', '我家娘子是拽姐')]),
    });
    final resolver = SourceResolver(facade);
    final match = await resolver.resolve(
      title: '我家娘子是拽姐',
      excludeId: 'hongguo',
    );
    expect(match!.episodeAt(99)!.index, 1); // FakeFacade.detail 只有一集
  });
}
