# Android TV 遥控器适配分析与实施方案

> 2026-10-20 实施更新：独立 TV module 与 App/flavor 集成已落地，实际范围和验收边界见 [实施记录](android-tv-implementation.md)。以下保留原分析方案，不能视作全部条目已实施。

日期：2026-10-20。分析对象：`flutter_hongguo/packages/app` 主工程及 `packages/api`、`packages/core`，源码基线 HEAD `6830b07`，同时检查了当时工作区文件。`imports/` 内历史迁入版本不作为改造对象。

本次只执行源码分析、官方资料核对和方案编写，未修改业务/Android 构建代码，未运行 TV 模拟器或实体电视。下文目录、flavor、状态机与命令属于待实施方案，不表示已经支持 TV。

## 1. 结论与范围

**可行，建议新增 `tv` product flavor 单独打包，复用现有 PC 宽屏设计、Dart 核心、API 与本地媒体流水线，增加专门的 TV 展示与遥控器交互层。** Android TV 运行 Android 原生包，不能直接使用 Windows/macOS 安装包；“PC 版适配”主要指复用现有大屏 UI 和播放业务。

风险主要集中在交互与设备验证：现有键盘支持不是完整的五向遥控器支持，屏幕宽也不代表电视设备；必须明确初始焦点、方向路径、浮层焦点约束、返回栈、连按行为以及播放器按键优先级。现有 media_kit 的 Android 支持为复用提供基础，但不证明某台电视的解码器、音频输出与遥控器已验收。[media_kit 官方包说明](https://pub.dev/packages/media_kit/versions/1.2.6)。

推荐首期覆盖：TV 启动器入口 → 发现/分类 → 系统输入法搜索 → 详情 → 分集 → 下载准备 → 本地播放/seek → 上下集/清晰度 → 返回详情并恢复焦点；同时覆盖收藏/历史、本地缓存、设置及失败重试。首次配置必须可用遥控器独立完成。语音识别、手机扫码输入、Cast、桌面推荐频道不是首期依赖。

## 2. 源码现状：证据、影响和改造位置

| 证据：当前文件与行为 | 判断及影响 | 建议改造路径 |
|---|---|---|
| `features/library_page.dart`：以 720/1100 宽度切换 NavigationBar/Rail/侧栏；DramaCard 使用 InkWell | 大屏布局与部分可聚焦控件可复用，但没有 TV 身份与稳定焦点恢复契约；并非完全没有键盘能力 | 接入 DisplayProfile；增加 TV 内容密度、显式焦点分区和卡片身份恢复 |
| `features/library_page.dart`：搜索 TextField、滚动内容、横向筛选浮层 | 默认方向推断可能在长列表、跨分区或重建后跳错；搜索输入阶段需由 IME 处理按键 | 为导航/搜索/筛选/内容分组，保留当前筛选与滚动状态；独立输入模式 |
| `features/detail_page.dart`：现成详情、播放按钮和分集网格 | 业务可复用；需要首焦点、当前集定位及详情返回卡片恢复 | 播放/继续观看作为首焦点，选集按稳定 vid 记忆 |
| `features/player_page.dart`：Space、左右 ±5 秒、PageUp/Down、I、F、Esc 的页面级快捷键 | 普通遥控器没有这些字母键；左右 seek 与浮层方向导航存在冲突风险，需测试当前后代是否消费事件 | 以当前交互上下文决定 Intent，不能给整个页面无条件绑定方向键 |
| `playback/compact_controls.dart`：任意键唤醒；仅 Tab 标记 keyboardFocus；隐藏时 ExcludeFocus | D-pad 操作不会像 Tab 一样阻止自动隐藏；可能让正在操作的焦点消失 | TV 独立状态机；焦点位于控件或菜单期间不自动隐藏 |
| `playback/episode_workspace.dart`：悬停、键盘状态、I/Esc、抽屉 Focus/PopScope | 选集面板可复用；TV 需当前集首焦点、面板边界及关闭后恢复按钮 | 为抽屉单独 FocusScope，隐藏不能残留可遍历节点 |
| `playback/playback_transport.dart`：Slider 和 IconButton 等 | 默认组件可作为基础，不能只依赖拖动进度条；选中与聚焦需区分 | TV 进度编辑、确认/取消、按键步进；显式焦点描边 |
| `platform/background/host_policy.dart`：Android/iOS 都是 mobileHost | TV 会被当手机，可能沿用后台播放、PiP、移动端设置策略 | OS 能力与设备形态拆分；TV policy 单独决策 |
| `platform/background/playback_platform_native.dart`：已有 audio_service 媒体控制及 audio_session | 可以复用现有媒体命令链；需核对 Flutter 按键与 MediaSession 是否重复触发 | 单一命令分发器，前台/后台会话归属清楚 |
| `MainActivity.kt`：AudioServiceActivity，现有 MethodChannel 主要服务 PiP | 不应为 TV 简单替换成 FlutterActivity，否则可能破坏现有媒体服务 | 保留基类；增加设备信息通道，确需原生兜底时只转发未处理事件 |
| Android Manifest：有普通 LAUNCHER，无 LEANBACK_LAUNCHER、TV banner 和 touchscreen 非必需声明 | 能安装 Android 包不等于会显示在电视桌面 | 将 TV 配置放入 `src/tv`；检查 merged Manifest |
| `android/app/build.gradle.kts`：无 productFlavors；已有签名环境变量、测试 ABI 分支 | 新 flavor 会改变 variant/输出文件名，现有 CI 脚本不能原样假定产物 | 增加 mobile/tv 维度，同步 CI、release_meta、validate_release 与测试参数 |
| `packages/api/lib/src/media_cache.dart`：已有并发预算、成品校验、任务合并；`prefetch_window.dart` 持有预热租约 | 下载、解密和离线播放可沿用；低端盒子应收缩预算 | 使用设备 profile 注入调度参数，保留前台优先和缓存租约 |

这些是源码可核对事实及风险推断；没有将潜在焦点冲突写成已在 TV 复现的故障。

## 3. 构建方案：mobile / tv 双 flavor

### 3.1 包与发布关系

| 项目 | mobile | tv |
|---|---|---|
| Flavor | mobile | tv |
| Dimension | device | device |
| Android applicationId | 保留现有 `com.example.hongguo_app` | `com.example.hongguo_app.tv` |
| Namespace / Kotlin 包 | 保持现状 | 同用现有 namespace/Kotlin 包，不随 suffix 改代码目录 |
| 名称 | 红果剧场 | 红果剧场 TV |
| 入口 | `lib/main.dart` | 同入口读取 appFlavor，避免双入口参数组合错配 |
| 启动器 | 普通 LAUNCHER | LEANBACK_LAUNCHER；首期不要求手机桌面入口 |
| UI | 当前自适应 UI | TV shell、焦点体系、TV 播放控制 |
| 设置/缓存/凭据 | 当前私有目录 | 不同 applicationId 独立沙盒；不自动共享登录/设备身份 |
| 分发 | 保持现有发布规则 | 独立 APK 附件；需要 Play 时独立 AAB/listing |

TV 使用独立 ID，便于共存、回滚和差异化策略。这是单独应用的发布路线；若以后要求同一个 Play listing 覆盖手机/TV，必须重审 applicationId 与分发方案，不能假设 suffix 后仍是同一个应用。现有签名密钥可以按发布策略复用，版本号继续从 workspace/pubspec 的现有发布流程读取；更新同一 TV 包必须保持稳定签名。

Flutter 官方支持 Android product flavor、`--flavor` 以及通过 `appFlavor` 读取选择。新增后所有 Android 构建/测试应明确 flavor；对原来未指定 flavor 的脚本补 mobile，不把 default-flavor 当作唯一保障。不要在桌面构建命令无条件追加 Android flavor。[Flutter flavors](https://docs.flutter.dev/deployment/flavors)。

### 3.2 待实施文件布局

```text
packages/app/android/app/
  build.gradle.kts                    # device 维度、mobile/tv、suffix
  src/main/AndroidManifest.xml        # 共享 Activity、权限、服务；不放专属 launcher
  src/mobile/AndroidManifest.xml      # LAUNCHER
  src/mobile/res/values/strings.xml   # mobile 名称
  src/tv/AndroidManifest.xml          # TV launcher/features/banner/方向策略
  src/tv/res/values/strings.xml       # TV 名称
  src/tv/res/drawable-xhdpi/tv_banner.png
packages/app/lib/
  platform/device_profile.dart        # UI 形态、输入方式、能力的组合
  platform/device_profile_native.dart # Android UI mode/features 通道适配
  input/remote_intents.dart           # 输入含义；不含播放器业务
  input/remote_actions.dart           # 按当前上下文分发
  input/tv_focus_registry.dart        # 稳定身份、恢复、滚动协调
  widgets/tv_focusable.dart           # 聚焦反馈与语义
  features/tv/tv_shell.dart           # 导航、内容分区与入口
  playback/tv_player_controls.dart    # TV 状态机、进度预览与菜单
```

保持原分层：`core` 的 crypto/media/models 不感知遥控器；`api` 不导入 Widgets；app 的 input 层表达 Intent，由播放/目录控制器调用现有业务。TV shell 复用现有 Runtime/Repository，不再复制签名、取址、解密或历史存储。

### 3.3 Manifest 与资源要求

TV flavor 增加 leanback feature、touchscreen 非必需、LEANBACK_LAUNCHER、TV 横屏配置及 banner。`main` 中原普通 launcher 应迁至 mobile，不能只叠加 TV filter 后忽略合并结果；共享服务与权限保留。不同 flavor 的 display name 使用 `strings.xml`，不强依赖 `resValue`，规避 AGP 版本差异。

TV-only 分发建议 `android.software.leanback required=true`，明确该包面向电视；非标准机顶盒若未声明 leanback，Play 过滤与侧载可运行性是不同问题，可由强制 TV profile 实现侧载试验，但不预先承诺兼容。手机包不加入 TV 入口。不要全局锁 Android 横屏；仅 TV 的合并 Manifest/能力策略生效。

复用“果中有戏”图标，并新增含“红果剧场 TV”文字的 320×180 xhdpi banner，不能直接把方形图标拉伸成横幅。官方对入口和资源的定义见 [Create a TV app](https://developer.android.com/training/tv/get-started/create)。

实施后从 `packages/app` 执行以下预期命令；现在尚未添加 flavor，因此这些命令当前不可用：

```bash
../../.fvm/flutter_sdk/bin/flutter build apk --release --flavor tv --split-per-abi
../../.fvm/flutter_sdk/bin/flutter build appbundle --release --flavor tv
../../.fvm/flutter_sdk/bin/flutter build apk --release --flavor mobile --split-per-abi
../../.fvm/flutter_sdk/bin/flutter run --flavor tv
```

CI 增加可选目标 `android-tv`，区分 mobile/TV flavor 与 APK/AAB 产物。建议附件命名 `Hongguo-<version>-android-tv-arm64-v8a.apk` 等；这里为命名约定，不是现成文件。不可把 TV 包重命名后覆盖手机 APK。打包契约测试同时校验 applicationId、flavor、签名、ABI、banner/launcher、校验和和完整性。

## 4. 设备形态和焦点模型

### 4.1 不只按分辨率判断

推荐 profile 三轴：`os=android`、`formFactor=television`、`input=dpad`，另有 `pip/hardwareDecode/mediaSession/lowRam` 等能力。TV flavor 固定默认 television；原生 `UiModeManager` 的 television 类型、leanback feature 作为证据与兼容信息。PC 可通过开发配置强制 TV UI 进行键盘预验收，但 PC 成功不代替 Android TV 测试。仅出现方向键输入不应把手机永久切 TV。

OS 判断继续用于文件、插件；设备形态决定布局，输入模式决定焦点/快捷键。TV 不走桌面 window_manager 全屏，也不照搬 mobileHost 的全部偏好。

### 4.2 全局焦点契约

- 一个可见页面只有一个逻辑活动焦点；进入首页落在默认导航或第一项内容，进入详情落在“继续观看/开始观看”。加载/错误页也要有可达的取消、重试、返回。
- 侧栏、顶部搜索、筛选、内容网格、播放控制、选集抽屉各有明确 FocusTraversalGroup/FocusScope。跨区边界显式定义；区域内部优先利用 Flutter 原生方向遍历，不一开始重写全部遍历算法。
- 用 `section + seriesId/vid` 保存恢复身份，不用列表 index 作为唯一依据。节点消失时回落同区最近可用项，再回落导航；不要向已 dispose 的 FocusNode 请求焦点。
- 页面返回恢复同一卡片、筛选状态与滚动位置；追加分页不能抢焦点。数据替换后要等 layout/scroll 完成再定位；虚拟列表需要先使目标项构建，再 requestFocus，单独调用 ensureVisible 不保证能定位未构建项。
- 弹层打开焦点进入弹层，背景 ExcludeFocus；关闭恢复触发按钮。用焦点描边/底色区分“当前聚焦”和“已选中”，不能只依赖鼠标 hover、颜色或长按菜单。
- 长按方向允许系统 repeat 做连续移动/进度预览；确认动作不重复执行，返回只处理一次；失焦/路由离开取消积累中的按键状态。

Flutter 的 Focus、FocusTraversalGroup、Shortcuts/Actions 可支撑这些机制，应在平台映射和业务动作之间保留独立边界。[Focus 系统](https://docs.flutter.dev/ui/interactivity/focus)、[Actions 与 Shortcuts](https://docs.flutter.dev/ui/interactivity/actions-and-shortcuts)。

### 4.3 大屏样式起点

以下是项目建议起点，不是平台强制数值：按 logical pixels/dp 设计，1080p/4K 都根据实际密度布局，避免物理像素硬编码；页面保留约 32–48 的内容边距；正文约 20–24、标题 28–36；聚焦 3–4 描边、约 1.03 缩放且不挤动邻项。低端盒子或减少动态效果时只保留描边，不依赖模糊/多层阴影。

内容卡片控制列数与标题行数，优先减少一次可见的信息密度。导航恢复与对焦可见性比动画优先。竖屏短剧在横屏电视居中等比显示，黑色侧边，不裁剪或拉伸；横屏内容按原始比例适配。选集浮层覆盖侧边区域，但不改变视频宽高比或自动旋转屏幕。

## 5. 遥控器操作与播放器状态机

### 5.1 单一命令入口

D-pad/确认/Back 为完整操作基线，不依赖 Menu、数字键、字母键、鼠标或空格。Flutter 的 select/Enter/numpadEnter 映射应在目标 SDK/实体设备记录验证，不先假定所有遥控器等价；原生 KeyEvent 仅在 Flutter 无法可靠收到时兜底，不把同一次按键同时广播两条路径。

MediaSession 的 play/pause/next/previous 与 UI Intent 最终进入同一命令分发器。不要仅以时间窗口粗暴去重全部按键；先明确哪个层消费事件、哪个层收到 native media callback，只有实测重复路径才增加带来源/序号的防重复措施。系统 Home/电源/音量不被应用拦截。[Android 控制器指南](https://developer.android.com/training/tv/get-started/controllers)。

| 上下文 | 方向键 | OK / 确认 | Back |
|---|---|---|---|
| 首页/分类/设置 | 在当前区及定义好的边界移动焦点 | 激活控件或进入子页 | 关弹层 → 返回上一页 → 根导航 → 系统首页 |
| 搜索文字编辑/IME | 交给输入法与编辑器 | 输入法确认/提交搜索 | 先由 IME 关闭键盘，再恢复搜索控件焦点；不能同时退出页面 |
| 视频画面，控制栏隐藏 | 上/下显示控制栏并聚焦默认按钮；左/右进入进度预览 | 播放/暂停并显示状态；同一次事件仅执行一次 | 退出播放页；TV 播放默认沉浸式，不额外退出“桌面全屏”一次 |
| 视频控制栏可见 | 导航按钮；进度条获得焦点才步进时间 | 激活聚焦按钮 | 隐藏控制栏并把焦点交还视频根节点 |
| 进度预览 | 左/右按 5 秒步进，长按可加速但设最大步长 | 提交最终 seek | 取消预览，恢复原播放位置/状态 |
| 选集/清晰度/设置面板 | 面板内移动，不触发视频 seek | 提交当前项 | 仅关当前面板，恢复入口焦点 |
| 下载中/失败 | 移动到取消/重试/返回 | 执行当前项 | 取消当前准备并返回上一层；不留下覆盖新请求的旧结果 |

状态定义：`videoHidden`、`controlsVisible`、`seekPreview`、`panelOpen`、`preparing`、`failed`。交互层持有 UI 状态，播放/准备状态仍由现有业务提供，不重复管理两份 player 状态。暂停、忙碌、错误、菜单打开或焦点在控件内时禁止自动隐藏；播放中且焦点返回视频后，约 4 秒无操作才隐藏。

进度预览保存进入时的 position/playing，重复方向键只更新预览，不对每个 repeat 都调用 seek；提交/短按去抖策略必须统一，结束时再 seek。无论如何优化，离开预览都有明确提交/取消语义。列表方向导航不发生 seek，输入法文字操作也不触发播放快捷键。

### 5.2 Back 与系统生命周期

建立一个路由/浮层 Back 协调入口，避免多个 PopScope 和 Escape 快捷键分别处理一次物理 Back。关闭最上层面板 → 取消进度预览 → 隐藏控制层 → 退出播放路由 → 详情/首页恢复焦点；每次只消费一层。根页面最终正常返回系统，不使用无限拦截或强制 kill 进程。

TV 首期策略：Home/切应用/息屏保存进度并暂停视频；不继承手机可开启的后台音频持续播放。PiP 默认从 TV 设置中隐藏，后续有明确设备能力与独立验收再开放。播放时维持屏幕唤醒，暂停/离开时释放；音频焦点丢失、HDMI 输出变化、拔插遥控器都需测试。现有媒体会话可复用，但只作为同一播放器的会话适配层。

## 6. 分阶段实施与验收门槛

| 阶段 | 主要工作 | 必须交付的可检查结果 |
|---|---|---|
| P0：TV flavor 与输入探针 | mobile/tv 分包、profile、Manifest/banner、按键记录页 | 两包可并存、启动入口正确；真实遥控器方向/OK/Back/媒体键完整日志；验证 minSdk 实际解析值与 ABI |
| P1：全站 D-pad 可达 | TV shell、卡片、详情、搜索/IME、筛选、设置、收藏/历史、缓存页 | 不使用鼠标触摸完成关键链路；弹层不漏焦点、长列表可翻页并恢复 |
| P2：播放交互 | 上述状态机、进度预览、清晰度/选集、Back、MediaSession 归一 | 本地合成片播放/声音/seek/切集正常，一次按键不双触发；当前资源管理与取消回归通过 |
| P3：盒子性能与发布 | 低内存 profile、缓存预算、音频/解码兼容、签名及 CI 矩阵 | 32/64 位目标设备记录、安装升级/冷启动/恢复/断网测试、产物与 ABI/签名/页面大小校验 |

建议先做 P0–P2 的单设备闭环，再按证据扩展兼容矩阵。实现、调试、机型覆盖都不能仅靠代码行数估算；设备未确定前不承诺日程。若 P0 发现硬解/音频或插件阻塞，先记录样本、系统与插件版本，决定 media_kit 参数/原生播放器替换的范围，勿提前重写整个播放器。

## 7. 验证方案

### 7.1 自动测试

- Widget：方向移动、确认一次、Back 一层、初始焦点、网格边界、列表末行、分页不抢焦点、删除当前项后的回落。
- 播放交互：浮层左右只导航；视频根节点左右预览；seek 提交/取消、边界 clamp、重复键释放；忙碌与暂停不丢焦点。
- 输入：搜索 IME 关闭与页面 Back 分离；文本编辑不触发播放器快捷键；长按确认不重复跳路由/提交下载。
- 集成：沿用 `integration_test/offline_playback_test.dart` 的离线素材与 runtime 注入，新增 TV 遥控器流程；保留 PC/手机鼠标/触摸回归。
- 构建契约：merged Manifest、TV label/banner、手机包无 TV launcher、包名/签名、AAB/APK flavor 产物匹配。只通过 Widget 测试不能证明 MediaSession/插件或 TV Launcher 正常。

flavor 实施后的开发命令（从 `packages/app` 执行，须连接指定 TV 设备；多设备时使用 adb -s）：

```bash
../../.fvm/flutter_sdk/bin/flutter run --flavor tv
adb shell input keyevent 19   # 上
adb shell input keyevent 20   # 下
adb shell input keyevent 21   # 左
adb shell input keyevent 22   # 右
adb shell input keyevent 23   # OK
adb shell input keyevent 4    # Back
adb shell input keyevent 85   # 媒体播放/暂停
```

ADB 注入适合烟测，不代替实体遥控器的蓝牙、红外重复键与系统媒体分发路径。

### 7.2 设备矩阵与性能

最低验证组合：TV 模拟器 + 一台常见 arm64 Android TV/Google TV + 一台低内存/32 位目标盒子（仅当计划支持）。记录 Android 版本、ABI、RAM、电视分辨率/逻辑密度、遥控器型号、实际 codec 与音频输出。没有对应设备时明确标为未验证，不能把手机横屏当 TV 真机证据。

资源建议起点：低端机同时准备 1 个媒体任务、最多预热下一集 1 个；沿用前台优先、任务合并和缓存租约。核对串行预算下预热不会抢占当前集。测量 release/AOT 的首屏、下载/解密分段耗时、主线程 frame time、峰值 PSS、磁盘占用和持续播放温度；不套用桌面吞吐。

样本至少包含竖屏/横屏 H.264+AAC、可用 HEVC、音视频多轨、断网/过期 URL、低磁盘、快速连续切集、恢复历史、解密失败、蓝牙/HDMI 音频切换。HEVC 可用性由电视及实际播放器构建决定；优先 H.264 不表示可以隐式承诺转码或所有电视硬解。

### 7.3 发布边界

截至检索日，Google Play TV 质量要求包含五向 D-pad 可操作、正确 Back、TV launcher/banner，以及现行 AAB、32/64 位和 16 KB 页面兼容要求。需要检查 Flutter 引擎和所有第三方 `.so`，不能仅因 SDK 较新就认定合规；minSdk 要检查合并结果及依赖约束，不能直接把平台文档最低 API 当成本工程可用最低版本。Play 分发与侧载内部测试分开验收。[TV app quality](https://developer.android.com/docs/quality-guidelines/tv-app-quality)。

本次未进行商店审核、ABI/ELF 页面校验或任何设备安装。

## 8. 优先决策与暂缓项

已采纳用户方向：TV flavor 独立打包。方案建议 mobile 保持现有包 ID，TV 追加 `.tv`；新增 TV 入口和 UI profile，复用现有 Runtime；不从 imports 拷贝另一套实现。正式实施前只需确认目标盒子/电视及分发渠道，再据此调整 device matrix、最低 SDK 和 TV-only feature 过滤。

暂缓：自建屏幕键盘、跨端账号同步、手机控制协议、推荐频道、语音助手深度命令、TV PiP、多视频同屏。先确保没有 Menu/鼠标/数字键的简单遥控器能完整操作 App，再扩展高级体验。

## 9. 参考资料

2026-10-20 核对，技术判断以当前源码为主，平台要求以以下官方页面为准：

- [Flutter Android flavors](https://docs.flutter.dev/deployment/flavors)
- [Flutter Focus](https://docs.flutter.dev/ui/interactivity/focus)
- [Flutter Actions / Shortcuts](https://docs.flutter.dev/ui/interactivity/actions-and-shortcuts)
- [Android TV 创建与入口](https://developer.android.com/training/tv/get-started/create)
- [Android TV 遥控器](https://developer.android.com/training/tv/get-started/controllers)
- [Android TV 导航](https://developer.android.com/training/tv/get-started/navigation)
- [Android TV 质量要求](https://developer.android.com/docs/quality-guidelines/tv-app-quality)
- [media_kit 官方包](https://pub.dev/packages/media_kit/versions/1.2.6)
