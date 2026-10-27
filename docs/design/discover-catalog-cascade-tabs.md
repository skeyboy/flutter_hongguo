# 发现/分类：一级页面横滑切换 + 二级联动筛选

日期：2026-10-27。状态：§1–§10 是上一轮（发现↔分类外层横滑，已提交为 `7e5ea8a`）的方案与落地记录；**§11 是本轮**——把每一页自己的一级也做成可横滑的页面（嵌套 `AutoTabsRouter.pageView`）并把边际逐级交接，代码已落地、`tool/verify_all.sh` 全量退出码 0、iPhone 实机帧已重取（读数见 §11 末两条；macOS 那一路仍录不到窗口层，本轮实机证据只有 `ios-*` 那批）。本轮按「梳理修复优化 → 提交 → 推送 → 发版」这一条指令已走完推送与 `v0.3.6` 打标发版（`5db32ab`，五端安装包已发布，过程记在 §11 第 11 条）。

> 行号基线：§1–§2 是改动前（`aa3cfb7`，v0.3.5）的读数，§3–§10 是上一轮落地后的读数，**本轮之后它们都过期了**；当前文件的对应位置与本轮新增结构一律写在 §11。

## 1. 现状（现读代码，`packages/app/lib/features/library_page.dart`）

> §1–§2 里的 `:行号` 是本轮改动前（`aa3cfb7`，v0.3.5）的读数，作为「改之前长什么样」的基线保留；改动后的对应位置写在 §3–§4 与 §10（上一轮那一份），再往后的见 §11。

- 页面切换是一个本地整数：`int destination = 0`（:96），由 `_navigate`（:632）用 `setState` 改写，底部 `NavigationBar`（:1397）、窄屏外的 `NavigationRail`（:1460）、宽屏侧栏 `ListTile`（:1439）都调它。它不是路由：`app_navigation.dart:148` 里根路由 `/` 只有一个 `Catalog`，`LibraryPage` 就是它的全部内容；`docs/evidence/theme-rail/` 里那批真机帧拍的都是这一个页面的三次 `setState`。
- 筛选条件全在一个 State 里：`genre / view / board / theme / query / sort`（:48-59），喂给 `feedKey`（:77）与 `feeds` 保活表（:75）。
- 胶囊行 `_choiceRow`（:961）按当前状态摆两组：有搜索词→只有「清除搜索」；发现→`[推荐|最新|榜单]` 再接 `[短剧|漫剧|AI 短剧]`；榜单态→后一组就地换成 `[推荐榜|热播榜|新剧榜]`。题材栏 `_themeRail`（:1058）钉在下方，搜索或榜单时高度归零。
- 真机上一屏最多同时出现：搜索框 + 离线检查、频道一组、类型一组、题材一栏、标题、网格——**四个筛选维度加一个搜索挤在同一头部**，而它们并不平级。这就是这轮要解决的形状问题。

## 2. 一级 / 二级的真实关系（按接口能问什么来定）

接口只有三条取数路径（`_requestPage` :149）：`search(query)` 吃掉一切、`rank(board)` 只吃 `board`、`browse(gen题材, sort, theme)` 吃 `genre + sort + theme`；`themes(genre)`（:671）说明**题材是类型的子集**。据此，维度之间不是并列的四个开关，而是两棵父子树：

| | 一级（选它才决定二级有什么） | 二级（内容随一级变） | 说明 |
|---|---|---|---|
| 发现 | 频道 `view`：推荐 / 最新 / 榜单 | 推荐·最新 → 类型；榜单 → 榜单（推荐榜/热播榜/新剧榜） | 二级整行换掉，是因为 `rank` 接口根本没有 `genre` 参数，榜单态留着一个改了也没用的类型行就是假控件 |
| 分类 | 类型 `genre`：短剧 / 漫剧 / AI 短剧 | 题材 `theme`（吸顶栏） | `themes(genre)` 是唯一的父子依赖；换一级必然清空并重装二级 |

两条硬性约束，决定「发现不该再有题材栏」：

1. 发现里的题材与分类里的题材是同一个 `theme` 字段、同一个父子（都挂在 `genre` 下）。同一维度在两个页面各自出现一次，就是上一轮从面板里删掉的那种重复。
2. 发现的推荐/最新确实吃 `theme`（`browse` 有这个参数），所以撤掉它是一次**能力收口**，不是接口做不到：收口的理由是发现回答「平台在推什么、什么类型」，分类回答「这一类里具体哪一路故事」。横滑把两者缝在一起之后，从发现甩到分类只需一次手势，比在发现里再堆一栏更便宜，也让每个页面各自只剩两级。

跨页共享的是**一级里的类型**：`genre` 上收到 shell。在分类选了「漫剧」再甩回发现，发现的二级类型行仍然选中「漫剧」；在发现选「最新」甩到分类，分类的排序不受影响（旧实现是 `_navigate` :639 离开发现就把 `view` 复位；本轮 `view` 仍是 shell 上的一个字段，但它只在 `feedKeyOf(pane)` 的 `pane == 0` 分支里参与取数，分类的键、排序、榜单都各自读成默认值——同一条规则换了个更硬的写法：不是「出门时清零」，而是「另一页根本不看它」。

## 3. 方案

### 3.1 路由：嵌套 tabs router，滑动即路由切换

- `LibraryPage` 变成 **shell**：仿 TV 的 `features/tv/tv_library_page.dart:24-86`，在 State 内建一个局部 `RootStackRouter.build`（:176），根路由 `CatalogShell`（path `/`）带两个子路由 `CatalogDiscover`（path `catalog-0`）与 `CatalogCategories`（path `catalog-1`），`build` 用 `AutoTabsRouter.pageView(routes: tabRoutes, animatePageTransition: true, builder:)`（:1579）——`pageView` 而不是手搭 `PageView`，因为换页时的 children 复用、`preload` 与 `_warpToCurrentIndex` 都在它内部。路由名与键名共用一份 `paneRoutes` / `paneName`（:167-171），所以「页面叫什么」在文件里只有一个出处。切换只有 `tabs.setActiveIndex(i)` 一个入口（`_selectTab` :804 → :821），`NavigationBar/NavigationRail/侧栏` 的点击和滑动手势都走它；`destination`（:152）退化成 router 的镜像，只有 `_onTabChanged`（:836）写它。
- 为什么不用主路由的 children：`app_navigation.dart:152` 的根 `Catalog` 是 `ValueListenableBuilder`，热换 runtime/主题时必须不换 router、不丢滚动位置（:121 的注释就是这条约束）；把 tabs 挂到主路由上，等于让 `home.value` 的每一次刷新去重建一层路由树。测试面也小：`test/` 下 14 个文件会挂出这个页面，其中只有 5 个直接构造 `LibraryPage(...)`，其余经 `HongguoApp()` 进来（本轮现读 `grep -rl "HongguoApp()\|LibraryPage(" test/`），嵌套 router 自包含，主 router 行为不动（`app_navigation_test.dart` 断言的 root 状态对象存活、`slidePageTransitions` 几何都不变）。
- 历史栈不增长：`setActiveIndex` 是兄弟页切换而非 push，因此 Alt+←、返回键、`MacWindowFrame(immersive:)` 的判断都不受影响；`PopScope` 仍然只管搜索建议。
- 嵌套 router 有自己的一个坑，实测到并补上了：`Router` 重建父级时不会重画被路由的子树，所以 shell 的 `setState` 到不了 pane。做法是覆写 `setState`（:210）顺带 bump 一个 `viewRev`（:207），`_CatalogShell` / `_CatalogPane`（:1750 / :1762）都是它的 `ValueListenableBuilder`。
- 我的 (`destination == 2`) 不进滑动集合：它盖在两个 tab 之上（`Stack` + `Offstage(offstage: mineOpen, child: pages)`，:1708），`_selectTab(2)` 走 `_openMine`（:824）而不是 `setActiveIndex`。误甩进个人库的代价比甩一次分类大得多，且我的没有 feed。用 `Offstage` 而不是 `if` 替换，是因为被遮住的两个 pane 仍要参与布局——`StackFit.expand` 配松散 Stack 会让离屏子节点贡献零尺寸，把「我的」一起压没。

### 3.2 手势：PageView + 默认触控族输入，行内横滑不被抢

- 两个 pane 各是一个完整目录页（搜索框、两级筛选、吸顶题材栏、网格、翻页），承载它们的 `PageView` 就是 `AutoTabsRouter.pageView` 内部那个 `EagerPageView`（`cacheExtent: _children.length`，两页都常驻，换页不重建）。反向没有手写的 `PageController.animateToPage`：`TabsRouter` 本身是 `ChangeNotifier`，shell 只 `_attachTabs`（:1732）挂一个监听，`_selectTab → setActiveIndex → router.notifyAll → 内部 controller 动画`，页面自己跟着走。
- 成环是 auto_route 内部两个闸门挡住的，不是本轮加的：它的 `_handleScrollNotification` 先 `if (notification.depth != 0) return false`，所以内层纵向列表与胶囊行的横向滚动都动不了页索引；`setActiveIndex` 又被 `if (_activeIndex != index)` 包着，所以 `_onTabChanged` 天然幂等（首次提示 `swipeHintSeen` 也因此不会被重复置位）。
- 设备族策略最终是**沿用默认，而不是加自定义 `ScrollConfiguration`**：`ScrollBehavior.dragDevices` 的默认集合是 SDK 里的 `_kTouchLikeDeviceTypes`（`.fvm/flutter_sdk/packages/flutter/lib/src/widgets/scroll_configuration.dart:29-37`：touch、stylus、invertedStylus、trackpad、unknown），本来就不含鼠标，所以桌面上「鼠标拖列表」从来不动，页面切换继承同一条。鼠标拖同一段距离不换页因此写成断言钉住（`catalog_tabs_test.dart` 的 `createGesture(kind: mouse)`），而不是靠文案约定；原来的方案文本（沿用 `episode_swipe.dart` 的 `fromFinger` 再叠一层 `ScrollConfiguration`）是同一结论的重复实现，删掉了。TV 遥控器没有对应输入，所以首次提示只在 `compact`（手机/平板宽度）出现。
- 竞技场事实：栏内的 `SingleChildScrollView(scrollDirection: Axis.horizontal)`（本轮 `filter-choices-<页>` :1224、`theme-rail` :1291，键在 :1225 / :1292）在内层，横向拖拽先被它们拿走——**手指在胶囊行/题材栏上横滑 = 滚这一行，在网格空白处横滑 = 换页**。这是要写进用例的行为，不是待修的冲突；窄屏上胶囊行本来就溢出需要横滑，抢不得。
- 首次提示按平台×设备分派已落地：`compact && !swipeHintSeen` 时在网格下方给一行「左右滑动切换 发现 · 分类」（:1398-1404，键 `swipe-hint`），一旦真的换过页就不再出现；桌面与 TV 因为宽度不 `compact` 而拿不到这条文案，与它们没有对应输入是一致的。

### 3.3 两级联动的可见化

- 一级行与二级行同高（`_filterRowHeight = 52`，本轮 :26）但**不同层级语言**：选中态一级/二级都用 `ChoiceChip`，选中项加粗到 `w700`（:1175）；两组之间立一条 1×24 的竖缝（:1237-1242），让「频道回答的是看哪一路流、类型/榜单回答的是看哪一类故事」不糊成一行；二级的父名直接写进标签——分类题材栏首枚是「全部 · 漫剧」（:1303）。
- 一级变更对二级的动作显式化：分类换类型 → 题材栏立刻进 `theme-rail-loading`（本轮 :1271）；发现 `view` 切到 榜单 → 二级整行换成榜单三档（`_selectFilter` :876 的 `case 'view'` 分支只剩 `view = value`，榜单三档与标题都读同一份 `_boardNames` :43），频道的选择到此为止——它不改共享的 `genre`，也不碰分类的题材栏，理由见 §5 末条。
- 发现不再渲染题材栏（`_themeRail(pane, compact)` :1257 只在 `pane == 1` 的 sliver 列表里出现，:1385），分类不再有频道行（`_choiceRow` :1201 那条 `if (pane == 0)` 分支——旧文件 :1001 的 `destination == 0` 换成了 pane 自己的条件）。
- 搜索仍然吃掉两级：`query` 非空时两级行只剩「清除搜索」（本轮 :1189-1200，清除键 `clear-search-<页>`），且 `query` 已经是 per-pane 的：`paneQuery` / `paneFocus`（:65-68）各 pane 一份，`queryOf(pane)`（:135）读。两个 TextField 共用一个 controller 会被 Flutter 断言拒绝，这条拆法是先写进设计的，落地时按它执行。

## 4. 键位与作用域（两个 pane 同时存活 ⇒ 键必须唯一）

| 旧键 | 新键 |
|---|---|
| `catalog-results` | `catalog-results-discover` / `catalog-results-categories`（:1343）——本轮之后它仍是**按 pane** 的键，因为静止时一个 pane 只有一级页在树里（§11） |
| `catalog-feed`(PageStorageKey) | `catalog-feed-discover` / `catalog-feed-categories`（:1346）→ **本轮再细一层**：`catalog-feed-<页>-<一级>`（§11，一处真实回归） |
| `filter-choices` | `filter-choices-discover` / `filter-choices-categories`（:1225） |
| `search-field` / `clear-search` | 各 pane 一份：`search-field-<页>`（:975）/ `clear-search-<页>`（:1194） |
| `theme-rail(-loading/-retry/-<id>)` | 分类 pane 保留原名；发现 pane 不再有该键 |
| `filter-view-*` / `filter-board-*` | 只在发现 pane，键名不变 |
| `filter-genre-*` | 发现（非榜单）与分类各一份：`filter-genre-discover-<值>` / `filter-genre-categories-<值>`（由 `keyPrefix: 'genre-${paneName(pane)}'` :1218 生成） |
| `search-suggestions(-dismiss)` | 键名不变，但同一时刻只有一份浮层存在：`suggestionsPane`（:74）记录它属于哪个 pane |
| 新增 | `catalog-tabs`（底部 `NavigationBar` :1619）、`catalog-tab-<index>`（宽屏侧栏 :1652）、`swipe-hint`（:1404） |
| `my-page` | 不变（不在滑动集合里） |

页名只有一个出处：`paneName(pane)`（:171）——`discover` / `categories`，与路由名 `CatalogDiscover` / `CatalogCategories`（:167）同一对词。上一轮写表时用的 `-catalog` 已弃用：分类在屏幕上就叫「分类」，不需要第二个词指代整个目录。

滚动控制器同样按 pane 一个：`paneScroll`（:59）为两个 pane 各建一个，`scroll`（:218）只是「当前 pane 的那个」的读法；`_nearEnd(pane)`（:312）、`_restoreScroll(pane, offset)`、各处跳顶都按 pane 取，`_ThemeFeed.scroll` 仍按 feed 记录存偏移，回切时两帧补跳（上一轮 :466 的修复在新结构里是 :347 一带的 `pane = feed.pane`）。

> **本轮更正这一条**：一级成为页面之后「按 pane 一个 controller」不成立了——拖拽中同页的两级会同时布局，一个 controller 只能挂一处。**现为「按 (pane, 一级) 一个」**，见 §11 第 2 条；这一条当时的写法保留作基线。

## 5. 后端配合清单（不改接口也能落地，但记下来）

- `rank` 不吃 `genre`：榜单态无法按类型收窄，所以二级只能整行换成榜单。若上游给出 `rank(genre)`，发现的榜单二级可以再挂一层类型。
- `search` 不吃 `theme`：搜索态必须撤掉两级行，否则是假控件（现状保持）。
- 推荐流若希望继续支持题材收窄，需要上游确认 `browse` 的 `theme` 在推荐排序下是否有意义；当前 UI 收口到分类，不依赖这条确认。
- **本轮修掉的一条前端遗留（不是接口缺口）**：`_selectFilter` 的 `case 'view'` 里，进入榜单曾把共享的 `genre` 写成 `comic_series`（旧 :874，连带清掉 `theme`/`themes`、`themesRevision++`、`_themesScope.cancel()`；自首提交 `4711d2d` 起就在，无注释说明动机）。横滑之后 `genre` 成了两页共享的一级，于是「在发现点一下榜单」会看不见地改掉分类的一级——而 `rank(board)` 根本不吃 `genre`（改了也不影响榜单的取数，只影响甩过去之后的分类）。**但接口事实要说全**：三档榜单在上游就是漫剧榜（`packages/api/lib/src/catalog.dart:498-515` 固定发 `selected_items: comic_series_rank` + `comic_series_hot_rank / comic_series_hot_play / comic_series_new_rank`），`docs/design/pc-mobile-ui.md:26`、`docs/design/horizontal-filter-panel.md:67` 也要求 UI 明说它是漫剧榜、不能冒充别的体裁排行。所以本轮经确认的改法是**把这件事从「改状态」换成「写在标题上」**：频道分支只剩 `view = value`（:889-895），标题由 `_sectionTitle`（:1123-1134）拼成「漫剧 · 推荐榜 / 漫剧 · 热播榜 / 漫剧 · 新剧榜」（漫剧那一截取 `_genreNames[_boardGenre]`，`_boardGenre` / `_boardNames` 在 :42-43），榜单三档也共用这份 `_boardNames`（原来在胶囊行里还内联写过一遍）。连带效果：分类的题材栏不再被点一下榜单就清空，§10 那条「甩进分类时补一次题材」的门因此只需要处理「真的还没跑完/跑失败」两种情况。回归断言在 `test/horizontal_filters_test.dart` 的「频道 belongs to 发现, 榜单 takes the type place, search leaves neither」：标题是「漫剧 · 推荐榜」、点热播榜后变成「漫剧 · 热播榜」、切到分类后选中的一级仍是短剧。

## 6. 验收标准

> 本轮把「左右滑动」这件事分成两层来验收（内层翻页、边际交接），新增的验收条目写在 §11 第 5 条。

- 手指在网格区左右甩：发现↔分类换页，且 `tabs.activeIndex` 与导航栏选中项一致；鼠标在桌面拖同一段距离不换页。
- 手指在胶囊行、题材栏上左右甩：只滚该行，不换页。
- 换页不重新请求：分类已翻过三页的题材，甩到发现再甩回来还是那三页与那个偏移（保活在 shell 的 `feeds`，不在 pane）。
- 每个页面同时最多两级可见：发现 = 频道 + (类型|榜单)；分类 = 类型 + 题材；搜索态只剩「清除搜索」。
- 在分类选「漫剧 · 悬疑」，甩到发现：发现的二级类型行选中「漫剧」，且发现的列表不因带上了 theme 而变化（`theme` 只属于分类的 feedKey 分支）。
- 在发现点「榜单」：共享的一级不动（甩回分类仍停在 viewer 自己选的那个类型）、分类的题材栏不被清空也不被取消在途请求、榜单是漫剧榜这件事写在标题里（「漫剧 · 推荐榜 / 漫剧 · 热播榜 / 漫剧 · 新剧榜」），不再靠偷偷改写一级来表达。
- `flutter analyze` 两包干净，`packages/app` 全量、`packages/tv` 全量、core/api/cast 全量通过；本轮改动文件 `dart format` 干净。

## 7. 测试

> 下列是第一版落地时那 8 条；本轮把 `catalog_tabs_test.dart` 按两级语义重写成 16 条并改了 `horizontal_filters_test.dart` 的吸顶用例，现读清单见 §11 第 7 条。

- 新增 `test/catalog_tabs_test.dart`：滑动换页与路由索引一致；鼠标不换页；行内横滑不越权；换页保留两个 pane 各自的 feed；`genre` 跨页共享；一级变更后二级行的形态（榜单↔类型）正确。
- 改点：`horizontal_filters_test.dart`、`theme_rail_test.dart`、`interaction_cache_test.dart`、`adaptive_ui_test.dart`、`app_navigation_test.dart`、`catalog_sort_test.dart`、`widget_test.dart`、`mobile_recovery_test.dart`、`network_cache_behavior_test.dart` 里所有裸键查找换成带 pane 作用域的键，「开面板」相关残留按上一轮口径复核。`horizontal_filters_test.dart` 的「频道 belongs to 发现…」这一条在本轮多担四件事：榜单态标题是「漫剧 · 推荐榜」、点热播榜后是「漫剧 · 热播榜」（旧实现写死「漫剧榜单」）、切到分类后被选中的一级仍是短剧（`ChoiceChip.selected`）、题材栏没被点榜单这件事清空。
- `integration_test/theme_rail_live_test.dart` 已加两个标记：`shot=tab-swipe-to-categories`、`shot=tab-swipe-back-to-discover`（`_swipe()` 按页宽取距离：起点在中心偏 `-dir × 0.28 × 页宽`、拖 `dir × 0.56 × 页宽`，touch 族默认输入，拖完立刻断言 `destination` 与 `tabs.activeIndex` 都真的落了位），并把裸键换成作用域键（`filter-genre-categories-*`、`catalog-results-discover|categories`）；两处题材帧（`shot=theme-two`、`shot=theme-three`）改成先 `_waitRows` 等到 `feed.items` 非空再拍，后面的下滚断言才有真实列表可拖（见 §8 第 5 次那次 `the live list never scrolled`）；取帧脚本 `tool/verify_theme_rail_live.sh` 不动——它按 `shot=([\w-]+)` 取标，新标记自动进 `docs/evidence/theme-rail/`。

## 8. 真机验证

macOS 窗口（1100×760）与 iPhone 模拟器（390×844）各录一遍：发现顶部（两级=频道+类型）、甩到分类（类型+题材，栏吸顶）、分类里甩回发现、榜单态二级换成榜单三档。合成点击不用于验证原生手势（本条链路只用 `drag` 于 widget 测试，真机帧靠夹具自己打到目标状态）。

本轮结果（2026-10-27）：

- iPhone 模拟器 `yxy-iPhone17Pro` **一整批同次运行**通过（`harness exit=0`，`ev=armed → ev=done`，`enter-categories destination=1 themes=26`，`shot=theme-two-scrolled offset=400` 与 `shot=theme-two-restored offset=400`），十帧全部落在 10:21 同一批并逐帧看过：
  - `ios-rail.png` = 进分类后一级 ✓短剧、二级栏 ✓全部 · 短剧 + 动作|冒险|魔幻|爱情，列表此刻还是骨架 +「正在更新内容…」——栏已填好、分类首页数据还没回，是真实的首帧而不是失败。
  - `ios-genre-comic.png` = 一级切到漫剧后，栏首枚跟着变成「全部 · 漫剧」，后面是 剧情|奇幻|玄幻|末世，行是漫剧（1000 集 / 399 集）——§3.3 那条二级随一级换血。
  - `ios-discover.png` = 发现的两级是 `✓推荐|最新|榜单 ‖ ✓短剧|漫剧`，**没有题材栏**，标题「为你发现」。
  - `ios-rank.png` = 点榜单后二级整行换成 `✓榜单 ‖ ✓推荐榜|热播榜…`，标题「漫剧 · 推荐榜」（旧实现写死「漫剧榜单」，把一级借来当标题；§5 末条），行确实是漫剧。
  - `ios-tab-swipe-to-categories.png` = 从榜单态甩进分类：底部导航选中「分类」+ **一级仍是「短剧」** + 二级题材栏首枚「全部 · 短剧」+ 满格列表、无报错行——夹具在 `integration_test/theme_rail_live_test.dart:171` 已把类型选回短剧，旧代码会在点榜单时把它改写成漫剧，这一帧就是那条越权写入的反证。
  - `ios-tab-swipe-back-to-discover.png` = 甩回之后发现自己的两级是 `推荐|最新|榜单 ‖ 短剧|漫剧`（共享的一级跟过来了）、**没有题材栏**、标题「为你发现」、网格直接接在标题下面——没有骨架、没有「正在更新」那一行，说明回来读的是留着的行而不是重新取的一份，即 §10 第一条保活规则在真机上的样子。
  - `ios-theme-two.png` / `ios-theme-two-scrolled.png` / `ios-theme-three.png` / `ios-theme-two-restored.png` = 栏吸顶（一级行已随列表划走）、「动作」自己的行、下滚到偏移 400、切「冒险」换另一套行、再切回「动作」仍是同一批行且偏移仍是 400、全程没有骨架也没有「正在更新」——每条题材一份保活 feed 与「回切夹平偏移」那两处修复在同一批帧里读得出来。
  - 一句要收口的更正：上一批（09:08 那次）里 `ios-tab-swipe-to-categories.png` 顶部曾有一行「网络刷新失败，仍显示上次结果。」+「重试刷新」，是回切时后台 `_refreshKept` 撞上一次真实网络抖动，走的正是 §10 那条保活路径的失败文案（行没被动过）。本批这一帧没有这行，所以它不是这条链路的常态，只是那一次抖动的记录。
- 这一批之前挡了三次，都记下来免得下次再猜：第 2、3 次 `enter-categories themes=0` → `rail-empty error=题材加载失败`，而产品代码 `catch (_)` 把原因吞了，于是在 `_loadThemes`（:845）的 catch 里加一行 `debugPrint('catalog.themes($requestedGenre) failed: $failure')`（:866）——UI 仍然只显示「题材加载失败」，但取证跑必须分得清「被取消的 flight」和「上游什么都没回」。加上之后第 4 次打出真实原因是「内容接口未返回数据，请稍后重试」，定性为上游返空（这个端点本轮多次偶发返空），不是产品缺陷。第 5 次卡在 `the live list never scrolled`（偏移 0.0），它自己那批的 `ios-theme-two.png` 显示「动作」当时还是骨架：夹具在拖之前没等行到位，拖的是一份骨架，属夹具时序而不是产品缺陷。第 6 次因此加了 `_waitRows(tester, where)`（`integration_test/theme_rail_live_test.dart:35`，读 `state.feed.items` 直到非空，超时打 `rows-timeout where=… loading=… error=…`），把 `shot=theme-two`、`shot=theme-three` 两处从「固定等 1.2 s」改成「等到真有行再拍」。
- macOS 那一路本轮**没取到**：这台会话此刻的 `screencapture` 只返回壁纸（无菜单栏、无 Dock、无任何窗口层），录屏窗口矩形里根本没有应用窗口，十帧全是风景。已把被覆盖的 8 张 v0.3.5 帧从 git 恢复、删掉本轮两张废帧；`rail.png / discover.png / rank.png / tab-swipe-*` 等 macOS 帧要等屏幕解锁后重跑 `HONGGUO_RAIL_DEVICE=macos tool/verify_theme_rail_live.sh` 补。横滑本身在两处被钉住：`test/catalog_tabs_test.dart` 的 8 条（含鼠标不换页、行内横滑不越权）与上面这组 iPhone 帧。
- 夹具另外两处顺手修的：`_swipe` 的拖拽距离改为按页宽取（桌面一页 900 px，原来写死的 320 px 只够手机一页，桌面上弹簧回弹后 `catalog-results-categories` 根本不存在）；开机探针改读 `feed.error / feed.loading / feed.items`（这两个字段本轮迁到了每条 feed 的记录上，探针还在按旧形状读，一失败就自己先崩）。

## 9. 风险与回滚

- 最大风险是两个 pane 同时存活带来的重复键与重复 controller，处理方式是 §4 的作用域化；如果测试面冲突过多，回滚点是把 `PageView` 换成「只有当前 pane 存在 + 切换时瞬时替换」（保住路由与联动，放弃拖拽中的双页可视）。实际落地没有触发这条回滚：作用域化之后全部旧用例只需改键与加一次换页等待，未拆掉常驻双页。
- 单文件仍是同一个文件（本轮从 1649 行到 1946 行），shell / pane 是同一个文件里的两个 Widget（`_CatalogShell` :1750、`_CatalogPane` :1762），拆分粒度停在「读得动」这一档；改动集中在同一文件内，不改 TV 与主路由；回滚只需 `git revert` 本轮提交。

## 10. 落地状态（本轮实际做了什么，与方案有出入的地方）

三处与 §3 的写法不同，都是「实现选择了更硬的那条路」，方案文本已就地改成实际形态：

1. §3.1 原写 `AutoTabsRouter(routes:, duration: Duration.zero, transitionBuilder: 直通)` → 实际是 `AutoTabsRouter.pageView(routes: tabRoutes, animatePageTransition: true, builder:)`；换页要有滑动过程，直通动画和它互斥。
2. §3.2 原写「给页面切换加只放 touch+stylus 的 `ScrollConfiguration`」→ 实际**没有加**：Flutter 默认 `dragDevices` 本来就不含鼠标，桌面上的「鼠标拖不换页」是默认行为，本轮把它写成断言而不是新配置。
3. §3.2 原写「`onPageChanged` + `animateToPage`，两边用谁先动的闸门外环成」→ 实际是 `TabsRouter` 监听（:1732-1736）单向驱动，回环由 auto_route 自己的 `depth != 0` 与索引守卫消掉，不需要本地闸门。

三条新的保活/取数规则，测试与真机帧都要按它们判：

- 进入一个**已看过**的页面 = 保留原有行 + 后台 `_refreshKept`（220 ms 去抖后在 :594 触发，本体 :422），失败文案是「网络刷新失败，仍显示上次结果。」；这条路径不再走 `_reload`，所以旧文案「网络刷新失败，正在显示本地缓存。」只属于显式 `_reload`。**本轮把这条的范围收窄了**：它只说「从 我的 回目录」那一种进入；在页内横滑换一级（推荐↔最新、类型↔类型）是「原位继续」，不再问上游，理由与回归见 §11 第 6 条。
- 甩进**没看过**的分类、且题材栏还是空的（这一次进入之前谁也没为共享的一级跑过题材，或跑了但返回空）→ 立刻补一次 `_loadThemes(genre)`（`_switchFeed` 里 :601 的 `incoming.pane == 1 && themes.isEmpty && themesError == null && !themesLoading`）。**在途不补、失败不补**：`themes` 在请求控制层是同一把 label 的一份 flight（`packages/api/lib/src/request_control.dart:206-210` 的 `_flights[key]` 合并），补一次会先 `_themesScope.cancel()` 掐掉正在跑的那次（`request_control.dart:45-47`），而加入的正是那份已被取消的 flight——真机上直接落到「题材加载失败」——这条是 macOS 取证第一跑被它挡下之后加的门，回归用例见 `test/catalog_tabs_test.dart` 的「entering 分类 mid-flight leaves the theme request alone」。失败本身仍只有重试胶囊这一个入口。写这条规则时它还要兜住「发现停在榜单上、题材请求被取消过」那种空栏，§5 末条把那次取消删掉之后，这个来源没有了。
- 从「我的」返回不再重读缓存（`_selectTab` :804-822 只在设置改动过的时候才 refresh），所以旧版那次「回目录必然重进缓存、头部出现『刷新』一行」的现象消失了；`interaction_cache_test.dart` 里依赖它的断言已改走「换类型拿新 cursor」这条路。

门禁读数（本轮工作树，SDK `.fvm/flutter_sdk`，`tool/verify_all.sh` 全量退出码 0；这一遍是在标题改成「漫剧 · 推荐榜」、`_loadThemes` 加了那行 `debugPrint`、夹具加了 `_waitRows` 之后重跑的，与之前那次读数一致）：格式门（`dart format --output=none --set-exit-if-changed packages tool`）与 `dart analyze --fatal-infos` 干净；`core +117`、`api +77`、`cast +52`、`tv +36`、`app +246 ~1`（含新增 `test/catalog_tabs_test.dart` 的 8 条）全绿；oracle 103 向量、离线解密样本 84 条通过。§6 最后一条「两包 analyze + 各包全量」由此满足。本轮按约定只本地提交、不推送也不打 tag，所以这是**工作树**读数；提交树的那一份要等真正推送前在分离 worktree 里再跑一遍。

取证进度见 §8：iPhone 帧已拿到**一整批同一次运行**的十帧并逐帧看过；macOS 帧因这台机器当前没有可录的窗口层而缺，等屏幕可用时补一次 `HONGGUO_RAIL_DEVICE=macos tool/verify_theme_rail_live.sh`。那一轮为取证可归因加的唯一产品侧改动是一行 `debugPrint`（当时在 `library_page.dart:866`，本轮之后是 :1126；只在 `_loadThemes` 的 catch 里，UI 文案不变）。

## 11. 本轮：把每页自己的一级也做成页面，边际逐级交接（2026-10-27）

用户原话：「发现 和 分类内部的同样需要可执行左右滑动切换。当"发现"和"分类"左右滑动到到边际后继续滑动再执行 "发现" "分类" 这两个tab间的自动切换」，并指定「参照 `AutoTabsRouter.pageView` / `AutoTabsRouter.tabBar` 这种方式」。两条经确认的选择：① 内层用**嵌套 `AutoTabsRouter.pageView`**（不是手搭 `PageView`，也不是把类型行改成 `tabBar`）；② 分类的题材栏**保持横栏 + 只做边际交接**，不升级为第三层内滑页。本节全部 `:行号` 是当前工作树 `packages/app/lib/features/library_page.dart`（2368 行）的现读值。

1. 一级成为路由（slot）。`slotSets`（:64）：发现 = `[recommend, latest]` + 仅当 catalog 实现了 `RankCatalogRepository` 才有的 `rank`；分类 = `_genreOrder`（:72，短剧/漫剧/AI 短剧）。`slotOfPane(pane)`（:75）读的还是那两个老字段（发现的 `view`、分类的共享 `genre`），所以「一级是什么」在状态层只有一个出处，路由只是它的名字：`slotRouteName`（:387-388，`CatalogSlot$pane-$slot`）、`innerRoutes`（:392）、router 里每个 pane 的 RouteDef 挂上 `children`（:356-374）。slot 路由一律 `maintainState: false`（:367）——静止时同 pane 只有一级页在树里，键、`Text` finder、焦点遍历都保持唯一；拖拽中 auto_route 的 `preload` 会把邻页拉进来，这正是下面第 2 条「controller 必须一级一个」的原因。
2. 每 (pane, 一级) 一份控制器与去抖，feed 键不变。`slotScroll`（:80）+ `slotKey`（:84）+ `scrollAt`（:86）+ `scrollOf(feed)`（:97）；`slotFilterTimer`（:137）；自动翻页的在跑集合从「按页」变成「按记录」（`autoScheduled` :129），`_nearEnd`（:537）用 `feed.slot != slotOfPane(feed.pane)` 挡掉不在屏上的那一页——三条列表可能在拖拽中同时有 client，只有屏上那条许它继续翻。**`feedKeyAt`（:158）不新增字段**：`view`/`genre` 本来就编码了一级，所以磁盘快照的键与 v0.3.5 兼容，回切读的还是同一份缓存。
3. 视图结构：`_pane`（:1628）= 固定的 `_paneBand`（:1643）+ `Expanded(_innerPages(pane))`（:1704）。band 里是搜索框、离线检查、胶囊行、（分类）题材栏、首次提示；`_slotPage`（:1715）只剩标题、状态行、网格、页脚。**这是对 `docs/design/pc-mobile-theme-rail.md` §5「顶部瘦身：搜索与筛选随列表划走，题材栏吸顶」的一次反转**，代价说清楚：手机端搜索框与胶囊行不再随列表划走，列表能用的可见高度比以前少一整个 band（一行搜索 + 52 的胶囊行 + 分类再一道 52 的题材栏，`_filterRowHeight` :26）。为什么非反转不可：一个 `TextEditingController` 与一个 `ScrollController` 都只能挂一处，而内层横滑要求拖拽中把两页同时铺开；把 chrome 复制进每个一级页就是同键双份，`find` 与状态都会撞。题材栏本来就是这一页的「二级 tab」，跟着页走而不是跟着列表走。`_themeRail` 的注释（:1539 一带）已按此改写，上一轮那个 `SliverPersistentHeaderDelegate`（`_ThemeRailHeader`）随吸顶机制一起删掉了。
4. 边际逐级交接：三层各听各的，一次手势最多换一层。
   - 胶囊行/题材栏的横滑先到 band 的 `_onBandScroll`（:294；累计量 `bandEdgePull` :253，阈值 `_edgePullExtent = 48.0` :258）：这一页在那一侧还有下一页 ⇒ 花掉并 `return true`（通知到此为止，所以 shell 不会重复计数）；没有了 ⇒ 清零、`return false` 把整段上交。
   - 列表区直接压在内层 `EagerPageView` 上，由它自己的 `PageScrollPhysics` 翻页；内层到头之后它的 `OverscrollNotification` 冒到 shell 的 `_onNestedScroll`（:260，挂在 :2042），同一 48 px 阈值 → `_selectTab`（:1058）。
   - shell 自己的 `AutoTabsRouter.pageView`（:1907）是 `depth == 0` 那一层，`_onNestedScroll` 第一句就把它让开：外层翻页由它自己的物理做，不需要累计。
   - 「默认 `dragDevices` 不含鼠标」这条继承不变，所以鼠标在两层都不换页（写成断言，见第 7 条）。
   - 两个 router 的接入只有一份方向：`_attachInnerTabs`（:2082）在内层 builder 里挂 `innerChanged`（:410），`_onInnerTabChanged`（:2106）把 router 的落点写回状态，`_gotoSlot`（:2119）反过来让 chip 驱动 router，`_syncInnerIndex`（:2096）负责「共享的一级在对面也把自己那页翻过去」。回声由守卫消掉：`slot == slotOfPane(pane)` 直接 return，所以 chip 与甩不会各进一次。
5. 本轮验收标准（加在 §6 之上）：一次拖拽只换一层；内层到头之后同向再拖才换外层；`我的` 仍不在集合里（分类最后一个类型上再往左甩，什么都不动）；胶囊行自己还有宽度时先滚自己；换一级不重新问已经拿过的行；共享类型在两边同时选中，且对面的 router 跟着落在那一页上。
6. 本轮修的两处真实回归，都是新结构带出来的：
   - **PageStorage 串偏移**：三个一级 controller 曾共用 `catalog-feed-<页>` 这一把 `PageStorageKey`，新进入的一级页一上屏就恢复了上一页的偏移（实测那一例 68 px，正是 band 头部的高度），题材栏被顶到视口顶——`horizontal_filters_test.dart` 里 rail 的 top 从 116 变成 48 就是这个。键加一级后缀（:1730 `catalog-feed-${paneName(pane)}-$slot`）之后恢复。
   - **换一级多发一次首屏请求**：`_applySlot`（:2128）原先走 `_switchFeed(keepAlive: true)` 的默认 `refresh`（:791），「回 推荐」被 `_refreshKept`（:844 那台定时器）又问了一次上游，`catalog_sort_test.dart` 的「回切不再发请求（各频道自己的页缓存）」当场 +1。现在是 `refresh: false`：页内横滑是「原位继续」，只有从 我的 回目录才后台刷新（§10 第一条的范围因此收窄，已就地标注）。
7. 测试面（现读计数）：`catalog_tabs_test.dart` **16 条**——内层一次拖拽只换本页级（`a swipe moves one page of 发现…`）、内层尽头再甩才交给 shell（`the pull past the last of a page is handed to the shell`）、分类的三个类型自己翻且 past 分类没有下一页、导航栏与甩一致、鼠标两层都不动、胶囊行还有宽度时只滚自己、胶囊行耗尽时**逐级**交接（`a row that runs out hands over one level at a time`：只要本页还有下一页，shell 就不许动）、换页各留自己的行、共享类型从对面开出的正是那一页、在途不补题材请求、页在途离开仍填自己的行、搜索浮层挡住两级、一份类型只跑一次题材、刷新接管在途页、保活上限。`horizontal_filters_test.dart` 7 条，其中原「吸顶」用例改名 `the band stays put over a long scroll and the rail keeps answering`，断言从「胶囊行随头部从树里消失」翻成「band 不动、rail 矩形不动、列表在底下滚」。
8. 首次提示文案跟着覆盖两级：`左右滑动切换本页，滑到尽头再切换 发现 · 分类`（:1689-1690）。置位时机仍然是「真的换过外层页」（`_onTabChanged` :1090-1093），因为这句话的后半件没做到之前，提示没有理由消失。
9. 门禁读数（两套分开）：本轮**工作树**（SDK `.fvm/flutter_sdk`）`tool/verify_all.sh` 全量退出码 0；格式门 202 文件 0 changed、`dart analyze --fatal-infos` No issues found；`core +117`、`api +77`、`cast +52`、`tv +36`、`app +254 ~1`；oracle 103 向量、离线解密样本 84 条通过。**提交树**两份各自在分离 worktree 里重跑同一套：功能提交 `ccbd6f9` 与工作树逐项相同（退出码 0，`+117/+77/+52/+36/+254 ~1`、analyze 干净、oracle 103、离线 84），发布提交 `5db32ab` 亦然，另加 CI 里那条 `python3 -m unittest discover -s tool/ci/tests` 9 条通过。
10. 取证（本轮已补，读数如下）：`integration_test/theme_rail_live_test.dart` 的 `_swipe()` 原来「一次拖拽 + 断言 `destination`」在新语义下必然停在 最新 页——已改成同向连甩直到 shell 应答，并打 `inner-first from=… pulls=…` 记录花掉了几次内层；新增 `_swipeInner()` 与 `_mark('shot=inner-latest')`，专门取「内层换页而外层没动」这一帧。取帧脚本 `tool/verify_theme_rail_live.sh` 不动（按 `shot=([\w-]+)` 取标，新标记自动进 `docs/evidence/theme-rail/`）。
    - iPhone `yxy-iPhone17Pro`：三跑，前两跑被上游挡下（第一跑 `boot-failed error=内容接口未返回数据` 整页 0 行；第二跑到 `theme-two` 又 `rows-timeout` 同一个文案，之后的「列表没滚起来」是它的下游后果，不是产品缺陷），第三跑一整套 10 帧同一次运行、`ev=done`，全部逐帧看过：`ios-rail`（分类首进，band 里 类型 + 题材两行都在、列表在骨架）、`ios-genre-comic`、`ios-discover`（甩回 发现，仍选中 推荐，band 上方一行「正在更新内容…」）、**`ios-inner-latest`（本轮新增这一帧：一级已经翻到 最新、标题「最新上架」，底部导航仍然选中 发现——内层换页而外层没动）**、`ios-rank`（发现停在 榜单 一级，二级整行换成 推荐榜/热播榜）、`ios-tab-swipe-to-categories` / `ios-tab-swipe-back-to-discover`（连甩两次内层才交接一次，日志 `inner-first from=discover pulls=2`；甩回来仍落在 榜单 那一页）、`ios-theme-two` / `-scrolled offset=400` / `theme-three` / `-two-restored offset=400`（切「宫斗」换一套行，切回「悬疑」还是 400 那一屏，band 与栏矩形全程不动）。
    - macOS：`HONGGUO_RAIL_DEVICE=macos tool/verify_theme_rail_live.sh` 两跑，夹具侧都是好的（第一跑上游 `themes=0` → `rail-empty error=题材加载失败`；第二跑 `ev=done` 十个标记齐），但录出来的每一帧都是桌面壁纸——这台机器仍然没有可录的窗口层（窗口矩形由夹具如实报出，裁剪到的那块屏上根本没有窗口的画面，和 §8 那次的结论同一条）。所以 `docs/evidence/theme-rail/` 里无前缀的那批还是上一轮 08:28 的帧（band 之前的结构），本轮的实机证据只有 `ios-*` 这一批；这次空录覆盖到的 8 张已按提交态还原（`discover` / `genre-comic` / `rail` / `rank` / `theme-two` / `theme-two-scrolled` / `theme-three` / `theme-two-restored`），本轮新落的 3 张废帧（`inner-latest.png`、`tab-swipe-to-categories.png`、`tab-swipe-back-to-discover.png`）已删除。屏幕可用时再补一次同一条命令即可。
    - 补一轮（同一台 iPhone 模拟器，把「两级各自跑完才交接」在**两个 tab 上都钉一遍**）：夹具新增 `_swipeInner(categories, -1, …)` 两脚走到 分类 自己的尽头（`短剧 → 漫剧 → AI 短剧`，每一脚都断言 `destination` 仍是 1 且 `innerTabs[1].activeIndex` +1），落帧 `ios-inner-categories-last.png`（底部导航仍选中 分类、一级选中 AI 短剧、题材栏换成「全部 · AI 短剧」那一批）；`_swipe()` 的打点也从「只在花掉内层时说话」改成两种都报：本轮日志为 `inner-first from=discover pulls=2`（发现 从 推荐 起，内层先吃掉两脚才轮到 shell）、`edge-first from=categories pulls=0`（分类 已在自己第一页 短剧，第一脚直接上交）、`edge-first from=discover pulls=0`（发现 此时停在 榜单 这一末页，向左已无可翻，同样第一脚上交）。四个读数合起来才是这条规则的完整实机形状：**内层还有下一页时外层绝不动，内层到头之后第一脚就交出去**；`_swipeInner` 的三处断言是「不越级」的硬证据，两个 `pulls=0` 是「不拖沓」的硬证据。
11. 推送与发版（这条指令的后半件已走完）：功能提交 `ccbd6f9`（含上一轮未推的 `7e5ea8a`，18 个文件）、更正提交 `52efc8a`、发布提交 `5db32ab`（两处 pubspec 同步 `0.3.6+18` + `tool/ci/validate_release.py` 的说明：新增一条两级横滑、并把 0.3.5 那条还写着「rail pins to the top of the list」的话改成 band 的真相）。`git push` 第一次被 GitHub 以 `HTTP 408` 掐断（这批提交带着 ~25 MB 的 iPhone 帧），带一次性 `-c http.postBuffer=524288000` 重跑即过——没有改仓库 git 配置。轻量 tag `v0.3.6` 指向 `5db32ab`（与既有 6 个 tag 同一种），Release 运行 `40475837350` 12m31s 成功，`Hongguo v0.3.6` 已发布 12 个安装包（android 三 abi + android-tv 三 abi + linux/macos/windows 各二）加 `release-manifest.json` / `SHA256SUMS.txt` / `iOS-signing-status.txt`，iOS 未签所以没 IPA——与 0.3.5 的策略一致。发布说明里那句证据话一开始写成了「Verified from windowed macOS and iPhone simulator frames」，而 macOS 那一路本轮只录到壁纸（第 10 条），已同时改掉 `tool/ci/validate_release.py` 与已发布的那一份正文（`gh release edit v0.3.6 --notes-file`），现在只声明 iPhone 帧。Android 手机那条取证仍挂在任务 #4，而且这次看清了它是**两道独立的门**（设备已改走无线 adb，`adb devices` 里是 `192.168.0.44:37277`，不再是 serial `8c9cf729`）：① `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`——HyperOS 的装包策略，与走不走 USB 无关，屏幕上也没有等确认的弹窗；② 机上那份是 CI 的 arm64 split release 包（`versionCode=2017 versionName=0.3.5`，split 包被 Flutter 自动加 `1000 * ABI_VERSION`），本地 debug 包的 versionCode 就是 pubspec 的 build 号 18，于是先撞 `INSTALL_FAILED_VERSION_DOWNGRADE`，flutter 的兜底 `adb uninstall` 又被 `DELETE_FAILED_INTERNAL_ERROR` 拒掉（顺带说明：一次失败的取证跑本来有机会把用户手上的正式版卸掉）。`flutter test` 没有 `--build-number` 这个口，所以光开「USB 安装」还不够，要么在手机上先卸载 0.3.5，要么给 debug 构建另配一个高于 2017 的 versionCode。

