# 发现/分类 筛选改版契约（theme-rail-scroll + filter-entry-page）

> 基线：origin/main `f6928ed`（v0.3.33）。两个 feature 分支各持一份独立实现，
> 互不触碰对方文件。Agent A 只读本文件，Agent B 持有本文件并随实现修订。

## 背景与现状

- 发现/分类两 tab 共用 `packages/app/lib/features/library_page.dart`（PC/移动/Web），
  二级筛选（题材 rail）在 `_level2Row` / `_themeChips`：
  - 桌面族（desktopHost）截断到 `_desktopRowMax = 8` 枚，其余塞进 PopupMenuButton
    「更多 ▾」（`theme-rail-more`），行本身 `SingleChildScrollView` 无 controller；
  - 触控族完整词表横滑（`rowAt('rail-$pane')` controller + Scrollbar）。
- 「更多筛选」现状：桌面 `≡ 更多筛选`（`filterChipKey`）与触控 `≡ n`
  （`filter-narrow*`）→ `_toggleFilterPanel` → OverlayEntry 锚定浮层 /
  底部抽屉，内容为 `discover_filter_panel.dart`（DiscoverFilterPanel）。

## 模块 A（分支 feature/discover-theme-rail-scroll）：二级筛选项水平滑动 + 点选自动居中

### A1 展开「更多」，全平台完整词表横滑

- 删除 `_themeChips` 的 `_desktopRowMax` 截断与「更多 ▾」PopupMenuButton
  分支：所有平台二级行 = 完整词表的单行水平滚动（不许 wrap 换行）。
- 桌面族接上 `rowAt('rail-$pane')` controller + Scrollbar（与触控族同一控制器契约），
  保证后续 A2 的居中滚动在两族走同一条代码路径。
- 桌面行尾渐隐遮罩（`ShaderMask`/gradient fade）提示右侧还有内容；行两端
  hover 渐显左右滑动箭头按钮（键 `theme-rail-arrow-left` / `theme-rail-arrow-right`，
  仅桌面渲染；到边界时对应箭头隐藏或禁用），点击动画滑动约一屏（0.8×viewport）。
- 桌面允许鼠标拖拽横滑本行（仅本行 ScrollConfiguration 放行 mouse drag）；
  触控族物理与手势仲裁不变（横滑切级逻辑 `_onRowScroll` 不因 A 改动而变化：
  rail 行的横滚继续不触发级层切换）。

### A2 点选后自动居中

- 点选任一 chip（`_selectFilter('theme', ...)` 成功后）与「恢复/切一级导致
  选中项不在视口内」时，把选中 chip 动画滚动到行内尽可能水平居中的位置：
  `target = chipCenter - viewportCenter + currentOffset`，clamp 到
  [0, maxScrollExtent]，150–250ms easeOutCubic，尊重 `disableAnimationsOf`
  （禁动画时直接 jumpTo）。
- 实现放一个私有助手（如 `_centerSelectedChip(pane, slot)`），由 chip
  onSelected、`_trackBandTarget` 级层 refill、restore 深跳三处调用；
  用 chip 的 `ValueKey('theme-rail-${option.id}')` 找 RenderBox 求中心。
- 排序行、一级行、`≡`/`排序` 尾部控件布局不受影响；`_filterRowHeight` 不变。

### A3 门禁

- `flutter analyze packages/app` 零问题；app 包相关测试全过
  （`theme_rail_test` / `horizontal_filters` / `catalog_tabs` 等既有契约用例
  需按新交互更新：桌面不再有 `theme-rail-more`，改为断言横滑 + 箭头 + 居中）。
- 新增用例：①桌面点选第 10 枚 chip 后其中心距行视口中心 ≤ 半个 chip 宽；
  ②`theme-rail-more` 键不存在；③箭头点击改变 `rail` controller.offset；
  ④disableAnimations 下点选后 offset 即时到位（无动画等待）。
- 禁止 commit；禁止改动 `discover_filter_page` / `discover_filter_panel.dart`
  （B 的边界）。

## 模块 B（分支 feature/discover-filter-entry-page）：更多筛选入口页

### B1 入口改为页面跳转

- 桌面 `≡ 更多筛选` OutlinedButton 与触控 `≡` ActionChip 的 onPressed 改为
  `pushAppPage(context, AppScreen.discoverFilter, ...)`（新增 screen 枚举项 +
  route name，沿用 `app_navigation.dart` 既有推送契约；TV 隔离路由走
  MaterialPageRoute 兜底分支同样成立）。
- 删除浮层路径：`_toggleFilterPanel` / `filterPanelEntry` OverlayEntry /
  底部抽屉 / `filterSheetSetState` 及其焦点、返回栈、`_filterLayerOpen`
  分支一并移除；`discover_filter_panel.dart` 由新页面组件替代后删除该文件。
- 打开时携带当前 `genre`、题材选择与 `selected` dims（与发现页同源状态对象
  `library_page_state`），页面内改动**实时写回**同一状态：返回发现页后
  `_dimCount`、请求参数、带位计数一致，无需二次同步代码。

### B2 页面结构（逐级分类 + grid）

新文件 `packages/app/lib/features/discover_filter_page.dart`：

1. 顶部：页面题（`更多筛选 · $genreLabel`）+ 重置按钮；其下一级「内容类型」
   chip 行（真人剧/漫剧/AI剧，与发现页一级同源 `_genreNames`）；切换一级时
   题材与各维度词表重新拉取（`filterRows(genre)`），失效的选中项清空并
   toast 明示（沿用「切一级清失效值」既有语义）。
2. 逐级分类分区：题材（二级完整词表，来自当前一级桶）→ 按 `filterRows`
   返回顺序逐个维度分区（画风/状态/年代…，维度名用上游原文
   `catalogDimRowNames` 兜底）。每区一行横滑 chip（与 A2 同款居中策略），
   「全部/不限」打头；每维一选或空（`select_items` 形状不变）。
   词表加载中/失败/缺维三态如实呈现（缺行提示保留，不画没给的维度）。
3. 排序：继承发现页当前档位，页内提供同款三档切换（`catalogSortKeys`）。
4. 内容 grid：`SliverGrid` + `SliverGridDelegateWithMaxCrossAxisExtent`
   （与发现页同 delegate），`DramaCard` 渲染；数据来自
   `FilteredCatalogRepository.browseFiltered(CatalogQuery(genre, sort, dims))`。
   任一筛选变化：cursor 归零、保留旧列表淡入新结果（沿用发现页
   「切筛选不闪空」的既有模式）；错误态给重试；空结果给空态文案。
5. 分页：到底前 `加载更多`（nextCursor），触控滚动接近底部自动加载
   （设置页既有「自动加载更多」偏好开关同样生效）。

### B3 平台策略

- 移动（触控）：全屏页 + AppBar 返回（手势返回可用）；chip 行横滑点选居中；
  单手可达：筛选区在内容上方自然滚动，无吸底操作条。
- 桌面（鼠标）：宽屏多列网格（同一 maxCrossAxisExtent 自然增列）；维度区
  全宽 wrap 不横滑（空间足够时不制造第二个滚动维度——与移动策略相反，
  按空间自适应：行宽 ≥ 720px 用 Wrap，否则横滑）；Esc / 返回按钮关页；
  hover 态与滚动条沿用应用既有 ScrollBehavior。
- Web：同桌面布局（kIsWeb 归入桌面分支渲染，但 hover 箭头等仅 pointer
  设备渲染）。
- TV：本次如实降级——TV flavor 侧栏「分类」语义聚合保持现状，新页面
  仅保证 TV 隔离路由下能以焦点导航打开与返回（入口在 TV 族由侧栏承接，
  不新增 TV 专用布局）；契约与 README 注明该边界，后续如需 TV 专属
  三段式布局另行立项。
- 动画统一 150–250ms easeOutCubic，尊重 `disableAnimationsOf`。

### B4 门禁

- `flutter analyze packages/app` 零问题；新增 `discover_filter_page` 页面
  测试：①打开即带当前 genre/dims；②点维度 chip 后 grid 请求数变化
  （fake 仓库断言 `browseFiltered` 收到的 dims）；③切一级清失效选中 +
  toast；④重置按钮清空全部；⑤加载更多追加且 cursor 正确；⑥空态/错误态。
- 既有 `discover_filter_panel` 相关测试改写或随浮层删除；`library_page`
  测试中浮层相关锚点（`filter-panel-*`）改为页面路由断言。
- 禁止 commit；禁止改动 `_themeChips` / `_level2Row` 的 A 模块边界
  （入口 chip 的 onPressed 改路由除外——该行改动是 B1 授权范围）。

## 合并策略

A 先合（只动 rail 行），B 后合（含契约文档与原型）；两者仅在
`library_page.dart` 的入口 chip onPressed 一处可能相邻，A 不触碰该行。
推送前主 Agent 统一重跑两 worktree 门禁。
