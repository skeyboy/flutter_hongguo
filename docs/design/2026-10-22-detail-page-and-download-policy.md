# 详情页与下载策略优化（TV 动作行 / 选集限高翻页 / 相关推荐 / 下载只限并发）

日期：2026-10-22　状态：设计定稿，待实现
适用端：TV（Android TV）、Mobile（Android/iOS）、Desktop（macOS/Windows/Linux）

## 0. 需求与结论一览

| # | 需求 | 结论 |
| --- | --- | --- |
| 1 | TV 详情页把「观看 / 下载 / 收藏」放到一行省空间 | 采纳，三动作进同一 `Row`，收藏改成与 `TvFocusable` 同形态的按钮 |
| 2 | 下载不要「下载量限制」，改为限制并发数，且不与播放中自动提前缓存冲突 | 采纳：移除下载侧的集数/容量门禁；下载并发独立可配（1–3）；手动下载与自动预缓存**分预算**，互不挤占 |
| 3 | 详情页剧集列表缩小高度、展示 3~4 行、可水平滚动 | 采纳「多行分页 + 水平翻页」，三端统一组件，行高按端取 3 或 4 行 |
| 4 | 详情页增加影视资源推荐，依据现有接口能力设计 | 采纳「同题材相关推荐」，用现有 browse+题材面板实现；**不加任何「热度/最新」标记**（上游不给可信字段），并列出后端配合清单 |

## 1. TV 详情页动作行

现状：`packages/app/lib/features/tv/tv_detail_page.dart:104-127` 三个动作是竖直 `Column` 里的三块，观看 `Padding(all:14)+fontSize:24`、下载同尺寸、收藏是 48 高的 `IconButton`，彼此 `SizedBox(height:20/24)`。

改为一个 `Row`：

- 顺序固定「▶ 开始观看 · 下载剧集 · 收藏」，`crossAxisAlignment: center`，`spacing` 用 `SizedBox(width:16)`。
- 观看仍持有 `playNode`（`tv_detail_page.dart:21,52,107` 依赖它做 autofocus 与返回后回焦），必须保证 `Row` 里第一个可聚焦项就是它。
- 下载仅在 `runtime is DownloadRuntime` 时出现（保持现有条件）。
- 收藏不再用 `FavoriteButton` 的 `IconButton` 形态：在 `personal/favorite_button.dart` 增加一个 TV 形态（`TvFocusable` 包裹、文案「收藏 / 已收藏」、复用同一套 `PersonalLibrary` 读写与 `_toggled` 语义），手机端形态不动。
- 断言兼容：`tv_catalog_test.dart:87`、`tv_remote_test.dart:313/327/419`、`tv_hevc_platform_test.dart:152` 断言 `'▶ 开始观看'` 文本；`interaction_cache_test.dart` 断言 `'开始观看'`。文案一字不改，只改排布，避免动测试口径。

省下的纵向空间留给简介与选集；简介 `Text` 加 `maxLines: 2 + TextOverflow.ellipsis`（TV 上长简介会把选集挤出首屏）。

## 2. 选集：限高 + 多行 + 水平翻页

新组件 `packages/app/lib/playback/episode_pager.dart`，三端共用：

```
EpisodePager({
  required List<Episode> episodes,
  required int Function() currentIndex,      // 高亮当前集
  required ValueChanged<int> onSelected,
  int rows,                                   // 手机 3、桌面 4、TV 4
  double cellExtent,                          // 单元格宽，按端给
})
```

- 分页：`PageView`（水平），每页一个**不滚动**的网格，页高 = `rows * cellHeight`，整块高度恒定 → 详情页不再被 100 集拉长。
- 翻页控件：页首/页尾各一个箭头按钮（`Icons.chevron_left/right`，禁用态置灰）+ 中间「第 a/b 页」文本。触摸端可直接横滑页面。
- TV 焦点交接：箭头是 `TvFocusable`；焦点落在本页最后一项再按右 → 翻到下一页并把焦点交给该页首项；本页首项按左 → 翻上一页并聚焦其末项。沿用 `packages/tv/lib/src/choice_rail.dart:61-87` 的 `onKeyEvent` 手写方向键范式与 `TvFocusable` 的 `ensureVisible`（`focusable.dart:79-88`）。
- 遥控器上下键：页内多行，行间移动交给 `TvNavigation` 的几何五向兜底（详情页当前即依赖它，无 `FocusTraversalGroup`）。
- 手机端 `detail_page.dart:276-301` 的 `SliverGrid(maxCrossAxisExtent:100)` 全展开形态替换为该组件（`rows: 3`）。
- 兼容断言：`interaction_cache_test.dart:326/331` 断言 `'第 3 集'` 可见——分页后第 3 集仍在第 1 页内（每页 ≥ 12 项），断言不失效；若失效按事实改测试并在提交说明里写清。

## 3. 相关推荐（只基于上游真实能力）

### 3.1 上游事实（已核到行号）

- 端点只有 4 个：browse 列表 / 题材面板（同一 landpage 端点两种 `req_type`）、漫剧榜、搜索、详情分集、取址。**没有任何 recommend/related/相似 端点**；`need_personal_recommend=1` 只是设备个性化开关（`video_model_client.dart:86`）。
- `Drama.fromJson` 原本只解析 `series_id/title/cover/intro/episode_cnt`，而上游行对象**确实带题材标签**：真实键名是 `cover_tag_info_list`（参考实现 `references/hongguo-web/server/src/service/client.js:425,590` 的 `coverTags()` 读的正是这个键；`tags/coverTags` 只是参考实现的输出名）。元素可能是 map（依次取 `text/content/name/tag_text/title` 并剥 HTML）或裸字符串，行对象与其内嵌 `video_detail` 两处都可能出现。
- 无演员/导演维度；榜单只有 3 个漫剧榜且 query 固定，短剧无榜；短剧的「最新/热门」是 browse 按 `sort=online_time/hot_score` 拉两页（`search_suggestions.dart:22-25`）。
- 已记录约束：推荐行不带 `published_at/score/rank`，「图标只能声明这一行来自哪个榜单，不能声明今天上架或热度数值」（`docs/design/search-focus-suggestions.md:28`）。
- **真实上游取样（2026-10-22 12:37，`docs/evidence/related-dramas/live-sample.json`，取样脚本 `packages/api/tool/related_sample.dart`）**：短剧题材面板 29 项，id 形如 `cate_165`，名称为 悬疑/宫斗/脑洞/青春…；首页 12 行的 `category_schema` 名称常是 剧情/反转/逆袭 这类**叙事词，不在面板词表里**，名字直等能命中的只有 **1/12**。即「同题材」覆盖率天然很低，不是解析 bug。

### 3.2 设计

1. `Drama` 增加 `List<String> tagNames`：解析 `category_schema`（字符串形态的 JSON，逐条取 `name`；已是 List 时取 `element.name`），退化用 `tag_info.text`；行对象与内嵌 `video_detail` 两处都扫。缺失/类型异常/空一律空列表，去重、不猜不抛。**`cover_tag_info_list` 不解析**——它是封面角标文案（爆剧/新剧/独播），与题材面板永不相等。
2. 新模块 `packages/app/lib/recommendations/related_dramas.dart`：
   - 输入当前 `DramaDetail`；先取题材面板（`catalog.themes(...)`，内存 6h 已有）把 `tagNames` 映射成 `selector_item_id`（形如 `cate_7`）；
   - 用第一个命中的题材 `browse(theme: id)` 取一页，**按 id 排除当前剧**，取前 12 条；
   - **无 tag 或面板名不命中 → 退到 `browse(sort: 'hot_score')`，标题改为「平台热门」**（1/12 的实测覆盖率不允许整块常缺席；这条降级仍诚实：标签只声明这次请求按什么排序，口径同 `search_suggestions.dart:15-17,22-25`）；
   - 结果只进内存缓存 10 分钟，**不写 LibraryCache**（与搜索推荐位同一口径：陈旧数据会撒谎）；
   - 失败/无题材命中 → 返回空列表，UI 整块不出现，不弹错误、不占位（与 `search_suggestions.dart:87-93` 的吞失败策略一致）；
   - 请求走 `CatalogRequestScope`（范式 `detail_page.dart:25-30,41-43`），离开页面即取消；限速由 `catalog.dart:238-251` 的 260ms 队列统一负责，不自建节流。
3. UI：详情页底部「相关推荐」横向封面条（封面 + 标题，点击进同端详情页；TV 用 `TvFocusable`，手机/桌面复用 `CachedNetworkImage` 卡片）。**不显示任何「最新/热度」角标**，标题只允许「同题材 · <题材名>」或降级后的「平台热门」，因为这是我们能证明的唯一两种关系。
4. 实测补充：`category_schema` 里的 `id` 与面板 `selector_item_id` 不是同一命名空间（响应窗口内未出现 `cate_` 形式），所以只能按名称对齐，无法用 id 提升命中率。

### 3.3 后端配合清单

| 需要 | 现状 | 有了之后能做什么 |
| --- | --- | --- |
| 真正的 related/recommend 端点（按 series_id 召回） | 无 | 推荐位从「同题材」升级为「相关」，可去掉本地题材映射这一步 |
| 详情响应直接给 `selector_item_id` 级别的题材 id | 只给 tag 名，需再拉题材面板做名字→id 映射 | 省一次请求、消除改名导致的映射失败 |
| 列表行给可信 `published_at` / `score` | 缺（文档已记） | 才允许出现「最新」「热度」角标与真实排序 |
| 短剧榜单（非漫剧 cell） | 只有 3 个漫剧榜 | 推荐位可标注来源榜单 |

## 4. 下载：去掉量限制，只留并发限制

### 4.1 要移除的（下载侧「量」门禁）

`packages/app/lib/downloads/download_manager.dart`：

- `:293-295` 「已达下载集数上限」
- `:300-302` 「已达下载容量上限」
- `:347-350`、`:392-395` 开跑前与完成前的 `quota` 抛出
- `:353-364` 进度回调里按 `total` 预估超容量即置 failed 并 `stop()`
- `:456-463` `resume()` 的同两条限制

保留 `:296-299` 的 500 条任务记录上限（这是记录管理护栏，不是用户的下载额度，500 条实际不构成限制）。

### 4.2 与自动提前缓存「不冲突」怎么落实

两条通道今天共用同一个调度器与同一份字节预算：`prefetch_window.dart:62 → runtime_native.dart:285-291 → media_cache.dart:151/227 _pump`，下载走 `download_manager.dart:351 → runtime_native.dart:145-148`，同一个 `_pending/_active/maxConcurrent`、同一份 `_reserved/_pinSizes`（`media_cache.dart:335-343,354-361`）。冲突点就在这儿：手动下载是 `retainFile` 的 pin，体积计入 `_pinSizes`，会挤掉预缓存预算，反过来预缓存也受下载影响。

改法：

1. `MediaCache` 的字节预算**只统计非保留（自动）文件**：`_pinSizes` 拆成 `_autoBytes` 与 `_retainedBytes`，`maxBytes/maxFiles` 门禁只看 `_autoBytes`；`prune()` 继续保护保留文件（`media_cache.dart:588-591` 已有）。
2. 下载不再受 `maxCacheMb/maxCacheFiles` 约束（见 4.1），自动缓存的两项设置在设置页语义收窄为「自动缓存」，文案不再提「手动下载可能超过上限」（`settings_page.dart:664-670`）。
3. 并发：新增 `downloadConcurrent`（1–3，默认 1）设置项，`DownloadManager._pump`（`:321-336`）由「同一时刻只跑 1 个」改为「最多 N 个」；播放让路规则（`:148`：正在播放且 `concurrentPreparations<=1` 时暂停下载）改为按「剩余可用并发槽」判断，即下载占用的并发不与 `maxConcurrent` 前台准备抢同一批槽位——保持 `_pump` 里前台优先、后台最多 `maxConcurrent-1` 的既有不变式（`media_cache.dart:230-238`）。
4. 磁盘写满兜底：不再有额度，靠真实写失败。`.part` 写入失败已有 `deleteOnError` 与失败清理（`media_cache.dart:469-477,386`），下载任务侧把 ENOSPC 类失败落到 `DownloadPhase.failed` + 明确文案（现有 `download_manager.dart:211-213` 的保存失败告警保留）。仓库内没有任何 freeSpace 预检，本轮不新增（避免造一个测不出来的东西），列入后端/系统配合。

### 4.3 受影响测试（必须一起改，不许悄悄放宽）

- `packages/app/test/download_manager_test.dart:99` `settings quota cancels oversized transfer…`：语义整体反了 → 改成「额度不再拦截：超额传输照样完成，且并发数被限制住」。
- `packages/api/test/prefetch_scheduler_test.dart:111,132`（字节预算淘汰/取消预缓存）：预算改为只看自动文件后，需重算夹具里的保留/自动构成，断言口径不变。
- `packages/api/test/media_cache_test.dart:105`（手动下载在 LRU 与清理中存活）：应继续通过，是 4.2 第 1 条的保护性测试。
- `packages/app/test/interaction_cache_test.dart:365-373`、`settings_store_test.dart:240-242`、`tv_settings_test.dart:40`：涉及 `30 集 / 512 MB` 的 UI 断言，随设置项语义与新增并发项一起更新。

## 5. 验收口径

1. 单测：`packages/{core,api,app,tv,cast}` 全绿（在包目录内跑，api/core 有相对 fixture 路径）；`dart analyze --fatal-infos packages` 无 issue。SDK 一律用 `.fvm/flutter_sdk/bin/*`（3.47.4）。
2. 三端各出一张详情页截图（TV 模拟器、手机或 iOS 模拟器、macOS 带窗口），证明：动作行一行、选集块高度恒定、推荐位出现且无「热度/最新」角标。
3. 下载：一次并发 3 任务、总量超过原 512MB 上限的场景，任务全部完成且自动预缓存仍可插入（不被下载预算饿死）；证据为下载管理页截图 + 日志。
4. 无真机/无接收端的能力不得声称端到端通过；本轮相关推荐只有本地假数据测试 + 至少一次真实上游响应留样。

## 6. 落地状态（2026-10-22 12:40，工作树未提交基线）

已实现：§1 TV 动作行、§2 `EpisodePager` + 三端详情页接入（手机 3×100 / 桌面 4×120 / TV 4×170）、§3 `tagNames`（`category_schema`）+`related_dramas`+`RelatedDramasSection`+热门降级、§4 门禁移除/双台账预算/`downloadConcurrent`。

门禁读数（`.fvm` 3.47.4，包目录内跑）：core 117、api 71、app 215（~1 skip）、tv 32、cast 52；`dart analyze --fatal-infos packages` → No issues found。

真实上游留样（§5.4）：`packages/api/tool/related_sample.dart --dump-schema` → `docs/evidence/related-dramas/live-sample.json`（面板 29 项 / `cate_N`、首页 12 行仅 1 行名称命中面板、`category_schema` 出现 18 次且窗口内无 `cate_` id、未命中剧走 `hot_score` 拿到 12 条且不含当前剧）。

仍未验收，不得当作已完成：三端详情页截图（§5.2）、并发 3 + 超 512MB 的真实下载场景（§5.3）。
