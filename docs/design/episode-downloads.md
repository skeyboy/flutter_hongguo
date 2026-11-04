# 剧集下载：功能与 UI 设计

状态：已按“功能/UI 设计 → 开发计划 → 实现 → 验证”完成。设计先于功能代码落地。

## 用户路径

详情 → 下载 → 选择画质与分集 → 加入下载 → 下载管理 → 已下载 → 本地剧集 → 离线观看 / 连播 / 续播。

手动下载是用户要求保留的离线内容，与播放时的自动预缓存区分。两者共用下载、解密、校验和本地列表，不重复建一套播放器。未校验完成的文件不显示为“已下载”。

| Before | After | Why |
| --- | --- | --- |
| 主按钮仅播放 | 播放主按钮旁放描边“下载”次按钮 | 保持播放优先，下载明确可发现 |
| 自动缓存会被容量规则淘汰 | 手动下载用任务清单保护 | 用户主动下载不会悄悄消失 |
| 我的只看已完成缓存 | 增加“下载管理”，显示进行中、失败和已完成 | 可以离开详情后继续管理 |
| 后台能力混在设置中 | 选集窗口说明当前策略，设置仍由用户决定 | 不自动打开后台开关或请求无关授权 |

## 平台布局

- 手机竖屏：详情播放按钮旁下载；底部选集 sheet（安全区域、约 75% 高度），固定标题/关闭及底部“下载 N 集”，中部滚动分集。支持全选/清空、自动/720p/1080p；已下载项禁选，进行中项显示状态。界面用标准触摸目标尺寸。
- PC：居中有宽高上限的对话框，分集横向网格、画质与批量选择、底部确认；支持键盘、滚动和明确关闭。任务页宽度限制并展示状态、进度和操作，不弹出文件选择器，不把未处理视频保存到用户公共目录。
- 手机横屏/小窗口：仍采用可滚动的安全区域面板，固定确认按钮，不让网格撑出屏幕。
- TV：复用标准可聚焦按钮/分集选择；仅前台下载，不显示手机后台承诺。并行预算为 1 时，播放优先暂停手动队列，退出播放器后再继续。
- Web/不支持本地媒体的 runtime：不展示可操作的下载入口，避免点击后才告知不可用。

## 下载管理与观看

“我的”顶部快捷区域下增加“下载管理”入口（进行中数量/总数）；原“本地缓存”入口继续存在。下载管理提供“下载中 / 已完成 / 全部”筛选、逐集进度、暂停/继续/重试/取消、完成后离线观看入口。已完成下载仍按视频所属剧目归类出现在现有本地剧集页面；复用本地续播和连续播放，不依赖网络详情。

选择器默认不选集，避免误耗流量。提交后提示已加入，不要求停留在详情。已完成项从下载管理删除时确认，删除正在播放的文件会被拒绝；取消未完成任务不删除其他消费者/播放器正在使用的视频。

下载管理按剧目归组后提供两个整组动作：标题行的“删除本剧全部下载”同时移除该剧的缓存文件与未完成/失败/已取消的任务记录，正在使用的文件跳过并在结果里如实计数；顶栏仅在队列里还有暂停、失败或已取消的任务时出现“继续全部”，一次性重新排队，不触碰已完成和进行中的任务。

## 按缓存剧目更新下载

本地剧集页（一剧一组的分集视图）提供三个剧目级动作：

- “拉取最新剧集”用该组已知的剧目标识在线请求详情，合并元数据后只把本地没有、队列里也没有保留记录的分集按原画质排队下载；已全部缓存则回答“已是最新”，不重复排队，也不改动本地文件。
- “选择下载新集”问的是同一个在线读数，但**不替观众决定**：把在线详情交给详情页那枚选集窗口，由观众点名要补哪几集。窗口里本地已有的分集显示“已下载”并禁选——包括播放时自动预缓存、下载队列里没有记录的那些，否则会重复取同一个文件；画质默认接着这部剧已有的画质（可在窗口里改），全选只选可下载项。在线比对下来没有新集时不弹一个空窗口，只用一句话报这次读数。
- “删除本剧缓存”删除整组文件并清掉该剧的未完成下载记录；正在使用的文件保留。

在线两个动作共用同一次读取（`scanOnlineEpisodes`：问上游 + 把集数合并进离线库 + 算出缺口），差别只在缺口是自己排队还是交给选集窗口。三者都以删除后的实际文件读回结果为准，而不是任务状态。待识别视频没有剧目标识，不显示这两个在线动作；只有能提供剧目归组的本地缓存页与下载管理有这些入口，榜单页没有剧目归组概念，因此不出现“下载更多”类控件。

### 触屏族从剧目卡片直接进入

本地缓存剧集的网格卡片有两个手势：点开进分集页，**长按弹出这一部的动作面板**（`拉取最新剧集` / `选择下载新集` / `删除本剧缓存`，标题行写文件数与体积），于是不用先走进分集页再回到页头就能整部刷新、挑几集下载或整部删掉。面板里的在线两行复用分集页页头那两个已存在的入口，删除照旧先确认（`删除本剧全部缓存？`），长按不是第三条删除路径；页头那句说明也按 `desktopHost` 分别写「长按/右键一部剧可拉取最新剧集、挑几集下载或整体删除缓存」。

一次只让一个手势办一件事：面板打开期间卡片不再响应第二次长按，因为拉取与删除改写的正是弹出它的那一层，第二个面板会读到第一个面板已经改过的归组。

遥控族不动这一层——遥控器没有长按，卡片按住就等于普通按下（进分集页），它需要的两个动作在分集页页头本来就是可聚焦、有文字的两枚目标。给 TV 卡片加长按只会造出一个按不到的手势，所以 `DramaCard.onLongPress` 为空时卡片保持原样，目录网格那些没有整体动作的卡因此还是一枚单一目标。

## 状态与持久化

任务状态：排队 → 下载/处理 → 已完成；可暂停、取消、失败后重试。暂停基于取消当前管道，继续时重新解析片源并可能从头传输，不宣称断点字节续传。

任务保存剧目与集号、vid、画质、状态、进度和错误摘要；不保存片源 URL、签名或明文密钥。沿用独立原子 JSON 后端。恢复时先读任务、再恢复系统传输并与实际完成文件核对；移动端开启后台下载后，上个进程遗留的未完成任务在下次启动自动重新排队（默认仅 Wi-Fi，用户主动暂停的不算遗留任务），其余宿主仍显示暂停、需用户继续，避免未经确认就使用流量。已完成但文件缺失显示失败，不伪装为可观看。

任务由应用 runtime 持有，不归详情页生命周期所有。UI 离开不取消。单个手动工作者复用 MediaCache 租约、解密和校验；同一 vid+画质去重，已有缓存可复用。媒体准备的其他消费者拥有独立租约。

手动任务的排队/进行中/完成键传给 MediaCache 保留判断：自动 LRU 清理、自动预缓存停止不影响手动任务；设置中清理普通缓存保留手动下载，用户从下载管理或本地列表主动删除才移除保留记录。没有永久持有已完成文件租约，因此仍允许显式删除。

沿用用户缓存设置作为手动下载容量与集数上限；超过限额拒绝新增或将任务置为失败，提示先清理/调整设置，不偷偷删除下载。下载时根据可用总大小/累计字节检查上限；磁盘写入失败显示错误，不伪装完成。下载大小不是精确剩余磁盘容量预估。

## 后台与播放优先

- Android/iOS：关闭后台缓存时，真正退后台暂停手动队列，回前台恢复自动暂停的任务；用户主动暂停的不自动恢复。开启时复用现有系统下载器和通知授权，上个进程遗留的排队/下载中任务在下次启动自动重新排队并显示“正在继续上次的后台下载”，用户手动暂停的记录保持暂停。系统可能延迟调度；传输完成后如 Dart 被挂起，需要回前台处理校验。关闭/强制终止 App 不保证继续完成。
- PC：应用进程存在时可以在其他页面/最小化后继续，退出进程后下次启动显示暂停记录。
- TV：后台暂停，不要求通知和后台传输。并行配置为 1 时有播放器页面在使用即暂停手动队列；配置为 2/3 的 PC/mobile 可边播放边下载一个手动任务。

## 开发计划（在本设计之后执行）

1. 实现独立下载队列与任务模型：原子持久化、去重、状态、限额、取消、恢复和监听；以可注入媒体回调进行队列测试。
2. 给 MediaCache 加可选的手动保留判断，不影响默认调用者；验证 LRU/清理/预缓存取消与手动任务隔离。
3. NativeRuntime 接入队列、生命周期、已有传输恢复及本地删除同步；播放器接入单并行预算时的让路/恢复。
4. 详情下载选集 UI、下载管理页及 auto_route 命名路由；“我的”增加入口，复用已有离线观看列表。
5. 验证状态/重启/失败、离开页面持续任务、不同窗口布局、原有播放和缓存回归；运行原生 POC。记录实际已测平台，不将桌面虚拟尺寸当作手机真机验证。

## 实现与验证结果

- `packages/app/lib/downloads/download_manager.dart`：应用级队列、持久化、容量与状态、生命周期和播放优先策略。
- `packages/app/lib/downloads/download_selection.dart`：手机底部选集与 PC 对话框。
- `packages/app/lib/features/downloads_page.dart`：按剧目归组的任务与离线观看入口，接入 auto_route；详情及“我的”已接入。
- `MediaCache.retainFile` 保护手动下载，停止预缓存可以保留独立手动任务。清理普通缓存不会删除手动下载；播放中删除被拒绝。
- 系统下载日志按工作文件身份清理，并串行化同一日志的读写，旧尝试取消完成时不会清理新尝试的密钥引用。任务清单不保存视频 URL 或明文密钥。
- 图片/元数据沿用既有离线库；不新增 SQLite 或第二套播放器。

验证证据在 `docs/evidence/episode-downloads/`：

| 范围 | 结果 |
| --- | --- |
| 应用测试 | 128 项通过；1 项 TV 构建专用用例按条件跳过 |
| API / 媒体测试 | 46 项通过，含手动保留、清理隔离和工作文件身份回调 |
| 新增任务/界面/日志测试 | 共 11 项覆盖队列去重、恢复、配额、写失败保护、三个窗口尺寸与删除确认 |
| 静态检查 | 无问题 |
| macOS 原生 POC | 通过：详情下载 → 离开详情 → 我的 → 真实离线纹理播放；退出播放后普通清理仍保留视频 |
| Android | arm64 mobile Debug 构建通过；真机已断开且无线重连超时，本轮未真机执行 |
| iOS / Windows / Linux / TV | 本轮未做对应原生下载验收；手机策略和 TV 单并行让路通过状态测试，不能视作真实后台系统验收 |

macOS 验证在临时独立源码副本进行，避免并行 TV 工作清理编译缓存；关键功能源码 SHA256 已核对与主项目一致。原生 POC 使用确定性 CENC 视频夹具验证真实下载/解密/发布/播放链路，不是线上视频服务或后台通知实测。

调试产物（普通 App 入口，不是测试入口，未发布 Release）：

- macOS：`artifacts/macos/downloads-poc/Hongguo.app`
- Android：`artifacts/android/hongguo-0.2.7+9-downloads-arm64-debug.apk`

任务在 UI 主动暂停后可能重新传输；未开启后台下载的手机、桌面与 TV，进程重启后遗留的任务仍显示暂停、需用户点击继续。已验证文件即使最终任务清单写入失败仍受保护，并显示记录保存警告。清单下一次成功写入会清除警告。原生后台传输、系统通知授权沿用现有设置，本轮没有改变默认开关。

导出的 macOS 调试 App 在增量构建后重新生成了顶层 ad-hoc 资源签名，保留沙盒/JIT 等调试 entitlements，深层签名校验通过；不代表 Developer ID 公证或正式发行包。

### 2026-11-01 轮：后台续传、归类删除与按剧目拉取

- 后台下载的缺口不在传输通道，而在重启后的态度：任务清单没有记住“因退后台而暂停”与“观众主动暂停”的差别，任何遗留任务下次启动一律显示“上次未完成，点击继续”。现在 `EpisodeDownload.toJson` 持久化 `autoResume`，由 `continuesAfterRestart`（`!television && mobile && backgroundDownloads`）决定是否自动重新排队：只有真正拥有跨进程传输通道的手机会自动续排（提示语「正在继续上次的后台下载」），桌面与 TV 保持原来的“等观众点击”。下载管理另有「继续全部」，一次重新排队所有暂停、失败与已取消的任务。
- 排队的启动点从 `_load()` 移到 `reconcile()` 末尾。按 `runtime_native.dart` 的 load → restoreDownloads → reconcile 顺序，若在 `_load()` 里就 pump，手机会在系统通道已下完的文件被认领之前重新发起一次下载；`_pump()` 仍受 `_loaded` 与 `_blocked` 约束，所以这次移动对桌面与 TV 没有影响。
- `packages/app/lib/catalog/local_group_delete.dart` 的 `removeLocalDrama`：删除整部剧的缓存文件，跳过使用中的，删完再读一次真实文件列表按身份核对，如实报告删了几个文件、多少字节、清掉几条未完成记录、几个暂时删不掉；入口两处——本地缓存剧集页头部与下载管理剧目标题行。
- `packages/app/lib/downloads/latest_episode_pull.dart` 的 `pullLatestEpisodes`：用剧集组已有的剧目 id 与众数画质问一次上游，只排本地缺的集，已在队列里（排队或暂停）的不重复排，并把新的集数信息合并进离线库。待识别视频没有剧目 id，直接拒绝发起请求。榜单页没有剧目归组，按需求不提供该入口，由 `榜单 grows no 下载更多` 用例钉住。

验证读数（2026-11-01，本地 NTFS 克隆 `hg-verify-dl`；源文件与 \\Mac 副本逐字节一致）：

| 范围 | 结果 |
| --- | --- |
| `dart format`（3.1.13） | 151 个文件，0 变更 |
| `flutter analyze packages/app` | 无问题 |
| `download_manager_test` | 12 项通过，含新增 4 项重启用例（手机自动续排／未开启仍等点击／观众主动暂停不被覆盖／TV 保持前台） |
| `local_group_delete_test` | 3 项通过：文件与在途记录同删、待识别视频只删文件、读不到缓存的运行时抛错且不动任何文件 |
| `latest_episode_pull_test` | 5 项通过：缺集入队并合并集数、已是最新、不重复排队、待识别视频不发请求、上游不可达时文件与队列原样 |
| `local_cache_management_test` | 6 项通过：触屏与遥控各走一遍拉取与归类删除、继续全部只在有待继续时出现、下载管理删本剧、榜单无新入口 |
| `downloads_tv_test` | 6 项通过（手机形态的图标按钮数因标题行新增删除入口由 6 变为 7） |
| `packages/app` 全量 | 388 项通过、1 项按条件跳过、0 项失败 |

未验证的部分要说清：本轮没有手机与 TV 真机验收。自动续排、继续全部、归类删除与在线拉取都在假传输通道（单并行槽、按微任务推进）与内存文件清单上验证语义；真实的 Android 系统下载交接、后台通知授权、仅 Wi-Fi 约束、以及播放中删除在设备上的表现均未实测（本机 ARM64 无法构建原生包，media_kit 只有 x64 版本）。窄屏与 TV 的排版只由 widget 测试的尺寸断言得出，不等于设备实测。

另记一条测试约束，后来人会撞上：widget 测试跑在 fake-async 区，队列推进依赖的 `Future.delayed(Duration.zero)` 计时器不会因 `await` 触发，只能由 `pump` 流逝时间——下载队列在 widget 测试里不能用 `queueTick()`，改用“pump + pump(400ms) + pump”；而下载管理页在有任务传输时渲染不定进度条，`pumpAndSettle` 永不收敛，只能按已知帧数推进。

### 2026-11-01 第二轮：从剧目卡片长按落到这两个动作

用户诉求（原话）：「本地缓存剧集可以长按整体删除 本地缓存剧集可以更新增加新的缓存集数」。上一轮把 `removeLocalDrama` 与 `pullLatestEpisodes` 接在分集页页头，路径是「点卡片 → 进分集页 → 页头两个动作」；这轮把同一对动作提到卡片本身，长按即达，规则与措辞见上一节。

改动面：`packages/app/lib/widgets/drama_card.dart` 多一个可空的 `onLongPress`（`InkWell` 的第二枚手势，为空时卡片行为不变）；`packages/app/lib/features/local_cache_page.dart` 的网格态多一枚 `showModalBottomSheet` 动作面板、一个 `busy` 闸门（一次只跑一个手势），页头那句说明在触控族补上「长按一部剧可拉取最新剧集或整体删除缓存」，TV 那句不变；动作面板里两行复用 `packages/app/lib/catalog/local_group_delete.dart` 与 `packages/app/lib/downloads/latest_episode_pull.dart`，没有新的删除语义。待识别归组照旧只给删除。

验证读数（2026-11-01，本地 NTFS 克隆 `hg-verify-dl`；与 \\Mac 副本逐字节一致；同一批读数也覆盖 `docs/design/auto-update.md` §9.6 那一条）：

| 范围 | 结果 |
| --- | --- |
| `flutter analyze`（`packages/app`） | `No issues found!` |
| `test/local_cache_management_test.dart` | **+9** 全过（上一轮 6 条 + 本轮 3 条：长按卡片拉最新并入队两集、长按卡片删除先确认再整部删、遥控族按住等于普通按下——不开面板、不动文件，页头那枚可聚焦的删除目标仍在原处） |
| `packages/app` 全量 | **+396 ~1** 全过 |

未验证的部分：没有手机真机读数。长按面板的命中与两枚动作都跑在 widget 测试的合成指针上，「一次只让一个手势办一件事」由 `busy` 标志的单元行为断言，不是手指连点的实测；窄屏上面板两行的排版只由测试的尺寸断言得出。TV 侧本轮是**证明没有变化**：遥控卡片长按被识别成普通按下，所以那条用例钉的是「没有面板、没有确认框、文件一个没少」，而不是新的遥控交互。

### 2026-11-01 第三轮：把这两个动作也交给指针族

用户诉求（原话）：「分析一下将最近两个版本及当前修改与pc和mobile同步，缺失功能补全」，随后的三个选择分别是「右键 + Dialog 形态（推荐）」「页头「刷新」按钮（推荐）」「只补 PC（与手机对齐）」——TV 保持原样。

盘点结论先记一条，免得后来人重复查：手机族没有结构性缺口，上一轮那两个动作本来就是照着触屏写的；真正的缺口全在 PC 一侧——弹层用的是手机上那种底部抽屉、右键没有任何反应、页头那句提示在桌面上写着「长按」、榜单只有下拉可点。Web 运行时（`packages/app/lib/platform/runtime_web.dart` 的 `_RemoteRuntime`）不是 `DownloadRuntime`，所以下载与缓存这几面墙在网页版按构造就不存在，这轮不动它。

- **一张卡两枚指针手势**：`packages/app/lib/widgets/drama_card.dart` 多一个可空的 `onSecondaryTap`，`InkWell` 自带的第二枚指针识别器，为空时卡片行为与之前完全一致。它开的必须是 `onLongPress` 开的同一个面板——一张卡只有一个「整体动作」目标，只是抵达方式按输入族分岔。理由写在字段注释里：鼠标不会把手指压在卡片上等材料。
- **面板跟仓库已有的形态规则走**：`local_cache_page.dart` 的 `_groupActions` 现在读 `MediaQuery.sizeOf`，`宽 ≥ 720 且 高 ≥ 400` 时 `showDialog(Dialog(ConstrainedBox(maxWidth: 420)))`，否则仍是底部抽屉。这不是新定的口径，是 `packages/app/lib/downloads/download_selection.dart` 与 `packages/app/lib/cast/cast_device_sheet.dart` 已经在用的那一条；两处先例加一处新用，才谈得上是规则。两行的内容与 key（`local-sheet-pull` / `local-sheet-remove`）在两种形态下同一个 `_GroupActions` 私有 widget 产出，删除仍然只有一份、仍然先问。
- **提示语按宿主分岔**：同一句尾部的动词由 `desktopHost`（`packages/app/lib/platform/background/host_policy.dart`）决定——桌面写「右键一部剧」，触屏写「长按一部剧」；TV 那句独立文本一字未动，TV 的说明早就在分集页用焦点目标表达。
- **一条测试约束，不写就会静默失效**：`tester.binding.setSurfaceSize(size)` 只收紧 RenderView 的布局约束，**不改 `view.physicalSize`**，所以 `MediaQuery.sizeOf` 依旧报默认的 800×600。用它的用例看着像在给手机尺寸，其实在给一个 ≥720×400 的窗口，于是形态分岔永远走 Dialog 那支，底部抽屉那支没人验过。改成像 `episode_pager_tv_page_test.dart` 那样设 `tester.view.physicalSize` / `devicePixelRatio = 1.0` 并在 teardown 里 `tester.view.reset`，`_openGrid` 再把「这个尺寸确实落进了 MediaQuery」断言出来，两支才算各自被跑过。

验证读数（2026-11-01，本地 NTFS 克隆 `hg-verify-dl`；与 \\Mac 副本逐字节一致）：

| 范围 | 结果 |
| --- | --- |
| `dart format --set-exit-if-changed`（`packages/app`） | 178 个文件，0 变更 |
| `flutter analyze packages/app` | `No issues found!` |
| `test/ranking_pull_test.dart` | **3** 项通过（新增「页头那枚 刷新」，见 `docs/design/discover-filters-and-ranking.md` §11） |
| `test/local_cache_management_test.dart` | **10** 项通过（新增「右键剧目卡片 opens the same panel, in a dialog the window can host」；原长按那条补上「400×780 里出现底部抽屉、没有 Dialog」的断言） |
| `packages/app` 全量 | **398** 项通过、1 项按条件跳过、0 项失败（上一轮 396，本轮 +2 条用例） |

未验证的部分要说清：本机 ARM64 建不了原生包（media_kit 只有 x64），所以**没有 macOS 真窗口帧、没有 Windows 帧、没有 iPhone 帧**。右键命中、Dialog 与抽屉的各自形态、以及页头那枚刷新，全部跑在 widget 测试的合成指针与 `tester.view` 的人工尺寸上；`kSecondaryButton` 在真实触控板/两键鼠标上的行为未实测。这轮也不涉及任何新的下载或删除语义，`removeLocalDrama` 与 `pullLatestEpisodes` 一个字节没改。

同一次改动在 Windows 侧的全仓门禁读数（`dart analyze --fatal-infos`、api/update 两项旧失败的归属、两份可移植 oracle、以及本机跑不了的 python3 / ffprobe / `-d windows` 三步）记在 `docs/evidence/windows-verify-2026-11-01/findings.md`。

### 2026-11-03 轮：把「联网看到有新集」交回观众挑

用户诉求（原话）：「本地缓冲剧集中联网刷新到有新的剧集后可增加一个入口来获取提供下载的入口来增加新的下载」「综合分析后执行功能优化可以复用之前的下载选择入口方式和选择下载剧集的功能」。上一轮那枚「拉取最新剧集」是一键把整段缺口按众数画质全排上，观众没有说「这几集我不要」的余地；这一轮把同一个在线读数接进详情页早就有的那枚选集窗口，入口两处，选择权回到观众手上。

改动面（复用优先，没有新建第二套选集 UI）：

- `packages/app/lib/downloads/latest_episode_pull.dart`：把在线读取从「读＋排队」里拆出 `scanOnlineEpisodes`，返回在线详情、本地与队列都还没有的位置、这部剧已有的画质与本地集数；`pullLatestEpisodes` 改为消费它再自己排队，**排队语义一个字节没改**（`latest_episode_pull_test` 原 5 项全过），只是那次「问上游 + 把集数合并进离线库」现在两个动作共用一次。
- `packages/app/lib/downloads/download_selection.dart`：`showDownloadSelection`/`DownloadSelection` 多两个可空入参——`cachedVids`（已在磁盘上的 vid）与 `initialQuality`（这部剧已有的画质）。缺省值就是详情页原来的行为。`available()` 之外多一个 `_blockedAs()`，把「这一集为什么点不动」讲明白：已有文件说「已下载」，队列里还留着记录的说「已加入」，只因提交在途而暂时禁用的格子仍然不吭声——这条是上一轮那句「不涉及新的下载语义」的反面，所以必须写明它动了单元格的两处渲染（触屏按钮与 `HONGGUO_TV` 的 TvGrid 格子）。
- `packages/app/lib/downloads/download_selection.dart` 的 `showCachedDramaDownloadSelection`：缓存剧目专用的那层薄封装——先扫一次，没有新集就用一句话回答（不弹一个空窗口），有新集才把在线详情连同「这些已经在磁盘上」交给同一个选集窗口。窗口自己那条「已加入下载，可在“我的 → 下载管理”查看」的提示照旧，因此挑集下载的确认反馈与详情页完全一致。
- `packages/app/lib/features/local_cache_page.dart`：三个输入族各就各位。分集页页头的动作行多一枚「选择下载新集」（触屏/指针 `local-download`，遥控 `local-download-tv` 同 label 的 `TvFocusable`）；卡片面板 `_GroupActions` 多一行 `local-sheet-download`，长按与右键开的还是同一个私有 widget；两处都走 `_pickDownload`，与既有 `_pull`/`_remove` 一样受同一枚 `busy` 闸门约束（一次只让一个手势改写这一层）。原先那个 `canPull` 标志改名 `canUpdate`，因为它现在管的是两个在线动作。待识别归组照旧一个在线入口都不给。

一处刻意的取舍：`cachedVids` 按 vid 禁选，不按 vid+画质。从缓存剧目进来时，这一集已经在磁盘上了，换画质重取不是这个入口要鼓励的事——画质想改，详情页那枚入口没有这层禁选。

验证读数（2026-11-03，本地 NTFS 克隆 `C:\Users\lee\scratch\hg-newep`：`git archive HEAD` 新鲜展开 + 本轮 6 个文件覆盖，覆盖后逐字节核对与 \\Mac 一致；**该树另带着另一会话未提交的选集窗口 TvGrid 分支**，见下方风险）：

| 范围 | 结果 |
| --- | --- |
| `dart format`（本轮 6 个文件） | 首轮 3 个变更（都是新写的单元格/断言换行），复跑 0 变更 |
| `flutter analyze packages/app` | `No issues found!` |
| `dart analyze --fatal-infos`（全仓） | 4 项 info，全部在本轮文件之外：`docs/evidence/windows-playback-version-2026-11-03/probe_asks.dart`（2 项 `depend_on_referenced_packages`）、`packages/api/test/progressive_lane_test.dart:86`、`packages/core/lib/src/media/progressive_decrypt.dart:31`（2 项 `library_private_types_in_public_api`） |
| `test/latest_episode_pull_test.dart` | **6** 项通过（新增「扫描只报告缺口：读在线、合并集数，但不替观众排队」——`runtime.calls` 不变、任务数不变、`episodeCount` 仍合并到 3） |
| `test/local_cache_management_test.dart` | **13** 项通过（新增 4：触屏分集页挑集——已缓存那集 `onPressed` 为空且标「已下载」，全选只入 2 集；三集全缓存时不弹窗口只报「已是最新：在线 3 集」；遥控那枚目标是可聚焦的且打开同一个窗口；长按卡片面板第三行 `local-sheet-download` 只点名 1 集，另一集没有偷偷排队） |
| `test/local_download_selection_tv_test.dart` | **1** 项通过（`--dart-define=HONGGUO_TV=true`，`tool/verify_tv.sh` 多一行；默认 flavor 下按条件跳过） |
| `packages/app` 全量 | **437** 项通过、**2** 项按条件跳过、0 项失败（跳过项＝原有的 TV 构建用例＋本轮这条） |

未验证的部分要说清：

- 没有设备读数。本机 ARM64 建不了原生包（media_kit 只有 x64），所以没有 iPhone/Android/Android TV 真机帧；长按第三行、右键 Dialog、遥控 `TvFocusable` 的命中全部跑在 widget 测试的合成指针与 `tester.view` 的人工尺寸上。
- 没有真实上游读数。`DownloadFakeRuntime` 的 `catalog.detail` 是一次内存读，「联网刷新发现新集」在这轮的证据里是靠先给 1 集、再把在线列表改成 3 集来模拟的，不是线上接口实测。
- 一个必须记下的高度：`tvBuild` 是编译期 flavor 标志（`appFlavor == 'tv' || bool.fromEnvironment('HONGGUO_TV')`），**不随 `TvEnvironment` 变**。所以只挂 `TvEnvironment(enabled: true)` 的 TV 形态测试拿到的仍是触屏按钮——第一次把格子断言写在共享文件里就是这么失败的。TV 侧真正要验的 TvGrid 分支只在 `--dart-define=HONGGUO_TV=true` 下存在，也因此本轮把它单独立了一个文件并加进 `tool/verify_tv.sh`。
- 那条 TvGrid 分支（`_tvCell` 与 `tvBuild ?` 那段）此刻还是工作区里另一会话未提交的改动，本轮只是给它补了「已在磁盘上的格子说『已下载』且点不动」这条覆盖。它进入门禁的方式是 `tool/verify_tv.sh`，不是默认的 `flutter test`；两边都跑过、都绿，但这两处代码谁先提交，另一处就得跟着一起绿。


### 2026-11-03 第二轮：下载按剧目归类，「追加下载」只报告缺口

用户诉求（原话）：「1 将下载按照剧集进行归类来执行管理，下载列表中点开剧集才能查看对应每一集的下载进度情况，删除剧集也要与下载进行相互校验关联」「2 剧集中追加更多下载目前存在bug,只有手动选择了对应的集才执行下载不需要刷新数据就加入下载中」。两次选择分别是「改成只检查，下载走选集」与「每剧一张卡片，点开进分集进度页」。

诉求 2 是上一轮那个入口的口径纠正：`pullLatestEpisodes` 把「读在线」和「按众数画质把整段缺口排上队」焊在一起，观众点的是「刷新」，得到的是「下载中多了一串没挑过的集」。这轮把焊接拆开——

- `packages/app/lib/downloads/latest_episode_pull.dart` → **改名** `latest_episode_check.dart`（`git mv`，两个测试文件同步改名），并且**删掉 `pullLatestEpisodes`**：留下的 `scanOnlineEpisodes` 只做一次在线读＋集数合并，`checkLatestEpisodes` 把它包成一句 `EpisodeCheck` 读数（在线 X 集 / 本地 Y 集 / Z 集可下载 / 另有 W 集已在下载中）。这条路径**不再调用 `enqueue`**，一行都不排。
- 入口的措辞跟着改：`local_cache_page.dart` 两处（卡片面板行与分集页动作）都写成「检查最新剧集」，面板那一行多一句副标题「只比对在线集数，不会自动排队下载」；key 从 `local-sheet-pull` 变成 `local-sheet-check`，`local-check` / `local-check-tv` 是动作行的两枚目标。进入下载中唯一的路仍是那枚选集窗口。
- 「已在下载中」这一档是新的：队列里 retained 的记录（排队/进行/暂停）不再被当成可下载的新集报出去，否则一句「有 2 集可下载」会把已经在跑的那集也算成缺口。取消掉的记录照旧算缺口、但不被检查复活。

诉求 1 需要一层两边共用的连接模型，否则卡片、分集页与删除各说各话：

- 新文件 `packages/app/lib/downloads/drama_downloads.dart`。`DramaDownloads` 是一部剧的队列记录 join 它在磁盘上的文件，`episodeCount` 取两侧 vid 的并集、`offlineCount` **只认磁盘**，`progress` 恒为确定值（在跑的那集按自己的 fraction 计入，不留一根不收敛的进度条——这条同时是测试能 `pumpAndSettle` 的前提）；`groupDramaDownloads` 按 `drama.id` 分组，只有文件、没有记录的剧**不进这张表**，那是「离线剧集」的主语。`downloadEpisodeRows` 是分集页的行：按 `vid_quality` join，两枚画质是两行，因为删掉一行不该宣称另一行也没了。
- 新文件 `packages/app/lib/features/download_episodes_page.dart`：点开一张卡片才看到的分集进度页。一行同时说清三件事——记录在说什么（阶段与消息）、磁盘上有没有它的文件、以及只有播放缓存没有记录的那种集（`播放时缓存 · 下载管理里没有这条记录，可直接离线观看`）。主动作按阶段给：在跑→暂停、ready/仅缓存→离线观看、失败→重试下载、其余→继续下载；次动作是在跑→取消下载、否则删除（有记录走 `manager.remove`，只有文件走 `runtime.evict` 并先问「删除本地剧集？」）。
- `packages/app/lib/features/downloads_page.dart` 整页重写为**每剧一张卡片**：标题＋一行汇总（`已完成 X / N 集 · 下载中 Y · 待继续 Z`）＋确定值进度条，触屏点卡片进分集页（`downloads-drama-<id>`），遥控是同一张卡上的两枚目标（`<title> 分集进度` / `<title> 删除本剧`）。全部/下载中/已完成三个筛选从「按任务」改成「按剧目」（`hasInFlight` / `hasOffline`），空态分两句：没有下载、以及「这个筛选下还没有剧目」。`AppScreen` 多一项 `downloadEpisodes('DownloadEpisodes', '/downloads/episodes')`，路由表由 `AppScreen.values` 生成，不需要另登记。
- 「相互校验」不是新写的机制，是把已有的机制接到同一份读数上：`removeLocalDrama`、`manager.remove`、`runtime.evict` 三条删除路径都删完再读回缓存，只有读回证明文件没了才算删掉；被播放器占住的那集**留着，它的记录也留着**，卡片继续显示它，回话写成「N 个正在使用中或暂时删不掉」。反向的校验也在：ready 记录的文件被外部清掉后，`reconcile` 把它落成失败（`文件已移除，请重新下载`），卡片的「已完成」当场从 1 掉到 0。
- 为此必须补的一环：页面原先只在 `initState`/刷新时读一次磁盘，之后 `manager` 的每次 emit 只 `setState`，于是「刚下完一集」的卡片仍按空盘报「已完成 0 / 2 集」。现在两页都用 `queueSignature`（`key:phase` 的指纹）判断：**只有阶段变化才重扫缓存**，进度 tick 不扫——一次传输每秒 emit 多次，把 `localEpisodes()` 挂在上面才是真的贵。

一处与既有习惯的冲突要记下：`downloads_page.dart` 此刻是另一个会话正在写的文件（它在这页加了「合成已下载的分集」入口与 `_mergeDrama`）。本轮三次 `Write` 被「文件自上次读取后已修改」挡回，最后按「整读→立刻整写」落地，并且**逐字保留**他们那枚 `downloads-drama-merge-<id>` 按钮与 `_mergeDrama`（改为从卡片调 `_mergeDrama(group.tasks.first)`，仍然只在 `runtime is MergeRuntime` 且非 TV 时出现）。

验证读数（2026-11-03，本地 NTFS 克隆 `C:\Users\lee\scratch\hg-dl5`：整棵工作区快照（含两会话的未提交改动），`flutter pub get` 通过；本轮文件先覆盖进该树、`dart format` 后逐字节回拷 \Mac）：

| 范围 | 结果 |
| --- | --- |
| `dart format`（本轮 12 个文件） | 首轮 3 个变更（新写的换行），复跑 0 变更 |
| `dart analyze packages/app/lib/downloads ... features/downloads_page.dart` | `No issues found!` |
| `dart analyze --fatal-infos packages/app` | 3 项，**全部在本轮文件之外**：`integration_test/tv_live_data_test.dart` 未使用导入、`lib/features/merge_tasks_page.dart:350` `use_null_aware_elements`（均属另一会话的合成工作），以及本轮一度报出的 `drama_downloads.dart` 缺 `Drama` 导入——已修 |
| `test/latest_episode_check_test.dart` | **7** 项通过（改写 3 项为「只报告、不排队」：`runtime.calls` 只有一次 1080p 读、`downloads.taskFor('13','1080p')` 仍为空；新增「暂停中的那集算在下载中、不算新集」） |
| `test/downloads_tv_test.dart` | **8** 项通过（原 6 项按卡片/分集两层重写；新增「遥控删本剧一次确认带走 2 条记录与 2 个文件，回话来自读盘」与「卡片打开后遥控退格回到卡片列表」） |
| `test/download_ui_test.dart` | **4** 项通过（详情页选集 → 我的 → 下载管理的旅程改为先点卡片再验 `离线观看`；删除确认那条同样下钻一层） |
| `test/local_cache_management_test.dart` | **14** 项通过（触屏与遥控两处从「拉取即排队」改成「检查后 `runtime.calls` 只多一次在线读、一条任务都没排」） |
| 新 `test/download_drama_grouping_test.dart` | **5** 项通过（一卡汇总＋点开才有分集行；两枚画质两行、删一行不骗另一行；只缓存那集删掉后记录一条没动、退回卡片汇总随之变化；文件被外部清空后 ready 记录落成失败且「已完成」归零；`inUse` 文件删不掉时卡片与记录都留着，回话写明 1 个删不掉） |
| `packages/core` / `packages/tv` | 132 / 38 项全通过 |
| `packages/app` 全量 | **453** 项通过、2 项按条件跳过、**3** 项失败 |

那 3 项失败必须写清归属，否则下一轮会查错地方：全在 `test/tv_feed_test.dart`（「a late first-page refresh cannot overwrite another theme」等 3 条），异常是 `Tried to build dirty widget in the wrong build scope`（`_FocusInheritedScope`）。用同一棵树把本轮 7 个 lib 文件还原成 HEAD 版本，失败照旧；再另起一棵纯 `git archive HEAD` 的树，只覆盖另一会话未提交的 `lib/features/tv/tv_library_page.dart`，**同样 3 项失败**，纯 HEAD 则 18 项全过。所以它是那次 TV 片单改动带进来的，与下载无关，本轮不动它，交由那条线处理。

未验证的部分要说清：本机 ARM64 建不了原生包（media_kit 只有 x64），**没有任何真机/真窗口读数**——卡片的点按与遥控两枚目标、确认框焦点、下钻与退格、以及「正在使用中删不掉」那条，全部跑在 widget 测试的合成指针与 `tester.view` 的人工尺寸上；`DownloadFakeRuntime.evict` 是 `NativeRuntime.evict` 的镜像（先拒 inUse、删完再 `forget`），所以「删除与下载相互校验」的证据仍然是一次内存读回，不是 macOS 上被 Spotlight/沙盒拒绝一次的真实后果。`queueSignature` 驱动的重扫同样只在 fake 的即时读上验过：真机上那次扫描要多久、会不会和传输抢 IO，本轮没有读数。
