import 'package:hongguo_core/hongguo_core.dart';

import '../catalog.dart';
import '../source_adapter.dart';
import '../video_model_client.dart';
import 'hongguo_adapter.dart';

export 'hongguo_adapter.dart';

/// 默认注册表清单。新增一个源 = 在这里加一行工厂，取址路由/来源枚举/
/// 设置项/错误文案全部自动生效，不改任何 if/else。
///
/// 用 `Function()` 提供器而非实例：SourceRegistry 每次调用 factory 都会
/// 生成适配器，客户端可能在设置变更后重建，提供器保证拿到当前实例。
List<SourceAdapter Function(SourceSettings)> defaultSourceFactories({
  required CatalogClient Function() catalog,
  required VideoModelClient Function() model,
}) {
  return [
    (settings) => HongguoAdapter(catalog(), model()),
    // 将来加源，例如：(settings) => XifanAdapter(catalog(), model(), settings),
  ];
}
