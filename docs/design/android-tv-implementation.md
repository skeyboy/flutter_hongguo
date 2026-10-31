# TV 独立交互模块与 App 集成

> 后续验收更新：现已删除旧手机 AVD，创建真正 Android TV API34 模拟器，并通过 9 次 Android 系统 D-pad/确认/Back 的完整原生播放链路。见 [Android TV 模拟器验收](../android-tv-emulator-verification.md)。下文手机镜像与磁盘受限记录保留为早期验收历史。

日期：2026-10-20。基于 [适配分析](android-tv-adaptation.md)，已实现独立 `hongguo_tv` 模块、App 适配和 mobile/tv Android 分包。原有 PC、手机业务继续使用既有页面与媒体服务。本次不涉及 imports 中的历史工程。

> 2026-10-31 复核：§1 的模块职责表仍与 `packages/tv/lib/src/` 对得上；§2 改成按「能不能走到」
> 与「有没有 TV 描边/字号/路由」两栏分列，并给出当前文件的行号，早期那份含糊的要点列表作废；
> §3 的 flavor/运行策略未变；§4 的 `9 项/81 项/6 项` 是 2026-10-20 的快照数字，当前数字以本轮
> 表格与 `flutter test` 为准。逐界面的遥控器状态另有清单，见 §2。

## 1. 模块边界

`packages/tv` 是独立 Flutter package，唯一运行依赖为 Flutter，不依赖 App、API、核心算法或 media_kit。已加入根 workspace，App 通过 path 依赖接入。

| 模块 | 实现职责 |
|---|---|
| `src/environment.dart` | flavor/预览开关、遥控器键识别、方向遍历、文本输入保护、可返回路由处理、原生设备信息查询 |
| `src/focusable.dart` | 单一焦点目标、聚焦描边、确认键按下激活、重复/抬起事件不重复提交、焦点滚动可见 |
| `src/grid.dart` | 方向按网格坐标移动，稳定 ID 持有节点，屏幕外目标先滚动构建再申请焦点 |
| `src/player_state.dart` | video / controls / seek / panel 四层纯交互状态，预览范围约束、确认提交、返回取消 |
| `src/player_surface.dart` | TV 播放控件与选集/清晰度面板，通过 callbacks 调用宿主播放器 |

App 的 `features/tv/tv_library_page.dart` / `tv_detail_page.dart` 负责电视目录与详情，所有数据仍来自 `AppRuntime.catalog`。`PlayerPage` 使用原有准备任务、取消、解密、媒体文件和播放实例，只有 TV 分支改用模块里的播放操作层，不复制播放引擎。

`main.dart` 按 `appFlavor == 'tv'` 选择 TV 首页；`--dart-define=HONGGUO_TV=true` 仅用于桌面开发预览。设备模式不按屏幕宽度猜测。TV startup 会查询 Android UI mode/leanback/lowRam；无通道时报告 unknown，而非误判为电视。Android 通道添加到原 AudioServiceActivity，不替换既有 Activity 基类或 PiP 通道。

## 2. 已接入的界面与操作

遥控器可达有两个门槛，2026-10-31 起本表按第一个门槛如实分列：**能走到**＝Material
控件自身可聚焦，`TvNavigation` 的几何遍历能把它当方向目标、确认键能投递
`ActivateIntent`；**电视上能用**＝另有 3px 聚焦描边、10 尺字号和 TV 路由。只做到前者
的界面不算接入，标 否 而不是含糊过去。

| 界面 | 焦点目标与操作 | 描边 | 证据 |
|---|---|---|---|
| 侧栏 | 短剧、漫剧、AI 短剧、本地缓存、我的（含设置）；较低逻辑高度时可滚动 | 是 | `features/tv/tv_library_page.dart`（该页另一会话在改，行号不在此钉）；首个焦点 `nav-0`，见 `test/tv_catalog_test.dart:67` |
| TV 目录/榜单 | 大卡片布局、标题、排序、题材、自动分页；分页追加不抢焦点 | 是 | `packages/tv/lib/src/grid.dart`，卡片节点 `tv-grid-*` |
| 搜索 | 确认后打开输入对话框走系统输入法，文字编辑阶段不拦截左右键 | 是 | `tv_library_page.dart` 搜索对话框；退出链路见 `test/tv_search_remote_exit_test.dart` |
| 详情 | 顶部自带 `返回目录`（不再有 AppBar 箭头），动作行 `开始观看`/`下载剧集`/收藏，分集用 `EpisodePager`，空分集改为 `刷新分集`，并按看剧记录定位 | 是 | `features/tv/tv_detail_page.dart:137`、`:177`、`:191`、`:223`、`:234`；定位与空列表用例见 `test/tv_library_surfaces_test.dart` |
| 分集翻页 | 4 行定宽翻页，单元格 `episode-cell-N`，选中集带描边高亮 | 是 | `playback/episode_pager.dart`，用例 `test/episode_pager_tv_page_test.dart` |
| 播放 | 四层控件状态＋选集/清晰度面板，见下表；等比复用既有 Video，busy/error 给返回/重试，媒体键播放/暂停与前后轨道接到原播放实例 | 是 | `packages/tv/lib/src/player_surface.dart` |
| 本地缓存 | 剧目卡片按 `标题，N 集 · 体积` 成一个目标；进入后每个文件拆成 `播放` 与 `删除缓存` 两个目标，刷新/补全/重试都在导航里 | 是 | `features/local_cache_page.dart:75`、`:156`、`:171`、`:428`、`:463`、`:485`、`:493`、`:546` |
| 我的（收藏/历史） | 三个货架切换、每行「打开」＋「取消收藏/移除历史」两个目标、`清空历史`、设置入口；TV 上打开的是 `TvDetailPage` | 是 | `features/my_page.dart:127`、`:335`、`:384`、`:441`、`:450`、`:577` |
| 危险操作确认 | `删除缓存`、`清空历史` 走同一个 TV 弹窗，默认焦点落在 `取消`，确认键右移一步才是删除 | 是 | `widgets/tv_confirm.dart:12`、`:28`；按键链路见 `test/tv_library_surfaces_test.dart` |
| 设置 | 约 30 个控件全部换成一个目标一行：开关把状态写进标签（`已开启`/`已关闭`）、下拉框改成确认键推进的取值器（不再有菜单路由）、输入框与说明文字升到 19–22px、`ExpansionTile` 改为自带 `展开/收起` 目标、重建身份与删除走同一个 TV 弹窗、侧栏跳转目标加宽到 300px | 是 | `features/settings_page.dart:458`（`tv`）、`:464`（`_tvRow`）、`:501`（`_tvButton`）、`:525`（`_tvCycle`）、`:548`（`_advancedFields` 两端共用）、`:595`、`:676`、`:746`、`:811`（整页字号）、`:1016`、`:1275`；用例 `test/tv_settings_surfaces_test.dart`（8 例）、`test/tv_settings_test.dart`（TV 预览专项） |
| 下载管理 | 每行拆成「主操作」＋「次操作」两个目标，标签带上剧名与集数；筛选片、AppBar 的离线剧集/刷新、错误态 `重试` 全部 `TvFocusable`；删除走 TV 弹窗；TV 上去掉 AppBar 返回箭头，改用遥控器 Back | 是 | `features/downloads_page.dart:110`、`:136`（`_tvTask`）、`:224`（`_touchTask` 原样保留）、`:305`、`:325`、`:391`、`:419`；用例 `test/downloads_tv_test.dart`（6 例） |
| 下载选集面板 | 与搜索对话框同处另一会话的改造中 | 进行中 | `downloads/download_selection.dart` |

| 当前层 | 左右方向 | 上下方向 | 确认 | 返回 |
|---|---|---|---|---|
| 视频画面 | 进入 ±5 秒进度预览 | 打开控制栏并聚焦播放按钮 | 播放/暂停，同时打开控制栏 | 退出播放路由 |
| 控制栏 | 移动焦点 | 移动焦点 | 播放、上下集、进度、选集、清晰度、返回画面或退出 | 关闭控制栏，恢复视频焦点 |
| 进度预览 | 累积预览，约束到片长 | 打开控制栏 | 提交一次 seek | 取消预览，不 seek |
| 选集/清晰度 | 面板内移动 | 面板内移动/滚动 | 选择并关闭面板 | 关闭一层，恢复播放按钮焦点 |

控制栏的隐藏口径只有一条（2026-10-31 校订，早期「只在明确返回画面时隐藏、聚焦期间不
计时」这句是错的，已在 [适配分析](android-tv-adaptation.md) §5.1 同步废止）：30 秒无操作
计时隐藏，任何一次遥控器按键重新计时——包括被子按钮消费掉的键，所以焦点在控制栏上不会
被计时夺走；有模态路由压在上面时推迟隐藏；按返回/明确回到画面时立刻隐藏。选 30 秒而不是
Android TV 惯用的 3–5 秒，是因为本页控件层多、面板要停留；若日后收紧，改这段和
`player_surface.dart` 的同一个常量，不要留两份说法。当前并未照搬分析稿里所有长按加速
建议：repeat 支持连续固定步进，未做加速曲线。

确认兼容 D-pad select、Enter、numpadEnter、gamepad A；返回兼容系统 Back、Escape/goBack、gamepad B。Home、电源和音量由系统处理。父级方向导航只处理子控件未消费的事件，播放器面板内方向不透传为 seek。

## 3. Android flavor

| 属性 | mobile | tv |
|---|---|---|
| applicationId | `com.example.hongguo_app` | `com.example.hongguo_app.tv` |
| Namespace / Kotlin 包 | 原值 | 复用原值 |
| Launcher | LAUNCHER | LEANBACK_LAUNCHER + 兼容 LAUNCHER |
| 横屏 | 原策略 | TV Manifest 横屏 |
| PiP | 原策略 | TV Manifest 关闭；不显示入口 |
| 资源 | 原图标/本地化 | 共享图标 + 320×180 TV banner + TV 名称 |

TV 包保留普通 LAUNCHER 兼容 Flutter 的启动/集成工具；leanback required=true，分发身份仍是 TV-only，不是把手机包加 TV 入口。原 main Manifest 保留共享权限/服务，launcher 移至各 flavor。所有 Android 命令显式传 flavor；没有设置全局 default-flavor，避免影响 iOS/macOS scheme。两包可共存，设备身份、配置、缓存各自隔离。

TV 运行策略：后台暂停并保存既有播放状态，禁用后台下载与 PiP；最多预热下一集 1 集，原生媒体准备并发限制 1。媒体会话可在前台提供系统按键；TV 专用会话不允许系统播放命令在后台重启声音。原手机开关和 PC 窗口策略保留。

## 4. 构建与验证

从仓库根目录执行：

```bash
./tool/verify_tv.sh
# 在已连接设备上追加原生离线媒体集成；参数为 flutter devices 的设备 ID
./tool/verify_tv.sh emulator-5554
```

从 `packages/app` 执行：

```bash
../../.fvm/flutter_sdk/bin/flutter run --flavor tv
../../.fvm/flutter_sdk/bin/flutter build apk --debug --flavor tv
../../.fvm/flutter_sdk/bin/flutter build apk --release --flavor tv --split-per-abi
../../.fvm/flutter_sdk/bin/flutter build appbundle --release --flavor tv
../../.fvm/flutter_sdk/bin/flutter build apk --release --flavor mobile --split-per-abi
```

CI 的 `platforms` 新增 `android-tv`，可与 `android` 独立选择。TV 附件名包含 `android-tv`；手机附件保留原名称。打包脚本按 flavor 读取 Flutter 的新 APK 文件名，发布门禁不会把手机 APK 当作 TV 成品。`verify_mobile.py` 和 `verify_native.sh` 同步传 mobile flavor；主校验脚本加入 TV 模块测试。

验证按三层进行：模块状态/Widget → App 导航集成与 PC/手机回归 → Android 原生媒体集成。原生用项目固定 CENC 夹具和伪网络响应，不请求上游。

### 本次验收记录

正常入口的 arm64 TV 调试包保存于 `artifacts/android-tv/Hongguo-0.2.7-tv-arm64-debug.apk`；这是 debug 签名试装包，非商店发布包。

最终统计和原始日志见 [TV 验收摘要](../tv-verification.txt) 以及 `build/verification/tv-*`。

- TV 模块 9 项：方向确认与去重、文本编辑保护、进度边界/提交/取消、面板不触发 seek、屏幕外行焦点、设备能力 unknown/lowRam。
- App：81 项回归通过（含目录/详情全遥控进入与焦点恢复）；另用 TV 预览构建单独执行设置保存专项，1 项通过。TV 专项在普通回归中跳过，未重复计数。
- CI 打包契约 6 项：含 TV 独立附件检查。
- Android 集成：TV flavor 在 Android 15 arm64 模拟器中完成目录→详情→真实 CENC 流水线→media_kit 本地播放→遥控 seek→返回详情。片长约 1523ms，有实际音轨。此设备是手机系统镜像，不计作 Android TV 系统或电视真机通过。

曾尝试安装 Android 14 TV arm64 镜像并新建 TV AVD，但镜像/默认数据盘耗尽主机空间；较小自定义数据盘未能稳定启动。已清理本次新增的 TV 镜像/测试数据，不清理其他项目的文件。这个限制不通过放宽测试掩盖。

### 2026-10-31 轮：把 §2 的账补平

§2 过去把「外层有 `TvNavigation`，所以 Material 控件能被方向键走到」写成「已接入 TV」，
而 `本地缓存`、`我的` 实际仍是手机字号、无描边、点开的是手机详情页。本轮只动共享业务页与
TV 详情页，不碰另一会话在改的 `tv_library_page.dart` / `download_selection.dart`：

- `features/tv/tv_detail_page.dart`：删掉 AppBar——它的箭头是触摸路由的唯一出口，遥控器
  永远拿不到；页内自带 `返回目录`。按看剧记录定位到本设备看到的那一集，播放器退出后重新
  定位并翻页。分集为空时把 `开始观看` 换成 `刷新分集`，不再留一个按下去没反应的按钮。
- `features/my_page.dart`：货架、行、`清空历史`、设置入口全部 `TvFocusable`；一行拆成
  「打开」＋「取消收藏/移除历史」两个目标；TV 上打开 `TvDetailPage` 而不是手机详情页。
- `features/local_cache_page.dart`：剧目卡片与分集文件同理，播放/删除各成一个目标。
- `widgets/tv_confirm.dart`（新）：TV 上的确认弹窗把焦点停在 `取消`，破坏性操作在右一步。
- `test/tv_catalog_test.dart`：离场改用遥控器 Back（`escape`，Android keycode 4），不再用
  `pageBack()` 点触摸箭头——那条断言恰好是它过去能过的原因。
- `test/tv_library_surfaces_test.dart`（新，13 例）：三页在 1920×1080 下的按键链路用例，含
  删除弹窗 取消→右→确认 的走位，同时钉住手机分支不受影响。

验证（本地 NTFS 克隆；SMB 盘不能承载 Windows 构建）：

| 检查 | 结果 |
|---|---|
| `dart format --set-exit-if-changed` 本轮 6 个文件 | 0 变更 |
| `flutter analyze` 全仓 | No issues found |
| `packages/app` `flutter test` | +344 ~1 全过（跳过的 1 例是 TV 预览专项） |
| `packages/tv` / `core` / `cast` | +36 / +117 / +52 全过 |
| `flutter build apk --debug --flavor tv --target-platform android-arm64` | √ `app-tv-debug.apk` |
| `flutter build apk --debug --flavor mobile --target-platform android-arm64` | √ `app-mobile-debug.apk` |

同机 `packages/api`（9 例）与 `packages/update`（1 例）失败，与本轮无关：api 卡在临时目录被
占用（errno 32，文件锁），update 是 `release_downloader_test.dart:89` 用 `/` 手拼路径断言、
Windows 返回 `\`。上一轮 Windows 记录（`docs/evidence/windows-verify-2026-10-30/findings.md`）
写的是「全过」，这一轮不复现——api 的用例数已从 52 涨到 109，那一条要么当时没跑到，要么环境
变了，需要在 Mac 或 x64 CI 上复核，不能沿用旧表。

P1 里仍未接入的是设置页（1005 行、0 处 `TvFocusable`）和下载管理页（341 行同理）：它们的
开关/下拉框能被方向键走到并确认，但没有描边、没有 10 尺字号。本轮没有半做进去——一页三十
多个控件改一半只会让 §2 的表更难自证。下一步就从 §2 标 否 的那两行开始。

### 2026-10-31 次轮：§2 标 否 的那两行

上一轮留下的两页补完了。做法仍是「一个目标一行、状态写进标签」，不引入新的模块：

- `features/settings_page.dart`：`bool get tv` 走 `TvEnvironment.of(context)`，因此同一份
  页面在手机/PC 上保持 Material，在 TV 上不需要第二个文件。开关（含播放能力项、自动检查
  更新）与取值器共用 `_tvRow`；下拉框改成确认键推进的取值器，理由是菜单路由里要把焦点交
  出去再要回来，两个键才能做完一个键的事。`高级接口与签名参数` 从 `ExpansionTile` 改为
  `展开/收起` 目标，字段表 `_advancedFields()` 两端共用，避免最危险的一组参数在两个布局
  里各写一遍。整页说明文字用一层 `DefaultTextStyle.merge` 提到 19px，约 20 个 `Text` 调用
  点不逐个改。侧栏跳转列在 TV 上从 170px 加宽到 300px——`高级接口与签名参数` 在 20px 下
  放不下，第一轮就是被这条溢出测出来的。
- `features/downloads_page.dart`：行内两个目标（主操作带状态图标与进度，次操作是删除/取消
  的图标），沿用本地缓存页的拆法——整行一个目标会把行尾的破坏性操作吞掉。筛选片、AppBar
  两个动作、错误态 `重试` 都成目标；`_remove` 改用 `showTvConfirm`。TV 上
  `automaticallyImplyLeading: false`：遥控器用 Back 离开，看得见却走不到的箭头不算通路。
- `test/tv_settings_surfaces_test.dart`（新，8 例）与 `test/downloads_tv_test.dart`（新，6
  例）：1920×1080 下用 `select` 走真链路，钉住「TV 上没有 SwitchListTile/DropdownButton/
  ExpansionTile/ListTile/TextButton/OutlinedButton/FilledButton/IconButton」、取值器一次
  推进一格且只在保存后落盘、侧栏跳转会真的滚动、弹窗停在 `取消` 右移一步才执行，并同时断言
  手机分支的 Material 控件不受影响。
- `test/tv_settings_test.dart`（TV 预览专项重写）：原来点的是 `DropdownButton` 的菜单项，
  那是它过去唯一能过的原因；改为按标签里的状态循环到目标值，顺带证明取值器确实在推进。

写用例时撞到一个仍未修的问题：TV 预览模式（`--dart-define=HONGGUO_TV=true`）下跳到
`会话凭据` 后再按 `下`，主焦点直接变成 null——默认模式下同样三步不会，遥控器要靠再按一次
`上` 才抓回描边。本轮把这条走位改成向 `上`（每一步都必须落在声明过的目标集合里），页尾丢
焦点的成因留到下一轮，不用放宽断言把它藏起来。

验证（本地 NTFS 克隆；SMB 盘不能承载 Windows 构建）：

| 检查 | 结果 |
|---|---|
| `dart format --set-exit-if-changed` 本轮 5 个文件 | 0 变更 |
| `flutter analyze` 全仓 | No issues found |
| `packages/app` `flutter test` | +358 ~1 全过（跳过的 1 例是下面这条 TV 预览专项） |
| `flutter test --dart-define=HONGGUO_TV=true test/tv_settings_test.dart` | +1 通过 |
| 两份新用例在默认与 TV 预览两种模式下各跑一遍 | 8 与 6 全过 |
| `packages/tv` / `core` / `cast` | +36 / +117 / +52 全过 |
| `flutter build apk --debug --flavor tv --target-platform android-arm64` | √ `app-tv-debug.apk` |
| `flutter build apk --debug --flavor mobile --target-platform android-arm64` | √ `app-mobile-debug.apk` |

`--dart-define=HONGGUO_TV=true` 跑全套仍不是绿的（本轮实测 +251 −108）：它把整个 App（含目录、
详情、播放器）切到 TV 分支，手机用例的触摸控件断言自然全灭，失败集中在 `catalog_tabs_test` (25)、
`interaction_cache_test` (9)、`discover_desktop_layers_test` (9)、`adaptive_ui_test` (8)、
`theme_rail_test` (7)、`search_suggestions_test` (7)、`mobile_discover_layers_test` (7)、
`horizontal_filters_test` (7) 等手机/PC 专项。这是预览开关本身的粒度问题，不是这两页引入的；
TV 分支的正确回归是上面那条 flavor 专项加两组 `TvEnvironment` 用例。

到这里 §2 只剩 `下载选集面板` 一行标 进行中（`download_selection.dart` 由另一会话在改）。
`描边＝是` 说的是遥控器能走到并看得见面，仍不等于电视真机上验收：`docs/android-tv-emulator-
verification.md` 的原生链路覆盖的是目录→详情→播放，设置页与下载管理页的按键走位还没有在
Android TV 系统镜像上复核过。

## 5. 验收边界

本次交付是可构建、已离线测试及原生 Android 运行验证的 TV 适配版本，不宣称所有 TV 设备已兼容。尚需在目标电视/机顶盒验证：实体遥控器与蓝牙 repeat、系统 IME、TV Launcher 实际显示、Home/息屏/音频焦点、HEVC/硬解、HDMI 音频切换、低内存性能与长时间播放。Android 32 位及 TV 商店 16KB 原生库要求也需要目标构建独立验收；本次本机构建以 arm64 为主。

题材/排序等数据能力复用上游，不增加新协议。TV 首页复用现有我的/收藏/历史模块，不额外实现跨端账号、语音控制、Cast、跨设备记录同步或电视推荐频道。Google Play 上架、本地化横幅全量资源与设备目录过滤不作为本次完成项。

## 6. Android 模拟器界面记录

下图为 TV flavor 在 Android 15 手机镜像的横屏界面，截图前已通过 Android 系统输入方向键；不是实体电视截图。

![TV flavor Android 模拟器界面](../assets/android-tv-android-emulator.png)
