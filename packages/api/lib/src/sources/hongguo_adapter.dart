import 'package:hongguo_core/hongguo_core.dart';

import '../catalog.dart';
import '../source_adapter.dart';
import '../video_model_client.dart';

/// 红果薄包装：只把现有客户端归一到 SourceAdapter，不改任何旧行为。
/// 签名/排序/错误类型/官网层优先级全部沿用 CatalogClient + VideoModelClient。
class HongguoAdapter implements SourceAdapter {
  HongguoAdapter(this.catalog, this.model);

  final CatalogClient catalog;
  final VideoModelClient model;

  @override
  String get id => 'hongguo';

  @override
  String get label => '红果';

  @override
  SourceKind get kind => SourceKind.builtin;

  @override
  bool matches(String mediaId) => RegExp(r'^\d{1,30}$').hasMatch(mediaId);

  @override
  bool enabled(SourceSettings settings) => true; // 红果恒启用，validate 强制不可关

  @override
  Future<CatalogPage> browse({
    String genre = '',
    String? cursor,
    String? sort,
  }) {
    // 接口默认空串表示「用本源默认」，映射到旧客户端的 short_play 保持字节级一致。
    return catalog.browse(
      genre: genre.isEmpty ? 'short_play' : genre,
      sort: sort ?? 'online_time',
      cursor: cursor,
    );
  }

  @override
  Future<CatalogPage> search(String query, {String? cursor}) =>
      catalog.search(query, cursor: cursor);

  @override
  Future<DramaDetail> detail(String seriesId) => catalog.detail(seriesId);

  @override
  Future<VideoTrack> fetchTrack(String mediaId, {String quality = 'best'}) =>
      // preferApp=false 是旧客户端默认；VideoTrack.source 默认已是 hongguo，
      // 无需重建对象，保持 191 项红果测试行为不变。
      model.fetchTrack(mediaId, quality: quality, preferApp: false);
}
