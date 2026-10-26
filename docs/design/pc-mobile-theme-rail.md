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
- 自动续页只对当前记录生效；`destination == 2`、搜索与榜单状态下的现有抑制条件保持不变（第 6 节拆掉面板后，`filterOpen` 这个条件自然消失）。

### 3. 视图层：常驻题材横栏

- 位置：类型/频道胶囊行（第 6 节的 `_choiceRow`）之下、结果区之上，与 TV 的 header + 状态行同构；第 5 节之后它是这一族里唯一吸顶的一行。
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
| 胶囊行里的类型/频道/榜单 | 保持 250ms 合并刷新不变 |

### 5. 顶部瘦身：搜索与筛选随列表划走，题材栏吸顶

- 删除顶部品牌/标题条：`Brand` 行与「我的」快捷按钮在本页不再出现。底部导航、导航轨、宽屏侧栏已经各自带着它们，列表上方的每一像素留给内容；页面自己的标题降级为网格上方的一行 `_sectionTitle`。
- 搜索框、离线检查、筛选触发器都改成列表自己的头两个 sliver：它们随内容划出屏幕，不再常驻。
- 题材栏用 `SliverPersistentHeader(pinned: true)` 停在列表顶部不再离开，高度恒 `_filterRowHeight = 52`；chip、加载圈、重试、隐藏四种状态共用同一矩形，吸顶不会推动网格。
- 删除 `viewportHeight < 400` 的特殊分支：矮窗口本来就靠划走换空间。

### 6. 就地胶囊：类型/频道/榜单不再下拉

真机帧 `docs/evidence/theme-rail/sheet-before.png`（改名保留，正是被拆掉的旧结构）暴露的问题，按人机交互逐条：

| 冲突 | 现象 | 依据 |
|---|---|---|
| 同族语义两套机制 | 类型/频道是「点触发器→下拉面板」（2 步、当前值只剩一个词、其余选项藏起），题材是常驻横栏（1 步、全部可见） | 同一屏里两种收窄列表的方式长得完全不一样 |
| 面板不回答你点的问题 | 点「类型」时面板里同时列出「频道」，只靠标签加粗区分 | 用户无法预期面板内容 |
| 空间浪费 + 动作远离 | 1100 宽的横带只用了左侧 250px 放 3 个胶囊，「收起筛选」被甩到最右侧 800px 之外；触发器在右上、面板内容在左上 | 视线要在窗口里横跳两次 |
| 两个筛选面互斥 | 面板展开时题材栏被取消吸顶、行被下推；整屏遮罩还会把第一行推出构建范围 | 短窗口（600×340）实测网格直接消失 |
| 假控件 | 「推荐/最新」只改标题文案，请求参数一个字不变（`sort` 来自设置） | 点了列表不变，比没有更糟 |

处置：

- 三个维度都是 3 个互斥值，全部就地化成与题材栏同一语言的胶囊行 `_choiceRow`，一次点击生效：发现 = `[推荐|最新|榜单] ‖ [短剧|漫剧|AI 短剧]`，分类 = `[短剧|漫剧|AI 短剧]`，榜单态第二组换成 `[推荐榜|热播榜|新剧榜]`。两组之间一条 1px 竖线，读起来是两问而不是一排六选。
- 键位沿用面板时代的 `filter-<组>-<值>`，选中态同时给颜色和字重；窄屏上这一行和题材栏一样横向滑动。
- 删除 `_filterPanel`、`filterOpen`、`focusedFilter`、整屏遮罩与「收起筛选」：没有需要收起的层，Esc/返回键只剩搜索建议一层，题材栏因此恒吸顶不再被面板挤掉。
- 「最新」改为真的把 `sort` 覆盖成 `online_time`；「推荐」回到设置里的排序。频道只属于发现：进分类/我的时把 `view` 复位为 `recommend`，不让发现的频道状态悄悄改掉分类的排序。
- 榜单只在支持 `RankCatalogRepository` 的运行时出现——点了不变的胶囊不如不给。

### 7. 顺带修掉的保活缺陷

`_switchFeed` 的回切跳转发生在被离开的题材仍占据视口时，`jumpTo` 会被当时的 `maxScrollExtent` 夹平：真机帧实测 `theme-two-restored offset=0`（应为 401），单测因假接口即时返回而看不到。改为 `_restoreScroll`：先就地跳一次，再在下一帧按新内容的长度补跳一次。

## 验收标准

- 点题材不再出现空白帧；切回看过的题材，条目数与滚动位置和离开时一致。
- 每个题材各自翻页：A 翻到第 3 页后切到 B，B 从自己的第 1 页开始，A 的游标不受影响。
- 快速连点多个题材，只发出最终停留题材的请求（220ms 防抖），且没有任何迟到响应写进当前列表。
- 题材横栏常驻可见；类型、频道、榜单同样常驻可见，全页不存在需要「先打开」的筛选层。
- 加载中/失败重试不改变网格矩形；小窗口、大字体、超长题材名不溢出。
- 点「最新」必须真的换排序：请求里 `sort=online_time`；点「推荐」回到设置里的排序。榜单只在运行时支持榜单接口时出现。
- PC 键盘可完成整条栏的选择；手机返回键与 Esc 只收起搜索建议这一层，不误退页面。
- 题材加载失败时，之前已保活的题材仍可正常浏览。
- 下滚之后，屏幕上留下的只有 52 高的题材栏；搜索框、离线检查、胶囊行都随内容划走。

## 测试

- 更新现有三处按 `sticky-theme` + `filter-theme-cate_7` 路径点击的用例，改点横栏：`test/adaptive_ui_test.dart:135`、`test/interaction_cache_test.dart:140`、`test/mobile_recovery_test.dart:78`。
- 真机那条 `integration_test/offline_playback_test.dart` 同样跟着改了：它原来靠「点 `sticky-genre` → 截图 → 点『收起筛选』」演示面板，面板删掉后这两步都没有目标，现在直接截就地胶囊行。
- 新增 `test/theme_rail_test.dart`：常驻可见、切回保活（条目与 offset 不变）、每题材独立游标翻页、连点只发一次请求、迟到响应不覆盖、失败重试不推动网格、PC 键盘选中。
- 回归：`horizontal_filters_test.dart` 四个尺寸无溢出。
- 顶部瘦身与就地胶囊这两轮之后，`horizontal_filters_test.dart` 整份按新结构重写：四个尺寸断言「不开任何面板就看得见全部类型、选类型不推动横栏」；吸顶用例改为断言胶囊行随头部一起从树里消失、横栏停在视口顶部仍可点；连点合并只发一次请求；频道/榜单/搜索三种状态下各自该出现哪一组胶囊。`catalog_sort_test.dart` 补上「点 最新 → 请求里 `sort=online_time`，回 推荐 不再发请求（各频道自己的页缓存）」。`widget_test.dart`、`theme_rail_test.dart`、`interaction_cache_test.dart` 里「开面板 → 选值 → 收起筛选」的三步都缩成一步点胶囊。

落地情况：三处旧用例已改点 `theme-rail-*`，`test/theme_rail_test.dart` 7 条用例全部实装并通过。就地胶囊这一轮之后 `horizontal_filters_test.dart` 仍是 7 条（删两条面板用例、补两条胶囊与频道/榜单分组用例），`packages/app` 全量 238 通过 1 跳过，`packages/tv` 36 通过，`flutter analyze` 两包均无告警，本轮改到的 8 个文件 `dart format` 干净（`test/macos_picture_in_picture_test.dart`、`test/mobile_recovery_test.dart` 的格式偏差属在途那条线，本轮没有动）。`offline_playback_test.dart` 只在 `flutter analyze` 与显式真机跑里执行，不在 `flutter test test` 的 238 条里。

## 真机验证

`tool/verify_theme_rail_live.sh` + `packages/app/integration_test/theme_rail_live_test.dart`：真接口跑一遍 分类 → 悬疑 → 下滚 → 宫斗 → 回切悬疑，每个状态打一条 `HGRAIL t=... ev=shot=<名>` 标记，脚本按标记取帧存进 `docs/evidence/theme-rail/`。取帧方式按设备分两种：macOS 只能整屏录一段再按夹具自报的窗口矩形裁剪；模拟器和手机改成「标记一到就截图」（`simctl io screenshot` / `adb exec-out screencap`），因为录像本身有 ~1.5s 起录延迟，按时间戳回推抽帧会抓到下一个状态。

- macOS 窗口（1100×760）本轮按新结构重录：`rail.png` 分类顶部只剩「搜索一行 + 类型胶囊一行 + 题材栏」；`sheet-before.png` 故意留着，是被拆掉的旧结构——1100 宽的横带只用左侧 250px 放 3 个胶囊，「收起筛选」甩在最右侧 800px 之外；`genre-comic.png` 点一格「漫剧」即换类型，题材栏矩形纹丝不动（换完是自己的题材集）；`discover.png` 发现里两组胶囊并排一行，`推荐|最新|榜单 ‖ 短剧|漫剧|AI 短剧`，中间一条 1px 竖线；`rank.png` 点「榜单」后第二组就地换成 推荐榜/热播榜/新剧榜、类型让位、题材栏整行消失、标题改「漫剧榜单」；`theme-two-scrolled.png` 下滚到偏移 401 后搜索与胶囊整行划出，只剩 52 高的题材栏钉在内容区顶部；`theme-two-restored.png` 回切仍是 401 —— 上一轮同一帧实测是 0，即第 7 节那个夹平缺陷。第一次录制时 `theme-two-scrolled.png` 被 macOS Launchpad 整屏盖住，重跑一次才拿到干净帧（同一条命令，桌面录制前后要确认没有其他整屏层）。
- iPhone 模拟器 `yxy-iPhone17Pro` 本轮重录（`ios-*.png`）：`ios-rail.png` 390 宽自上而下是搜索 + 离线检查、类型一行（短剧/漫剧/AI 短剧）、题材一行（全部/动作/冒险/魔幻/爱情… 横滑）、标题、行，没有任何需要展开的层；`ios-discover.png` 发现的两组挤在同一行，竖线之后「漫剧」被屏幕右缘裁掉，靠横滑看到——与题材栏同一习惯；`ios-rank.png` 榜单态第二组换成 推荐榜/热播榜…，题材栏让位，行直接顶到胶囊行下面；`ios-theme-two-scrolled.png` 与 `ios-theme-two-restored.png` 都报 offset=401，两帧不再逐字节相同（回切那一帧多一行「已显示本地缓存，正在刷新…」），条目与位置一致。上一轮记录的模拟器偶发整站空返回本轮未复现，夹具里的 `ev=boot-failed` 原因打印保留。
- Android 手机 `23113RKC6C`（Android 16，`8c9cf729`）本轮未能取证：`--flavor mobile` 的 apk 预构建成功（`assembleMobileDebug` 20.8s，产物 195 MB），卡在装机这一步。机器上先装着 versionCode 2015 的旧包，直接安装报 `INSTALL_FAILED_VERSION_DOWNGRADE`；Flutter 自动卸载旧包后重装报 `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`，手动 `adb install -r -t` 复现同一错误，且截屏确认屏幕上并没有等待用户点确认的弹窗——这是 MIUI/HyperOS 的「USB 安装」开关，只能在手机上手动打开，不在自动化能碰的范围里。副作用：那条自动卸载已经把这台上原有的 2015 版应用卸掉了，需要时重新装一次发布包。手机打开「USB 安装」后重跑 `HONGGUO_RAIL_DEVICE=8c9cf729 tool/verify_theme_rail_live.sh` 即可补齐 `docs/evidence/theme-rail/android-*.png`。
- 390 紧凑布局另有 `test/theme_rail_test.dart`、`test/adaptive_ui_test.dart`（`Size(390, 844)`）两组用例兜住，不依赖上面任何一台设备。

## 已知交织

`library_page.dart` 及其测试当前有另一条在途改动（请求代次/网络恢复，`CatalogRequestScope`）尚未提交，本次改造直接叠加在其工作树版本之上，无法只提交本文件的本轮 hunk。

现读证据：`git show HEAD:.../library_page.dart | grep -c CatalogRequestScope` = 0，工作树同一查询 = 5；`packages/api/lib/src/request_control.dart`（274 行，未跟踪）与 `hongguo_api.dart` 的导出改动都在另一条线上。因此本轮既不把别人的在途实现以本节的名义压上 main，也不做「只改索引提交本轮路径」——那样得到的树从来没编译过。

处置：整棵工作树（除 `.idea/`）快照成分支 `feat/pc-mobile-theme-rail`，起点 `bcf8c6a`（v0.3.4），main 与工作树都不动；提交树在独立 worktree 里过了一遍 CI 同套门禁（app analyze 干净、app 238 通过 1 跳过、tv 36、core 117、api 77、cast 52、TV 标记用例 1）。等网络那条线自己落 main 后，本分支 rebase 上去只留题材横栏的增量。

就地胶囊这一轮同样按整棵工作树快照续在分支上：`60db477`（产品 + 测试 + 证据 + 本节当时已有的文字），门禁全部跑在这一条的树上——独立 worktree 实测 app analyze 干净、app 238 通过 1 跳过、tv 36；core/api/cast 的字节与上一条快照 `1103c3b` 完全一致（`git diff --name-only 1103c3b 60db477` 只含 app 与 docs 两组路径），本轮没有重跑。`60db477` 之后本节的补写单独成一条 docs 提交，与已验证的树只差这份文档。校验用的 worktree 跑完即删。
