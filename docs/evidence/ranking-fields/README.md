# 榜单字段与筛选词表 · 实机取样证据

**跑的是什么**：`packages/api/tool/rank_sample.dart`（只读、匿名、无凭据）。取数口径 = 走 app 自己在用的 `CatalogClient`（同一个签名策略、同一个重试器），所以这里读到的就是产品将来能读到的，不是抓包猜的。

```
(cd packages/api && ../../.fvm/flutter_sdk/bin/dart run tool/rank_sample.dart <abs-output-path>)
```

**落了什么、没落什么**：四次运行各写一份 JSON。文件里只有维度名、`selector_item_id`、`cate_*` id、榜单卡的标题/集数/热度文案/评分/徽标/主色，以及字段是否存在与是否为 null 的形状读数。**没有** URL、请求头、签名参数、媒体 key、cookie、手机号/设备号，也没有任何整包响应体（`rank_sample.dart` 的 `_isSensitive` 拦键名，`shape()` 把 >40 字符的字符串折成 `<string:N>`）。评论只记条数。这是本目录 158–176KB/份 与既有先例（`docs/evidence/related-dramas/`）同量级的原因。

## 1. 四次运行覆盖矩阵（同一天 71 秒内、同一网络、`retry: NetworkRetry(delays: const [])`）

| 文件 | `at`（UTC） | short_play 词表 | comic_series | ai_series | 三块榜 |
| --- | --- | --- | --- | --- | --- |
| `live-sample.json` | 2026-10-30T02:04:01Z | 缺（空 200） | 9 维 | 7 维 | 3/3 各 10 条 |
| `sample-1.json` | 2026-10-30T02:04:56Z | 缺 | 缺 | 缺 | 3/3 各 10 条 |
| `sample-2.json` | 2026-10-30T02:05:04Z | 7 维 | 8 维 | 7 维 | 3/3 各 10 条 |
| `sample-3.json` | 2026-10-30T02:05:11Z | 7 维 | 缺 | 7 维 | 3/3 各 10 条 |

- 词表按类型**分次缺席**：short_play 2/4、comic_series 2/4、ai_series 3/4、sample-1 全缺。缺席的形态是同一条：`IncompleteCatalogResponse: 内容接口未返回数据，请稍后重试`（上游 HTTP 200 + 空 body，`catalog.dart:377-382` 因此把该客户端的请求策略升级为签名请求）。
- 榜单**四次全通**、每块 10 条、名次稳定（推荐榜第 1 名一直是《糯糯下山，师兄们都慌了》）。所以「榜」比「筛选词表」可靠，界面不能把两者绑在同一次请求的成功上。
- 结论落到设计上：筛选行必须能整行消失（缺词表 ≠ 空状态），榜模块不能因为筛选失败而一起空。原型 `docs/design/prototypes/discover-filters-ranking.html` 的「有词表 / 加载中 / 词表缺行 / 请求失败」四档就是在演示这条。

## 2. 筛选项：上游按类型发布的完整维度（四次取样的并集）

`row_name`（上游原名）与实测项数；`selector_item_type` 之外还带了 `selection_type`（单选/多选由上游给，不用前端猜）。

| 类型 | 体裁 | 主题 | 设定 | 背景 | 受众 | 时间 | 推荐 | 画风 | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 真人剧 short_play | 3 | **29** | **42** | 11 | 2 | 4 | 3 | — | — |
| 漫剧 comic_series | 3 | 8 | 8 | 9 | 2 | 4 | 3 | **3** | **2** |
| AI 剧 ai_series | 3 | 8 | 8 | 9 | 2 | 4 | 3 | — | — |

- id 就是 `cate_*`（主题/设定/背景/画风）、`1`/`0`（受众=男频/女频）、`days_7|14|30|90`（时间）、`creation_status_0|1`（状态）、`online_time|hot_score|hot_collect`（推荐三档）。
- **app 发了哪些键、缺哪些**（现读 `catalog.dart:409-421` 的 `_selection()`，它总共只组 7 个键）：`genre`/`sort`/`category_dim_theme` 三个是真填的；`category_dim_role`（设定）、`category_dim_epoch`（背景）、`gender`（受众）、`online_time`（时间）**四个键发出去了但恒送空数组**；`category_dim_art_style`（画风）与 `creation_status`（状态）**这两个键在本仓里连出现都没有**（`grep -rn "art_style\|creation_status" packages/api/lib packages/app/lib` 零命中），而它们恰好是漫剧独有的两维。词表读取侧同样只挖一行：`_themes()`（`catalog.dart:470-504`）命中 `type` 含 theme 或 `row_name` 含「主题」的那一行就 `return`，其余 6–8 行连同 `row_name`、`selection_type` 一起丢。
- 所以发现页「只有两个筛选」是实现缺口，不是上游缺口——缺的是「把已发的四个空键填上 + 补发两个没发的键 + 把词表整表读回来」。这条决定了 §4 的分层能落地，且不用等后端。
- `全部画风/全部状态`只在漫剧出现，是**维度集合按类型不同**的直接证据：界面不能画一张固定表单，只能「上游给几行画几行」。

## 3. 榜单：赛道 × 榜单由上游自己发布（`cell_selector`）

下表是**四次取样的并集**（`live-sample.json` 顶层 `cellSelectorSample` 是其中一次的原文，差异见后面的条数说明）：

| 赛道 `selected_items` | 发布出来的榜（`sub_selected_items`） | 块数 |
| --- | --- | --- |
| `all`（全部） | 推荐榜 `ranklist_hot_sc` / 热播榜 `ranklist_hot_play_sc` / 臻果榜 `ranklist_prestige` / 预约榜 `ranklist_subscribe` / 新剧榜 `ranklist_new_rank_sc` / 热搜榜 `ranklist_hot_search_sc` / 追更榜 `ranklist_chase_update` / 必看榜 `ranklist_must_watch` / 收藏榜 `ranklist_followed` | 9 |
| `comic_series_rank`（漫剧） | 推荐榜 / 热播榜 / 新剧榜 / 热搜榜 | 4 |
| `human`（真人剧） | 推荐榜 / 热播榜 / 新剧榜 / 热搜榜 / 必看榜 / 收藏榜 | 6 |
| `ai_playlet`（AI 剧） | 同上六块 | 6 |
| `ranklist_celebrity`（演员） | 剧星榜 `ranklist_series_actor` / 星光榜 `ranklist_actor_fans` | 2（`live-sample` 那次返回 0，见下） |

- 合计 **5 条赛道 / 25–27 块榜**（id 全部互不相同）。**条数不是常量**：`live-sample` = 25（演员赛道整个 `sub_cell_selector` 缺失）、`sample-1`/`sample-2` = 27、`sample-3` = 26（全部赛道少返回臻果榜 `ranklist_prestige`，且赛道顺序变成 全部/真人剧/漫剧/AI剧/演员）。app 现在硬编码只认漫剧赛道下的 3 块（`catalog.dart:506-550`），也就是「接口已发布、app 未接」。**任何界面/代码都不得写死赛道数或榜块数**，必须每次从 `cell_selector` 现读。
- **周期这一维上游没有**：`inner_rows` 四次都是空（`[]`）。所以「日/周/月」不能做——不是暂缓，是这条设计要删掉（原文档 §8.2 押的是「必须先抓真响应枚举」，现在枚举完了）。
- 演员赛道的两块是**演员榜，条目不是剧**（剧星榜/星光榜）。所以榜单页不能假设每条 `RankEntry` 都挂得住 `Drama`：接这两块要么给演员专用条目模型，要么在界面上把它们跟剧榜分开。
- 「全部」赛道**不是其余赛道的并集**：它独占臻果榜 / 预约榜 `ranklist_subscribe` / 追更榜 `ranklist_chase_update` 三块，这三块在任何单赛道下都没有；反过来漫剧只有 4 块（没有必看/收藏）。

## 4. 榜卡字段：哪些今天就有真值（`rawCards`，每块榜 10 条）

| 界面元素 | 上游字段 | 实测样本值 | app 现状 |
| --- | --- | --- | --- |
| 位次 | 无字段，`cell_data` 数组下标 | 1…10 | 只能靠下标（本来就该这么用） |
| 热度/推荐文案 | `rec_text_item.RecommendText` | 「997万推荐」「9388万热度」「6182万热度」 | `Drama`（`catalog.dart:81-129`）未保留 |
| 次行（收藏等） | `secondary_info_list[i].content` | 「422.8万收藏」「38万收藏」 | 未保留 |
| 评分 | `score` | 「8.2」「8.6」 | 未保留 |
| 徽标 | `tag_info.text` | 「爆剧」「新剧」 | 未保留 |
| 副标题（题材·集数） | `sub_title` | 「玄幻·全1000集」 | 未保留 |
| 占位主色 | `color_dominate` | `#282828`、`#481810` | 未保留（离线封面缺位时可用） |
| 播放量 | `play_cnt` | 11770116 / 1035 | 未保留 |
| 更新时刻 | `rank_version` | 见下 | 未保留 |
| 趋势箭头 | `rec_arrow_type` | **四次 30 张卡全为 0** | 字段位在、语义未证实 → 界面画虚线占位 |

榜内还有但本轮设计不用的：`recommend_info`、`recommend_reason_list`、`hot_comments`（只记条数）、`category_schema`、`copyright`、`pay_info`、`support_listen`、`disable_play`、`book_exist`、`duration`、`content_type`、`episode_cnt`。

**两条必须写进界面的坑**：

1. `play_cnt` 与 `rec_text_item` 不是一个口径。热播榜第 3/4 名《遇棠方知涉：被偏执大佬黏上了3》《烛九阴第八季》的 `play_cnt` 只有 **1035 / 984**，而 `rec_text_item` 写 **6182万 / 6038万热度**。同一条卡上两个数差四个数量级 → 界面只能说一个「热度」，取 `rec_text_item`；`play_cnt` 不许并排显示，否则用户会以为榜是错的。
2. `rank_version` 只给两块榜。推荐榜恒为 `''`，热播/新剧给 epoch 秒：`live-sample`（02:04:01Z 取）→ `1793325600` = 02:00:00Z，另外三次（02:04:56/02:05:04/02:05:11Z 取）→ `1793325840` = 02:04:00Z。**整分钟**（mod 60 = 0），且比取样时刻滞后 0–4 分钟，所以「更新于」能写分钟、不能写「实时」。推荐榜拿到空串 → 那一步只能不显示「更新于」。

## 5. 这些读数怎么被用掉

- `docs/design/discover-filters-ranking.html` 里的 `const API` 常量由 §2/§3/§4 直接导出（`sample-2.json` 的词表 + `live-sample.json` 的赛道榜单与卡面字段），字段名与 `show_name`/`selector_item_id` 原样保留；原型页脚的取样时刻就是本节四次 `at` 的两个来源。**原型不写死条数**：赛道数、榜块数、维度项数都由这份常量现算，所以本表若被更正，原型不会跟着撒谎。
- 设计文档 `docs/design/discover-filters-and-ranking.md` §8 的「未证实」条目按本表逐条改成实测结论；§6.1 是由此写出的详细人机交互规格。
