# 契约：SourceAdapter / SourceRegistry / SourceSettings

> 多源适配器「注册即接入」的**接口契约**。本契约先于任何实现落地；P0–P4 的代码必须与此签名一致。
> 上游方案与语义来源：[多源适配器方案](../design/multi-source-adapters.md)、[8.0 后端分析](../analysis/2026-11-23_hongguo-drama-API后端分析.md) §6。
> 参考实现：`C:\Users\lee\WorkBuddy\spaces\2026_11_23_18-01-38\hongguo-drama-ref`（GPL-3.0，仅移植协议行为，不复制签名密钥）。

## 0. 契约不变量（必须先读）

1. **上层零改动**：`App` 只依赖 `CatalogRepository` 与 `VideoTrack`；适配器/注册表/路由门面全部封装在 `packages/api`。
2. **红果字节级不变**：`HongguoAdapter` 内部包装现有 `CatalogClient` + `VideoModelClient`，默认开关、签名、错误类型、191 项 api 测试行为全部保持。
3. **ID 自带路由**：任何 `seriesId` / `vid` 都带来源前缀（红果为纯数字无前缀）；分派只靠 `SourceRegistry.forId(id)`，不得新增 if/else 链。
4. **能力用 `is` 门控**：可选能力（`FilteredCatalogRepository` 风格）用独立 interface，调用方 `is` 判断，不塞进核心契约。
5. **锁集不绕过**：任何源返回 `locked:true` 的分集，适配器抛 `SourceLocked`，不返回地址。

---

## 1. `SourceAdapter`（`packages/api/lib/src/source_adapter.dart`，新增）

```dart
enum SourceKind { builtin, custom }

/// 一个来源的协议边界：只做「本源协议 → 统一数据类」的归一 + 本源安全校验。
/// 不碰 UI、不碰缓存、不碰其它源。
abstract interface class SourceAdapter {
  /// 稳定标识：hongguo / xifan / hema / reelshort / dramabox / custom:{uuid}
  String get id;

  /// 设置页展示名（中文）
  String get label;

  SourceKind get kind;

  /// 该 ID 是否归属本源。hongguo 匹配纯数字；其余匹配自身前缀。
  bool matches(String mediaId);

  /// 依据当前设置判断是否启用。hongguo 恒 true；其余按 SourceSettings。
  bool enabled(SourceSettings settings);

  Future<CatalogPage> browse({
    String genre = '',
    String? cursor,
    String? sort,
  });

  Future<CatalogPage> search(String query, {String? cursor});

  Future<DramaDetail> detail(String seriesId);

  /// 取址。返回 [VideoTrack]（其 source/format/policy 已由适配器填好）。
  /// 锁集抛 [SourceLocked]；上游不可用抛 [SourceUnavailable]；
  /// 参数/配置非法抛 [SourceRejected]。
  Future<VideoTrack> fetchTrack(String mediaId, {String quality = 'best'});
}
```

### 1.1 可选能力接口（与核心契约分离，`is` 门控）

```dart
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

/// 自定义源连通性测试（P3）。
abstract interface class SourceTestCapability {
  Future<SourceTestResult> test();
}
```

> **不实现**可选能力的适配器不得在 UI 暴露对应入口；调用方一律先 `is`。

---

## 2. `SourceRegistry`（`packages/api/lib/src/source_registry.dart`，新增）

```dart
class SourceRegistry {
  /// 工厂列表：custom 源按配置动态生成，故不是固定实例列表。
  SourceRegistry(this.factories, this.settings);
  final List<SourceAdapter Function(SourceSettings)> factories;
  final SourceSettings settings;

  /// 路由核心。只返回「已启用且匹配」的第一个适配器。
  /// 未命中返回 null（由门面按历史纯数字数据兜底 hongguo）。
  SourceAdapter? forId(String id);

  /// UI 来源列表的数据源（按 enabled 过滤，顺序稳定）。
  List<SourceAdapter> get enabled;

  /// 从 ID 反推源 ID，兼容历史纯数字 → hongguo。
  String sourceOf(String id);
}
```

### 2.1 路由优先级

1. `forId` 遍历 `factories`，对每个 `factory(settings)` 检查 `enabled && matches`。
2. 命中多个时（不应发生）取注册表顺序第一个；ID 语法保证唯一。
3. 未命中 → `null`。门面层对历史纯数字 ID 兜底 `hongguo`。

### 2.2 自动加入的落点

新增一个源 = ① 新增 `src/sources/<id>_adapter.dart` 实现契约；② 在 `sources.dart` 的 `factories` 清单加一行。
取址路由、来源枚举、设置项、错误文案**全部自动生效**，不改 if/else。

custom 源是 `custom` 工厂按 `settings.customSources` 每条启用配置生成 `custom:{uuid}` 适配器——这是运行时「自动加入」的实现。

---

## 3. 路由门面

```dart
/// 替代 runtime_native.dart:_rebuildClients 里的直接 new CatalogClient。
class RoutingCatalogRepository implements CatalogRepository {
  RoutingCatalogRepository(this.registry, this.primary); // primary = hongguo adapter

  @override
  Future<CatalogPage> browse({...});   // 默认对 enabled 源并发扇出 + 统一 deadline + 去重
  @override
  Future<CatalogPage> search(String query, {String? cursor});
  @override
  Future<DramaDetail> detail(String id); // registry.forId(id)?.detail(id) ?? primary.detail(id)
  @override
  Future<List<CatalogFilter>> themes(String genre);
}

/// prepare(vid) 解析阶段用 registry.forId(vid).fetchTrack(...)
/// 之后仍走既有 media_cache / CENC 解密 / 播放链路，不变。
```

**扇出语义**：默认对 `registry.enabled` 并发查询（统一 deadline）、按「剧名 + 源」去重、来源标签随 `Drama` 返回；保留 primary 兜底。后续 UI 加来源 Tab 时可直接切为单源查询，**门面不变**。

---

## 4. `SourceSettings`（`packages/core/lib/src/config/app_settings.dart` 扩展）

```dart
class CustomSourceConfig {
  final String uuid;    // v4 格式
  final String name;    // 1–40 字
  final String url;     // https，无 userInfo，非私网/回环/Fake-IP
  final bool enabled;
  const CustomSourceConfig({...});
  Map<String, dynamic> toJson();
  factory CustomSourceConfig.fromJson(Map<String, dynamic> json);
}

class SourceSettings {
  /// 内置源开关。hongguo 恒 true（validate 强制）；
  /// xifan/hema 默认 true；reelshort/dramabox 默认 false。
  final Map<String, bool> builtin;
  final List<CustomSourceConfig> customSources;

  bool isEnabled(String sourceId);
  Map<String, dynamic> toJson();
  factory SourceSettings.fromJson(Map<String, dynamic> json);
  void validate(); // 沿用 AppSettings.validate 风格
}
```

### 4.1 默认值（严格对齐参考语义）

| 源 | 默认 | 可关闭 |
|---|---|---|
| hongguo | 开 | 否（固定） |
| xifan | 开 | 是 |
| hema | 开 | 是 |
| reelshort | 关 | 是 |
| dramabox | 关 | 是 |
| custom:{uuid} | 逐条 enabled | 是 |

`AppSettings` 新增字段 `SourceSettings sources`，纳入 `toJson/fromJson/copyWith/validate` 与 `settings_store` 持久化事务。

---

## 5. 错误分类（`packages/api/lib/src/source_adapter.dart`）

```dart
sealed class SourceException implements Exception {
  final String sourceId;
  final String message;
}

/// 锁集：当前来源不可播，引导官方平台。不绕过付费/CDN 鉴权。
class SourceLocked extends SourceException { ... }

/// 上游不可达 / 超时 / 解析失败。可重试，UI 显示「该片源暂时不可用」。
class SourceUnavailable extends SourceException { ... }

/// 参数 / 配置 / ID 非法（含私网 URL、坏 UUID、跨源 ID 不匹配）。不可重试。
class SourceRejected extends SourceException { ... }
```

| 场景 | 异常 | UI 文案 | 可重试 |
|---|---|---|---|
| `locked:true` 分集取址 | `SourceLocked` | 当前片源不可播，请到官方平台确认可看范围 | 否 |
| 上游 5xx / 超时 / 空包 | `SourceUnavailable` | 该片源暂时不可用 | 是 |
| 私网/带凭据 URL、坏 UUID、ID 前缀不符 | `SourceRejected` | 片源配置无效 | 否 |
| 未启用源被请求 | `SourceRejected` | 片源未启用 | 否 |

> 错误文案**不得回传含签名参数的远端异常原文**（与参考 `custom-source.js` 一致）。

---

## 6. 数据模型最小扩展（向后兼容，默认值 = 红果行为）

| 类 | 新增字段 | 默认 | 用途 |
|---|---|---|---|
| `VideoTrack` | `String source` | `'hongguo'` | 归属源，缓存键命名空间、诊断 |
| `VideoTrack` | `VideoFormat format` | `VideoFormat.mp4` | `hls` 走 HLS 通道（P2 评估前不开放） |
| `VideoTrack` | `List<VideoTrack>? candidates` | `null` | 自定义源多线路候选 |
| `VideoTrack` | `MediaUrlPolicy? policy` | `null` | 逐轨白名单/公网校验策略 |
| `Episode` | `bool locked` | `false` | 选集页「当前来源不可播」 |

**必须同步修的隐藏点**：`mediaPath` 现直接拼 `${vid}_$quality.mp4`；ID 前缀的 `:` 必须做安全转义（如 `:`→`_c_`、非 ASCII→hex），否则产生歧义/非法文件名。

---

## 7. 验收判据（P0 门禁）

- [ ] `SourceAdapter` / `SourceRegistry` / 门面 / `SourceSettings` 全部按此签名落地。
- [ ] `HongguoAdapter` 包装旧 Client，默认行为字节级不变。
- [ ] 全量 `dart test` 绿（core/api/cast/update/app/tv），无新增 analyze 告警。
- [ ] `registry.forId('123')` → hongguo；`forId('xifan:x:y')` → xifan（P1 起）。
- [ ] `mediaPath` 对 `custom:uuid:vod:1:2` 生成合法文件名，且不同 ID 不碰撞。
