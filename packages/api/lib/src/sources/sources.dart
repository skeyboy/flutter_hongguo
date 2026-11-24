import 'package:dio/dio.dart';
import 'package:hongguo_core/hongguo_core.dart';

import '../catalog.dart';
import '../source_adapter.dart';
import '../video_model_client.dart';
import 'custom_source_adapter.dart';
import 'dramabox_adapter.dart';
import 'hema_adapter.dart';
import 'hongguo_adapter.dart';
import 'reelshort_adapter.dart';
import 'xifan_adapter.dart';

export 'custom_source_adapter.dart';
export 'dramabox_adapter.dart';
export 'hema_adapter.dart';
export 'hongguo_adapter.dart';
export 'reelshort_adapter.dart';
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
    // 海外源默认关（SourceSettings.builtin），enabled() 内门控，注册但不主动查询。
    (settings) => DramaboxAdapter(dio()),
    (settings) => ReelshortAdapter(dio()),
    // 将来加源：在这里加一行工厂即可，取址路由/来源枚举自动生效。
  ];
}

/// 自定义源的动态工厂：每条启用的配置生成一个 `custom:{uuid}` 适配器。
/// 这是「运行时自动加入」的落点——加一条配置即刻可搜、可取址，不改代码。
///
/// [currentSources] 提供当前设置，让适配器每次请求都能复查配置是否变更/删除
/// （等价参考 assertEnabled）；[tokens] 供配置变更时撤销在途请求。
List<SourceAdapter> customSourceAdapters({
  required Dio Function() dio,
  required List<CustomSourceConfig> Function() currentSources,
  CancelTokenRegistry? tokens,
}) {
  final registry = tokens ?? CancelTokenRegistry();
  final byUuid = <String, CustomSourceConfig>{
    for (final config in currentSources())
      if (config.enabled) config.uuid: config,
  };
  return [
    for (final entry in byUuid.entries)
      CustomSourceAdapter(
        uuid: entry.key,
        dio: dio(),
        initial: entry.value,
        configOf: () {
          final current = currentSources();
          for (final config in current) {
            if (config.uuid == entry.key) return config;
          }
          return null; // 已删除 → 适配器下次请求会拒绝。
        },
        tokens: registry,
      ),
  ];
}
