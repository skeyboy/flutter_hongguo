# 片源切换与自动选源 UX 方案（source-switching-ux）

- 基点：`b306185`（main，含合并后的 `Episode.accessibleCount` + `locked` 并集）
- 分支：`feature/source-switching-ux`
- 参考：`references/hongguo-web/web/app.js`（选集卡片、自动连播、播放失败
  双向分类「no-source / playable」、预热下一集）——单源网页版没有多源概念，
  可借鉴的是**交互形态与错误分类思路**；多源取址原理参照
  `references/hongguo-drama`（submodule，`07791ca`，即
  `docs/analysis/2026-11-23_hongguo-drama-API后端分析.md` 的上游仓库），
  本项目多源适配器栈的落地以其结论为基线。

## 0. 现状缺口（探索结论）

| # | 缺口 | 证据 |
|---|---|---|
| G1 | 设置页承诺「来自 X 的内容将出现在搜索结果中」，但 `RoutingCatalogRepository.search/browse` 直委 primary（红果），其它源内容**从未出现** | `routing_catalog.dart:72-88` |
| G2 | 片源开关保存后**不生效**：`saveSettings` 的 `_rebuildClients()` 不覆盖 `sources`，注册表持旧快照 | `runtime_native.dart:366-410`、`source_registry.dart:26` |
| G3 | `VideoTrack.candidates` 只有类型定义 + custom 源填充，**无消费点**，多线路回退不落地 | `video_model_client.dart:204/236`；`media_cache.dart` 零命中 |
| G4 | 限免标记（「限免外」）只看本源 `beyondFree`，**不看有没有备选来源**；`locked` 在 UI 零消费，选集无任何标记 | `player_page.dart:1594-1627`；`episode_pager.dart:319-356` |
| G5 | 详情页/播放页无任何来源切换入口；`browseFrom/searchFrom` 无人调用 | `routing_catalog.dart:40-63`；`detail_page.dart:139-143` |

## 1. 设计原则

1. **红果路径零语义变化**：所有聚合/回退都以红果优先，回退只在失败或
   明确切换时发生。
2. **一切回退对用户可见**：自动切源成功时 toast「已切换到 X 源」；全部
   失败时失败卡片列清楚试过哪些源。
3. **标记诚实**：选集上的「限免外」只在**没有任何备选可播来源**时展示；
   有备选时保持可点，点击失败走跨源解析。
4. TV 全部入口遥控可达（`TvFocusable`），沿用 `tv_settings_surfaces_test`
   的约束。

## 2. 分阶段方案

### M1 片源开关即时生效 + 设置页展示增强

- `runtime_native.saveSettings`：对比新旧 `AppSettings.sources`，有变化即
  重建 `SourceRegistry` + `RoutingCatalogRepository`（保留 `_customTokens`、
  dio），并把注册表快照接到新的 `settings.sources`。
- 设置页「片源」分区：
  - 每行副标题标明来源类型与状态：红果「内置 · 始终启用」；国内源
    「国内 · 搜索结果中混入该源内容」；海外源「海外 · 需海外网络，默认关闭」；
    自定义源「自定义 · 苹果 CMS」+ 接口域名。
  - 分区头加「已启用 N 个来源」。
- 测试：saveSettings 重建（sources 变化触发、不变不触发）；分区渲染。

### M2 跨源同名解析器 + 详情页片源切换

- 实际落点 `packages/api/lib/src/source_resolver.dart`（原计划 app/catalog，
  为让播放层与 UI 层都能复用且纯 Dart 可测，下沉到 api 包）：
  `SourceResolver(facade).resolve({title, excludeId, excludeIds, episodeIndex})`
  → 依序在其它启用源 `searchFrom` 搜剧名，标题精确匹配（优先）或包含匹配，
  返回 `SourceMatch(sourceId, sourceLabel, drama, detail)`；`episodeIndex`
  由 `episodeAt()` 用于选集对齐（同 index 优先，找不到取最后一集）。
  依赖收窄为最小接口 `SourceSearchFacade`（`RoutingCatalogRepository` 天然
  实现），总预算 8s，`excludeIds` 排除已试源防自动跨源来回横跳，全部
  失败返回 null。
- 详情页：AppBar actions 加「片源」入口（`SourceSwitchSheet`）：
  - Phone：bottom sheet 列启用源（排除当前），点选 → resolver → 命中则
    push 新 DetailPage（带 `fromSource` 提示），未命中 toast「X 源未找到同名剧」。
  - TV：动作行加 `TvFocusable`「切换片源」，弹层同样遥控可达。
- 测试：resolver 匹配/超预算/全失败；sheet 交互。

### M3 播放自动选源

- **3a 同源候选回退**：`media_cache` 下载主 URL 失败（非取消）时依序尝试
  `track.candidates`（逐条过 `policy` 校验），取第一个成功者；全失败抛原错误。
  同时 xifan/hema 适配器把 `backup_url`（若有）填入 `candidates`。
- **3b 跨源自动回退**：播放失败分类为 `noSource/sourceRejected` 且存在其它
  启用源时，用 M2 resolver 以当前剧名 + 集号解析备选；命中则无缝换轨续播
  （进度对齐到同集开头），toast 提示；失败则保留现有失败卡片，文案列出
  「已在 N 个来源尝试」。
- **不做**「点击前预切源」：每集都先查其它源的成本（搜索+详情）不可接受；
  顺序仍是「当前源先试，失败才跨源」。
- 测试：candidates 回退（成功/全失败/被 policy 拒）；跨源回退成功与失败。

### M4 限免标记收敛

- 「限免外」/locked 标记条件改为
  `restricted && !hasPlayableAlternative`；`hasPlayableAlternative` =
  （启用的其它源数 ≥ 1）——有备选时不展示标记、不禁点，点击后由 M3b 兜底。
- 落点：`player_page.dart` 选集网格、`episode_pager.dart`（详情页 + TV）。
- 失败卡片 hint：有备选时改为「已在 N 个来源尝试，均未提供这一集」。
- 测试：标记条件（单源 vs 多源）。

### M0 搜索聚合多源

- `RoutingCatalogRepository.search`：**首页**（cursor 为空）并发查全部
  启用源（hongguo 结果保持原排名优先，其它源按注册表顺序尾随、按源内
  顺序），按标题去重，单源失败或 3s 软超时静默跳过；带 cursor 的翻页
  直委红果——游标是红果私有语义，混源翻页无法对齐（首页混入的其它源
  不会在下一页重复）。`browse` 同样保持红果直委，发现页混排破坏现有
  排序体验，明确不做。
- 合并语义抽成静态方法 `mergeSearchPages(primary, others)` 便于纯数据
  测试；`routing_search_merge_test.dart` 覆盖顺序/去重/失败源/游标。
- 设置页文案同步为「搜索结果中混入该源内容」。
- 测试：聚合顺序、单源失败不拖垮整体、去重、开关过滤。

## 3. 执行顺序与门禁

M1 → M4（标记逻辑小，先落） → M2（resolver） → M3（播放自动选源） →
M0（搜索聚合）。每阶段跑对应包测试；最后全量门禁：
`core / api / tv / cast / app` 全绿 + `dart analyze` 无 error + 真实提交推送
（CI 验证）。TV 布局改动必须过 `tv_settings_surfaces_test` 同款遥控可达约束
（新增 `tv` 断言用例）。

## 4. 不做的事（边界）

- 发现页（browse）不聚合多源。
- 搜索聚合只在首页；翻页（带 cursor）直委红果，游标不跨源。
- 不做跨源进度同步（切源后从该集开头播）。
- 不做「锁定集跨源预检」：标记只做启发式（有备选就不标），不真实预查。
- 自动跨源每会话最多两次，且已试过的源不再回切。

## 5. 落地记录（本轮执行结果）

全部阶段已实现并提交到 `feature/source-switching-ux`。关键实现与计划差异：

- 解析器下沉 api 包（见 §2 M2），新增「精确命中跨源优先」与 `excludeIds`。
- 跨源自动回退落在播放页 `_tryCrossSource`：只对
  `noSource/sourceRejected` 触发，换轨后 `PrefetchWindow.retarget` 撤销旧源
  预热、按新集列表重启；失败卡片列出已尝试的片源数。
- 搜索聚合抽 `mergeSearchPages` 纯函数；首页混入其它源、游标仍取红果。

门禁（本轮 Windows 本机）：

| 包 | 结果 |
|---|---|
| core | 155 全绿 |
| api | 全量仅 `video_model_client_test` 的 120ms deadline 用例偶发失败——在干净基线 `b306185` 上同样复现，确认既有 flaky，与本分支无关；另 `media_cache_test` 一条在并发负载下偶发，单跑两次全绿 |
| cast | 52 全绿 |
| tv | 38 全绿 |
| app | 两批共 526 全绿（含跨源/预取/片源分区/TV 遥控用例） |
| analyze | 五包 No issues found |

TV 真机遥控回归未做（本机无 TV 设备/模拟器），由 `tv_settings_surfaces_test`
与 TV 包 38 测试兜底；CI 负责 Windows 桌面构建验证。
