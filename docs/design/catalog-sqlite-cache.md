# 发现/分类/榜单：筛选词表与列表内容的 SQLite 缓存 + 差异 patch

状态：设计交付，本轮不改产品代码（实施需单独授权）。行号与计数均为本文写作时**现读工作树**所得；注意工作树里已有一批**未提交**的发现页/榜单实现（`packages/api/lib/src/catalog.dart`、`packages/app/lib/features/library_page.dart` 处于 `M`；`packages/api/lib/src/ranking.dart`、`packages/app/lib/ranking/`、`packages/app/lib/features/discover_filter_panel.dart` 等处于未跟踪 `??`），HEAD 是 `4c13aea`（v0.3.14+26）但**不含**这些文件，所以本文引用的榜单代码只存在于当前工作树，一旦回退到 HEAD 就读不到。

## 0. 诉求拆解

三条诉求，各自对应一件事，不混为一谈：

1. **筛选相关的标题参数入库**：「发现/分类/榜单」顶部的内容类型、题材、排序行，以及榜单的赛道 × 榜块名称，都是上游 `selector` 词表；现在它们只在内存里（6 小时）或压根不落盘。
2. **首次加载后入库，之后 DB 优先 + 联网差异 patch**：目标是把「切一次筛选就重画一次、抖动一次就空一次」改成「先出本地目录，再用网络答复做增量校准」。
3. **视频列表资源页同样**：列表页快照现在是 JSON 整文件重写，改成 DB 行级读写 + 异步 patch，用来优化首次加载和左右滑动切换时的观感。

一并要求考虑**数据迁移**。本文把它拆成两件事：老用户已有 JSON 快照的一次性导入（§8.2），以及 schema 版本前滚/回滚策略（§8.1、§8.3）。

## 1. 现状：三层不同介质，三种不同「异常」

### 1.1 谁存在哪

| 数据 | 现在存哪 | 生命期 | 重启后 | 每次切换是否联网 |
| --- | --- | --- | --- | --- |
| 筛选词表（题材/维度行） | 进程内 Map，`packages/api/lib/src/catalog.dart:311` `_vocabulary`，TTL 6 小时 `:438` | 6h | **丢** | 是（冷进程必发 `need_selector_panel` 请求） |
| 榜单词表（赛道 × 榜块） | 进程内 `packages/app/lib/ranking/ranking_controller.dart:31` `_boards` | 进程 | **丢** | 是（`tracks` 在答复前是空的，`:20-23`） |
| 浏览/搜索列表快照 | JSON 文件 `library-cache.json`（`runtime_native.dart:110-112`），80 键 / 每键 500 条 / 7 天（`library_cache.dart:88`/`:85`/`:63`） | 7d | 在 | 出屏不发，但 30s 外必发刷新（`library_page.dart:1066`） |
| 剧集详情（集号/vid） | 同一 JSON 文件的 `details` 段（`library_cache.dart:176` 附近 `rememberDetail`），无过期 | 无限 | 在 | 详情走另一条链路 |
| 本地视频文件 | `media-cache`（`runtime_native.dart:123-124`） | 容量策略 | 在 | 不在本轮范围 |

结论：**「词表」和「列表」是两个完全不同的缓存成熟度**——列表已经有磁盘快照与「先读快照再联网」的正确时序，词表一点都没有。所以本轮不是把 JSON 换成 SQLite 就完事，而是把词表从「无盘」升级为「有盘 + 可增量」，顺带把列表的整文件重写换成行级写。

### 1.2 「数据异常」在这套上游里长什么样（实测）

来源：`docs/evidence/ranking-fields/README.md` §3，四次取样（`live-sample`、`sample-1/2/3`）。

| 观测 | 数值 | 对缓存设计的含义 |
| --- | --- | --- |
| `landpage` 词表面板按题材的覆盖率 | 真人剧 2/4、漫剧 2/4、AI 剧 3/4；有一次全缺 | 一次答复没带词表是常态 → patch 不能因为「这次没回」就删旧词表 |
| 一次答复里的榜块数 | 25 / 27 / 27 / 26（并集 27，5 条赛道） | 条数不得写死；`sample-3` 还少返回了臻果榜 `ranklist_prestige` |
| 赛道顺序 | `sample-3` 变成 全部/真人剧/漫剧/AI剧/演员 | 顺序是上游给的，客户端按 ordinal 存但不得当作热度解释（榜单除外） |
| 演员赛道的 `sub_cell_selector` | `live-sample` 整个缺失，其余三次有 2 块（剧星榜/星光榜） | 「这次没带」和「真的没有」必须可区分 → 护栏 B |
| `inner_rows` | 四次全空 | 没有周期维度，不发明（§14） |
| `rank_version` | 整分钟 epoch；推荐榜为空串 | 时间口径只能 nullable 存（§5 的 `rank_version` 列允许 NULL） |
| `play_cnt` vs `rec_text_item` | 同卡差 4 个数量级 | 一个界面只呈现一种热度；库里也不并置两个「热度」 |

一句话：**上游「一次答复不完整」是既成事实**，所以 patch 的核心不是「同步」，而是「把一次答复降级成一份证据」——见 §6.2 的四条护栏。

## 2. 与既有约定的冲突处置

`docs/design/interaction-cache-v2.md:15` 写着「原生使用应用私有目录 JSON 原子写入，**不增加平台数据库插件**」。本轮诉求（用 sqlite）与它直接冲突，处置如下：

- **被替代的部分**：列表快照与词表的存储介质、写入粒度（整文件 → 行级）。这条约定原本是为「不引入平台插件」服务的，而本次实测发现它是**伪约束**：`pubspec.lock:988-1024` 里 `sqflite 2.4.4+2` / `sqflite_android` / `sqflite_common 2.5.14` / `sqflite_darwin` / `sqflite_platform_interface` 全都已经是 `dependency: transitive`（由 `flutter_cache_manager` 拉进来）。插件注册面现读为证：`packages/app/.dart_tool/flutter_build/dart_plugin_registrant.dart` 里只有 `sqflite_android` 与 `sqflite_darwin` 两处 import 及对应的 `registerWith()`（android 一段、darwin/ios+macos 两段），也就是说 Android/iOS/macOS 三端**产物里已经有 SQLite**，本轮在真实意义上只新增 Windows/Linux 的原生依赖（§3.3）。该文件是构建生成物、不入库、行号会漂，所以按内容认、不按行号认。
- **原样保留的不变量**（这些与介质无关，换库不许顺手改掉）：
  - 私有目录、失败不阻塞在线浏览（`library_cache.dart:50-52` 的 catch 语义）；
  - **不混合新第一页和旧分页游标**（`interaction-cache-v2.md:13`），本文 §7B 明确怎么守；
  - 过期异步结果不覆盖当前页面（同上，沿用现有 revision / `CatalogRequestScope` 竞态门）；
  - 失败保留旧内容并提供刷新入口（`library_page.dart:1092-1099`，现读文案即「网络刷新失败，正在显示本地缓存。」）；
  - 达到单列表上限时不保存截断后游标（`library_cache.dart:86`）；
  - **不持久化 session、签名参数、播放地址、内容密钥**（`library_cache.dart:19` 的注释即不变量），§9.4 把它写成断言。
- **不改的部分**：个人剧目库、搜索历史、下载账本、设置（`runtime_native.dart:106-143`）继续走 `FilePreferencesBackend` 的 tmp+rename 原子写（`settings_store_native.dart:8-29`）。它们是小而整的 KV，不是需要行级 patch 的关系数据。
- 该文档需在实施 P0 的同一轮里改写，列在 §14 的清扫清单。

## 3. 选型

### 3.1 不选 drift / ORM

drift 带来 codegen、构建期依赖与 `build_runner` 纪律，收益（类型安全查询）在「7 张表、全是主键点查与简单范围删」这个规模上不划算；本仓现在连 `build_runner` 都没有。直接写 SQL，schema 与迁移全暴露在一份文件里，更容易审计「有没有把不该存的东西存进去」。

### 3.2 选 sqflite（复用已在产物里的那份）

- Android / iOS / macOS：零新增原生依赖，插件注册已完成，`sqflite_darwin` 覆盖 macOS。
- 唯一需要谨慎的是 macOS 的 Keychain 无关（本库不涉及），以及沙盒目录：沿用 `getApplicationSupportDirectory()`（`runtime_native.dart:25`）作为库文件所在目录，和 `library-cache.json` 同目录，迁移时不用跨目录找文件。
- Web：不接 SQLite。现有 web 运行时对缓存管理已经明确拒绝（`runtime_web.dart:125` 抛 `CatalogError('浏览器版缓存由内容服务管理')`），本轮给它 `MemoryCatalogStore`，行为等于今天的 6h 内存词表 + 无盘列表。

### 3.3 Windows / Linux 是本轮唯一的真新增

`packages/app/windows` 与 `packages/app/linux` 目录存在且现读无任何 sqlite 引用（`grep -ril sqlite` 两目录皆空），生成物插件注册表的对应段里也没有 sqflite（同上，按内容认）。因此 Windows/Linux 需要：

- `sqflite_common_ffi`（纯 Dart FFI 实现，避开平台插件通道）+ `sqlite3_flutter_libs`（提供随包的 sqlite3 动态库）。
- 这条依赖会进五端 CI 构建，且按既定纪律**付费 CI 先单平台验证**：P3 单独一期，先本地 Windows 实机跑通再上 CI（§12、§13.4）。
- 若上游拒绝增加 dll 体积，退路是 Windows 也走 MemoryStore + 现有 JSON（功能不降级为「不能筛选」，只是重启后需联网一次）。这个退路写在 §15 风险 3 的缓解里，不作为默认。

## 4. 模块边界与注入点

依赖方向必须保持 `api` 可纯 Dart 测试——`tool/verify_all.sh:15` 用 `dart test` 跑 `packages/api`，那里不能 import 任何 Flutter 插件。

```
packages/api/lib/src/snapshot_store.dart      # 纯 Dart：接口 + DTO + patch 算法
  abstract interface class CatalogSnapshotStore
    Future<VocabRecord?>  readVocabulary(String genre);
    Future<void>          patchVocabulary(String genre, List<CatalogDim> rows);
    Future<RankVocab?>    readRankVocabulary();
    Future<void>          patchRankVocabulary(List<RankTrack> tracks);
    Future<FeedRecord?>   readFeed(String key);
    Future<void>          patchFeed(String key, CatalogPage page, {int? afterOrdinal});
    Future<void>          clearFeeds();

packages/app/lib/catalog/sqlite_catalog_store.dart   # sqflite 实现 + 迁移
packages/app/lib/catalog/memory_catalog_store.dart   # web / 测试 / 降级
```

注入沿用现有做法，不新发明一套：

- 契约面：`LibraryCacheRuntime`（`runtime_contract.dart:108-109`）旁边加 `CatalogStoreRuntime { CatalogSnapshotStore get catalogStore; }`。
- 装配点：`runtime_native.dart:110`（现在就在那里造 `libraryCache`）紧邻处开库并包 try/catch；开库失败 → 退化为 `MemoryCatalogStore` 并设 `store.warning`，语义对齐 `runtime_native.dart:42-48` 已有的下载记录降级写法。
- 消费点（**全部是已存在的读写位置，不新增联网时机**）：
  - 词表：`catalog.dart:427-442` 的 `_vocabularyFor` 在内存 miss 之后、发请求之前插一次 DB 读；`:434` 的 `_filterRows` 返回后调 `patchVocabulary`；空答复回退写在 `:435`。
  - 榜单：`catalog.dart:713` `_rankBoard` 成功返回后调 `patchRankVocabulary(page.tracks)`；`ranking_controller.dart:74` 的 `open()` 与 `:107` `selectTrack` 先读 DB。
  - 列表：`library_page.dart:1053` `readFeed` → 改调 store；`:1090` / `:1179` / `:1193` 的 `_saveSnapshot` → 改调 `patchFeed`；`:1671` `_loadThemes` 走词表面。
- 主键沿用界面已经算好的键：`library_page.dart:239` `feedKeyAtLevel` 的 `jsonEncode` 串**原样**当 `feed_key`，不在 store 里重新拼一套（重拼必然漂移，漂移就变成两份缓存）。榜单页用与 `ranking_controller.dart:64` `keyOf` 同构的 `rank|<track>|<board>`。

## 5. 表设计

建库时先 `PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA auto_vacuum=INCREMENTAL;`，然后：

```sql
-- 筛选词表：维度行（一次 landpage 答复里的每一行）
CREATE TABLE vocab_dim (
  genre      TEXT    NOT NULL,           -- 一级内容类型，取 catalogDimKeysByGenre 的键（catalog.dart:62）
  dim_key    TEXT    NOT NULL,           -- 维度标识，必须在 catalogDimKeys 白名单内（catalog.dart:21）
  dim_name   TEXT    NOT NULL,           -- 上游 show_name 原样，不翻译不改写
  ordinal    INTEGER NOT NULL,           -- 上游顺序；第一行是主题行（_themeDim, catalog.dart:703）
  fetched_at INTEGER NOT NULL,           -- 本地毫秒 epoch
  PRIMARY KEY (genre, dim_key)
);

-- 筛选词表：维度下的可选项
CREATE TABLE vocab_item (
  genre        TEXT    NOT NULL REFERENCES vocab_dim(genre, dim_key) ON DELETE CASCADE,
  dim_key      TEXT    NOT NULL,
  item_id      TEXT    NOT NULL,         -- 上游 selector_item_id，入库前必须过 validateSelectorId
  item_name    TEXT    NOT NULL,         -- 上游 show_name
  ordinal      INTEGER NOT NULL,
  fetched_at   INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,         -- 只在「判定完整的答复」里据此淘汰
  PRIMARY KEY (genre, dim_key, item_id)
);

-- 榜单词表：赛道（selected_items）
CREATE TABLE rank_track (
  track_id     TEXT    NOT NULL PRIMARY KEY,  -- ^[a-z0-9_]{1,64}$（ranking.dart:171）
  label        TEXT    NOT NULL,              -- 上游 show_name
  ordinal      INTEGER NOT NULL,              -- 上游顺序，sample-3 会变
  has_sub      INTEGER NOT NULL DEFAULT 0,    -- 最近一次是否带回 sub_cell_selector
  last_seen_at INTEGER NOT NULL
);

-- 榜单词表：榜块（sub_selected_items）
CREATE TABLE rank_board (
  track_id   TEXT    NOT NULL REFERENCES rank_track(track_id) ON DELETE CASCADE,
  board_id   TEXT    NOT NULL,                -- 同样过 validateSelectorId
  label      TEXT    NOT NULL,
  ordinal    INTEGER NOT NULL,
  is_default INTEGER NOT NULL DEFAULT 0,      -- 上游 is_selected，不自造默认
  last_seen_at INTEGER NOT NULL,
  PRIMARY KEY (track_id, board_id)
);

-- 剧：跨列表去重的目录元数据
CREATE TABLE drama (
  series_id   TEXT    NOT NULL PRIMARY KEY,   -- Drama.id：series_id|book_id|search_result_id（catalog.dart:176-181）
  title       TEXT    NOT NULL,
  cover       TEXT    NOT NULL,               -- 封面 URL 属目录元数据，与现快照一致（library_cache.dart:8）
  intro       TEXT    NOT NULL,
  episode_cnt INTEGER NOT NULL DEFAULT 0,
  tag_names   TEXT    NOT NULL DEFAULT '[]',  -- JSON 数组；现在 JSON 快照丢了它（dramaJson，library_cache.dart:5-11）
  updated_at  INTEGER NOT NULL
);

-- 列表页：一页 = 一行 feed + N 行 feed_item
CREATE TABLE feed (
  feed_key    TEXT    NOT NULL PRIMARY KEY,   -- feedKeyAtLevel 的串，原样
  genre       TEXT,                           -- 冗余列，仅供按题材淘汰与设置页统计
  head_hash   TEXT    NOT NULL,               -- 见 §6.1；未变则不重绘
  cursor      TEXT,                           -- 下一页游标；触顶 500 条时置 NULL
  item_cnt    INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  accessed_at INTEGER NOT NULL,               -- LRU
  stale       INTEGER NOT NULL DEFAULT 0,     -- 上次 patch 失败或被熔断
  source      TEXT    NOT NULL DEFAULT 'network'
              CHECK (source IN ('network','local','local+calibrated'))
);

CREATE TABLE feed_item (
  feed_key   TEXT    NOT NULL REFERENCES feed(feed_key) ON DELETE CASCADE,
  ordinal    INTEGER NOT NULL,                -- 上游数组下标：榜单名次即下标（ranking.dart position）
  series_id  TEXT    NOT NULL REFERENCES drama(series_id),
  heat       TEXT,                             -- 以下六列只在榜面 feed 非空，且沿用上游文案
  collect    TEXT,
  score      TEXT,
  badge      TEXT,
  subtitle   TEXT,
  dominate_color TEXT,                         -- 只存 6 或 8 位十六进制（同 ranking.dart:148 的规则），否则 NULL
  rank_version INTEGER,                         -- 整分钟 epoch；NULL＝该榜不做时间声明（推荐榜实测空串）
  PRIMARY KEY (feed_key, ordinal)
);

CREATE INDEX idx_feed_accessed  ON feed(accessed_at);
CREATE INDEX idx_item_series    ON feed_item(series_id);
CREATE INDEX idx_seen           ON vocab_item(genre, dim_key, last_seen_at);
```

`PRAGMA user_version = 1` 是唯一的版本记号（不建自管 meta 表，避免「meta 说 1、pragma 说 2」的双头）。

**不建的表**（每少一张，迁移与隐私面就小一分）：

- `episode`：剧集详情继续留在现有 JSON `details` 段，是否并库放到 P4（§12）。
- 播放地址 / 内容密钥 / 签名参数 / session / 手机号 / device id：**不建列、不写键名**，见 §9.4。
- `search`：搜索建议不在本轮（§14）。
- 下载任务、本地文件索引：已有各自的持久面。

## 6. 差异 patch

### 6.1 身份键与 hash 覆盖

| 数据 | 身份键（决定 upsert 命中谁） | 参与比较的字段 | 变了会怎样 |
| --- | --- | --- | --- |
| 维度行 | `(genre, dim_key)` | `dim_name`、`ordinal` | 名称变 → 改文案；顺序变 → 重排该行位置 |
| 维度选项 | `(genre, dim_key, item_id)` | `item_name` | 只改名 → 静默替换 chip 文案 |
| 赛道 | `track_id` | `label`、`ordinal`、`has_sub` | `ordinal` 变 → tab 顺序变（可接受，`sample-3` 实测会变） |
| 榜块 | `(track_id, board_id)` | `label`、`ordinal`、`is_default` | 默认块变 → 下次进入选中的榜变，需重发一次内容请求 |
| 剧 | `series_id` | `title/cover/intro/episode_cnt/tag_names` | 集数增 → 卡片副标题变 |
| 列表页 | `feed_key` | 前 `min(item_cnt, 12)` 条的 `(series_id, ordinal)` 拼接 → `head_hash` | hash 相同 → **完全不重绘**（§10） |
| 榜条目 | `(feed_key, ordinal)` | `series_id` + 六个展示列 + `rank_version` | 任一变 → 该行重绘；`rank_version` 变 → 「更新于」变 |

规范化固定为：字段按声明序拼接、trim、折叠重复空白，再取短 hash（本端 64-bit FNV-1a 十六进制）。不用加密 hash——这里要的是「够用的相等性判断」，不是防篡改；用它换掉 SHA 也换掉一个依赖。

`head_hash` 只覆盖首屏前 12 条，是刻意的：左右切换回来时，翻页追加的尾部不该让头部重绘，而尾部变化本来就不需要用户重新看一次头部。

### 6.2 算法（四类数据同一套）

1. 读旧（DB）→ **立即渲染**，不发请求、不显示骨架。
2. 请求网络：沿用现有 260ms 请求间隔串行化（`catalog.dart:321`、`:465`）与 `requestDeadline`（`:340`），**不因为加了 DB 就放宽节流**——节流是上游给的约束，不是缓存的代价。
3. 逐行 upsert：命中且字段等 → 只推 `fetched_at` / `last_seen_at`；命中且不等 → 覆盖；未命中 → 插入。
4. 淘汰：仅在本次答复被判定「完整」时，删除该答复中缺席的旧行。
5. 写 `head_hash` / `updated_at`；任何一步抛错 → 内存里保留本次网络结果、`stale=1`、旧数据不动（等价于今天的 `library_cache.dart:50-52` 容忍）。

「完整」怎么判——四条护栏，全部可单测：

- **护栏 A（空答复不删）**：网络返回 0 行、或词表面板缺行（`catalog.dart:435` 的空回退分支）→ 本次只更新见到过的行，删除集为空。理由：§1.2 里 AI 剧 4 次有 1 次全缺，删一次就等于用户重装。
- **护栏 B（赛道无子榜不删）**：某赛道这次没带 `sub_cell_selector`（`has_sub` 置 0）→ 保留它已有的榜块行，只是不画 tab。理由：演员赛道 `live-sample` 缺失、其余三次有 2 块。
- **护栏 C（标识白名单，非法不入库）**：`item_id`/`track_id`/`board_id` 必须过 `validateSelectorId`（`ranking.dart:171-176`，`^[a-z0-9_]{1,64}$`），维度键必须在 `catalogDimKeys`（`catalog.dart:21`）内；否则整行丢弃。理由：上游返回值不能扩出一个客户端不认识的维度——那条维度点下去必发一个非法 `select_items`。
- **护栏 D（幅度熔断）**：本次计划删除的行数 > 该作用域上一次库内行数的 50% → 判为可疑答复，本轮**只加不删**并置 `stale=1`；只有连续 3 次同样熔断才真正执行删除。理由：一次 `sample-3` 少一块榜不该清空 27 块的词汇表；但真实改版也不会连续 3 次都少同一批。阈值是客户端策略，不进 UI 文案。

**为什么不做整页替换**（现在 JSON 的做法）：整页替换把上游一次抖动 1:1 传导成用户看到的空白或重排；行级 upsert + 熔断把「一次答复」降级成「一份证据」，异常面从「整页」缩到「一行」。

## 7. 读取时序

### A. 词表（切内容类型/题材）

```
_vocabularyFor(genre)  catalog.dart:427
 ├ 内存命中且 6h 内（:429-431）→ 直接返回（现状不变）
 ├ miss → store.readVocabulary(genre)
 │   ├ 有 → 立即用它出筛选栏（source=local），并**并行**发 _filterRows
 │   └ 无 → 同步发 _filterRows（首启路径，与今天一致）
 └ 网络回来 → patchVocabulary（§6.2）→ head 变则通知重建，不变则不动
失败 → 保持现有「题材加载失败」+ 重试入口（library_page.dart:1700、:1882）
```

要点：DB 命中**不取消**网络请求，只是不再阻塞首屏——这正是诉求 2 的「优先读库 + 联网 patch」。

### B. 列表页（首次加载 + 左右切换）

现有时序已经是对的，本轮只换介质、加行级 patch：

```
library_page.dart:1053 readFeed(key) → store.readFeed(key)
 ├ 命中 → 出屏；:1066 的「30 秒内不重发」保留（避免滑动来回各发一次）
 ├ :1090 _saveSnapshot → store.patchFeed(key, page)
 └ :1092-1099 失败保留旧内容 + 刷新入口：不变
```

守两条硬约定：

- **不混合新第一页和旧分页游标**：`patchFeed` 更新 `ordinal < 本次条数` 的段，并把 `cursor` 换成**本次答复**的 cursor；本次是第 2 页（`afterOrdinal` 非空）时按 ordinal 段追加，绝不覆盖首页与 cursor。触顶 500 条时 `cursor=NULL`（`library_cache.dart:86` 的规矩照搬）。
- **竞态**：沿用现有 revision / `CatalogRequestScope` 门（`catalog.dart` 的请求作用域），过期异步结果不覆盖当前页面。左右切换时，已渲染 pane 用内存态，未渲染 pane 走 DB 出屏 + 后台 patch——所以切换不再被网络阻塞，这是诉求 3 的直接收益。

### C. 榜单

```
进入模块 → store.readRankVocabulary()
 ├ 有 → 立刻画出 赛道 tab × 榜块 tab（解决 tracks 空到答复，ranking_controller.dart:20-23）
 └ 无 → 现状：发一次 rankBoard() 拿词表
open(key) :86-90 的 visited||inFlight 护栏：DB 命中算 visited，但**仍**在后台跑一次 patch
条目 → 存进 feed/feed_item（feed_key = rank|track|board），more() :96-105 走 §6.2 追加段
```

演员赛道的处理保持本轮原型已确立的口径：`has_sub=0` 或 `unrecognizedCards>0`（`ranking.dart:66-72`）时**不画 tab、不把 `RankEntry` 假装成 `Drama`**，但库里留着它的行不删（护栏 B），界面显示「这一榜的条目不是剧」而不是「这个榜是空的」。

## 8. 数据迁移

### 8.1 机制

`PRAGMA user_version` + `onCreate`/`onUpgrade`，**forward-only**：`onUpgrade` 里按 `oldVersion` 逐段执行到 `onCreate` 的最新 schema，没有跳步捷径。客户端永不执行反向迁移，没有 `DROP` 回退路径。

### 8.2 老用户一次性导入（JSON → SQLite）

在 P2 里、开库成功后立刻做一次，做完不再做：

1. 读 `library-cache.json`（`runtime_native.dart:111`）。`data['version'] != 1` 的三种情况分别处理（对应 `library_cache.dart:35`）：缺键/未知 → 跳过导入、建空库；`1` → 导入；更高（未来版本写的） → 跳过并记 warning。
2. `feeds` 段 → `feed` + `feed_item`，`dramaJson` 五列直接映射，`tag_names` 写 `'[]'`（旧数据确实没有，不伪造）。
3. `details` 段的剧 → `drama` 表（`_enrich` 的「取更完整的值」语义在这里复用一次即可）；集号/vid 仍留在原 JSON，因为本轮不建 `episode` 表。
4. 导入**幂等**：`feed_key` 已存在则跳过整页。
5. 成功后把原文件**改名**为 `library-cache.json.imported`（不是删除——可回退、可取证、坏了能对照重跑）；失败则原文件保持原名，下次启动再试，并在设置页显示一次「本地快照迁移未完成，本次仍读旧文件」。
6. 词表**没有可迁的数据**（现在只在内存），所以本文不承诺「升级后首启零请求」；首启仍有一次词表请求，之后才有本地。这句必须写清楚，否则验收口径会含糊。

### 8.3 降级、损坏与清理

- **库版本比当前 app 支持的高**（用户回滚了 app 版本）：不写、不猜 schema、整个 store 退化为 `MemoryCatalogStore`，磁盘文件原样保留，等下一次升级接上。回滚期间的表现 = 今天的行为（无盘），不是崩溃。
- **打开失败 / `SqliteException`**：改名 `catalog.db.corrupt-<毫秒>` 后重建空库，且**每进程只重建一次**（否则一次抖动会反复建库、把 warning 刷满）。
- **`clearCache`**：现在 `runtime_native.dart:250` 与 `:284` 调 `libraryCache.clearFeeds()`。新 store 的 `clearFeeds()` 只 `DELETE FROM feed`（靠 `ON DELETE CASCADE` 带走 `feed_item`），**保留词表**——词表是目录能力不是个人痕迹，清空它等于让用户下次必联网。若设置页要「彻底清」，另给 `clearAll()`，两者在 UI 上文案分开。
- `.imported` / `.corrupt-*` 文件不进任何备份/体积统计。
- TV / 手机 / 桌面**同一 schema、同一 `user_version`**；`tvBuild` 只影响并发（`runtime_native.dart:135` 的 `maxConcurrent`），不影响表结构——避免「TV 上一份 schema，手机上另一份」这种永远对不齐的迁移。

## 9. 容量、TTL、写放大、隐私

### 9.1 边界（沿用，不换数字）

feed ≤ 80 键（`library_cache.dart:88`）、每 feed ≤ 500 条（`:85`）、feed 快照 7 天（`:63`）。界面 pane 的 `_feedKeep = 32`（`library_page.dart:292`）是**内存保活数**，不是库上限，两者并存；代码注释里要分别标注，别混。淘汰按 `accessed_at` LRU，`drama` 行只在不被任何 `feed_item` 引用时才删（否则下次出屏缺元数据，反而更糟）。

体积上界：80 × 500 × ~120 B ≈ 4.8 MB（`feed_item`），`drama` 去重后远小于此。删除后若 freelist > 4096 页且本进程未做过，执行 `PRAGMA incremental_vacuum`（依赖建库时的 `auto_vacuum=INCREMENTAL`）。

### 9.2 词表不过期

词表没有 TTL，用 `stale` + 每次进入后台 patch 表达新鲜度。**不做 7 天删除**，否则「切题材必联网」被重新发明出来。唯一让词表消失的动作是设置页 `clearAll()`。

### 9.3 写放大

一次网络答复 = 一个事务；事务内批量 `INSERT OR REPLACE`；字段等值则只更新 `last_seen_at`（不碰其他列）；`head_hash` 未变则不写 `feed` 行。**不在读路径写盘**（今天 `readFeed` 是纯读，保持）。

### 9.4 隐私不变量（可执行）

表里只允许出现：上游公开的目录字段（标题/封面 URL/简介/集数/标签名/词表名称与标识/榜单展示文案）+ 本地时刻。**不允许**：session、签名参数、播放地址、内容密钥、手机号、device id。落实成两件硬事：

- `sqlite_catalog_store.dart` 顶部注释继承 `library_cache.dart:19` 那句「No session, video source URLs or content keys」，作为可 grep 的约定；
- 单测断言：写夹具时若 payload 里出现 `video_url`/`content_key`/`session` 之类的键名，或建表后 `PRAGMA table_info` 的列名集合不等于本文的白名单 → 测试失败。把「没存进去」从口头承诺变成门禁。

（`device-id.txt` 仍在 `runtime_native.dart:27`，与本轮无关，不进库。）

## 10. UI 语义与来源标记

DB-first 之后，界面必须诚实地表达「你看到的是本地目录，正在校准」，不能让人以为已经是最新：

| 情形 | 画面 | 提示文案（PC 全句 / 触控族短句） |
| --- | --- | --- |
| DB 命中，patch 后 `head_hash` 未变 | **不重绘、不滚动、不清滚动位置** | 无（静默）——这条最重要：左右切换来回不该跳位 |
| DB 命中，patch 后有变化 | 原地替换变化的行；若选中项被上游改名，保留选中状态 | PC「本地目录 · 已更新」/ 短句「已更新」 |
| DB 命中，patch 进行中 | 首次出屏无骨架、无转圈；右上角状态点 | PC「本地目录 · 正在更新」/ 短句「本地 · 更新中」 |
| DB 命中，patch 失败 | 列表保持 + 一条可点的重试 | 「更新失败 · 重试」（保留语义沿用现读的 `library_page.dart:1092-1099`：「网络刷新失败，正在显示本地缓存。」） |
| DB 无 + 网络失败 | 现有失败文案不变 | 不新增「离线可用」这类承诺 |
| 被熔断（护栏 D） | 界面不变，`stale=1` | 不向用户暴露阈值细节；只计入设置页统计 |
| 榜单词表来自 DB | tab 立刻可见，条目区显示「正在更新」 | 同第一行规则 |

另外两条来自本轮已确立的交互纪律，实现时必须一起满足：

- 词表缺行的占位在触控族**必须可点重试**，不能是划不动的死标签（原型已按此修正，`discover-filters-and-ranking.md` §6.1.5）。
- 赛道/榜块**数量一律现读**，任何界面与代码不得写死（`README.md` §3 与原型都按此改过）。

设置页新增只读块：本地快照页数、词表覆盖的题材数、最近一次成功 patch 时刻、库文件体积；两个动作按钮——「清列表快照」（`clearFeeds`）与「重新联网校准」（清 `stale` 后强制一次 patch）。

## 11. 上游配合清单（不用现状降级 UI）

1. `landpage/v` 的词表面板带一个版本标识（`selector_version` 或 `E2ETag` 任一）。有了它，「完整答复」的判定从启发式（护栏 D 的 50%/3 次）换成确定式，熔断可以直接下线。
2. `cell/change/v` 在某赛道无子榜时返回**空数组**而不是缺字段，让客户端能区分「真的没有榜」和「这次没带」。
3. 榜单给出与 `rec_text_item` 同口径的 `play_cnt`；在口径统一前，界面继续只呈现一种热度（`ranking.dart:35-36` 已刻意不并置）。
4. `rank_version` 在推荐榜返回空串而非缺失/0，以便「不做时间声明」是有意的第三种状态。
5. 若上游提供 `If-None-Match` 类协商，patch 可退化为「未变则完全不写」。当前没有，所以靠 `head_hash` 在本地实现等价效果。
6. 上述任一条不落实，本端也由 §6.2 的护栏承担；**不得**因为词表抖动把筛选层降级成一维 tab。

## 12. 分期与验收

| 期 | 内容 | 验收（必须带窗口的实机截图，不认 headless） |
| --- | --- | --- |
| P0 | api 侧纯 Dart：`CatalogSnapshotStore` 接口 + `MemoryCatalogStore` + §6.2 patch 核心与四条护栏，接进 `_vocabularyFor`/`_rankBoard`/`_filterRows` 钩子 | 单测覆盖 A/B/C/D；同进程内切题材第二次零网络；`packages/api` 仍 `dart test` 通过（不引入插件 import） |
| P1 | app 侧 `SqliteCatalogStore`：建表 + WAL + `user_version=1`；注入 `runtime_native.dart:110` 旁；`CatalogStoreRuntime` 契约 | macOS 冷启动首屏（词表 + 列表）由 DB 出屏；**断网**冷启动列表仍出屏、筛选栏有词表；切换来回不跳位 |
| P2 | 迁移：JSON→SQLite 一次性导入、`.imported` 改名、高版本退化 MemoryStore、设置页统计与两个按钮 | 覆盖安装升级后首启不出现「筛选栏空」；回滚旧版不崩溃；重复启动不重复导入 |
| P3 | Windows/Linux：`sqflite_common_ffi` + `sqlite3_flutter_libs`，**先本地 Windows 实机验证再上付费 CI** | Windows 冷启动同 P1 口径；CI 构建时长与包体可接受（`git bundle` 量字节数） |
| P4（可选） | `LibraryCache._details` 并库（`drama` + `episode`），收敛双介质 | 仅当 JSON 整文件重写被测量成可观测的启动耗时才做 |

## 13. 测试与门禁

1. **api 纯 Dart（`verify_all.sh:15`）**：用 Fake store 驱动 patch 语义——空答复不删、无子榜不删、非法 id 不入库、熔断只加不删、`head_hash` 稳定性（同数据两次相等；仅顺序变则不等）、首页与旧 cursor 不混合、`patchFeed(afterOrdinal)` 追加不覆盖。
2. **app 集成（`verify_all.sh:22`，`sqflite_common_ffi` 内存库）**：建表成功、`user_version` 升级路径（0→1、1→2 的脚手架用例）、`ON DELETE CASCADE` 只带走 `feed_item`、LRU 淘汰到 80、`clearFeeds` 保留 `vocab_*`、损坏文件改名重建且每进程一次。
3. **必须继续绿的现有关联用例**（现读目录）：`packages/app/test/library_cache_test.dart`、`interaction_cache_test.dart`、`network_cache_behavior_test.dart`、`horizontal_filters_test.dart`、`discover_desktop_layers_test.dart`、`catalog_tabs_test.dart`、`catalog_sort_test.dart`；`packages/api/test/catalog_vocabulary_test.dart`、`catalog_retry_test.dart`、`catalog_test.dart`、`catalog_page_size_test.dart`、`drama_tags_test.dart`。**注意：榜单目前没有独立测试文件**（`packages/**/test/*rank*` 现读为空），P0 要新建 `packages/api/test/rank_patch_test.dart`，不能假装已有覆盖。
4. **夹具入库纪律**：`docs/evidence/ranking-fields/` 的四次取样就是 patch 测试的夹具来源，尤其要用 `sample-3`（少一块榜 + 赛道顺序变）和 `live-sample`（演员赛道缺 `sub_cell_selector`）——把真实抖动钉进断言，而不是造一份理想答复。
5. **隐私门禁**：§9.4 的列名白名单断言 + 夹具敏感键检查，跟 `packages/api/tool/rank_sample.dart` 已有的 `_is_sensitive()` 同一套词汇，避免两处各写一份规则。
6. **格式**：`dart format` 只对本轮新增/修改的文件跑。`.fvm/flutter_sdk` 是指向 `~/fvm/versions/3.47.4` 的共享只读 SDK，曾一次误改 ~829 个文件且 git 无法恢复——不对其执行任何写操作。
7. `tool/verify_all.sh` 不含 `tool/ci/tests`，需单跑；推送前在分离 worktree 里对**提交树**跑同一套门禁，再打 tag。

## 14. 本轮不做，与待更正的清扫清单

本轮不做：搜索建议缓存、下载任务与本地文件索引、播放取址、投屏、`episode` 并库（P4）、周期维度（`inner_rows` 四次全空，不发明）、演员榜条目的对象化（条目不是剧，保持 `unrecognizedCards` 计数）。

**待更正（实施 P0 的同一轮里全部收口，改一条结论要扫全部副本面）**：

1. `packages/api/lib/src/ranking.dart:5-6` 的头注释写「Four live samples measured 22-27 blocks」，与实测单跑 25/26/27、并集 27 不符（`docs/evidence/ranking-fields/README.md` §3）→ 应为 25–27，并注明四次各自数值与 `sample-3` 少臻果榜。
2. `docs/design/discover-filters-and-ranking.md` 里 P2′（`rank()` 参数化）与 P2″（`filterRows()` + 抽屉）的状态行：代码**已在当前工作树实施但尚未提交**（现读 `catalog.dart:404` 已按参数分派 `_rankBoard`，`:420` 已暴露 `filterRows`，`:418` 已有 `_themeDim`）→ 改为「已实施，随工作树未提交」并核实行号；提交后行号需再核一次。
3. `docs/design/interaction-cache-v2.md:15`「不增加平台数据库插件」→ 按 §2 改写：列表与词表快照改为 SQLite（Android/iOS/macOS 复用已在产物中的 sqflite，Windows/Linux 新增 FFI），个人数据/下载/设置继续 JSON 原子写；同时保留 §2 列出的全部不变量。
4. ~~`docs/README.md`「交互与缓存改进」一节需补本文索引~~ **本轮已做**：现读 `docs/README.md:35` 是本文索引行（该文件当前处于 `M`，同样未提交）。
5. 实施前重新现读所有行号：本文的每个 `file:line` 都是**工作树**（HEAD `4c13aea` 之上的未提交改动）读数，`ranking.dart` 与 `packages/app/lib/ranking/` 在 HEAD 上根本不存在；代码一动或一提交，这些坐标就可能漂。

## 15. 风险

| # | 风险 | 触发条件 | 缓解 | 残留 |
| --- | --- | --- | --- | --- |
| 1 | 一次不完整答复把词表删稀 | 上游面板覆盖率 2/4~3/4（§1.2） | 护栏 A–D，默认只加不删 | 上游新增 id 在首次答复前不显示（≤1 次刷新） |
| 2 | 把上游顺序误当语义固化 | 若 ordinal 其实是随机的 | `ordinal` 只在同 `head_hash` 前缀下比较；UI 不将非榜单条目的 ordinal 解释为名次 | 非榜列表的排序变化会被静默接受 |
| 3 | sqflite 在 Windows/Linux 未注册导致功能缺失 | P3 依赖未就位或 dll 打包失败 | P3 独立一期、先本地实机验证；退路是 Win/Linux 走 MemoryStore + 现有 JSON | 包体/构建时长增加；两平台首启仍需联网 |
| 4 | 库损坏或被外部改动 | 磁盘异常、用户手动动文件 | 改名重建（每进程一次）+ 必要时退化 MemoryStore | 损坏当次冷启动等同新用户 |
| 5 | 回滚旧版后筛选栏空白 | 用户装回不认识 DB 的版本 | §8.3 高版本库只读不写、旧版走自己逻辑；不删任何 JSON | 不保证回滚后首屏仍可用，只保证不崩 |
| 6 | 双介质语义分裂（JSON `details` + SQLite feed） | P1–P3 期间 | feed 的**唯一写入目标是 SQLite**，JSON 只作迁移来源与 `.imported` 留档 | 详情仍在 JSON，需 P4 收敛；设置页两处统计需分别标注 |
| 7 | `_feedKeep=32` 与库上限 80 被混为一谈 | 读代码的人（含未来的我） | §9.1 明确两者身份；代码注释与设置页文案分别表述 | — |
| 8 | `head_hash` 未变但用户期待「刷新后看到新内容」 | 强刷新 | `force`（现有 `library_page.dart:1066` 的 `!force` 分支）时跳过 hash 短路，强制重绘一次 | — |
