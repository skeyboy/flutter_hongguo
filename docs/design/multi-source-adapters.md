# 多源适配器「自动接入」方案（西饭 / 河马 / DramaBox / ReelShort / 自定义源）

> 承接 [8.0 后端分析](../analysis/2026-11-23_hongguo-drama-API后端分析.md) §6「未覆盖」：参考项目支持红果之外的四源与苹果 CMS 自定义源，当前工程仍是单源红果。
> 本文是**分析与方案**，不是实施记录。参考实现位于 `C:\Users\lee\WorkBuddy\spaces\2026_11_23_18-01-38\hongguo-drama-ref`（GPL-3.0，来源链见 NOTICE.md）。
> 核心命题：参考实现的分派是**硬编码 if/else**，新增一个源要改主进程 + 取址 + UI 三处；本方案要的是**注册即接入**——新增源只落地一个适配器文件并注册一次，取址路由、来源列表、设置项与失败文案自动获得。

## 0. 结论先行

| 问题 | 结论 |
|---|---|
| 参考项目是怎么做多源的 | 5 个独立适配器模块 + 统一 5 方法接口 + `source:` ID 命名空间 + settings 开关枚举；**分派靠前缀 if/else** |
| 当前工程能不能直接接 | 不能。三处硬编码单源假设：`detail`/`fetchTrack` 只收 `^\d{1,30}$`、下载层白名单只有 `fromWeb` 布尔开关、没有 registry |
| 「自动加入」的落点 | 引入 `SourceAdapter` 契约 + `SourceRegistry`（前缀→适配器）+ 路由门面；上层只认 `CatalogRepository` / `VideoTrack`，零改动 |
| 六个源的接入顺序 | 红果迁移为适配基准 → 西饭/河马（国内明文 MP4，最易验证）→ DramaBox/ReelShort（海外，含 HLS 待评估）→ 苹果 CMS 自定义源（运行时 CRUD） |
| 最大风险 | HLS 播放通道缺失、自定义源 SSRF、GPL/NOTICE 合规、真网不可在本环境验证 |

---

## 1. 参考实现的多源机制拆解（真正要学的东西）

### 1.1 统一适配器接口

`xifan.js` / `hema.js` / `dramabox.js` / `reelshort.js` / `custom-source.js` 是平级模块，导出几乎相同的形状：

| 方法 | 返回 | 语义 |
|---|---|---|
| `browseList(options)` | `{success, results[], page, hasMore, nextPage, genres[], pageTitle, sourceUrl}` | 分类浏览；结果已归一为 `series_id/title/cover/episode_count/tags/source` |
| `search(keyword, page, options)` | 同上 | 搜索 |
| `fetchEpisodeList(seriesId)` | `{series_id, series_title, cover, total, episodes[{vid, vid_index, title, locked, source}], source}` | 分集目录 |
| `fetchPlayUrlSingle(vid, sid, options)` | `{url, source, locked, error, format, spadeA, codec, userAgent, referer, candidates?}` | 取址 |
| （可选）`resolveSeriesId` / `mediaRequestOptions` / `testCustomSource` / `validateSource` | — | 分享链接解析、逐跳网络策略、自定义源连通性测试 |

**关键**：4 个海外/第三方源全部返回 `spadeA: null, codec: ''` —— 明文 MP4/M3U8，不进 CENC 解密；`locked:true` 时**不给地址**，提示去官方平台确认可看范围（不绕过付费/CDN 鉴权）。这是必须保留的语义。

### 1.2 ID 命名空间是整个机制的骨架

| 源 | 剧集 ID | 分集 ID |
|---|---|---|
| 红果 | 纯数字 `series_id` / `vid` | 纯数字 |
| 西饭 | `xifan:{source}:{duanjuId}` | `xifan:{source}:{duanjuId}:{episodeId}` |
| 河马 | `hema:{bookId}` | `hema:{bookId}:{chapterId}` |
| DramaBox | `dramabox:{bookId}` | `dramabox:{bookId}:{chapterId}` |
| ReelShort | `reelshort:{bookId}:{slug}` | `reelshort:{bookId}:{slug}:{number}:{chapterId}` |
| 自定义 | `custom:{uuid}:{vodId}` | `custom:{uuid}:{vodId}:{line}:{episode}` |

`sourceOf(id)` 从前缀反推来源；取址时再用前缀二次校验「这个 vid 确实属于当前 sid」。**ID 自带路由信息**，因此分派无需额外参数透传。

### 1.3 来源开关枚举

```js
BUILTIN_SOURCES = [hongguo, xifan, hema, reelshort, dramabox]
getMediaSources(settings)
  = 内置源按 settings.builtin_sources[id] 过滤
  + settings.custom_sources.filter(enabled).map(id => `custom:${id}`)
```
语义：红果固定开启不可关；西饭/河马默认开（`!== false`）；ReelShort/DramaBox 海外默认关（`=== true` 才开）；自定义源逐条 `enabled`。UI 的来源列表由此函数派生，不写死。

### 1.4 安全边界（比当前工程严格，必须一起移植）

- `web-media-guard.js`：`isPublicMediaUrl` 拒绝私网/回环/`198.18.0.0/15` 假 IP/带凭据 URL；`webMediaRequestOptions` 对**每一跳重定向**重新校验目标并在 HTTPS 上 pin 源，防 VPN Fake-IP 与 DNS rebinding。
- `custom-source.js`：UUID + URL 白名单校验；每次请求 `assertEnabled` 复查启用态与配置是否变更；`cancelRequests` 按源撤销在途请求；错误文案不回传含签名 URL 的远端异常。

### 1.5 参考实现的问题（本方案要改进的点）

分派是**三处硬编码 if/else 链**：`main.js` 的 `browse-list` 用三元选 `moduleName`、`hongguo.js:538-542` 与 `:736-740` 用 `startsWith` 逐个转给适配器、`main.js:1651-1655` 搜索再写一遍。新增源 = 至少改三处，且漏改一处就静默走红果、极难查。这正是「自动加入」要消灭的东西。

---

## 2. 当前工程的可用面与阻塞点

### 2.1 可直接复用（不要重写）

| 现状 | 位置 | 复用方式 |
|---|---|---|
| `CatalogRepository` 契约 + `is` 能力接口 | `api/lib/src/catalog.dart:269` / `:287`、`ranking.dart:76` | 新源实现同一契约；`FilteredCatalogRepository`/`RankCatalogRepository` 仍是红果专属能力，调用方已用 `is` 门控 |
| 数据归一化边界 | `Drama.fromJson` / `Episode` / `DramaDetail` / `CatalogPage` | 适配器把各源 JSON 归一到这几个类，App 层无感 |
| 明文直链已跑通 | `VideoTrack.fromWeb`、`media_cache.dart:593` | 官网明文 MP4 已能下载播放，第三方明文 MP4 复用同一条路 |
| UA / Referer 已建模 | `VideoTrack.userAgent` / `.referer` | 海外源逐源填 UA/Referer，无需改下载层 |
| 契约优先装配 | `runtime_native.dart:294 _rebuildClients` | 路由门面在这里装配一次，设置变更时随客户端重建 |
| 设置持久化 | `AppSettings.toJson/fromJson/copyWith/validate` + `settings_store` | 新增来源配置字段沿用同一事务 |

### 2.2 三处必须改的硬编码

1. **`catalog.dart:889` `_detail`**：`RegExp(r'^\d{1,30}$')` 拒绝所有带前缀 ID → 改为委托 registry 的 `forId()`。
2. **`video_model_client.dart:439` `_fetchTrack`**：同样只收纯数字 vid → `VideoModelClient` 退为「红果适配器」，路由在其外层。
3. **`media_url.dart` / `media_cache.dart:593`**：白名单是 `track.fromWeb ? webMediaDomains : appMediaDomains` 的固定域名表；任意第三方/自定义源主机都会被 `MediaUrlDecoder.checked` 判非法 → 改为**逐轨策略**（见 §3.5）。

### 2.3 缺失项

- `VideoTrack` 没有 `source` / `format`（mp4|hls）/ `candidates`（自定义源多线路）；`Episode` 没有 `locked`。
- 没有来源注册表，也没有来源开关/自定义源配置模型。
- **没有 HLS 播放通道**：`media_cache` 下载成 mp4、渐进解密吃 CENC 分片；ReelShort 和自定义源会返回 `m3u8`。这是 P2 的硬门槛，不可假装不存在。

---

## 3. 目标架构：注册即接入

```
                         ┌──────────────── App 层（零改动）────────────────┐
                         │ CatalogRepository / AppRuntime.prepare(vid)      │
                         └───────────────────┬─────────────────────────────┘
                                             │ 单一门面
                         ┌───────────────────▼─────────────────────────────┐
                         │ RoutingCatalog / RoutingVideoResolver            │
                         │   source = sourceOf(id) → registry.forId(id)     │
                         └───────────────────┬─────────────────────────────┘
        ┌────────────────────────────────────┼────────────────────────────────────┐
        │                        SourceRegistry（前缀→适配器，启用态枚举）        │
        └──┬──────────┬──────────┬──────────┬──────────┬──────────────────────────┘
    ┌──────▼───┐ ┌────▼────┐ ┌───▼────┐ ┌───▼────────┐ ┌────▼──────────┐
    │ Hongguo  │ │  Xifan  │ │  Hema  │ │ DramaBox / │ │ CustomSource  │
    │ Adapter  │ │ Adapter │ │Adapter │ │ ReelShort  │ │ Adapter(uuid) │  ← 新增源=加一个文件
    │(旧 Client│ │         │ │        │ │  Adapter   │ │ 运行时按配置生成│
    │  包装)   │ │         │ │        │ │            │ │               │
    └────┬─────┘ └────┬────┘ └───┬────┘ └─────┬──────┘ └──────┬────────┘
         │            │          │            │               │
    六头签名+v5    明文MP4     明文MP4    明文MP4/HLS     苹果CMS 多线路
    +CENC解密      +公网guard  +公网guard  +UA/Referer   +assertEnabled+candidates
```

### 3.1 `SourceAdapter` 契约（`packages/api/lib/src/source_adapter.dart`，新增）

```dart
enum SourceKind { builtin, custom }

abstract interface class SourceAdapter {
  String get id;                       // hongguo/xifan/hema/reelshort/dramabox/custom
  String get label;
  SourceKind get kind;
  bool matches(String mediaId);        // 前缀判定；hongguo 匹配纯数字
  bool enabled(SourceSettings settings);

  Future<CatalogPage> browse({
    String genre = '', String? cursor, String? sort,
  });
  Future<CatalogPage> search(String query, {String? cursor});
  Future<DramaDetail> detail(String seriesId);
  Future<VideoTrack> fetchTrack(String mediaId, {String quality = 'best'});

  // 可选能力用独立接口 + is 门控，沿用 FilteredCatalogRepository 的既有模式：
  // SourceBrowseCapability / SourceShareLinkCapability / SourceTestCapability
}
```

每个适配器的**职责边界**：只做「本源协议 → 统一数据类」的归一和本源安全校验；不碰 UI、不碰缓存、不碰别的源。

### 3.2 `SourceRegistry`（`source_adapter.dart` 同文件或 `source_registry.dart`）

```dart
class SourceRegistry {
  SourceRegistry(this.adapters, this.settings);
  final List<SourceAdapter Function(SourceSettings)> adapters; // custom 源按配置动态生成
  final SourceSettings settings;

  SourceAdapter? forId(String id) =>                 // 路由核心
      adapters.map((f) => f(settings)).firstWhere((a) => a.enabled(settings) && a.matches(id));
  List<SourceAdapter> get enabled =>                 // UI 来源列表
      adapters.map((f) => f(settings)).where((a) => a.enabled(settings)).toList();

  String sourceOf(String id) => forId(id)?.id ?? 'hongguo'; // 兼容历史纯数字数据
}
```

- 红果是 `hongguo` 适配器，内部包装现有 `CatalogClient` + `VideoModelClient`，行为字节级不变（保住现有 191/187 项 api 测试）。
- 自定义源不是固定实例，而是 `custom` 工厂按 `settings.customSources` 里每条启用配置生成 `custom:{uuid}` 适配器——**这就是运行时「自动加入」**。
- 新源接入只需：① 新增 `src/sources/<id>_adapter.dart` 实现契约；② 在 `sources.dart` 的注册表清单加一行。取址路由、来源枚举、设置项、错误文案全部自动生效。

### 3.3 路由门面（上层零改动的关键）

```dart
class RoutingCatalogRepository implements CatalogRepository {
  RoutingCatalogRepository(this.registry, this.primary); // primary = hongguo
  Future<CatalogPage> search(String q, {String? cursor}) async {
    // 默认：对 enabled 源并发扇出 + 统一 deadline + 按剧名+源 去重，来源标签随 Drama 返回；
    // 保留 primary 兜底。后续 UI 加来源 Tab 时可直接切为单源查询，门面不变。
  }
  Future<DramaDetail> detail(String id) => registry.forId(id)!.detail(id);
  // browse/themes 按当前派生的来源列表聚合；hongguo 独有的 Filtered/Rank 能力仍由 is 门控。
}
```
`runtime_native.dart:_rebuildClients` 用门面替换直接 `new CatalogClient`；`prepare(vid)` 在解析阶段用 `registry.forId(vid).fetchTrack(...)`，之后仍走既有 `media_cache` / 解密 / 播放链路。

### 3.4 数据模型的最小扩展（向后兼容，默认值保持红果行为）

| 类 | 新增字段 | 默认 | 用途 |
|---|---|---|---|
| `VideoTrack` | `String source` | `'hongguo'` | 归属源，缓存键命名空间、诊断 |
| `VideoTrack` | `VideoFormat format` | `mp4` | `hls` 时走 HLS 通道（P2） |
| `VideoTrack` | `List<VideoTrack>? candidates` | `null` | 自定义源多线路候选 |
| `VideoTrack` | `MediaUrlPolicy? policy` | `null` | 逐轨白名单/公网校验策略（§3.5） |
| `Episode` | `bool locked` | `false` | 选集页显示「当前来源不可播」 |

缓存文件命名把 `vid` 里的 `:` 做安全转义（`mediaPath` 现在直接拼 `${vid}_$quality.mp4`，带前缀的 ID 会产生非法/歧义文件名）——这是 ID 命名空间引入后**必须同步修**的隐藏点。

### 3.5 逐轨媒体安全策略（替代 `fromWeb` 布尔）

```dart
sealed class MediaUrlPolicy { ... }
class DomainAllowlistPolicy implements MediaUrlPolicy {   // hongguo：app/web 域名表
  const DomainAllowlistPolicy(this.domains);
}
class PublicWebPolicy implements MediaUrlPolicy {          // 第三方/自定义：公网校验 + 逐源主机集
  const PublicWebPolicy({this.hosts});
}
```
- `MediaUrlDecoder.checked` 前先过统一 `isPublicMediaUrl`：https、无凭据、非私网/回环/`198.18/15` 假 IP；再按 policy 做域名族或逐源主机校验。
- 下载层逐跳重定向**复用现有 302 跟随循环**（`media_cache._downloadFollowingRedirects`），在每一跳插入同一校验，等价于参考的 `beforeRedirect`；不要用「先探测后连接」的 TOCTOU 写法。

### 3.6 来源配置模型（`core` 的 `AppSettings` 扩展 + `settings_store` 持久化）

```dart
class SourceSettings {
  final Map<String, bool> builtin;      // hongguo 恒 true；xifan/hema 默认 true；海外默认 false
  final List<CustomSource> customSources; // {uuid, name, url, enabled}
}
```
- 默认值严格对齐参考：红果不可关、西饭/河马默认开、ReelShort/DramaBox 默认关。
- `validate()` 沿用现有风格：UUID 格式、URL 长度/协议、名称长度；拒绝私网与带凭据地址。
- 设置页新增「片源」分区：内置源开关列表 + 自定义源 CRUD + 「测试连接」按钮（调 `testCustomSource`），列表项从 `registry.enabled` 派生。

---

## 4. 契约优先：先定义、再编码

1. `docs/contracts/source-adapter.md`：`SourceAdapter` / `SourceRegistry` / `SourceSettings` / `SourceQuery` 的 Dart 签名、返回结构、错误分类（`SourceLocked` / `SourceUnavailable` / `SourceRejected`）。
2. `docs/contracts/source-id.md`：六个前缀的 ID 语法、解析/校验规则、跨源去重键。
3. `docs/contracts/media-url-policy.md`：`isPublicMediaUrl` 的 Dart 版判定表与逐跳校验时机。
4. 三份契约评审通过后，各阶段按不重叠目录分发子 Agent：`packages/api/lib/src/sources/*`（适配器）、`packages/core/lib/src/config/*`（配置）、`packages/app/lib/features/*`（设置 UI）互不重叠。

---

## 5. 分阶段落地与门禁

| 阶段 | 内容 | 完成判据 | 门禁 |
|---|---|---|---|
| **P0 骨架** | `SourceAdapter`/`SourceRegistry`/路由门面/`SourceSettings`；红果迁移为适配器；数据类扩展默认值；`mediaPath` 转义修复 | 只跑红果，行为与现状一致 | 全量 `dart test`（core/api/cast/update/app/tv）绿；无新增 analyze 告警 |
| **P1 国内明文源** | 西饭 + 河马：portalPage/aggregation、__NEXT_DATA__ 详情、明文 MP4 取址、`locked` 文案、公网 guard | 两源可浏览/搜索/选集/取址；锁集给明确文案不绕过 | 离线 fixture 测试 + `dart test`；真网探测脚本另跑 |
| **P2 海外源** | DramaBox + ReelShort：英文 SSR、`resolveSeriesId`、UA/Referer、`format`；**先评估 HLS 通道** | 未解锁集明确提示；m3u8 不静默失败 | HLS 评估结论落地为设计文档；无 HLS 能力则仅开放 mp4 集并在 UI 标注 |
| **P3 自定义源** | 苹果 CMS：`validateSource`/`testCustomSource`/`assertEnabled`/`cancelRequests`/多线路 candidates | 粘贴 URL→测试→保存→立即可搜（运行时自动加入） | SSRF 用例（私网/回环/Fake-IP/凭据 URL）全部拒绝；配置热变更时撤销在途请求 |
| **P4 收口** | 设置页「片源」分区、来源标签、错误文案按 code 分派、NOTICE/文档 | UI 来源列表与开关由 registry 派生 | 真实 `flutter build`（跨 flavor）+ widget 测试 + 文档索引更新 |

**验证命令（沿用工程既有方式）**：各包 `fvm dart test` / `fvm flutter test`；根 `tool/verify_all.sh`。本环境是 Windows + W: SMB，`dart analyze` 曾出现启动即 SIGTERM，以测试编译替代；**真网取址一律显式探测，离线测试不能替代**。

---

## 6. 风险、边界与合规（诚实披露）

| 项 | 说明 | 处置 |
|---|---|---|
| HLS | 当前无 HLS 播放/下载通道；ReelShort 与自定义源可返回 m3u8 | P2 先出评估；未落地前只开放 mp4 集，m3u8 明确标注「暂不支持」，不得当作已支持 |
| 付费/锁集 | 参考实现对 `locked` 集直接拒给地址 | 保留；不做解锁、不绕过鉴权，文案引导官方平台 |
| 自定义源 SSRF | 用户可控 URL 是最强攻击面 | 公网 IP 校验 + 逐跳重定向校验 + 禁凭据 + 配置变更撤销；单测覆盖 |
| GPL-3.0 | 适配器思路与可能的常量来自 GPL 项目（DramaBox/ReelShort 又源自 MIT 项目） | 只移植协议行为、不复制 GPL 签名密钥；更新 NOTICE.md 来源链；自定义源协议为公开苹果 CMS 规范 |
| 搜索口径 | 多源扇出会带来排序/去重/时长预算差异，官网翻页语义也不同 | 默认扇出 + 来源标签；翻页游标内嵌 source，避免混源重复（参考项目自己的教训） |
| 环境 | 本轮为只读分析，未做任何代码改动；未做真网验证 | 所有「可用」判断都来自代码与参考实现，不代表上游当前可达 |

---

## 7. 下一步

若确认方向：先写 §4 三份契约文档并评审；评审通过后从 P0 开始按不重叠目录分发实施，每阶段跑全量测试门禁再进入下一阶段。
