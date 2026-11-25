import 'dart:core';

import 'package:hongguo_core/hongguo_core.dart';

/// 逐轨媒体 URL 安全策略。替代全局白名单布尔开关：第三方源主机不固定，
/// 必须在每一跳重定向复用同一策略（见契约 §3）。
sealed class MediaUrlPolicy {
  const MediaUrlPolicy();
}

/// 红果：app/web 域名表，走现有 MediaUrlDecoder.checked，字节级不变。
class DomainAllowlistPolicy extends MediaUrlPolicy {
  const DomainAllowlistPolicy(this.domains);

  final List<String> domains;
}

/// 第三方/自定义源：公网校验 + 可选逐源主机集。
/// hosts == null 表示只做公网校验（上游主机列表可能动态）。
class PublicWebPolicy extends MediaUrlPolicy {
  const PublicWebPolicy({this.hosts, this.refererHost});

  /// 逐源主机族，如 ['xifan.tv', 'hema.tv']；后缀匹配按完整标签边界。
  final List<String>? hosts;

  /// 逐源 Referer 域名（可选，用于 header）。
  final String? refererHost;
}

/// 在 MediaUrlDecoder.checked 之前调用：先过公网判定，再按策略分派。
/// 非法抛 FormatException；返回校验后的 Uri。
Uri checkMediaUrl(String value, MediaUrlPolicy policy) {
  final uri = Uri.tryParse(value);
  if (uri == null) {
    throw const FormatException('Unsupported upstream URL');
  }

  // 公网判定是纯函数：挡私网字面量/凭据/非 https，不回传远端异常原文。
  final reason = isPublicMediaUrl(uri);
  if (reason != null) throw FormatException(reason);

  switch (policy) {
    case DomainAllowlistPolicy(:final domains):
      // 红果轨保持原路径与原文案，CENC 解密流程不受影响。
      return MediaUrlDecoder.checked(value, domains);

    case PublicWebPolicy(:final hosts):
      if (hosts != null &&
          !hosts.any((h) => uri.host == h || uri.host.endsWith('.$h'))) {
        throw const FormatException('Unsupported upstream URL');
      }
      return uri;
  }
}
