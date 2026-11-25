import 'catalog.dart';
import 'ranking.dart';
import 'source_adapter.dart';
import 'source_registry.dart';
import 'source_resolver.dart';

/// 路由门面：上层 App 只认 CatalogRepository，来源分派全在门面内完成。
///
/// P0 只有红果一个适配器，所有方法直接委托 primary，行为字节级不变；
/// 但 [detail] 已按 ID 前缀走 registry，为 P1+ 的多源分派留好唯一入口。
/// 新增源只改 defaultSourceFactories 清单，本门面不变。
///
/// 同时实现 Filtered/Rank 能力接口：红果独有的筛选/榜单能力由调用方
/// `is` 门控；在只有红果时这些能力必须继续可用（保住 discover 页）。
class RoutingCatalogRepository
    implements
        CatalogRepository,
        FilteredCatalogRepository,
        RankCatalogRepository,
        SourceSearchFacade {
  RoutingCatalogRepository({
    required this.registry,
    required this.primary,
    required this.rank,
  });

  final SourceRegistry registry;

  /// 红果 CatalogClient（能力接口的委托对象）。
  final CatalogClient primary;

  /// 红果榜单客户端（P0 仍只红果有榜单）。
  final RankCatalogRepository rank;

  void close() => primary.close();

  /// 来源列表供 UI 派生（设置页「片源」分区用），不写死枚举。
  @override
  List<SourceAdapter> get sources => registry.enabled;

  /// 按源单查：翻页游标内嵌来源，避免混源重复。P1 的西饭/河马经此入口
  /// 提供浏览/搜索，默认 browse/search 仍走红果保住 discover 页行为。
  Future<CatalogPage> browseFrom(
    String sourceId, {
    String genre = '',
    String? cursor,
    String? sort,
  }) {
    final adapter = registry.forSource(sourceId);
    if (adapter == null) {
      throw ArgumentError.value(sourceId, 'sourceId', '片源未启用或不存在');
    }
    return adapter.browse(genre: genre, cursor: cursor, sort: sort);
  }

  @override
  Future<CatalogPage> searchFrom(
    String sourceId,
    String query, {
    String? cursor,
  }) {
    final adapter = registry.forSource(sourceId);
    if (adapter == null) {
      throw ArgumentError.value(sourceId, 'sourceId', '片源未启用或不存在');
    }
    return adapter.search(query, cursor: cursor);
  }

  /// 详情：ID 自带来源前缀，路由到对应适配器；未命中兜底红果客户端。
  /// 纯数字历史 ID 命中红果适配器，委托结果与旧 CatalogClient 完全一致。
  @override
  Future<DramaDetail> detail(String id) =>
      registry.forId(id)?.detail(id) ?? primary.detail(id);

  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) => primary.browse(
    genre: genre,
    sort: sort,
    theme: theme,
    cursor: cursor,
    seen: seen,
  );

  /// 搜索聚合：首页（[cursor] 为空）并发查所有启用源，红果结果保持原排名
  /// 在前、其它源按注册表顺序尾随，按标题去重；单源失败静默跳过。带游标
  /// 的翻页直委红果——游标是红果私有语义，混源分页无法对齐，故不聚合。
  @override
  Future<CatalogPage> search(String query, {String? cursor}) async {
    if (cursor != null) return primary.search(query, cursor: cursor);
    final primaryPage = await primary.search(query);
    final others = registry.enabled.where((a) => a.id != 'hongguo').toList();
    if (others.isEmpty) return primaryPage;

    // 单源软超时：一个慢源不应让整个搜索卡住；失败静默跳过（设计 §1）。
    const perSource = Duration(seconds: 3);
    final pages = await Future.wait([
      for (final adapter in others)
        adapter.search(query).timeout(perSource).catchError((Object _) {
          return const CatalogPage(<Drama>[]);
        }),
    ], eagerError: false);
    return mergeSearchPages(primaryPage, pages);
  }

  /// 搜索合并纯函数：红果首页结果原样在前，其它源按传入顺序尾随；
  /// 标题去重（同名剧跨源只保留红果/靠前源的一条），游标始终取红果的。
  /// 抽成静态便于单测合并语义，不必搭真实 CatalogClient。
  static CatalogPage mergeSearchPages(
    CatalogPage primaryPage,
    List<CatalogPage> otherPages,
  ) {
    final titles = primaryPage.items.map((d) => d.title.trim()).toSet();
    final merged = <Drama>[...primaryPage.items];
    for (final page in otherPages) {
      for (final drama in page.items) {
        final key = drama.title.trim();
        if (key.isEmpty || !titles.add(key)) continue;
        merged.add(drama);
      }
    }
    return CatalogPage(merged, nextCursor: primaryPage.nextCursor);
  }

  @override
  Future<List<CatalogFilter>> themes(String genre) => primary.themes(genre);

  @override
  Future<List<CatalogDim>> filterRows(String genre) =>
      primary.filterRows(genre);

  @override
  Future<CatalogPage> browseFiltered(CatalogQuery query) =>
      primary.browseFiltered(query);

  @override
  Future<RankPage> rankBoard({
    String track = rankSeedTrack,
    String? board,
    String? cursor,
  }) => rank.rankBoard(track: track, board: board, cursor: cursor);
}
