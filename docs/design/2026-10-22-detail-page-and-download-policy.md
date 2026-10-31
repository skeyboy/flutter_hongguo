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
   - 限速由 `catalog.dart` 的 260ms 串行队列统一负责，不自建节流。原计划让请求走 `CatalogRequestScope`（页面销毁即取消），但该 API（`packages/api/lib/src/request_control.dart` 与 api barrel 导出）属于另一会话尚未提交的改动，本轮已解耦提交；接回只需给 `RelatedDramaLoader.load/_start` 加回 `scope` 参数并用 `scope.run` 包住 `_read`——`_start` 的 catch-all 已经会吞掉 `RequestCancelled` 并且不写缓存。
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

## 6. 落地状态（2026-10-22 13:50，已提交 `7b76dcd` + `8afdbf8`）

已实现：§1 TV 动作行、§2 `EpisodePager` + 三端详情页接入（手机 3×100 / 桌面 4×120 / TV 4×170）、§3 `tagNames`（`category_schema`）+`related_dramas`+`RelatedDramasSection`+热门降级、§4 门禁移除/双台账预算/`downloadConcurrent`。

门禁读数分两个口径，别混用。提交内容的独立工作树（`../flutter_hongguo-verify-v0.3.2`，只含本轮路径；该 worktree 连同其中的 `build/verification/**` 原始日志已于 2026-10-22 删除，以下读数是该树被删前的历史记录）：core 117、api 57、app 211（~1 skip）、tv 32、cast 52，CI 口径另跑 `dart test`（api）57、`flutter test test/tv_settings_test.dart --dart-define=HONGGUO_TV=true` 1、`python3 -m unittest discover -s tool/ci/tests` 9 全绿，`dart analyze --fatal-infos packages` → No issues found。开发工作树的读数是 core 117、api 71、app 215、tv 32、cast 52，多出来的用例属于另一会话尚未提交的请求控制与计时改动，不代表已入库。

本轮相关推荐取数已与 `CatalogRequestScope` 解耦后提交（该 API 与 `request_control.dart` 仍未入库），页面销毁时的取消待其落地后接回。

真实上游留样（§5.4）：`packages/api/tool/related_sample.dart --dump-schema` → `docs/evidence/related-dramas/live-sample.json`（面板 29 项 / `cate_N`、首页 12 行仅 1 行名称命中面板、`category_schema` 出现 18 次且窗口内无 `cate_` id、未命中剧走 `hot_score` 拿到 12 条且不含当前剧）。重跑该探针只读列表与详情接口，不打印 URL、请求头、请求体或任何签名。

仍未验收，不得当作已完成：三端详情页截图（§5.2）、并发 3 + 超 512MB 的真实下载场景（§5.3）。v0.3.2 是在这两项未完成的情况下按决定先发的大包，发布说明里对应的两条只声明到组件与用例层，设备验证仍挂在验收清单上。

## 7. 2026-10-31 实施补记：标签行与 `tagNames` 链路

出处：`docs/design/video-detail-redesign.md` §3.3（标签行）与 §7（推荐块名）。那份文档的 §0 表里 25 条，读完代码后只有 §3.3 是**客户端要补**的一条，其余 24 条都是原型向已有代码对齐（头部尺寸、无 hero、无侧栏、`Text(intro)` 不截断、分页器无外壳、AppBar 56/22、下载弹层高度、推荐卡尺寸……代码本来就是这样），所以本轮只动这一条，外加顺手在它上面修掉一条真 bug。

| 做了什么 | 在哪 | 判据与读数 |
| --- | --- | --- |
| 头部下方渲染 `tagNames`，面板有同名词的那枚才是入口 | `features/detail_page.dart:298-305`（`Wrap`，位置在头部 `Row` 与简介之间，就是 §3 的那条块序）、`:91` `_tags`、`:99` `_tag` | 入口 = `ActionChip(key: detail-tag-entry-<cate_id>)`；面板无 = `Text(key: detail-tag-plain-<词>)`。同名判据与「同题材 · X」共用一条：`option.name.trim() == name`（`recommendations/related_dramas.dart:94`），不就近找一个相近的词 |
| 词表取的是发现页**正在用的那一型** | `:49` `_loadPanel`，取 `catalogThemeHandoff.genre`；发现页在 `library_page.dart:716` 挂上、`:3389` `_writeSlot` 里 publish | 用例「标签映射的是发现页正在用的那一型的词表」：先切到漫剧再进详情，`themes()` 收到的参数就是 `comic_series`。词表没回 = 一枚入口都不画（用例「词表没回 = 这一页一个入口都不画」） |
| 点入口 = pop 回发现页并带上该筛选 | `:117` `_openTheme` → `navigation/catalog_theme_handoff.dart`（新，40 行）→ `Navigator.popUntil(isFirst)`；发现页 `library_page.dart:2004` `_applyThemeAsk` 消费 | 消费走的是它自己 `找同题材 ›` 那条 `_selectFilter('theme', id, destination)` + `_explain`，所以排序、滚动位置、L2′ 其余维度一个字都不动；从「我的」/榜单那一层点进来的先 `_selectTab(destination)` 把层摘掉。用例「点入口 pop 回发现页，主题行当场选上这一个」验到 `theme-rail-cate_7` 亮、请求带 `cate_7` |
| **修**：`_load()` 合并出的 Drama 一直丢 `tagNames` | 当时改在 `detail_page.dart:88`，本轮 §8 起那条规则整体搬到 `catalog/detail_fallback.dart:20` | 丢的那个后果不是标签行画不出，是 `loadRelated` 永远读不到题材词 → 推荐块永远落「平台热门」。把这一行删掉，本轮 4 条用例一起红（含「详情合并后仍带着题材词，推荐块才敢叫「同题材 · X」」）——这条是已验的，不是推测 |
| **修**：离线快照不存题材词 | `catalog/library_cache.dart:7-16`（`dramaJson` 按上游写法存 `category_schema`）、`:112-135`（`_enrich` 三个来源取第一个非空）、`:218` | 用例「离线快照把题材词一起存下来」。以前断网进详情，标签行与「同题材」都无从读起 |

本轮没做、也不许当成做了的：

- **TV 这一页不加标签行。** 那份文档 §8 的焦点序（`:128-251`）里没有它，`features/tv/tv_detail_page.dart` 是另一套版面；要给遥控族加，得先把「标签行落在动作行之前还是之后、跨行焦点怎么交接」写进 §8，而不是先画了再说。
- **§6 那条 TV 待办仍未定**：下载 snackbar 的「查看」在遥控族按不动（焦点不会自己跳到 snackbar）。二选一（提示 + 焦点留在原动作 / 动作行第三枚按钮）没定，就没动 `downloads/download_selection.dart`——那个文件此刻另有会话在改。
- **§3.2 窄屏封面与标题降档、§8 选集格子 16/14 字号**：两份文档都明写「待议，不由原型擅自拔高」，本轮一行没改。
- **验收口径**：本轮只跑到组件与用例层（下表）。§5.2 的三端详情页真机截图、「点标签 → 发现页被收窄」的实机读数仍未做，不得写成已完成。

验证读数（2026-10-31，Windows 克隆树 `C:\Users\lee\Documents\Codes\flutter_hongguo`；Dart 套件只能在 NTFS 克隆里跑，`\\Mac` 共享目录跑不了）：`dart format --set-exit-if-changed` 本轮 5 个文件 0 变更；`flutter analyze`（`packages/app`）No issues found；`flutter test`（`packages/app`）+364 ~1 全过（新增 `test/detail_tag_row_test.dart` 6 例，跳过的那 1 例是 flavor 专项）；`flutter test --dart-define=HONGGUO_TV=true test/tv_settings_test.dart` +1。两个 flavor 各出一包：`flutter build apk --debug --flavor tv --target-platform android-arm64` → √ `app-tv-debug.apk`，`--flavor mobile` → √ `app-mobile-debug.apk`。

## 8. 2026-10-31 第二轮：把同一条判据补到剩下两支，并裁定 §6 的 TV 待办

`docs/design/video-detail-redesign.md` §0 那 25 条里，需要客户端动的一直只有 §3.3 一条；上一轮做的是手机/平板/桌面那一支。这一轮按同一份文档做两件收尾：**§7 的块名判据在 TV 那一支同样成立**、**§6 末尾那条 TV 待办定下来**。§7 未做清单里第 2 条（TV 待办）本轮关闭，第 1 条（TV 标签行）与第 3 条（待议两条）仍开着。

| 做了什么 | 在哪 | 判据与读数 |
| --- | --- | --- |
| 详情页的兜底合并从"每页各写一遍"变成一条规则 | `catalog/detail_fallback.dart`（新，24 行）；调用方 `features/detail_page.dart:76`、`features/tv/tv_detail_page.dart:43` | 不是整理代码，是修 bug：TV 那一支以前直接用详情响应，`tagNames`/标题/封面/简介全没兜底，所以遥控族的推荐块**永远**落「平台热门」——上一轮在手机侧修掉的正是同一条。用例「详情没回题材词时用列表行兜底，块名才不是「平台热门」」：详情只回 id 与两集，列表行带 `玄幻` → 块名读得出、标题与简介读得出。把 `tv_detail_page.dart:43` 那句合并删掉，只有这一条用例红（已验，不是推测） |
| 推荐块与标签行读**同一张面板** | `recommendations/related_dramas_section.dart:57-61`（传 `catalogThemeHandoff.genre`）、`recommendations/related_dramas.dart:132-136`（`loadRelated` 收 `genre`；loader 的缓存键本来就含类型） | 块名「同题材 · X」声称的是"这次 browse 按该题材筛"，那么 id 与 genre 必须同源。以前恒用 `short_play`：在漫剧那一型里进详情，标签行是拿 `comic_series` 面板判「面板有/面板无」的，块却是拿另一张面板判、拿另一型的列表筛——同一页可以同时撒谎。用例「换了一型之后，标签和推荐块读的是同一张面板」读 `(genre, theme)` 这一对：`contains((comic_series, cate_7))`，并反向断言没有任何一个 `cate_7` 请求配着别的类型发出去 |
| **§6 TV 待办裁定：动作行加一枚 `下载管理`** | `features/tv/tv_detail_page.dart:219-240`（`TvFocusable(label: '下载管理')` → `MaterialPageRoute('/tv/downloads')` → `features/downloads_page.dart`，那一页早有 TV 版面 `:303-332`） | 二选一里选了"第三枚按钮"而不是"提示 + 焦点留在原动作"，因为后者要改 `downloads/download_selection.dart`（本轮另有会话在改那个文件），前者只在 TV 这一页里补一个可达焦点项，代价与收益都当场可读。**注意这条没"修好" snackbar**：`download_selection.dart:46-62` 那枚「查看」在遥控族仍然按不动，只是多了一条走得通的路；等那个文件空闲再决定摘不摘 |
| 用例收尾的一个坑（写下来免得下一轮重踩） | `test/tv_library_surfaces_test.dart:440-448` | `DownloadFakeRuntime` 的 `dispose()` 里 manager 的保存是防抖计时器，`addTearDown(runtime.dispose)` 会在 teardown 里干等 10 分钟；必须按 `download_ui_test.dart:24-28` 那套「先起 dispose、`await tester.pump()`、再 await」收尾 |

仍没做、也不许当成做了的：

- **TV 详情页标签行**：§3 的块序是照 `detail_page.dart` 写的，§8 的 TV 焦点序是照 `tv_detail_page.dart` 的实际顺序写的，两份口径没给「标签行上不上 TV」一条裁定；而 TV 的主题行在 `features/tv/tv_library_page.dart`（本轮另有会话在改），消费方不在这页里。等 §8 补一条焦点序、那个文件空闲，再做入口与跨行交接。
- **TV 那一页没有离线兜底**（本轮对账新发现，未改）：`features/detail_page.dart:67-74` 在详情请求失败时读 `LibraryCache` 那条快照并画 §3.1 的离线横幅，`features/tv/tv_detail_page.dart:42-49` 没有这一段——遥控族断网进详情只有「加载失败 + 重试」。没顺手补一半，是因为 §3.1 的快照与「重试刷新」是**成对**的：只把快照读出来、正文里却没有一个焦点项走得到的刷新钮，就等于把陈旧数据静默当成最新数据画出来。要做就得连那条「重试刷新」一起进 §8 的焦点序。
- **§3.2 窄屏封面/标题降档、§8 选集格子 16/14 字号**：仍是待议，本轮一行没改。
- **验收口径不变**：本轮只跑到组件与用例层。§10 那条「浏览器带窗口逐视图截图」是**原型**的验收方式，不能当设备验证；详情页三端真机截图、「点标签 → 发现页被收窄」的实机读数依旧挂着。

验证读数（2026-10-31 第二轮，同一台 Windows 克隆树）：`dart format --set-exit-if-changed` 本轮 7 个文件 0 变更；`flutter analyze`（`packages/app`）No issues found；`flutter test`（`packages/app`）**+367 ~1 全过**（上一轮 364，本轮新增 3 例：`test/detail_tag_row_test.dart` 1 例、`test/tv_library_surfaces_test.dart` 2 例）；`flutter test --dart-define=HONGGUO_TV=true test/tv_settings_test.dart` +1；两个 flavor 各出一包：√ `app-tv-debug.apk`、√ `app-mobile-debug.apk`。反向验：在克隆树里分别撤掉本轮两条修复，`flutter test test/tv_library_surfaces_test.dart test/detail_tag_row_test.dart` 得到 **+20 −2**，红的正是「详情没回题材词时用列表行兜底」与「换了一型之后，标签和推荐块读的是同一张面板」这两条，其余不动；恢复后 7 个文件与共享盘逐字节一致。
