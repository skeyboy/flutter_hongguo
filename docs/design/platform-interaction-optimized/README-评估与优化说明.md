# 平台交互原型 · 评估与优化说明

> 生成日期：2026-11-26
> 对象：`platform-interaction-{tv,mobile,pc}.html`（源自 `docs/design/prototypes/` 最新版改版稿）
> 本目录是原型的**优化副本**：原始三稿未改动，全部优化在此目录内进行。
> 打开方式：直接用浏览器打开五个 HTML（依赖 `prototype-data.js` / `prototype-real-data.js` / `interaction-prototype.js` / `interaction-prototype.css` 已随目录复制）。
>
> **本版本范围声明：不执行播放页相关的交互操作变更。** PC / Mobile / TV / iPad 的播放器与播放控制状态机一律沿用上一版原需求；本轮只改官网搜索分页、个人中心、iPad 信息架构、详情页信息顺序。五份原型顶部均有黄色标注。

---

## 一、评估结论（结合当前项目交互 + API 数据结构）

评估基准来自现读代码与设计文档，关键依据：

- `packages/api/lib/src/catalog.dart` — `Drama` / `CatalogFilter` / `CatalogDim` / `CatalogQuery` / `CatalogPage`
- `packages/api/lib/src/ranking.dart` — `RankEntry` / `RankPage` / `RankTrack` / `RankBoard`
- `packages/api/lib/src/catalog.dart` `Episode` — `vid/index/title/accessibleCount/locked`，`beyondFree = index > accessibleCount`
- `packages/api/lib/src/video_model_client.dart` — `VideoTrack{quality,format,candidates,policy}`
- `packages/core/lib/src/config/app_settings.dart` — `AppSettings`（本地事务持久化，无服务端端点）
- `docs/design/discover-filters-and-ranking.md` §4 — 排序只有三档；榜单两层（赛道 × 榜单）；位次来自数组下标；热度只取 `rec_text_item`
- `docs/evidence/ranking-fields/README.md` — 榜单真值字段位（热度/收藏/评分/徽标/主色/更新口径）

### 1. 数据结构不一致（硬伤，已修）

| 问题 | 原型原状 | 真实结构 | 影响 |
|---|---|---|---|
| 排序键是编造的 | `hot` / `new` / `favorite`，文案热门/最新/收藏 | `online_time` / `hot_score` / `hot_collect`（最新上架/最高热度/最高收藏） | 原型请求参数无法映射到真实请求 |
| 榜单只有一排 tab | 推荐/热播/新剧 三个扁平 chip | 赛道(`selected_items`) × 榜单(`sub_selected_items`) 两层，5 赛道 × 25–27 榜 | 丢失「赛道」这一层，通用榜名误导为当前类型榜 |
| 榜卡只显示收藏数 | `favoriteCount`（模拟 hash 值） | 位次=下标、热度=`rec_text_item`、收藏=`secondary_info_list`、评分=`score`、徽标=`tag_info.text`、主色=`color_dominate`；`play_cnt` 与热度不同口径不能并列 | 榜不像榜，信息密度不足 |
| 更新口径缺失 | 只写「缓存日期」 | `rank_version` 非空才写「更新于 HH:MM」，推荐榜实测为空 → 必须可空；不写「实时」 | 口径失真 |
| 选集只有数字 | `{number,title,vip,preview}` 且 vip 全 false | `vid/index/title/accessibleCount/locked/beyondFree` | 限免集无标识，点击无门禁 |
| 线路是纯装饰 | `{id,label,status,playable}`，切换只弹 toast | `VideoTrack{quality,format,candidates,encrypted}`，同源多线路走 candidates 回退 | 切线路不改变任何状态 |
| 设置只弹 toast | 保存按钮仅 `showToast("设置已保存")` | `SettingsStore.save()` 本地事务持久化 + 版本迁移 | 原型不体现「保存后仍在」 |

### 2. 交互桩（已修）

- 播放器 `seek()` 只弹 toast，进度条/时间不动；移动端进度条 `value*7.48` 硬编码时长
- 移动端设置页**没有保存按钮**， snackbar 默认文案却是"设置已保存"（自相矛盾）
- PC 的 J/L 键只 toast；`[data-track]` 切换不被播放器消费
- 移动端 `state.sort` 无 UI 控件，只能被重置
- 三端详情页 `sourceLabel/sampledAt/simulatedFields` 是原型元信息，不是业务字段（已保留但明确标注为"模拟字段"）

### 3. 主流 App 调研对照（第二轮依据）

后台并行调研 PC / Mobile / TV / iPad 四端主流影视 App（腾讯/爱奇艺/优酷/芒果/B站/Netflix/YouTube/Apple TV/Google TV/红果/ReelShort/DramaBox 等），结论：

- **PC**：左侧 rail + 顶部搜索是共识；筛选收进抽屉；进度条 hover 缩略图+时间气泡；剧院/画中画双形态；完整快捷键；低频操作进右键菜单；唯一强调色。
- **Mobile**：红果原创「单列竖屏 feed + 九宫格选剧」双模式最贴合短剧；双击 ±10s、长按临时 2×、抽屉选集（已看/未看异色）、追剧/预约、限免余额明示；toggle 即时生效 + 表单显式保存。
- **TV**：焦点三态（放大 1.15×+描边+投影）且与选中分离；注视点固定、整行移动；控制条进度条独占上行；Back 逐层消费 + 两次返回防误触；一屏 4–6 卡露角提示。
- **iPad**：横屏左 rail（带标签）+ 右内容两栏；竖屏退化单列；三段式播放页；竖剧默认"适应"保留完整画面 + 一键"铺满"；画中画/边选边看；窗口变窄自动降列。

调研来源 URL 见各端 agent 报告（Netflix Tudum、Apple HIG、Android 设计指南、华为视频帮助、流媒体网、各产品帮助页等）。

---

## 二、已执行的优化

### 轮次一 · 对齐真实 API 与交互

**共享层**
- `prototype-data.js`：`SORTS` 改为真实三档键；`browse()` 按新键排序；`makeEpisodes()` 输出 `vid/index/accessibleCount/locked/beyondFree`；`rank()` 支持 `(type, trackId)` 并返回 `RANK_TRACKS`、位次/热度/评分/徽标/主色/收藏/`updatedAt`/`trend:null`；`tracks` 补 `quality/format/candidates`。
- `interaction-prototype.js`：新增 `PlaybackClock`（真实推进进度，支持 seek/倍速）与 `SettingsStore`（localStorage 持久化，对齐 `SettingsStore.save()` 语义）；新增 `bell` 图标。

**三端共同**
- 榜单升级为**赛道 × 榜单两层**；切换赛道自动落到该赛道第一块榜；某赛道没有的子榜整枚不画；标题写赛道名（消除"通用榜名"误导）。
- 榜卡渲染位次 + 热度 + 评分 + 徽标 + 题材集数 + 主色占位；收藏与热度不同框并列；更新口径写「更新于 HH:MM」，空 `rank_version` 不写；live 空榜明确「不降级为浏览推荐」。
- 选集渲染锁定态（虚线斜纹），点击限免外集时：无可用备选线路才拦截，有备选则允许点击走跨源兜底（对齐 `restricted && !hasPlayableAlternative`）。
- 线路 chip 显示清晰度与备用线路数；切换 toast 说明 candidates 回退。
- 播放器 `seek` 全部改为真实推进（TV 确认提交 / Mobile 双击横滑 / PC 按钮与 J/L）。
- 设置保存写入 localStorage，重开仍在；移动端补出「保存」按钮。

**分端**
- Mobile：筛选抽屉新增**排序三档**控件（原本 `state.sort` 无 UI）；搜索改用当前排序。
- PC：排序菜单描述改为真实三档口径；搜索改用当前排序。

### 轮次二 · 结合主流 App 调研

- **TV**：焦点升级为「放大 1.06× + 高亮描边 + 柔和投影」三态；大卡片（海报/选集/榜行）不整体放大只加内描边；导航项失焦态保留栏目上下文；退出播放器改为**两次 Back 防误触**；快进退预览同时显示目标时间点与相对秒数。
- **PC**：进度条新增 **hover 时间气泡 + 点击落点 seek + 方向键微调**；新增 **T 剧院模式**；J/L 改为真实 ±10s；快捷键卡片同步。
- **Mobile**：发现页新增**单列沉浸 / 九宫格双模式切换**（红果双模式）；详情页补**追剧 + 预约**按钮与限免提示；iPad 横屏 rail 展开为 180px 带标签、栅格加到 5 列、详情两栏；播放器新增**「适应 / 铺满」**开关（解决竖剧横屏黑边/裁切痛点）。
- **iPad**（在 mobile 稿的设备形态上强化）：`pad.landscape` 两栏布局 + 5 列栅格；`split` 窗口变窄降列已有基础；画中画/旋转入口保留。

---

## 三、验证

- 全部 JS 文件（5 共享 + 4 内联）通过 `node --check`。
- 四份 HTML 中所有 `querySelector("#id")` 引用的元素均存在（TV 53 / Mobile 81 / PC 87 / iPad 32，零缺失）。
- 用 Chrome headless 对四个原型做了真实渲染 + 控制台错误检查：四端零错误；「我的」页异步渲染、榜单真值展示均已截图核验。

---

## 四、第三轮 · 真值数据 + 新形态（2026-11-26 下午）

本轮把 README 上一版列出的四条「后续建议」全部实施，并回应三项新需求。

### 4.1 真值数据接入（来自实机采样，不再编造）

新增两个共享文件，四个原型统一加载：
- `prototype-real-data.js` — 从 `docs/design/prototypes/discover-filters-ranking.html` 的 `const API` 原样导出；源头是 `docs/evidence/ranking-fields/live-sample.json` + `sample-2.json`（2026-10-30 四次实机匿名采样，走 app 自己的 CatalogClient）。
- `prototype-data.js` — 完全重写，消费真值模块：

| 数据 | 真值来源 | 本轮前（编造） | 本轮后（真值） |
|---|---|---|---|
| 剧目 | `API.feed` | 30 条自造剧名 | 36 条真值（真人剧/漫剧/AI 剧各 12），如「离婚后他才知道资方只认我」「从黑龙开始，吞噬诸天第二季」 |
| 赛道×榜 | `API.rankTracks` | 3 赛道 × 3 榜 | **5 赛道 × 25 榜**（全部/漫剧/真人剧/AI 剧/演员；推荐/热播/臻果/预约/新剧/热搜/追更/必看/收藏…） |
| 榜卡字段 | `API.rankBoards` | 模拟收藏数 hash | 真值位次/热度（如「9388万热度」）/收藏（「422.8万收藏」）/评分（「8.2」）/徽标（「爆剧」）/副标题（「玄幻·全1000集」）/主色（`#481810`） |
| 更新口径 | `API.rankMeta` | 写死日期 | 推荐榜 `updatedAt=null`（上游空串）；热播/新剧取 epoch 秒换算 |
| 筛选项 ID | `API.dims` | `cate_5007` 等假 ID | 真值 `cate_165` 悬疑、`cate_739` 逆袭、`online_time/hot_score/hot_collect` 三档 |
| 搜索 | 独立方法 | `search = browse` 别名 | 独立 `search()`，返回 `passback`/`searchId`，游标语义与目录 offset 区分 |

**诚实性约束**：本轮只有 3 块榜落了卡面真值；其余榜名是真值、卡面按榜名语义映射最近样本，UI 在 notice 里明示「本次未落卡面样本」。真值采样不含简介/封面/题材归属，这三项仍标记「原型占位」。`play_cnt` 与热度不同口径，不并列显示；`rec_arrow_type` 全 0，趋势不画假箭头。

### 4.2 Mobile 顶部筛选重构（释放内容空间）

- 原 3 行常驻 chip（内容类型 / 题材 / 状态）→ **1 行横滑题材 chip + 漏斗按钮**。
- 内容类型、状态、排序全部收进底部抽屉；漏斗按钮带**生效筛选数角标**。
- 效果：首屏多出约 2 行高度给内容（截图核验九宫格卡片从 1.5 行增至 2.5 行）。

### 4.3 iPad / Android 大屏独立原型（新建）

`platform-interaction-ipad.html` + `ipad-prototype.css` + `ipad-prototype.js`，三种形态可切换：
- **横屏两栏**：180px 带标签 rail + 内容区；三段式播放页 = 左选集 / 中播放 / 右剧情+弹幕（依据爱奇艺 HD「边选边看」、B 站 HD 三栏）。
- **竖屏单列**：rail 收窄为图标、播放页上下堆叠。
- **分屏窄窗**：栅格降 2 列、隐藏右侧弹幕栏、控制条紧凑（依据 iPadOS 多窗口）。
- 竖剧「**适应 / 铺满**」开关（解决红果 iPad 默认裁切切头痛点）、画中画、外露倍速/清晰度/换源。

### 4.4 「我的」页扩展（真结构）

Mobile 与 iPad 的「我的」页从「继续观看 + 一个按钮」扩展为完整个人中心：
- 用户头 + **4 项统计**（追剧/观看历史/已缓存/预约）
- **4 个快捷入口**（观看历史/缓存管理/我的追剧/预约更新，可平滑滚动定位）
- **观看历史**：`WatchRecord` 真字段（剧名/第 N 集/`positionMs`/`durationMs`/`quality`/`local`）+ 进度条 + 续播按钮
- **缓存与下载**：本地任务状态（已完成/下载中 %）、清晰度、文件大小
- **我的追剧 / 预约更新**：`favorites` / 预约列表
- 页脚明示数据源 `PreferencesBackend.read()` 与存储键 `favorites` / `history` / `<dramaId>:<vid>`。

### 4.5 SourceSwitch 换源面板（README 建议 4）

`interaction-prototype.js` 新增 `SourceSwitch()` 组件，四端详情页均加「换源」入口：
- 展示真字段 `quality` / `format` / `candidates` / `fromWeb`
- 模拟 `SourceResolver.resolve` 的 **8s 解析预算**：命中即切，未命中回退第一条可用线路并明示。

---

## 五、评审辅助

- 部分原型支持 URL 参数直接打开指定页：`?screen=mine|rank|settings`（Mobile）、`?screen=rank|categories|detail|mine`（iPad）；PC / TV 需点击左侧导航，便于设计评审与自动化截图。
- 官网搜索原型：`website-search.html` 打开即演示第 1 页；可切换「空结果 / 服务不可用」场景，点「越界页验证」看 200 + 空列表。
- 数据真值可核对：浏览器控制台执行 `HGPrototypeData.RANK_TRACKS` / `HGRealData.rankBoards` / `HGWebSearch.request({query:"我",page:2})` 即见原始采样值与分页响应。

## 六、仍未做（需真接口 / 新决策）

1. **榜单接实时接口**：当前用真值留样（2026-10-30），要接线上需解决 `cell_id=7470092475068071998` 的签名请求；原型已把入口参数写全，替换 `rank()` 内部即可。
2. **真封面图与搜索 series_id**：采样刻意不含 URL（脱敏），现用 SVG 占位；官网搜索接口的原始留样仓库中也不存在，`series_id` 为稳定派生 ID。接入线上需换真实 `series_cover` / `series_id`。

---

## 七、第四轮 · 官网搜索 / 我的统一 / iPad PC 化 / 详情顺序（2026-11-26 晚）

### 7.1 官网搜索分页原型（新增）

`website-search.html` + `web-search.js`，对齐 `packages/api/lib/src/web_source.dart` 与 `catalog.dart:880-888`：

| 项 | 原型实现 |
|---|---|
| 请求 | `GET /api/search/result?aid=8662&query={关键词}&page={n}`，page 从 1 起，**无 pageSize / cursor** |
| 字段 | `series_id` / `series_title` / `series_cover` / `series_intro` / `episode_cnt` / `tag_info.text`，由 `searchListFromJson` 归一 |
| 分页判定 | 优先 `hasMore`（true / 1 / "true"）；缺省回退 `totalPages > pageNum` |
| 越界页 | 仍回 200 + `searchList: []`，不降级为其他结果 |
| 场景 | 正常 / 空结果 / 服务不可用（`code` 为字符串时视为不可用） |
| 交互 | 搜索框、快捷词、页码 / 上下页 / 越界页验证、←/→ 翻页、结果选中联动 JSON 面板 |

**诚实性**：仓库没有 `/api/search/result` 原始留样。结果剧名 / 集数 / 徽标 / 评分复用 2026-10-30 实机匿名采样（feed + 榜单卡）；`series_id` 为稳定派生 ID，封面 / 简介为占位；每页固定 4 条仅为演示翻页（真实每页条数由上游决定）。不会中途切到 App 侧 `search/tab/v`。

### 7.2 「我的」四端统一

`interaction-prototype.js` 新增 `HGProto.PersonalCenter`，Mobile 原内联实现抽成共享组件，PC / TV / iPad 调用同一份：

- 统计 4 项（追剧 / 观看历史 / 已缓存 / 预约）+ 快捷入口 4 个（平滑定位到对应分区）。
- 观看历史按 `WatchRecord` 真字段显示进度条与「续播」；追剧 / 缓存 / 预约列表与页脚存储键（`favorites` / `history` / `<dramaId>:<vid>`）一致。
- TV 新增「我的」导航项（补 `tv-focus` 焦点样式）；PC 原「继续观看 + 本地缓存」占位块替换为完整个人中心；PC / TV / iPad 大屏把记录区排成两列。
- iPad 删除独立「追剧」tab，追剧入口收进「我的」。

### 7.3 iPad = 小一号的 PC

- 导航对齐 PC：**发现 / 分类 / 榜单 / 我的**（不再有追剧 tab）。
- 新增 PC 式「分类」页：内容类型 chip 来自真值词表，复用同一份真值目录。
- 新增 PC 式「详情」页：详情头（含线路 + 换源）→ 操作区（继续观看 / 追剧 / 缓存）→ 选集 → 相关推荐；点击卡片先进详情，「继续观看」才进播放器。
- **播放页冻结**：三段式播放面板（左选集 / 中播放 / 右剧情弹幕）逐字保留，未做任何交互变更。
- 顺带修复 iPad 容器未继承 `.app` CSS 变量导致主按钮文字不可见的问题（`class="app pad-app"`）。

### 7.4 详情页选集上移（PC 样式）

顺序统一为 **详情头 → 操作区 → 选集 → 相关推荐**。PC 原本已符合；Mobile 与 TV 把「相关推荐」从选集上方移到下方；iPad 新详情页直接采用该顺序。浏览器实测（getBoundingClientRect）：PC 区块 top 为 324 / 560 / 613 / 657 / 926 / 994，iPad 为 162 / 376 / 485 / 522 / 891 / 928，两者序列完全一致。

### 7.5 本轮验证（补充：iPad 操作区与 PC 对齐）

iPad 详情页操作区改为 **继续观看 / 追剧 / 缓存**（与 PC 逐项一致），「换源 · 查看解析预算」按钮移到详情头文案区线路下方（PC 同位置），移除原操作区内的「预约」按钮（PC 无此项，预约仍保留在「我的」页）。缓存按钮沿用 PC 的 `data-toast="已加入下载队列"` 语义。

### 7.6 本轮验证

- 6 个 JS 文件全部 `node --check` 通过；五份 HTML 的 `#id` 引用零缺失。
- Chrome CDP 真实渲染 + 交互：五页控制台 **零 error / 零 exception**。
- 关键断言：搜索 16 条 / 4 页 / 首页 4 卡、翻到第 2 页、错误场景文案；四端「我的」均 4 统计 + 4 快捷 + 2 历史 + 2 下载；四端详情页均为 `episodes-before-related`；iPad rail 4 项、分类 12 卡、详情 40 集 + 6 条相关、播放页仍为三段式。
- 截图核验：`/tmp/hg-verify-{search,pc-mine,tv-mine,mobile-mine,ipad-detail,ipad-mine}.png`。

### 7.7 四端「分类」tab 对齐（PC / Mobile / TV / iPad）

PC 原本已有分类页，本轮以 PC 为基准补齐 Mobile 与 TV 缺失的入口，四端导航与信息层级一致：

- **导航**：四端统一为 **发现 → 分类 → 榜单 → 我的**（设置按端形态放在侧栏底部 / 底部导航）。Mobile 顶部 sidebar 与底部 tab bar 同时补「分类」，底部导航由 4 项变 5 项，单项宽度 76px → 60px 以适配 390px 机型不溢出。
- **分类页**：与 PC 同款筛选维度（题材 / 内容类型 / 状态），词表全部来自 `prototype-real-data.js` 真值。Mobile 顶部已改为二级主从结构（见 7.9）；TV 用 chip + select，并保留 `tv-focus` 焦点三态与两次 Back 层级。
- **数据**：Mobile / TV 各自维护独立的 `state.category` 与游标，复用 `Data.browse`，不覆盖发现页筛选；海报点击沿用各端 `openDetail`，并补齐加载更多 / 空态 / 错误态 / 重试。
- **直达**：Mobile 支持 `?screen=categories` 评审入口；PC / iPad 原实现不变。

### 7.8 分类 tab 对齐验证

- 6 个 JS 与 5 份 HTML 内联脚本 `node --check` 全过；新增 `category*` 的 14 个 id 定义与引用一一对应，无缺失。
- Edge headless CDP 真实渲染 + 交互：Mobile / TV / PC / iPad 四页 **零 console error / 零 exception**。
- 关键断言：Mobile 顶部与底部导航均为 `发现 / 分类 / 榜单 / 我的 / 设置`，底部 5 项 `scrollWidth - clientWidth = 0`；Mobile / TV 分类页均首批 12 卡、摘要为真值词表「真人剧 · 全部题材 · 全部状态 · 共 12 部」，切到「AI剧」后摘要与卡面同步更新；Mobile 分类海报可进详情；TV 分类排序可独立切到 `hot_score`，chip 可聚焦，Back 回发现；PC / iPad 分类 tab 仍存在。
- 截图核验：Mobile 设备截图确认 5 项底部导航完整可见且「分类」高亮；TV 截图确认侧栏「分类」高亮、三轴筛选与海报栅格正常。

### 7.9 Mobile 发现 / 分类顶部筛选：二级主从

原顶部只有一个平铺的题材横滑行，内容类型藏在抽屉里，用户看不出筛选之间的依赖。现改为**一级（内容类型）→ 二级（题材）**：

- **层级表达**：一级行在上、二级行在下，依赖关系由**行位置 + 切一级联动刷新二级**体现，**不展示「主」「从」文字标签**——这两个字属引导话术、不是筛选维度（2026-11-26 移除，原型与 Flutter 代码同步）。「状态」是真实筛选维度名，保留。
- **一级**：内容类型 chip（真人剧 / 漫剧 / AI剧），常驻顶部。
- **二级**：题材 chip，词表由一级决定：`prototype-data.js` 新增 `dimsFor(contentType)` / `themeIdsFor(contentType)`，直接读真值 dims 分域词表 —— 真人剧 29 项（顶部横滑前 10 项，抽屉完整 30 项含「全部」）、漫剧 8 项、AI剧 8 项；漫剧另有画风维度，其余维度同样按域取词表。
- **联动规则**：切一级时重渲染二级 chip 与抽屉完整词表；若已选二级题材不在新一级词表中，自动清空为「全部」并 toast 明示「二级词表已更新，已选题材已清空」。发现页与分类页各自维护一级/二级状态，互不串扰。
- **抽屉调整**：移除重复的「内容类型」行（已提升为一级），题材行改为「二级完整词表」并随一级联动；保留状态与排序。
- **诚实性**：真值 feed 行不含题材字段，二级题材切换只做词表演示、不伪造过滤结果；选中题材时在数据源条与分类摘要显示「题材为词表演示（真值 feed 无题材字段）」。

**验证**：`node --check` 通过；CDP 实测 18 项断言全过 —— 一级词表 3 项、二级真人剧 11 项 / 漫剧 9 项 / AI剧 9 项、抽屉完整词表 30 → 9 项、失效二级值自动清空、toast 文案、摘要诚实性提示、两页零 console error；截图确认三行 chip 对齐正常（标签移除后需重新截图核验，见 §7.11）。

### 7.10 主从筛选左右滑动切换（设计备注）

发现页与分类页的顶部主从筛选支持横向滑动切换，按「二级优先、边界升级到一级、双边界不可执行」的状态机运行。

| 手势 | 二级状态 | 一级状态 | 执行结果 |
|---|---|---|---|
| 右滑 | 未到末项 | 任意 | **二级**选中下一项（优先） |
| 右滑 | 已到末项 | 未到末项 | **一级**向右切一次，二级随词表联动重置为「全部」 |
| 右滑 | 已到末项 | 已到末项 | **不可执行**，toast 提示「右滑已到末项，无可切换项」 |
| 左滑 | 未到首项 | 任意 | **二级**选中上一项（优先） |
| 左滑 | 已到首项 | 未到首项 | **一级**向左切一次，二级随词表联动重置 |
| 左滑 | 已到首项 | 已到首项 | **不可执行**，toast 提示「左滑已到首项，无可切换项」 |

- **左右对称**：左滑完全镜像右滑的约束与切换动作；一二级的边界分别以 chip 序列首 / 末项判定。
- **主从一致性**：升级到一级时不额外计算二级目标位置，而是走既有的一级点击链路 —— 由 `selectPrimaryType()` 重渲染二级词表、清空失效题材并提示，避免滑动与点击产生两套状态。
- **手势仲裁**：`pointerdown → pointerup` 水平位移 ≥ 36px 且 `|dx| > |dy|` 才判定为滑动；`.cascade-row .chip-row` 设 `touch-action: pan-y`，把横向手势留给滑动切换、纵向仍可滚动页面；切换后 `scrollIntoView({inline:"center"})` 让新选中项可见。鼠标指针不参与，避免与点击冲突。
- **键盘等价**：chip 聚焦时 `ArrowLeft / ArrowRight` 走同一套 `cascadeStep()`，并 `stopPropagation` 防止与全局返回键处理冲突。
- **不可执行是显式状态**：不是静默忽略，而是给出 toast，让用户知道已到筛选链两端。

**验证**：CDP 合成触控手势实测 18 项断言全过 —— 二级优先切换、二级边界升级一级并联动重置、一级边界回退、双边界不可执行反馈、小位移与竖向手势不误触、键盘等价、发现页与分类页均零 console error。

