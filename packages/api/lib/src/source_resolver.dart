import 'catalog.dart';
import 'source_adapter.dart';

/// 跨源同名解析结果：命中的来源与该剧详情（含集列表，供按 index 对齐）。
class SourceMatch {
  const SourceMatch({
    required this.sourceId,
    required this.sourceLabel,
    required this.drama,
    required this.detail,
  });

  final String sourceId;
  final String sourceLabel;
  final Drama drama;
  final DramaDetail detail;

  /// 按集号对齐：同 index 的集优先，越界时取最后一集（短剧集数大体一致，
  /// 缺集宁可给能播的最后一集也不直接失败——是否可播由取址层再判断）。
  Episode? episodeAt(int index) {
    for (final episode in detail.episodes) {
      if (episode.index == index) return episode;
    }
    return detail.episodes.isEmpty ? null : detail.episodes.last;
  }
}

/// 解析器依赖的最小门面：RoutingCatalogRepository 已天然实现，
/// 收窄成接口是为了让测试可以用假门面（不必搭真 CatalogClient）。
abstract interface class SourceSearchFacade {
  /// 当前启用的来源（顺序即注册表顺序）。
  List<SourceAdapter> get sources;

  /// 按源搜索。
  Future<CatalogPage> searchFrom(String sourceId, String query, {String? cursor});

  /// 详情（ID 自带来源前缀）。
  Future<DramaDetail> detail(String id);
}

/// 跨源同名解析：在其它启用源里搜同名片，供「详情页切换片源」与
/// 「播放失败自动选源」共用。
///
/// 顺序即优先级（红果永远不在候选里——它总是当前正要回退的那一个）。
/// 每个源：search → 标题匹配（精确 > 包含）→ detail；任何一步失败或
/// 超出 [budget] 就跳到下一个源，全部失败返回 null。解析本身不判断
/// 集是否可播——locked/beyondFree 由调用方结合标记策略决定要不要先试。
class SourceResolver {
  SourceResolver(this._catalog, {this.budget = const Duration(seconds: 8)});

  final SourceSearchFacade _catalog;
  final Duration budget;

  /// 当前剧 id 归属的来源（纯数字历史 id 视为红果；未知前缀也回红果）。
  String currentSourceId(String mediaId) {
    for (final adapter in _catalog.sources) {
      if (adapter.matches(mediaId)) return adapter.id;
    }
    return 'hongguo';
  }

  /// 备选来源：排除 [excludeId] 后仍启用的其它源，保持注册表顺序。
  List<({String id, String label})> alternatives(String excludeId) =>
      _candidates({excludeId});

  /// 按集合排除的候选源，供自动跨源防循环（已试过的源不再回切）。
  List<({String id, String label})> _candidates(Set<String> excluded) => [
    for (final adapter in _catalog.sources)
      if (!excluded.contains(adapter.id))
        (id: adapter.id, label: adapter.label),
  ];

  Future<SourceMatch?> resolve({
    required String title,
    required String excludeId,
    Set<String> excludeIds = const {},
    int? episodeIndex,
  }) async {
    final deadline = DateTime.now().add(budget);
    final query = title.trim();
    if (query.isEmpty) return null;
    // 精确命中跨源优先：先扫完全部候选找 exact；找不到才退回第一个
    // 「互相包含」的弱匹配。detail 取址延迟到确定返回哪个源之后。
    ({String id, String label, Drama drama})? weak;
    final excluded = <String>{excludeId, ...excludeIds};
    for (final candidate in _candidates(excluded)) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return null;
      try {
        final page = await _catalog
            .searchFrom(candidate.id, query)
            .timeout(remaining);
        final exact = page.items
            .where((item) => item.title.trim() == query)
            .firstOrNull;
        if (exact != null) {
          return await _detailOf(candidate, exact, episodeIndex, deadline);
        }
        weak ??= _weakMatch(page.items, query) == null
            ? null
            : (id: candidate.id, label: candidate.label, drama: _weakMatch(page.items, query)!);
      } on Object {
        // 单源失败不拖垮整体：静默进入下一个源，超预算即止。
        continue;
      }
    }
    if (weak == null) return null;
    return await _detailOf(
      (id: weak.id, label: weak.label),
      weak.drama,
      episodeIndex,
      deadline,
    );
  }

  Future<SourceMatch?> _detailOf(
    ({String id, String label}) candidate,
    Drama drama,
    int? episodeIndex,
    DateTime deadline,
  ) async {
    final detailLeft = deadline.difference(DateTime.now());
    if (detailLeft <= Duration.zero) return null;
    final detail = await _catalog.detail(drama.id).timeout(detailLeft);
    if (detail.episodes.isEmpty && episodeIndex != null) return null;
    return SourceMatch(
      sourceId: candidate.id,
      sourceLabel: candidate.label,
      drama: drama,
      detail: detail,
    );
  }

  /// 互相包含的弱匹配；同级取列表靠前者（搜索本身已排过序）。
  Drama? _weakMatch(List<Drama> items, String query) {
    for (final item in items) {
      final candidate = item.title.trim();
      if (candidate.contains(query) || query.contains(candidate)) return item;
    }
    return null;
  }
}

/// 把 [SourceException] 家族翻译成用户可读的一句话，供 toast/失败卡片共用。
String sourceFailureHint(Object error, int triedSources) {
  final prefix = triedSources > 1 ? '已在 $triedSources 个来源尝试，' : '';
  if (error is SourceUnavailable) return '$prefix该来源暂不可用，稍后再试。';
  if (error is SourceLocked) return '$prefix这一集在该来源需要付费或鉴权。';
  if (error is SourceRejected) return '$prefix该来源拒绝了这次取址请求。';
  return '$prefix取源失败，请稍后重试。';
}
