import 'package:dio/dio.dart';
import 'package:hongguo_core/hongguo_core.dart';

import '../catalog.dart';
import '../source_adapter.dart';
import '../video_model_client.dart';
import 'hema_adapter.dart';
import 'hongguo_adapter.dart';
import 'xifan_adapter.dart';

export 'hema_adapter.dart';
export 'hongguo_adapter.dart';
export 'xifan_adapter.dart';

/// 默认注册表清单。新增一个源 = 在这里加一行工厂，取址路由/来源枚举/
/// 设置项/错误文案全部自动生效，不改任何 if/else。
///
/// 用 `Function()` 提供器而非实例：SourceRegistry 每次调用 factory 都会
/// 生成适配器，客户端可能在设置变更后重建，提供器保证拿到当前实例。
List<SourceAdapter Function(SourceSettings)> defaultSourceFactories({
  required CatalogClient Function() catalog,
  required VideoModelClient Function() model,
  required Dio Function() dio,
}) {
  return [
    (settings) => HongguoAdapter(catalog(), model()),
    (settings) => XifanAdapter(dio()),
    (settings) => HemaAdapter(dio()),
    // 将来加源：在这里加一行工厂即可，取址路由/来源枚举自动生效。
  ];
}
