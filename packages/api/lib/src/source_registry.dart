import 'package:hongguo_core/hongguo_core.dart';

import 'source_adapter.dart';
// 带前缀调用，避免与本类的 sourceOf 方法同名导致递归。
import 'source_id.dart' as source_ids;

/// 注册即接入：新增源 = 新增一个 adapter 文件 + 在 sources.dart 清单加一行工厂。
class SourceRegistry {
  SourceRegistry(this.factories, this.settings);

  /// custom 源按配置动态生成，故这里是工厂列表而非固定实例列表。
  final List<SourceAdapter Function(SourceSettings)> factories;
  final SourceSettings settings;

  /// 路由核心：只返回「已启用且匹配」的第一个适配器。
  /// matches 本身已按 source-id §4 用前缀精确判定，无需再做 sourceOf 快筛。
  /// 未命中返回 null，由门面对历史纯数字 ID 兜底 hongguo。
  SourceAdapter? forId(String id) {
    for (final factory in factories) {
      final adapter = factory(settings);
      if (adapter.enabled(settings) && adapter.matches(id)) return adapter;
    }
    return null;
  }

  /// 按来源 ID 取已启用的适配器（custom 源用完整 `custom:{uuid}`）。
  /// 与 [forId] 的区别：这里按来源标识查，不要求传入一个真实媒体 ID。
  /// 设置页来源列表与「按源查询」入口共用。
  SourceAdapter? forSource(String sourceId) {
    for (final factory in factories) {
      final adapter = factory(settings);
      if (adapter.enabled(settings) &&
          (adapter.id == sourceId || adapter.id.startsWith('$sourceId:'))) {
        return adapter;
      }
    }
    return null;
  }

  /// UI 来源列表的数据源：按 enabled 过滤，顺序与 factories 一致。
  List<SourceAdapter> get enabled => factories
      .map((factory) => factory(settings))
      .where((adapter) => adapter.enabled(settings))
      .toList(growable: false);

  /// 从 ID 反推源 ID。custom 命中启用的适配器时返回完整 `custom:{uuid}`；
  /// 否则退回通用前缀判定（未知/历史脏数据 → hongguo），不抛异常。
  String sourceOf(String id) => forId(id)?.id ?? source_ids.sourceOf(id);
}
