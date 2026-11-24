# 契约：Source ID 命名空间

> 六个来源的 ID 语法、解析/校验规则、跨源去重键。ID 自带路由信息，是「注册即接入」的骨架。
> 依赖：[SourceAdapter 契约](./source-adapter.md)。语义来源：[多源方案 §1.2](../design/multi-source-adapters.md)。

## 0. 铁律

1. **剧集 ID 与分集 ID 都带前缀**（红果例外：纯数字，无前缀，兼容历史数据）。
2. **`sourceOf(id)` 只靠前缀反推**，不靠额外参数透传；取址时用前缀二次校验「这个 vid 确实属于当前 sid」。
3. **ID 中的分隔符 `:` 不参与业务语义**：各源自定义段（slug、line 等）自身若含 `:`，必须在编码前转义。本契约统一以 `:` 为层级分隔符。
4. **未知前缀一律视为 hongguo**（兼容历史纯数字/脏数据），不抛异常——由适配器的 `matches` 决定，门面兜底。

---

## 1. 六个前缀的语法

| 源 | 剧集 ID (`seriesId`) | 分集 ID (`vid`) | 段含义 |
|---|---|---|---|
| 红果 | `{digits}` | `{digits}` | 1–30 位纯数字，历史数据无前缀 |
| 西饭 | `xifan:{source}:{duanjuId}` | `xifan:{source}:{duanjuId}:{episodeId}` | source=渠道号，duanjuId/episodeId=平台 ID |
| 河马 | `hema:{bookId}` | `hema:{bookId}:{chapterId}` | bookId/chapterId=平台 ID |
| DramaBox | `dramabox:{bookId}` | `dramabox:{bookId}:{chapterId}` | bookId/chapterId=平台 ID |
| ReelShort | `reelshort:{bookId}:{slug}` | `reelshort:{bookId}:{slug}:{number}:{chapterId}` | slug=英文短名，number=集序号，chapterId=平台 ID |
| 自定义 | `custom:{uuid}:{vodId}` | `custom:{uuid}:{vodId}:{line}:{episode}` | uuid=源 UUID，vodId/line/episode=苹果 CMS 字段 |

### 1.1 段约束

| 段 | 规则 |
|---|---|
| `{digits}` / `bookId` / `duanjuId` / `chapterId` / `episodeId` / `vodId` / `number` | `[A-Za-z0-9_-]+`；数字 ID 段必须可解析为正整数 |
| `{source}`（西饭渠道） | `[A-Za-z0-9_]+`，参考实现实测值 |
| `{slug}`（ReelShort） | `[a-z0-9-]+`（小写连字符） |
| `{uuid}`（自定义） | RFC 4122 v4：`xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx` |

> 若上游原始 ID 含契约外字符（如 `.`），由适配器在归一时做 percent-encode 或映射，不把原始字符透传进 ID。

---

## 2. 解析 API（`packages/api/lib/src/source_id.dart`，新增）

```dart
enum SourceKind { builtin, custom }

/// 解析结果。kind/id 由前缀得出；segments 为去掉前缀后的各段。
class ParsedSourceId {
  final String source;        // hongguo/xifan/hema/reelshort/dramabox/custom
  final List<String> segments; // 不含 source 前缀
  final bool isEpisode;       // 段数是否达到该源的分集形态
  const ParsedSourceId({...});
}

/// 从 ID 反推来源，未知前缀/纯数字 → 'hongguo'。永远不抛。
String sourceOf(String id);

/// 严格解析。不合法抛 SourceRejected（见 source-adapter 契约 §5）。
ParsedSourceId parseSourceId(String id);

/// 校验一个 vid 是否属于给定 sid（同来源 + 剧集段一致）。
/// 用于取址时二次校验，防止跨源 ID 混用。
bool belongsTo(String vid, String seriesId);

/// 缓存文件名安全转义：把 ID 里的 : 与非法字符映射为 [A-Za-z0-9_-]。
/// 必须保证单射（不同 ID → 不同文件名），P0 门禁有碰撞测试。
String mediaKeyEscape(String id);
```

### 2.1 `sourceOf` 判定表（顺序敏感）

| id 形态 | 返回 |
|---|---|
| `^\d{1,30}$` | `hongguo` |
| 以 `xifan:` 开头 | `xifan` |
| 以 `hema:` 开头 | `hema` |
| 以 `reelshort:` 开头 | `reelshort` |
| 以 `dramabox:` 开头 | `dramabox` |
| 以 `custom:` 开头 | `custom`（完整 uuid 由 SourceRegistry 匹配 `custom:{uuid}` 工厂） |
| 其它 | `hongguo`（兼容历史脏数据，不抛） |

### 2.2 段数校验

| 源 | 剧集最少段 | 分集最少段 | 不满足时 |
|---|---|---|---|
| hongguo | 1（纯数字） | 1 | `SourceRejected` |
| xifan | 3 | 4 | `SourceRejected` |
| hema | 2 | 3 | `SourceRejected` |
| dramabox | 2 | 3 | `SourceRejected` |
| reelshort | 3 | 5 | `SourceRejected` |
| custom | 3 | 5 | `SourceRejected` |

### 2.3 `belongsTo` 规则

- `vid` 与 `seriesId` 解析出的 `source` 必须相同。
- `vid.segments` 的前 `seriesId.segments.length` 段必须与 `seriesId.segments` 逐段相等。
- hongguo：两者都是纯数字，直接相等即可（vid 与 sid 本来相同形态，不强制相等——分集 vid 是独立 ID）。
- 任一不满足 → `false`，由调用方抛 `SourceRejected`。

---

## 3. 跨源去重键

多源扇出搜索/浏览时，同一部剧可能在多源重复出现。去重键：

```dart
/// 跨源去重键：normalizedTitle + 集数区间（粗粒度）。
/// 来源标签保留在 Drama.source，去重不吞掉来源信息——UI 仍可展示「多源可看」。
String dedupKey(Drama d) => '${_normalizeTitle(d.title)}|${d.episodeCount}';
```

- `_normalizeTitle`：去空白、全角转半角、繁简不归一化（避免误合并不同剧）、大小写不敏感（英文源）。
- 同一 key 保留**第一个**（按 `registry.enabled` 顺序，红果优先），并记录 `sources[]` 供 UI 展示。
- 翻页游标内嵌 source：`cursor = base64('$source|$rawCursor')`，避免混源翻页重复（参考项目自己的教训）。

---

## 4. 与其它契约的接口

- `SourceAdapter.matches(id)` 用 `sourceOf(id) == this.id`（custom 适配器比较 `custom:{uuid}` 完整前缀）。
- `SourceRegistry.forId(id)` 用本契约的 `sourceOf` 做快筛，再调适配器 `matches` 精确判定。
- `VideoTrack.source` 取 `ParsedSourceId.source`，写入缓存键命名空间。
- `mediaPath` 用 `mediaKeyEscape(vid)` 生成文件名段（与 `source` 一起构成命名空间）。

---

## 5. 验收判据

- [ ] `sourceOf` 判定表 7 行全部有单测，含未知前缀兜底。
- [ ] `parseSourceId` 对六个源各给 1 个合法 + 1 个非法样例。
- [ ] `belongsTo('xifan:a:b:2', 'xifan:a:b') == true`；`belongsTo('hema:x:1', 'xifan:a:b') == false`。
- [ ] `mediaKeyEscape` 单射：`custom:u:v:1:2` 与 `custom:u:v:12` 不碰撞；含 `:` ID 生成的文件名在所有平台合法。
- [ ] `dedupKey` 对全角/半角标题归一化一致，繁简不合并。
