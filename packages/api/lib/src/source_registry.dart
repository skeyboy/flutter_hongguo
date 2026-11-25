import 'package:hongguo_core/hongguo_core.dart';

import 'source_adapter.dart';
// 带前缀调用，避免与本类的 sourceOf 方法同名导致递归。
import 'source_id.dart' as source_ids;

/// 注册即接入：新增一个源 = 新增 adapter 文件 + 在 sources.dart 清单加一行工厂。
///
/// 两类工厂：
/// - [factories]：一个工厂产出一个适配器（内置源，固定数量）。
/// - [expansiveFactories]：一个工厂按配置产出多个适配器（custom 源，
///   每条启用的自定义源配置生成一个 `custom:{uuid}` 适配器——运行时自动加入）。
class SourceRegistry {
  SourceRegistry(
    this.factories,
    this.settings, {
    this.expansiveFactories = const [],
  });

  final List<SourceAdapter Function(SourceSettings)> factories;

  /// 按配置动态生成多个适配器（custom 源）。每次读取都重新求值，
  /// 设置变更重建注册表后自动生效。
  final List<List<SourceAdapter> Function(SourceSettings)> expansiveFactories;

  final SourceSettings settings;

  /// 当前生效的全部适配器（内置 + 动态 custom）。
  List<SourceAdapter> get _all {
    final result = <SourceAdapter>[
      for (final factory in factories) factory(settings),
      for (final factory in expansiveFactories) ...factory(settings),
    ];
    return result;
  }

  /// 路由核心：只返回「已启用且匹配」的第一个适配器。
  /// matches 本身已按 source-id §4 用前缀精确判定，无需再做 sourceOf 快筛。
  /// 未命中返回 null，由门面对历史纯数字 ID 兜底 hongguo。
  SourceAdapter? forId(String id) {
    for (final adapter in _all) {
      if (adapter.enabled(settings) && adapter.matches(id)) return adapter;
    }
    return null;
  }

  /// 按来源 ID 取已启用的适配器（custom 源用完整 `custom:{uuid}`）。
  /// 与 [forId] 的区别：这里按来源标识查，不要求传入一个真实媒体 ID。
  /// 设置页来源列表与「按源查询」入口共用。
  SourceAdapter? forSource(String sourceId) {
    for (final adapter in _all) {
      if (adapter.enabled(settings) &&
          (adapter.id == sourceId || adapter.id.startsWith('$sourceId:'))) {
        return adapter;
      }
    }
    return null;
  }

  /// UI 来源列表的数据源：按 enabled 过滤，顺序稳定。
  List<SourceAdapter> get enabled => _all
      .where((adapter) => adapter.enabled(settings))
      .toList(growable: false);

  /// 从 ID 反推源 ID。custom 命中启用的适配器时返回完整 `custom:{uuid}`；
  /// 否则退回通用前缀判定（未知/历史脏数据 → hongguo），不抛异常。
  String sourceOf(String id) => forId(id)?.id ?? source_ids.sourceOf(id);
}
