# 视频详情承接页 · App 客户端形态（去网页化）

日期：2026-10-31　状态：设计定稿，原型已按本文改造
适用端：Mobile（Android/iOS）、Desktop（macOS/Windows/Linux）、Android TV
原型：[prototypes/video-detail.html](prototypes/video-detail.html)（本文是它的规格出处）
上一轮：[2026-10-22-detail-page-and-download-policy.md](2026-10-22-detail-page-and-download-policy.md)（TV 动作行 / 选集分页 / 推荐命名 / 下载只限并发）——本轮不推翻它的任何一条结论，只把**详情页这一页本身**从网页形态改成客户端形态。

> 入库时补一句口径（2026-11-06）：本文的每条「现读」与行号都是 2026-10-31 那次量的。此后 `detail_page.dart`（`Scaffold` 从 81 一带挪到 139、简介段从 255 挪到 337）、`tv_detail_page.dart`（`cellExtent: 170` 从 223 一带挪到 330）这些文件都在长——**照文中行号去跳会跳偏，按文中写死的符号名与结构去找仍然对得上**（文中不带目录的文件名，例如 `download_selection.dart`，实际住在 `packages/app/lib/downloads/`）。本文的价值是那 25 条裁定与版面口径，不是行号；要不要逐条重新对一遍实码，留作单独一轮，不在这里改测试迁就文档。

## 0. 为什么要改这一页

原型此前是把一个网页落地页塞进了设备外框：它有自己的顶栏、hero 头图、右侧标签栏、`?ep=` 地址栏导航和一屏 `auto-fill` 卡片墙。这些形态在 App 里都不存在，也不该存在——App 的详情页是**推入路由栈的一个页面**，不是一个带 URL 的地址。

下列每一条都指到已入库的真实代码，不是理想描述：

| # | 原型里的网页形态 | 客户端事实（现读） | 本文裁定 |
| --- | --- | --- | --- |
| 1 | 桌面框内一条网页顶栏：品牌 logo + 搜索胶囊 + 头像（`.desk-top .logo/.search/.me`） | 详情页是 `Scaffold` + `AppBar(title, actions:[FavoriteButton])`，全局搜索在客户端外壳里，不属于这一页（`packages/app/lib/features/detail_page.dart:81-85`） | 页内只留「返回 · 剧名 · 收藏」，logo/搜索/头像一律删掉 |
| 2 | hero 落地头图（渐变满宽 + 40px 大标题 + 三枚胶囊按钮） | 头部是一个普通 `Row`：封面 130×180 + 标题 26 + 「共 N 集」+「上次看到第 X 集」+ `Wrap` 里的主按钮（`detail_page.dart:177-253`） | 改成卡片式头部，不做全宽渐变头图；标题字号跟组件走，不按落地页放大 |
| 3 | 右侧 330px 标签栏「选集 / 接下来播放 / 缓存」（`.side` + `.tabs`） | 整个内容区是 `Center` + `ConstrainedBox(maxWidth: 960)` 的**单列** `CustomScrollView`（`detail_page.dart:140-143`），没有任何侧栏 | 删掉侧栏与标签页；选集进正文，缓存进弹层，「接下来播放」属于播放页而不是详情页 |
| 4 | 「正在播放」是同一 DOM 上 `classList.toggle('playing')`，靠 `scrollIntoView` 把播放器滚进视野 | 点任意一集 = `pushAppPage(context, AppScreen.player, PlayerPage)`（`detail_page.dart:125-138`），播放器是**另一条路由** | 改成路由栈两屏：详情页 →（推入）播放页；播放页 pop 回详情页原位，不做页内状态切换 |
| 5 | 集数与当前集写进地址栏：`history.replaceState` + `?ep=N`，注释写「分享出去直接落到这一集」 | 页面栈由 `RootStackRouter` + `slidePageTransitions` 管（`packages/app/lib/navigation/app_navigation.dart:46,101,141-145`）；App 没有 URL，分享走系统分享面板，不靠地址栏 | 地址栏导航模型删除。`?g=&i=` 只保留为**原型之间的入参**（发现页原型 `discover-filters-ranking.html:861` 用它跳过来），并在读出窗里明写这是原型调试入口，不是产品能力 |
| 6 | 「大家都在看」= `auto-fill` 卡片墙 + 每张角标分数（`.grid-cards` + `.card .heat`） | 推荐只有一块，标题只有两种：「同题材 · <词>」或降级后的「平台热门」，且类型里**刻意不带** 最新/热度 标记（`packages/app/lib/recommendations/related_dramas.dart:6-12`）；列表行没有可信 `published_at/score` | 卡片墙删除。块名、卡片尺寸都按组件读数走（`related_dramas_section.dart:61-71`：150×268 / TV 168×284，字号 22 / TV 26） |
| 7 | 选集用「1-30 / 31-60」分组条 + 一整片网格（`.epseg` + `.epgrid`） | `EpisodePager`：高度恒定为 `rows` 行，页内不滚动，翻页是左右箭头 +「第 a/b 页」（`packages/app/lib/playback/episode_pager.dart:12-28,240-260,340-372`） | 三端统一换成分页器读数；分组条是网页锚点导航的替身，删除 |
| 8 | 键盘快捷键提示行 `.kpihint` 印在播放器下方 | 快捷键只对鼠标键盘族成立；触控族没有键盘，TV 只有五向键 | 提示移出应用画框，进原型的按键说明条（与发现页原型的 `#kbd` 同一处理） |
| 9 | 手机屏内一条底部分段器「播放中 / 详情 / 推荐」（`.mseg`） | [沉浸式播放](immersive-playback.md) 第 3 行写死了：「播放页铺满视频，不使用 AppBar、**侧边导航或底部导航**」；详情页是推进来的子页，底部再放一条 tab 栏等于给二级页做一级导航 | 屏内分段器删除；形态切换交给原型控制条，不进应用画框 |
| 10 | 「来源说明」按钮 + 坐标浮层（`[data-why]` + `.pop` 用 `getBoundingClientRect` 定位） | App 里没有「来源说明」这个可点控件 | 保留说明内容，但降级为**原型注记**（虚线标记 + 读出窗），不在应用画框里画假按钮 |
| 11 | 没有 TV 版面 | TV 详情页已实施，且形态与手机/桌面不同：**无 AppBar**、返回是可达焦点项（`packages/app/lib/features/tv/tv_detail_page.dart:97-101`） | 补 TV 遥控族视图，焦点序按 `:133-261` 的实际顺序画 |
| 12 | 底部抽屉顶部一条「全部 / 未看」分段器，下面 20 格一组 | 抽屉里就是 `_episodePanel` 那一段内容——全部集数的可滚动网格，打开时定位到正在播的那一集（`EpisodeReveal`，`player_page.dart:1317-1322` + `:1039-1071`），没有任何集数筛选状态 | 分段器删除；「未看/已看」在这页只有格子里的在播高亮与已缓存副标，不给假造的筛选 tab |
| 13 | 下载对话框里三枚自造 chip（"全 40 集 / 最近 10 集 / 仅前 3 集"） | 真实表单是画质下拉 + 全选/清空 + 逐集格子 +「下载 N 集」（`download_selection.dart:177-370`） | 按代码那张表单画，见 §6 的更正 |
| 14 | 详情页头部封面上叠两枚角标：左上「红果首发」、右下「全 78 集」 | 头部是 `SizedBox(130,180) + DramaCover`，`drama_cover.dart` 全文没有任何角标；角标属于 `DramaCard` 那层 `Stack`，而且位置是**左下**、文案是 `${episodeCount} 集`（`drama_card.dart:38-56`）。「红果首发」是列表行字段，详情接口不返回 | 头部封面画成裸封面，一枚角标都不留；集数只由「共 N 集」那行文字承担。推荐轨卡片保留左下「N 集」，本轮样本未留存集数所以显示为空，并在注记里写清"不是不该有" |
| 15 | 推荐卡面上印着「悬停 1.5 秒出预览 · 点一下接播这一部」，第二行是原型自造的「筛选词：X」 | 1.5s hover 预览是**列表页**给卡面套的一层（`library_page.dart:2982`）；推荐轨装的是裸 `DramaCard`（`related_dramas_section.dart:90-93`），没有这一层。卡面第二行在代码里是 `intro`，为空时落默认文案「点开看看这个故事」（`drama_card.dart:72-79`） | 预览文案与「筛选词」都移出卡面：筛选词并进块头的取数注记，卡面第二行改回真实副标语义并标 `data-demo` |
| 16 | 简介段下面一枚「展开」+ 两行截断渐隐，点开才看全文 | `detail_page.dart:255-259` 是 `Text(intro, height:1.8)`，无 `maxLines`、无按钮；只有 TV 固定两行省略（`tv_detail_page.dart:162-167`） | 「展开/收起」整层删除，手机与桌面正文一次画完整段；TV 保留两行省略且不可展开 |
| 17 | 选集分页器被套进一张带边框、圆角、浅底的小卡片；触控族正文左右留白缩到 16 | 分页器外面只有 `Padding(24,8,24,32)`（`detail_page.dart:278-281`），没有任何容器装饰；正文留白三端都是 24（`:173`） | 卡片外框删除（它会让列数算式量到假宽度）；触控族留白回到 24，格子也不加 `min-height`——格子高度由 `cellExtent/1.5` 现算，加高等于改 `gridHeight` |
| 18 | 遥控族这一页也画了「选择剧集」标题，分页器同样套在一张 `border+radius+padding:12` 的卡片里 | TV 正文是 `Column` 直接放 `EpisodePager(rows:4, cellExtent:170)`，没有标题、没有外壳（`tv_detail_page.dart:221-230`）；标题+副标题那句只存在于 `detail_page.dart:262-273` | 标题与卡片外壳都删。外壳那 26px 横向内边距会把可用宽从 1848 压到 1771，10 列算式当场就演示错 |
| 19 | 遥控族的每格选集都有一层深底「芯片」、数字 22px；焦点项还带 `transform:scale(1.03)` | `TvFocusable` 只有 `padding:5 + radius:12 + 3px 边框`，**底色只在 selected 时出现**（`primaryContainer`），且没有任何缩放（`packages/tv/lib/src/focusable.dart:107-129`）；格子文字恒为 `fontSize:16`、页码 14，全仓 `grep textScaler` 零命中（`episode_pager.dart:316-324`、`:352-359`） | 底色从内层芯片移到格子本身、未选中不画底；数字回 16px、缩放删除。16/14 在 1920 宽的电视上偏小，这条作为待议写进 §8，不由原型擅自拔高 |
| 20 | 外壳开关给了两套自绘标题条：macOS 那条里印着剧名，Windows 那套画了 `─▢✕` | `MacWindowFrame` 第一句是 `if (!macHost) return child`（`packages/app/lib/platform/macos_window.dart:63`）——Windows/Linux 根本没有 App 自绘的标题条；macOS 那 32px 里只有三枚灯 + 一条透明拖拽区，**没有标题文字**，剧名是 `window_manager.setTitle` 交给系统的（`window_title_native.dart:8-14`） | Windows 档改成「这条整条消失」而不是换一套控件；标题条里的剧名删掉。灯的尺寸按代码回落到 32 高 / 13 圆点 / 24 占位 |
| 21 | 下载弹层被样式表里一条 `max-height:76%` 夹住，弹层顶部还画了一枚拖拽把手 | 代码只给高度不给上限：`height: size.height * (size.height<400 ? .95 : .78)`，且 `showDragHandle: false`（`download_selection.dart:32-40`） | 删掉 `max-height`，高度只由 JS 按那两档写；把手归位到**只有选集抽屉**有（`player_page.dart:1043` 是 true）。实机读数：390×844 的弹层 643px = 内容区 824 的 78%，740×352 的弹层 315px = 332 的 95% |
| 22 | 选集抽屉、播放页右侧面板、下载对话框三处头部下面都画了一条 1px 分隔线 | 三处头部都是 `Column` 里的裸 `Row`，没有 `Divider`（`player_page.dart:1050-1066`、`episode_workspace.dart:176-207`、`download_selection.dart:180-197`）；深色 `Dialog` 也没有描边 | 三条线全删。面板头部还照代码补上「钉住 ⇒ elevation 12→0」这一条唯一可见的差别（`episode_workspace.dart:170`） |
| 23 | 强调色是 iOS 系统红 `#ff2d55`；AppBar 画成 17px 半粗、52 高、白底带线，正文也是白底 | 主题里写死的是 `primary: 亮 #c74334 / 暗 #f08475`、`surface: 亮白`、`scaffoldBackgroundColor: 亮 #faf9f6`（`main.dart:41-45`），`AppBarTheme` 只把 AppBar 底色设成同一个 `#faf9f6` 且没有 `shape`（`main.dart:51-53`）；标题没给 style ⇒ M3 `titleLarge` 22/400，工具条恒 `kToolbarHeight` 56 | 变量改成代码常量（`--brand:#c74334`），AppBar 回 56 高 / 22 常规字 / 与页面同底色 / 无线；页面底色 `#faf9f6`，白色只留给卡片与弹层（那才是 `surface`） |
| 24 | 下载格子画成灰字小方框，选中时描边变红并写「✓ 已选」 | 它是 `OutlinedButton`：`padding:zero` + 选中换 `primaryContainer` 底色，**描边不变**，文字走按钮默认 `labelLarge` 14 且前景色就是 `primary`（未选中也是红字），选中标记是一枚 `Icons.check` 14（`download_selection.dart:304-335`）；TV 那版是 `_tvCell`，文字 16、描边恒 `outlineVariant`（`:153-168`） | 格子改成红字 14、选中只加底色 + ✓，TV 版 16/副行 12；「已下载」与 ✓ 两行互不排斥 |
| 25 | 三张网格共用一条 `auto-fill` 列数算式 | 代码里是三条不同公式：分页器 `floor((w+spacing)/(cellExtent+spacing))`（`episode_pager.dart:246-250`）、`SliverGridDelegateWithMaxCrossAxisExtent` `ceil(w/(max+spacing))`（flutter `sliver_grid.dart:504-505`）、`TvGrid` `ceil((w+14)/(maxExtent+14))` 且两轴间距恒 14（`packages/tv/lib/src/grid.dart:158、:169-170`） | 原型改成现算列数并写进 `data-cols`：播放页面板 300px 宽 ⇒ 4 列、下载对话框 680px ⇒ 6 列、TV 对话框 678px ⇒ 4 列（190/1.25/间距 14） |

## 1. 这一页在客户端里的位置

- **它是被推入的一页，不是一个地址。** 入口有四处：发现/分类/榜单卡片、历史与收藏、搜索建议、推荐块本身；全部走 `pushAppPage(context, AppScreen.detail, …)`（例如 `detail_page.dart:300-305` 里推荐块点开下一部）。转场是 `slidePageTransitions`：新页从右侧进入、旧页左移 0.3 退出（`app_navigation.dart:46-73`）。
- **返回只有一个语义：pop。** `AppBar` 的 leading 箭头、系统返回手势、Esc（非 macOS，`player_page.dart:1931`）都是同一件事。回到列表页时列表保活：体裁、筛选、排序、滚动位置都不重发请求（口径同发现页原型）。
- **不存在"页内两种态"。** 详情态与播放态是栈里的两条路由。播放页 pop 回来时详情页不重建、不重拉推荐。
- 原型读出窗必须把栈画出来：`发现(保活) → 详情(vid) → 播放(vid, ep)`，谁推谁、谁 pop 谁。
- **窗口装饰不属于这一页，而且只有 macOS 有。** `MacWindowFrame` 在 `!macHost` 时直接返回 child（`packages/app/lib/platform/macos_window.dart:63`），所以 Windows/Linux 的画框顶部没有 App 自绘的那条 32px；macOS 那条里也只有三枚灯 + 透明拖拽区，标题走系统 `setTitle`。它唯一与本页相关的行为是：路由 == player 时整条收起（`app_navigation.dart:235-236`）。原型的「macOS / Windows」外壳开关演的就是这两句，画框以内的 DOM 两端完全相同。

## 2. 版面分派：宽度 × 输入族，不是设备名，也不是响应式栅格

| 族 | 判定 | 详情页版面 | 缓存/选集的容器 |
| --- | --- | --- | --- |
| 手机竖屏 | 触控 + 宽 <720 | 单列，`EpisodePager(rows:3, cellExtent:100)`（`detail_page.dart:287-290`） | `showModalBottomSheet`，`isScrollControlled + useSafeArea`，高 78%（<400 高则 95%）（`download_selection.dart:32-44`） |
| 手机横屏 | 触控 + 高 <400 | 仍单列，不缩成窄栏；播放器吃满当前方向，不强转（`immersive-playback.md` 手机全屏条款） | 同上，用 95% 那一档 |
| 平板 / 桌面窗口 | 宽 ≥720（触控或鼠标） | **与手机同一套单列组件**，只有 `rows:4, cellExtent:120` 的差别；内容区最宽 960 居中 | `showDialog`：`Dialog` 内 720×min(680, 0.82h)（`download_selection.dart:20-30`） |
| Android TV | 遥控族 | 无 AppBar 的滚动正文：返回+标题行 → 简介 2 行 → 动作行 → 选集 4×170 → 推荐轨（`tv_detail_page.dart:133-261`） | 1920×1080 命中 `≥720×≥400` → 同一个居中对话框，格子里换 `TvGrid`（`download_selection.dart:269-287`），见 §6 |

三条硬规则：

1. **≥720 不产生第二种布局。** 桌面客户端不做两栏 + 标签侧栏；它只是把同一列变宽、行数变多、弹层从底部抽屉换成居中对话框。这是代码现状，也是本文的裁定——宽屏不等于该有侧栏。
2. **输入族决定提示与控件族**，不决定版面：快捷键说明只出现在鼠标族；触控族放大点击目标；TV 族完全不出现 hover/拖拽/快捷键文案（口径同 [发现页设计](discover-filters-and-ranking.md) §6）。
3. 内容列与设备边框之外才是原型 chrome（控制条、读出窗、按键条、注记）；任何「App 里没有的控件」不得画进应用画框内。

## 3. 详情页逐块结构

自上而下，块顺序三端一致（`detail_page.dart:143-309`）：

1. **离线横幅**（仅离线兜底时）：一行文案「网络加载失败，正在显示已保存的剧集信息」+ 尾部「重试刷新」，是正文里的第一条 sliver，不是 snackbar、不是遮罩弹窗（`detail_page.dart:145-170`）。
2. **头部**：封面 130×180 + 标题 + 「共 N 集」+（有记录时）「上次看到第 X 集」+ 主操作 `Wrap`。主操作只有两枚：`开始观看 / 重新观看 / 继续观看`（同一枚按钮三种文案，`detail_page.dart:224-230`）与 `下载`（仅 `DownloadRuntime`，`:232-246`）。**收藏在 `AppBar.actions`，不重复出现在正文里。**
   - 这一套尺寸三端共用，手机不另画一套：`SizedBox(130,180)` 与标题 26 都不随宽度变（`detail_page.dart:180-197`）。于是 390pt 宽的手机上，正文 342 − 封面 130 − 间距 24 = **153pt 给右侧那一列**，标题必然折两行、两枚按钮在 `Wrap` 里竖排。原型按这条真实结果画（本轮先前的手机版式是另配的 100px 封面 + 通栏按钮行，那属于第二种布局，已并回同一套）。
   - 由此产生一条**待议**（不改代码，先记在这里）：窄屏要不要把封面降到 110×152、或标题在 <720 时降到 22，让主操作能并排。这条属于版面提案，实施前要单独过一轮真机读数。
3. **标签行（本轮新增建议，客户端现状根本不渲染 `tagNames`）**：头部下方一枚一枚 chip，但**只有能在发现页面板词表里查到同名词的那枚才是入口**——点它 = pop 回发现页并带上该筛选（`select_items{ cate_…: ["…"] }`）；查不到同名词的只当文本，不给假入口。上游详情/列表行已给 `tagNames`，这一条不需要后端补数据，需要的是客户端把已有的字段画出来。原型里每枚 chip 直接标出「面板有 / 面板无」，就是为了让人当场验这条判据。
4. **简介**：手机/平板/桌面 = **整段渲染，没有「展开/收起」**——`detail_page.dart:255-259` 就是一个 `Text(display.intro, TextStyle(height: 1.8))`，不带 `maxLines`，也没有截断渐隐；上一版原型给它加了枚「展开」和一行遮罩，那是网页读长文的形态，不是这一页的。TV 才是固定 2 行省略（`tv_detail_page.dart:162-167`），且那两行不可展开。
5. **「选择剧集」+「选择一集，故事即刻开始。」**（`detail_page.dart:262-273`，文案被测试钉住，一字不改）+ §4 的分页器。
6. **推荐块**（§7）——页面到此结束。没有「猜你喜欢」，没有评论区，没有演职人员。
7. 加载中 = `CircularProgressIndicator`；失败 = 居中 `cloud_off` + 错误文案 + 「重试」按钮（`detail_page.dart:89-113`）。这两态都是**整页占位**，不给半截详情。

明确不画的（上游给不出，画了就是假控件）：评分角标、热度数值、评论/弹幕、演职人员、点赞数 → 见 §8 后端配合清单。

## 4. 选集：`EpisodePager`，不是分组锚点

- 高度恒等于 `rows` 行，与总集数无关（`episode_pager.dart:240-260` 里 `gridHeight = rows*cellHeight + (rows-1)*spacing`）；列数由 `cellExtent` 除可用宽度现算，不写死。
- 页内**不滚动**；翻页是页脚一行：左箭头 +「第 a/b 页」+ 右箭头，到界禁用置灰（`:340-372`）。触控与鼠标可直接横拖（`PageView.builder`，`:273`）。
- 单元格可见内容**只有一个集数数字**：分页器里没有"已看"状态位、没有时长、没有热度点——全文检索 `episode_pager.dart` 不存在 watched/seen/badge/duration 任何一条（只有 `currentIndex()` 决定哪一格是在播）。在播格的信号是底色 `primaryContainer` + `primary` 描边 1px + `primary` 加粗字、圆角 10（`episode_pager.dart:310-325,494-505`）；键盘族聚焦时描边才加到 3px（`:498-503`）。「已看」这件事在客户端属于观看记录，不塞进选集格子。焦点朗读用 label「第 N 集」（`:312`），触控/TV 同一套。
- TV：单元格与两枚箭头都是 `TvFocusable`；焦点落在本页末项再按右 → 翻页并把焦点交给新页首项，首项按左对称（`:175-221`）。这块是详情页里唯一需要跨页焦点交接的控件族。

## 5. 播放：另一条路由，返回逐层消费

- 进入：详情页任意一集 → `pushAppPage(AppScreen.player)`（`detail_page.dart:125-138`）。pop 回来后 `flush()` 观看记录并重绘，于是「上次看到第 X 集」与主按钮文案（继续观看）当场更新——这是详情页唯一需要重绘的时机。
- 播放页内返回键序（`player_page.dart:1600-1608` + `PopScope(canPop: !fullscreen && !episodeVisible)`，`:1936-1939`）：**关选集 → 退全屏 → 唤出控件 → 最后才 pop**。`_exitPage` 在真正 pop 前把选集面板、全屏、悬浮窗依次收干净（`:1611-1629`）。注意这条次序是播放页外层 PopScope 给的：`EpisodeWorkspace` 本身在这里是 `manageBack: false`（`:1896`），它自己的那条 PopScope 不参与。
- 选集在播放页只有**一段内容、两种外壳**（同一个 `_episodePanel`，`:1317-1505`）：宽 ≥720 走右侧覆盖面板（`min(340, 80%)`，`episode_workspace.dart:220`；自动隐藏 mac 3 秒、其余 5 秒，`player_page.dart:1893`；📌 钉住后不再收，且 elevation 由 12 变 0，`episode_workspace.dart:102-105、:170`——钉住前后**只有这一处可见差别**，原型据此切换面板投影）；窄屏走 `showModalBottomSheet`，高 `MediaQuery.height * 0.65` 且 `showDragHandle: true`（`player_page.dart:1039-1045`）。两种外壳的头部都是裸 `Row`：「选集」+ ⚙ 播放设置 + 📌（只有面板有）+ ✕，**下面没有分隔线**（`episode_workspace.dart:176-207`、`player_page.dart:1050-1066`）。面板内容按代码顺序：收藏按钮（`:1333-1340`）→「已提前缓存 x / y 集」→「第 N 集」→ 清晰度下拉 + 连播开关 → 上一集/下一集（两端 `onPressed: null`）→ `maxCrossAxisExtent 80 / 比例 1.25` 的可滚动网格。
- 那段网格的列数是 `ceil(w/(80+10))`（flutter `sliver_grid.dart:504-505`），不是详情页分页器那条 floor：340 宽的面板扣掉 `SliverPadding(20,4,20,24)`（`player_page.dart:1467`）= 300 ⇒ **4 列**，格子 67.5×54；390 宽的手机抽屉 ⇒ 350 可用，同样 4 列。原型实测两侧都是 4（`data-cols` 现算）。
- 面板里选一格 = `_selectEpisode`（`:1078-1084`）：换集 + 面板 `selected()`（未钉住就收起）+ 控件 hide + 抽屉 pop。**这不是路由跳转**，栈深不变、无转场；键盘越界则是一条 2.6 秒的边界提示「已经是最后一集」（`_step`/`_fleetingNotice`，`:1086-1099`），与面板里那两枚按钮的"禁用"是两种到头表现。
- 播放页不放详情页的那些块：没有简介段、没有推荐轨。但**收藏在播放页里也有**——它就挂在这段选集面板右上角（`:1333-1340`），因为换集时顺手收藏比 pop 回去再点少一步。
- 连播是本地队列行为，不叫推荐（口径同 `2026-10-22` 文档 §0）。

## 6. 缓存：底部弹层 / 居中对话框，且没有额度文案

- 容器按尺寸分派：`width ≥ 720 && height ≥ 400` → `showDialog`，否则 `showModalBottomSheet`（`download_selection.dart:16-47`）。这是同一段表单的两种呈现，不是两个功能。两条高度都是**代码写死的比例，不是 CSS 上限**：对话框 `min(680, h*.82)`、弹层 `h * (h<400 ? .95 : .78)`，且弹层 `showDragHandle: false`（`:32-40`）——所以手机竖屏那档**没有拖拽把手**，只有播放页的选集抽屉有。实机读数：1280×800 的对话框 720×656、390×844 的弹层 643（= 内容区 824 的 78%）、740×352 的弹层 315（= 332 的 95%）。
- **更正（本轮现读 `:177-370` 后）**：上一轮本文写过「表单只留 选集范围 + 并发 1–3」，实现里不是那两档，而是一张完整表单——按代码顺序：标题行「下载剧集 + ✕」（`:186`）→ 画质下拉「自动画质 / 720p / 1080p」（`:206-209`）+ 「全选/清空」（`:238-244`）+「N 集」计数（`:247`）→ 前后台与并发说明一行（`:252-261`，TV 换「仅在前台下载」）→ 逐集格子（`maxCrossAxisExtent 110`、比例 1.25，`:294`；已下好的那格显示「已下载」并禁用；TV 用 `TvGrid`，`:269`）→「下载 N 集」主按钮，未选任何一集时 `onPressed` 为 null（`:365-367`）。原型按这张表单画，不再自造 chip。
- 格子的真实形态是 `OutlinedButton`（`padding: EdgeInsets.zero`）：**未选中的文字也是 primary 色**（按钮默认前景），选中只把底色换成 `primaryContainer`、描边不变，并在文字下面加一枚 `Icons.check` 14；「已下载 / 已加入」那行副标 10px，且与 ✓ 互不排斥（`download_selection.dart:304-335`）。TV 那一版是 `_tvCell`：文字 16、副标 12、描边恒 `outlineVariant`（`:153-168`）。列数同 §5 那条 `ceil(w/(max+spacing))`：对话框 680 可用 ⇒ `ceil(680/118)=6` 列；TV 走 `TvGrid`，公式换成 `ceil((w+14)/(190+14))`、两轴间距恒 14（`packages/tv/lib/src/grid.dart:158、:169-170`）⇒ 678 可用 = **4 列**。
- 换画质会把在新画质下不可用的已选格剔除（`selected.removeWhere((i) => !available(i))`，`:212-217`）——所以「已选 N 集」会在切画质时变小，这不是 bug 而是同一档位约束。
- **仍然不出现任何"额度/上限"文案**（门禁按 `2026-10-22` 文档 §4 移除）：说明行只报前后台策略与并发数，不报"还能下几集"。
- 接受后的反馈是 `SnackBar`「已加入下载，可在"我的 → 下载管理"查看」+ 动作「查看」→ `pushAppPage(AppScreen.downloads)`（`:46-62`）——跳转入口放在 snackbar 的按钮上，不放在详情页正文里再加一枚按钮。
- TV：`下载剧集` 是动作行里的 `TvFocusable`（`tv_detail_page.dart:207-222`），1920×1080 命中 `≥720×≥400` 那一支 → **同一个居中对话框外壳**，只把格子里换成 `TvGrid`（`download_selection.dart:269-287`）；焦点被关在对话框内，Back 只关这一层并把焦点还给触发它的那枚动作按钮。
- TV 的一条待办（本轮新发现）：`SnackBar` 的「查看」动作在遥控族上按不动——焦点不会自己跳到 snackbar。本文裁定 TV 改为「提示 + 焦点保持在原动作」或直接把入口做成动作行的第三枚按钮，二选一，实现前先定（进 §9）。

## 7. 推荐：一块、两个名字、零个角标

- 块名只有两种：`同题材 · <题材名>`（这次 browse 按该题材筛）或 `平台热门`（`sort=hot_score`）。二者都只声明**请求按什么取数**，不声明相关性、不声明热度高低（`related_dramas.dart:6-12`）。
- 卡片两套尺寸、两种内容，都不带分数：
  - 手机/平板/桌面 = `DramaCard`：`SizedBox` 150×268，封面吃满剩余高度 + 标题 15px w600 最多两行 + 副标 12px 一行省略（`intro` 为空时是默认文案「点开看看这个故事」），封面**左下** 8/8 处一枚「N 集」（黑 70% 底、圆角 6、白字 11），且只在 `episodeCount>0` 时出现（`related_dramas_section.dart:61-62,76-84` + `drama_card.dart:22-83`、`:38-56`）。`DramaCard` 没有底色、没有投影、没有 hover 预览——「悬停 1.5s 出预览」是列表页给卡面套的一层（`library_page.dart:2982`），推荐轨用的是裸组件，不在那一层的作用范围里。
  - TV = `_TvDramaTile`：168×284，只有封面（圆角 10）+ 标题 18px 两行，**没有副标、没有角标**（`related_dramas_section.dart:107-129`）。
  - 块标题才是 22px（TV 26）；卡片标题 15/18 不跟着放大。
- **详情页头部那张封面是裸 `DramaCover`，一张角标都没有**：`detail_page.dart:180-184` 把它直接塞进 `SizedBox(130,180)`，没有 `DramaCard` 那层 `Stack`；`drama_cover.dart` 全文只有「加载中右下角转圈」和「失败底部居中重试钮」两种覆盖态。所以「红果首发 / 新剧」这类角标属于**列表行**（发现页原型在画），这一页不画；集数由标题下方那行「共 N 集」承担（`detail_page.dart:199-204`），不在封面上重复一遍。
- 无标签命中、上游返回空、请求失败 → 整块不出现，不占位、不报错（`related_dramas.dart` 文档注释与 `related_dramas_section.dart:15`）。
- 结果只进内存、有短时新鲜期，**不写 LibraryCache**：陈旧的"同题材"会在今天撒谎。
- 推荐里点进去 = 再推一条详情页路由（`detail_page.dart:300-305`），不是替换当前页、不是改地址。
- TV 卡片 label 是 `推荐：<剧名>`（`related_dramas_section.dart:108-109`），焦点朗读跟着走。

## 8. TV 版面与焦点序

版面自上而下（`tv_detail_page.dart:128-251`，`SingleChildScrollView(padding: EdgeInsets.all(36))` + `Column`，块间距是逐个 `SizedBox`：16 / 20 / 24 / 12 / 32，不是一条统一 gap）：

1. `‹ 返回` + 标题 32 粗体单行 —— 返回是**可聚焦项**，因为 `AppBar` 的 leading 箭头在触控上是这条路由唯一的出口、从来不吃焦点环，在 10 尺屏上遥控器点不到它就只是个装饰（`:96-99` 原注释）。
2. 简介 21px，`maxLines: 2`（`:162-167`）。
3. 动作行一个 `Row`：`▶ 开始观看` 24px（autofocus，`playNode`）· `下载剧集` 20px（仅 `DownloadRuntime`）· `♡ 收藏 / ♥ 已收藏` 20px（`FavoriteButton(tvLayout: true)`，`packages/app/lib/personal/favorite_button.dart:84-97`）。三枚都是 `TvFocusable(Padding(all:14) + Text)`，**没有图标底、没有胶囊背景**。
4. `EpisodePager(rows: 4, cellExtent: 170)`（`:223-230`）——**TV 正文里没有「选择剧集」这块标题**，标题+副标题那句是 `detail_page.dart:262-273` 的（且被测试钉住），遥控族这一页直接就是分页器。分页器下方才是条件文案「已定位到上次观看的第 N 集」18px（`:231-237`）。
5. `RelatedDramasSection(tvLayout: true)`，点进去是 `MaterialPageRoute(RouteSettings(name: '/tv/detail'))`（`:240-251`）——TV 不做横向滑入转场。
6. 加载中 / 失败：整屏**只有一个焦点目标**（`正在加载 · 返回` / `重试`），别让遥控器在一片不可点的文字里找出口（`:104-126`）。

焦点规则沿用已实施的 TV 契约，不在这页另立一套：焦点 = 3px `colorScheme.primary` 描边、选中 = `primaryContainer` 底色（两种信号分开，`packages/tv/lib/src/focusable.dart:113-128`）；遥控族走的是深色档，所以那圈描边的 `primary` 是**代码常量 `#f08475`**（`main.dart:41` 的 `dark ? Color(0xfff08475)`），而 `#2f211f` 那枚选中底色仍是 `primaryContainer` 的原型近似值，代码里没有这个字面量；跨行交给 `TvNavigation` 的几何五向兜底，本页不排 `FocusTraversalGroup`；溢出永远不折叠成「更多 ▾」（遥控器没有下拉）；Back 一次只消一层。

两条本轮实机量出来、写进规格而不是留给实现猜的：

- **这一页在 1920×1080 上必然滚动。** 按上面的尺寸排完，正文总高 1262px > 1080（原型量得，见 §10），选集分页器的下半部分和整条推荐轨都在折叠线以下；能用的原因是 `TvFocusable` 在拿到焦点后调 `Scrollable.ensureVisible(context, alignment: 0.5)`（`focusable.dart:82-101`，注释里写明是模拟器上量出来的：只 reveal 最近的可滚动区、或用 `keepVisibleAtEnd` 都会让焦点走出屏幕）。所以本页对滚动的要求是「**由焦点驱动**」，不是「给一个能拖的滚动条」——遥控器也没有可拖的东西。
- **选集格子的字号不分族。** 数字是 `fontSize: 16`、页码是 `14`（`episode_pager.dart:316-324`、`:352-359`），而全仓 `grep textScaler` 零命中、`main.dart:79-82` 的 `builder` 只塞了 `TvEnvironment`/`TvNavigation` 没有包 `MediaQuery` —— 也就是说 1920×1080 上这两处就是 16/14 物理像素，和同一屏上 32 的标题、26 的推荐轨标题差着一档。**待议**：要么给 TV 这一族传 `textScaler`（那是全站的事，不是这页能定的），要么 `EpisodePager` 收一个字号参数；本轮原型按现状画 16px，不替它拔高。


## 9. 后端配合清单（缺什么，不画什么）

| 需要 | 现状 | 有了之后这一页能多什么 |
| --- | --- | --- |
| 详情响应带可信评分/口碑字段 | 只有列表行的分数字符串，来源与口径未证实 | 头部才允许出现分数，且仍不做排序依据 |
| 详情响应带演职人员 | 无 | 头部下方一行「主演」，可点进同一搜索路由 |
| 评论/弹幕计数或列表端点 | 无 | 正文里才允许出现「评论」入口 |
| 真正的 related/按 series_id 召回 | 无；当前靠把一个面板词塞进 `select_items` 换一页 | 块名才能从「同题材 · X」升级为「相关」 |
| 详情直接给 `selector_item_id` | 只给题材名，需再拉面板做名字→id 映射 | 省一次请求，消除改名导致的映射失败 |
| 列表行给可信 `published_at` | 缺 | 才允许出现「最新」角标与真实时间排序 |

上表任何一项都不构成"现在可以画个假控件"的理由：原型里这些位置统一显示为虚线注记「未证实」，而不是灰色占位卡片。

## 10. 原型与验收

- 原型：`prototypes/video-detail.html`，控制条按 §2 的判定切六格 = 电脑客户端(1280×800) / 手机竖(390×844) / 手机横(740×352) / 平板竖(820×1180) / 平板横(1080×820) / TV 遥控族(1920×1080)，另有「停在详情页 / 已 push 播放页」这条页面栈开关与 macOS/Windows 外壳开关；形态切换控件属于原型 chrome，在画框外。TV 版面用键盘方向键走 `TvNavigation` 的几何焦点，Enter=确认、Backspace=Back 一层。
- 数据读数分三层，且界面要能自证：剧名/集数 = 实机 feed 常量；标签/面板词/推荐轨条目 = `docs/evidence/detail-related-2026-10-30/live-sample-2.json`；简介/进度/海报 = 演示值（勾选「标注演示数据」后全部描成虚线）。
- 验收口径：浏览器带窗口逐视图截图，证明 ①页内无顶栏 logo/搜索/头像 ②无 hero、无右侧标签栏 ③点一集是路由推入（读出窗画栈，播放器吃满）④选集块高度恒定且有「第 a/b 页」 ⑤缓存是底部弹层/居中对话框、内容是那张完整表单且无额度文案 ⑥推荐块名只有两种、无角标，「来源」是虚下划线注记而不是按钮 ⑦TV 视图焦点序与 §8 一致、对话框内焦点闭环 ⑧播放页选集在 ≥720 是右侧覆盖面板、窄屏是同一段内容的底部抽屉，且 Esc/返回按「弹层 → 面板 → pop 播放页」逐层消费。无头渲染不算验证。
- 验收取证方式（本轮实际用的那套，写下来免得下一轮重新发明）：带窗口 Chrome + CDP（`Emulation.setDeviceMetricsOverride` 换视口、`Page.captureScreenshot` 取帧、`Runtime.exceptionThrown` 收脚本报错），逐格截图后**读数与画面成对**——每格都记 `data-cols`、容器 `clientWidth/Height`、`getComputedStyle` 的颜色与描边。本机 `screencapture -x` 这一轮只出壁纸，所以取证走 CDP 而不是系统截图；无头渲染不算验证。
- 本轮取证到的帧与读数（`errors=[]` 全部通过）：电脑 1280×800 详情（AppBar 56 高 / 标题 22 / 与页面同底 / 无分隔线，分页器 7 列、可用宽 912）；手机竖 390×844 详情（3 列、可用宽 342）；手机竖下载弹层 643=78%、抽屉 536=65%、手机横弹层 315=95%；电脑播放页右侧面板 340 宽 / 网格 4 列 / 钉住时投影消失；电脑下载对话框 720×656 / 6 列 / 格子文字 `rgb(199,67,52)`；TV 1920×1080 正文总高 1262（必然滚动）、分页器 10 列、方向键跨页交接与焦点跟随滚动都验过；TV 下载对话框 720×680 / 4 列 / 间距 14 / 无描边。
- 本轮只动设计文档与原型，不动 Flutter 代码；实现与本规格的出入以代码为准，发现偏差写回本文而不是改测试迁就原型。
