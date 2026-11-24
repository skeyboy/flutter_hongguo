import 'package:hongguo_core/hongguo_core.dart';

import 'catalog.dart';
import 'media_url_policy.dart';
import 'source_id.dart';
import 'video_model_client.dart';

// SourceKind 与错误层级定义在 source_id.dart（单一定义），这里统一对外暴露，
// 让「契约 §1/§5 的类型都在 source_adapter.dart」这一约定仍然成立。
export 'source_id.dart'
    show
        SourceKind,
        SourceException,
        SourceLocked,
        SourceRejected,
        SourceUnavailable;

/// 一个来源的协议边界：只做「本源协议 → 统一数据类」的归一 + 本源安全校验。
/// 不碰 UI、不碰缓存、不碰其它源。
abstract interface class SourceAdapter {
  /// 稳定标识：hongguo / xifan / ... / custom:{uuid}
  String get id;

  /// 设置页展示名（中文）
  String get label;

  SourceKind get kind;

  /// 该 ID 是否归属本源。hongguo 匹配纯数字；其余匹配自身前缀。
  bool matches(String mediaId);

  /// 依据当前设置判断是否启用。hongguo 恒 true；其余按 SourceSettings。
  bool enabled(SourceSettings settings);

  Future<CatalogPage> browse({String genre = '', String? cursor, String? sort});

  Future<CatalogPage> search(String query, {String? cursor});

  Future<DramaDetail> detail(String seriesId);

  /// 取址。返回的 VideoTrack 其 source/format/policy 由适配器填好。
  /// 锁集抛 [SourceLocked]；上游不可用抛 [SourceUnavailable]；
  /// 参数/配置非法抛 [SourceRejected]。
  Future<VideoTrack> fetchTrack(String mediaId, {String quality = 'best'});
}

/// 能解析本源分享链接 → seriesId。分享落地页用。
abstract interface class SourceShareLinkCapability {
  Future<String?> resolveSeriesId(String url);
}

/// 逐源的网络请求策略（UA / Referer / 每跳重定向校验钩子）。
/// 返回给下载层，避免把网络策略散落在适配器里。
abstract interface class SourceNetworkCapability {
  MediaUrlPolicy get policy;

  ({String? userAgent, String? referer}) headersFor(Uri url);
}

/// 自定义源连通性测试（P3）。契约未给字段，先建最小骨架，后续按需扩展。
class SourceTestResult {
  const SourceTestResult({required this.ok, this.message = ''});

  final bool ok;
  final String message;
}

abstract interface class SourceTestCapability {
  Future<SourceTestResult> test();
}
