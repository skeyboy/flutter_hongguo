# TV 独立交互模块与 App 集成

> 后续验收更新：现已删除旧手机 AVD，创建真正 Android TV API34 模拟器，并通过 9 次 Android 系统 D-pad/确认/Back 的完整原生播放链路。见 [Android TV 模拟器验收](../android-tv-emulator-verification.md)。下文手机镜像与磁盘受限记录保留为早期验收历史。

日期：2026-10-20。基于 [适配分析](android-tv-adaptation.md)，已实现独立 `hongguo_tv` 模块、App 适配和 mobile/tv Android 分包。原有 PC、手机业务继续使用既有页面与媒体服务。本次不涉及 imports 中的历史工程。

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

- 侧栏：短剧、漫剧、AI 短剧、本地缓存、我的（含设置）；较低逻辑高度时侧栏可滚动。
- TV 目录：独立大卡片布局、标题、焦点描边；支持排序、题材、手动分页。分页追加不抢焦点。
- 搜索：确认“搜索短剧”后打开输入对话框，使用系统输入法；文字编辑阶段不拦截左右按键。无需触摸弹出输入法。
- 详情：加载失败可重试；首次聚焦开始观看；每个分集可确认播放。返回目录时恢复原卡片焦点与网格位置。
- 本地缓存、我的（收藏/历史）和设置：使用现有业务页，外层统一加入 TV 方向导航/确认映射。TV 设置隐藏手机后台/PiP 能力，并明确展示运行策略。
- 播放：等比使用既有 Video；busy/error 提供返回/重试。媒体键播放/暂停、前后轨道连接到原播放实例/切集入口。

| 当前层 | 左右方向 | 上下方向 | 确认 | 返回 |
|---|---|---|---|---|
| 视频画面 | 进入 ±5 秒进度预览 | 打开控制栏并聚焦播放按钮 | 播放/暂停，同时打开控制栏 | 退出播放路由 |
| 控制栏 | 移动焦点 | 移动焦点 | 播放、上下集、进度、选集、清晰度、返回画面或退出 | 关闭控制栏，恢复视频焦点 |
| 进度预览 | 累积预览，约束到片长 | 打开控制栏 | 提交一次 seek | 取消预览，不 seek |
| 选集/清晰度 | 面板内移动 | 面板内移动/滚动 | 选择并关闭面板 | 关闭一层，恢复播放按钮焦点 |

控制栏只在用户明确返回画面时隐藏；聚焦期间不计时自动消失，避免遥控器操作中焦点被移除。当前并未照搬分析稿里所有自动隐藏/长按加速建议：repeat 支持连续固定步进，未做加速曲线。

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

## 5. 验收边界

本次交付是可构建、已离线测试及原生 Android 运行验证的 TV 适配版本，不宣称所有 TV 设备已兼容。尚需在目标电视/机顶盒验证：实体遥控器与蓝牙 repeat、系统 IME、TV Launcher 实际显示、Home/息屏/音频焦点、HEVC/硬解、HDMI 音频切换、低内存性能与长时间播放。Android 32 位及 TV 商店 16KB 原生库要求也需要目标构建独立验收；本次本机构建以 arm64 为主。

题材/排序等数据能力复用上游，不增加新协议。TV 首页复用现有我的/收藏/历史模块，不额外实现跨端账号、语音控制、Cast、跨设备记录同步或电视推荐频道。Google Play 上架、本地化横幅全量资源与设备目录过滤不作为本次完成项。

## 6. Android 模拟器界面记录

下图为 TV flavor 在 Android 15 手机镜像的横屏界面，截图前已通过 Android 系统输入方向键；不是实体电视截图。

![TV flavor Android 模拟器界面](../assets/android-tv-android-emulator.png)
