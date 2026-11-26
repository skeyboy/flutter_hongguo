# 平台交互原型改版落地契约

状态：生效（2026-11-26）
真理来源：`docs/design/platform-interaction-optimized/README-评估与优化说明.md` §7.4–7.10 + 四份 HTML 原型
分支基线：`feature/platform-interaction-optimization` @ `52c6531`（已合入 main `1b4721c`）
工具链：Flutter 3.47.8 / Dart 3.13.7（`flutter`，PATH 上为 fvm stable）

## 0. 为什么按模块而非按平台拆分

真实代码里 PC / iPad / Mobile **共用同一套 widget**：`LibraryPage`（发现/分类/榜单宿主）+ `detail_page.dart`（详情页）。
只有 TV 是独立实现（编译期 flavor，`packages/app/lib/features/tv/` + `packages/tv/`），且 TV 导航按内容类型分栏（短剧/漫剧/AI短剧/本地缓存/我的），不是原型的「发现/分类/榜单/我的」。

因此"按平台拆"会让 3 个 agent 抢改 `LibraryPage` / `detail_page.dart` 产生写脏。改为按**不重叠文件模块**拆分：A=详情页操作区、B=发现/分类主从筛选、C=TV 独立目录。每个模块只写自己的文件集。

## 1. 全局约束（所有模块必须遵守）

1. **契约优先**：先读本文档与对应原型 README 段落，再改代码。
2. **不重叠写**：只写自己模块的文件集；跨模块的公共文件（如 `main.dart`、`app_settings.dart`、路由总表）一律不动，需要时在报告里提出由主 agent 处理。
3. **真值词表**：筛选项 ID/名称必须来自 `hongguo_api` 的 `CatalogDim`（`catalogDimKeys*`）与 `AppSettings`，不得硬编码伪造题材；真值 feed 无题材字段，二级题材只做词表演示，不得伪造过滤结果。
4. **诚实性**：任何"演示/占位"语义须在 UI 或日志明示，不造假数据。
5. **analyze 通过 ≠ 能编译**：本轮环境为 Windows arm64，受第三方插件限制可能无法真机/真包构建；每个模块必须跑 `flutter analyze` 与对应 test，并把"已验证 / 未验证缺口"分开如实报告。
6. **测试命令**：`flutter test -j 1 <相对路径>`（arm64 Windows 上默认并发会卡在 loading，必须 `-j 1`）。
7. **不提交**：git 提交由主 agent 统一执行；子 agent 只改工作区文件。

## 2. 模块 A — 详情页操作区对齐

**写权限**：`packages/app/lib/features/detail_page.dart`、`packages/app/lib/personal/favorite_button.dart`、`packages/app/lib/downloads/download_selection.dart`
**覆盖平台**：手机 / PC / iPad（共用 `detail_page.dart`）；TV 详情见模块 C，不在本模块。

契约（对齐原型「继续观看 / 追剧 / 缓存」）：
- A1 换源入口保持 `Key('detail-source-switch')`，位置在详情头 AppBar actions（原型已从操作区移到详情头）。**不新增操作区换源按钮**。
- A2 操作区三按钮语义：主按钮「继续观看」（保留现有 开始观看/重新观看/继续观看 三态逻辑，不改状态机）、追剧、缓存。
  - 追剧 = 现有 `FavoriteButton` 收藏语义（`personal/favorite_button.dart`）；如果把收藏移入操作区，须保留 AppBar 入口或明确二选一，且不得破坏 `favorite` 相关现有测试。
  - 缓存 = 现有 `DownloadRuntime` 下载按钮（`Key('download-drama')`）；把 label 从「下载」对齐为原型「缓存」语义时，须同步 `download_selection.dart` 的确认文案为「已加入下载队列」（原型真值文案），并保留既有下载测试断言可调整项。
- A3 移除「预约」：真实代码本就无预约入口，保持不引入；预约入口仅在「我的」页（如已有则保留）。
- A4 不新增「合成」以外的按钮语义；合成按钮维持现状（合并功能属于本项目特有，原型无对应）。
- A5 每个按钮加稳定 `Key` 便于 widget 测试；保留 `download-drama` / `merge-drama` 既有 key。

验收：
- `flutter analyze packages/app` 零新增问题；
- 相关测试（至少 `detail_tag_row_test.dart` 与任何引用 `download-drama`/`favorite` 的测试）`-j 1` 通过；
- 报告逐条说明 A1–A5 的落地情况与未验证缺口。

## 3. 模块 B — 发现/分类二级主从筛选 + 左右滑动切换

**写权限**：`packages/app/lib/features/library_page.dart`、`packages/app/lib/features/library/library_page_state.dart`、`packages/app/lib/features/discover_filter_panel.dart`
**覆盖平台**：手机 / PC / iPad（共用 `LibraryPage`）。

现状（已落地，勿重写状态机）：一级类型→二级题材分桶词表、切一级清空失效二级值、三级 overscroll handover 状态机、clamping 边界物理、阈值 48。

契约（补齐原型 §7.9/7.10 的差距）：
- B1 **切一级清空二级时 toast 明示**：在 `_writeSlot`（约 3761–3778 行）内，若原有 theme 被清空，调用现有 `_explain`（约 2344 行）提示「二级词表已更新，已选题材已清空」。文案以原型为准，可微调但须明示。
- B2 **层级不靠引导话术**：一级（内容类型）行在上、二级（题材）行在下，层级由位置与联动体现；**不展示「主」「从」标签**——这两个字属引导话术，不是筛选维度（用户 2026-11-26 明确要求，代码与原型均已移除）。PC/iPad 沿用同一 widget 自然继承。注意「状态」是真实筛选维度名，保留。
- B3 **方向键等价**：筛选 chip 聚焦时 `ArrowLeft/ArrowRight` 走与滑动同一切换函数（原型 §7.10），并 `stopPropagation` 避免与全局 Alt+← 返回冲突（后者在 `app_navigation.dart:226-234`）。
- B4 **双边界 no-op toast**：overscroll 到一二级均不可再切时（现 `library_page.dart:544-546` 静默 return false），给出 toast，**文案严格取原型真值**：右滑到边界为「右滑已到末项，无可切换项」、左滑到边界为「左滑已到首项，无可切换项」（见 README §7.10 规则表）。保持左/右对称，不可执行是显式状态而非静默忽略。
- B5 **发现与分类状态独立**：原型要求两页筛选状态互不串扰。真实代码 `library_page_state.dart:111-125` 共享 `genre/theme`。若改造牵动 feed key 与大量测试且风险高，**可在报告中标记为"本轮不落地并说明原因"**，但不得声称已落地。优先保 B1–B4 稳落地。
- B6 抽屉 `discover_filter_panel.dart`：切一级后题材词表须联动刷新，保持与原型 §7.9「抽屉词表 30→9」一致。

验收：
- `flutter analyze packages/app` 零新增问题；
- 相关测试 `-j 1` 通过：`catalog_tabs_test.dart`、`horizontal_filters_test.dart`、`mobile_discover_layers_test.dart`、`discover_desktop_layers_test.dart`；
- 报告逐条说明 B1–B6 落地情况，B5 未落地须如实标注。

## 4. 模块 C — TV 端分类入口对齐

**写权限**：`packages/app/lib/features/tv/` 下所有文件（`tv_library_page.dart`、`tv_feed_page.dart`、`tv_detail_page.dart`、`data/tv_feed_cache.dart` 等）。**不得改** `packages/tv/`（TV 基础组件）或 `main.dart`。
**覆盖平台**：TV flavor。

现状：TV 侧栏 `['短剧','漫剧','AI 短剧','本地缓存','我的']`（`tv_library_page.dart:149`），按内容类型分栏，每栏是 `_TvGenrePage` → `TvFeedPage`（题材 feed）。**无独立「分类」tab，也无榜单 tab。**

契约（对齐原型「分类」入口，但尊重 TV 真实形态）：
- C1 不照搬原型导航为「发现/分类/榜单/我的」——TV 现有按内容类型分栏本身就是"分类"的真实形态。改版目标为：**在 TV 提供明确的「分类」语义入口**，做法是新增一栏「分类」或把现有分栏页聚合出分类入口，须保持 TV 焦点三态与两次 Back 层级（`docs/design/tv-cross-row-focus-navigation.md`、`android-tv-adaptation.md`）。
- C2 新增/变更的导航项必须：加 `tv-focus` 等价焦点节点、`_SidebarArgs` 三者对齐（active/focus/exitLeft）、`_sidebarRoutes` 与 `routes` 数量一致、`nav` / `panes` / `remembered` 索引同步。任何索引不同步都会破坏两次 Back。
- C3 分类页数据源复用 `TvFeedPage` 的 `CatalogRequestScope` 与真值 `CatalogDim`，不得硬编码题材；若分类页只做"题材入口聚合"，须明示它复用现有 feed。
- C4 TV 详情（`tv_detail_page.dart`）操作区：原型已明确「此版本不执行播放页相关的交互操作变更」，详情页沿用 TV 现状（▶开始观看/下载剧集/下载管理/切换片源/收藏），**本轮不改 TV 详情**。
- C5 若新增栏位导致 `_sidebarRoutes` 从 5→6，须同步 `List.generate` 的所有计数与 `routes` 定义，并补充/调整 `tv_catalog_test.dart`、`tv_catalog_recovery_test.dart`、`focus_geometry_test.dart`。

验收：
- `flutter analyze packages/app` 零新增问题；
- `tv_catalog_test.dart`、`tv_catalog_recovery_test.dart`、`tv_*_test.dart` 相关 `-j 1` 通过；
- 明确报告：TV 分类入口的形态（新增栏 or 聚合入口）、两次 Back 是否验证、焦点三态是否验证、未验证缺口。

## 5. 验证协议（主 agent 统一执行）

| 阶段 | 命令 | 说明 |
|---|---|---|
| 语法 | `flutter analyze` | 各包零问题；注意 analyze≠能编译 |
| 测试 | `flutter test -j 1 <path>` | arm64 Windows 必须单并发 |
| 真机/真包 | 本机受限 | Windows arm64 + 第三方插件缺 x64/ATL，预计无法真实 build；如确实不可行须如实披露为未验证缺口，不得宣称完成 |
| 提交 | 主 agent 按模块分阶段 commit | message 标注模块 A/B/C，附验证命令与结果 |

## 6. 逐条落地差距（调研基线，供核对）

| 原型改版 | 落地状态（改版前） | 本轮目标 |
|---|---|---|
| iPad 详情操作区（继续观看/追剧/缓存 + 换源在详情头） | 部分：换源已在详情头；缺"追剧/缓存"文案 | 模块 A |
| 四端分类 tab | 手机/PC/iPad 已落地；TV 缺失 | 模块 C |
| Mobile 二级主从筛选 | 核心状态机已有；缺 toast/标签/独立状态 | 模块 B |
| 二级筛选左右滑动切换 | 三级 handover 已有；缺双边界 toast/方向键 | 模块 B |
