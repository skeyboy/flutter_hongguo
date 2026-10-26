# PC 与手机的题材展开与保活

日期：2026-10-26。状态：设计已确认方向，代码待实施。

## 一句话目标

把 Android TV 已经落地的「题材水平展开 + 每个题材一份保活列表」搬到 PC 与手机，输入方式从遥控器焦点换成点击与键盘。

## 现状

TV 与 PC/手机读同一份 `CatalogClient.themes(genre)`，但走的是两套完全不同的交互与状态模型。

| 维度 | Android TV（`features/tv/`） | PC / 手机（`features/library_page.dart`） |
|---|---|---|
| 题材入口 | 常驻水平栏 `TvChoiceRail`，全部选项单行铺开，左右键移动（`tv_library_page.dart:519`） | 工具栏 `全部题材 ▾` 触发器，题材藏在展开面板的一行 chip 里（`library_page.dart:852`、`:982`） |
| 选中方式 | 焦点即选中，220ms 防抖合并连续按键 | 点击 chip |
| 切换后 | 每个题材是一条独立的保活路由 `feed/:id`，各自持有列表、游标、分页、滚动与焦点（`tv_feed_page.dart:13`） | 同一个网格原地重载：`items` 先清空、游标归零、`scroll.jumpTo(0)`（`library_page.dart:180`、`:192`、`:582`） |
| 切回旧题材 | 立刻显示上次加载到的完整列表，220ms 后才在后台刷新 | 从磁盘快照异步读回（先空白一帧），且已加载的续页游标不保留，需要重新翻页 |
| 在途请求 | 每个题材一个 `CatalogRequestScope`，离开页面即取消，旧响应按代次丢弃 | 全局一个 `_feedScope`、一个 `revision`，切换即取消上一个题材的请求 |

结论：PC/手机的问题不在「题材选项找不到」，而在「题材不是一个页面」。切换永远是一次带空白的重载，看过的题材回到起点。

## 目标与非目标

目标

1. 题材像 TV 一样常驻展开成一条水平栏，不再收进下拉面板；PC 与手机同一套语义，只差密度。
2. 每个题材一份独立保活列表：独立的条目、游标、分页状态、错误与滚动位置；切回来立即是离开时的样子。
3. 切换即绘制保活内容，后台刷新走防抖，不在途请求之间互相覆盖。
4. 类型（频道/类型/排序）仍留在现有展开面板里，本次不动它们的交互。

非目标

- 不改 TV 实现，也不把 TV 的嵌套 `AutoTabsRouter` 搬过来：PC/手机不需要把焦点移进题材页，用一份内存记录即可获得同样的保活语义，风险小得多。
- 不改搜索、榜单、详情页的「同题材」横栏。
- 不改上游接口、缓存格式与签名协议。

## 拆分

四层可以分别验证，实施顺序即依赖顺序。

### 1. 状态层：一条题材一份记录

把当前散在 `_LibraryPageState` 上的列表状态收进一个记录，按已有的 `feedKey`（已含 destination/query/view/genre/sort/theme/board）索引：

```dart
class _ThemeFeed {
  final items = <Drama>[];
  final scope = CatalogRequestScope();
  String? cursor;
  Object? error;
  String? refreshError;
  DateTime? cachedAt;
  int revision = 0, emptyPages = 0;
  double scroll = 0;
  bool loading = true, loadingMore = false, refreshing = false, autoPaused = false;
}
```

`_reload`、`_more`、`_nearEnd`、`_saveSnapshot` 全部改成对「发起时捕获的那条记录」赋值，而不是对 State 字段赋值。这样旧题材的迟到响应只会落在它自己的记录里，天然满足「旧响应不覆盖新选项」，也保留了 `LibraryCache` 的磁盘快照不变。

### 2. 切换层：离开即停，进入即画

- 离开：保存滚动偏移，取消该记录的在途请求，把 `loading/loadingMore/refreshing` 置回 false（记录内容保留）。
- 进入：立即用该记录已有条目绘制；从未加载过的记录才显示骨架屏；已加载过的记录在 220ms 后做一次 `preserveContent` 后台刷新——与 TV 的 `tv_feed_page.dart:100` 同一规则，连续点几个题材只会刷新最终停留的那个。
- 自动续页只对当前记录生效；`filterOpen`、`destination == 2`、搜索与榜单状态下的现有抑制条件保持不变。

### 3. 视图层：常驻题材横栏

- 位置：`_stickyFilters` 之下、结果区之上，与 TV 的 header + 状态行同构。
- 内容：`全部` + 当前类型的题材，单行水平滚动，选中项用 primary 容器底色加粗，选中态同时有颜色和字重（不只靠颜色）。
- 稳定高度：整条横栏固定高度，`题材加载中` / `题材加载失败 · 重试` 占用同一行，切换不推动网格（TV 的 28 高度状态行同理）。
- 移除 `sticky-theme` 触发器和面板里的 `题材` 分组：同一维度不在两处出现。
- 键位：PC 上 chip 可 Tab 聚焦、Enter/空格选中，左右方向键沿栏移动并把选中项滚入可见区；手机只保证点击与横向滑动。
- 触控目标 ≥ 40px，横向间距 8px，长题材名截断不挤压。

### 4. 兼容层：什么时候不显示横栏

| 状态 | 横栏 |
|---|---|
| 有搜索词 | 隐藏（搜索接口不吃题材参数，不能显示成可选但无效） |
| 榜单 `view == rank` | 隐藏（榜单固定漫剧，无题材维度） |
| 我的 `destination == 2` | 隐藏 |
| 切换类型 | 立即清空旧题材列表并显示「题材加载中」，旧类型的响应不得填进新类型的栏（沿用 `themesRevision`） |
| 面板里的类型/频道/排序 | 保持 250ms 合并刷新不变 |

## 验收标准

- 点题材不再出现空白帧；切回看过的题材，条目数与滚动位置和离开时一致。
- 每个题材各自翻页：A 翻到第 3 页后切到 B，B 从自己的第 1 页开始，A 的游标不受影响。
- 快速连点多个题材，只发出最终停留题材的请求（220ms 防抖），且没有任何迟到响应写进当前列表。
- 题材横栏常驻可见，无需先打开面板；面板内不再有题材分组，其余分组行为不回退。
- 加载中/失败重试不改变网格矩形；小窗口、大字体、超长题材名不溢出。
- PC 键盘可完成整条栏的选择；手机返回键与 Esc 仍只收起最上层（面板/建议），不误退页面。
- 题材加载失败时，之前已保活的题材仍可正常浏览。

## 测试

- 更新现有三处按 `sticky-theme` + `filter-theme-cate_7` 路径点击的用例，改点横栏：`test/adaptive_ui_test.dart:129`、`test/interaction_cache_test.dart:138`、`test/mobile_recovery_test.dart:77`。
- 新增 `test/theme_rail_test.dart`：常驻可见、切回保活（条目与 offset 不变）、每题材独立游标翻页、连点只发一次请求、迟到响应不覆盖、失败重试不推动网格、PC 键盘选中。
- 回归：`horizontal_filters_test.dart` 四个尺寸无溢出。

落地情况：三处旧用例已改点 `theme-rail-*`，`test/theme_rail_test.dart` 7 条用例全部实装并通过；`packages/app` 全量 238 通过 1 跳过，`packages/tv` 36 通过，`flutter analyze` 两包均无告警。

## 真机验证

`tool/verify_theme_rail_live.sh` + `packages/app/integration_test/theme_rail_live_test.dart`：真接口跑一遍 分类 → 悬疑 → 下滚 → 宫斗 → 回切悬疑，按标记从录屏里取每个状态的一帧存进 `docs/evidence/theme-rail/`。

- macOS 窗口（1100×760）已验证：`rail.png` 常驻横栏（全部/悬疑/宫斗…横向滚动）、`theme-two.png` 与 `theme-three.png` 各题材自己的行、`theme-two-scrolled.png`（偏移 401）与 `theme-two-restored.png`（回切仍是 401，行与位置原样回来）、加载态下网格几何不动。
- iPhone 模拟器 `yxy-iPhone17Pro` 本轮未能取证：真机夹具停在首帧之前（`pumpWidget` 后 115s 无任何输出），同一台模拟器上跑上一轮已通过的 `route_transition_live_test.dart` 对照复现同样卡死，说明与本节改造无关，属工作树在途网络改动/模拟器并发占用的启动阻塞，待其收口后重跑 `HONGGUO_RAIL_DEVICE=<UDID> tool/verify_theme_rail_live.sh`。
- 390 紧凑布局由 `test/theme_rail_test.dart`、`test/adaptive_ui_test.dart` 的窗口用例覆盖。
- Android 手机/模拟器：同一场景。

## 已知交织

`library_page.dart` 及其测试当前有另一条在途改动（请求代次/网络恢复，`CatalogRequestScope`）尚未提交，本次改造直接叠加在其工作树版本之上，无法只提交本文件的本轮 hunk。

现读证据：`git show HEAD:.../library_page.dart | grep -c CatalogRequestScope` = 0，工作树同一查询 = 5；`packages/api/lib/src/request_control.dart`（274 行，未跟踪）与 `hongguo_api.dart` 的导出改动都在另一条线上。因此本轮既不把别人的在途实现以本节的名义压上 main，也不做「只改索引提交本轮路径」——那样得到的树从来没编译过。

处置：整棵工作树（除 `.idea/`）快照成分支 `feat/pc-mobile-theme-rail`，起点 `bcf8c6a`（v0.3.4），main 与工作树都不动；提交树在独立 worktree 里过了一遍 CI 同套门禁（app analyze 干净、app 238 通过 1 跳过、tv 36、core 117、api 77、cast 52、TV 标记用例 1）。等网络那条线自己落 main 后，本分支 rebase 上去只留题材横栏的增量。
