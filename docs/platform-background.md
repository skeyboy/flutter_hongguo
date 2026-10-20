# 0.2.6：后台能力与悬浮播放

[设计与平台矩阵](design/platform-background.md)。本轮代码仍位于迁移后的 `packages/core`、`packages/api`、`packages/app`；没有迁回参考工程。

## 使用

设置 → **后台与悬浮播放**，分别开启并保存：

- **后台播放**：移动端使用媒体通知/锁屏控制，后台继续声音播放；桌面在最小化后继续。关闭播放页会结束该播放器，不是跨页面常驻音乐模式。
- **后台下载**：后续缓存改由系统下载，离开播放页仍可完成已排队任务。移动端新增“仅 Wi-Fi”，默认开启；等待网络会显示等待状态。
- **悬浮播放**：播放器顶部出现画中画按钮。Android 使用系统 PiP；iOS 将当前本地 MP4 交给 AVPlayer；桌面切换可还原的置顶小窗。

移动端开启时显示说明；后台下载会申请通知授权。拒绝通知权限时系统可能不显示进度提醒，不代表允许绕过系统调度。

## 平台实现

| 行为 | 实现 |
|---|---|
| Android 后台声音与控制 | audio_service 前台媒体服务、MediaSession 和音频焦点；manifest 声明对应权限及 receiver |
| iOS 后台声音 | UIBackgroundModes=audio、AudioSession 与 audio_service 锁屏/控制中心；音频中断/耳机拔出暂停 |
| Android 悬浮 | MainActivity 的 PiP 通道，API 26+；按实际比例限制到系统接受范围，PiP 中隐藏普通 UI |
| iOS 悬浮 | 本地 clear MP4 → AVPlayerLayer → AVPictureInPictureController；暂停原播放器避免双重声音；返回时 seek/播放状态同步 |
| 桌面悬浮 | window_manager 记录原窗口、置顶、最大化/全屏状态；缩小并置顶，退出后恢复 |
| 系统下载 | background_downloader 原生传输，网络字节进度接入共享预算/取消逻辑；工作文件不直接暴露给播放器 |
| 下载恢复 | 普通任务文件只含密钥引用，密钥在系统安全存储；启动时对完成文件做解密/校验/原子发布；未完成旧进程任务取消后可重试 |

悬浮播放默认手动进入。Android 不申请覆盖任意 App 的 SYSTEM_ALERT_WINDOW 权限。iOS PiP 需要系统/设备允许，以及 AVPlayer 支持的音视频格式；失败会显示提示并恢复原播放器。当前 iOS 系统 PiP 在单集结束后退出；是否进入后续集遵循前台状态/后台播放及自动连播设置，不承诺在 PiP 窗内无缝跨集。

桌面“后台”是应用仍运行，不是退出进程后继续。Linux 置顶能力取决于窗口管理器，不能用同一 API 保证每个 Wayland 环境均生效。

## 任务与资源生命周期

- 当前播放本地文件，后台音频不会重复下载。
- 开启后台下载时，运行时额外持有预缓存租约，播放页关闭不取消已经排入的缓存；关闭后台下载会取消系统任务。
- 下载仍遵循现有并发、容量与完成清单，密钥不进通知、日志、普通偏好或下载任务 metadata。
- 正常完成/取消清理下载记录和密钥引用；系统强制结束后的已完成文件在下次启动恢复。密钥存储暂时锁定时保留记录，避免把未知文件当作已就绪。
- iOS/Android 被用户强制结束时不保证继续；iOS 解密和队列推进可能要返回 App。不是通过后台音频播放静音来维持任意下载任务。
- 默认关闭的新偏好兼容旧设置文件，主题/签名参数不会被混入这些开关。

## 源码入口

| 职责 | 文件 |
|---|---|
| 共享偏好与迁移默认值 | [app_settings.dart](../packages/core/lib/src/config/app_settings.dart) |
| 传输注入、等待网络、恢复原子发布 | [media_cache.dart](../packages/api/lib/src/media_cache.dart) |
| 系统任务、密钥记录与恢复 | [native_downloads.dart](../packages/app/lib/platform/background/native_downloads.dart) |
| 音频会话与系统媒体控制、PiP/桌面窗口 | [playback_platform_native.dart](../packages/app/lib/platform/background/playback_platform_native.dart) |
| 生命周期、悬浮按钮与纯视频界面 | [player_page.dart](../packages/app/lib/features/player_page.dart) |
| 设置、移动端说明与平台文案 | [settings_page.dart](../packages/app/lib/features/settings_page.dart) |
| Android 宿主与 PiP | [MainActivity.kt](../packages/app/android/app/src/main/kotlin/com/example/hongguo_app/MainActivity.kt) |
| iOS AVPlayer/PiP 桥接 | [AppDelegate.swift](../packages/app/ios/Runner/AppDelegate.swift) |

## 平台依据

- [Android 系统画中画](https://developer.android.com/develop/ui/views/picture-in-picture)
- [Apple AVPictureInPictureController](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller)
- [audio_service 平台配置](https://pub.dev/packages/audio_service)
- [background_downloader 平台调度与限制](https://pub.dev/packages/background_downloader)
- [window_manager 桌面窗口 API](https://pub.dev/packages/window_manager)

## 验证

验证计数、原生编译结果及平台限制见 [本轮验收记录](evidence/platform-background/README.md)。Mac 可实际验证原生下载和桌面窗口；Android/iOS 的编译成功不等于移动设备锁屏、长时间退后台和系统 PiP 真机验收。

Android 16 真机已完成系统画中画验证；真实窗口布局与系统后台操作以最新验收记录为准；iPhone 模拟器 API 返回不支持 PiP，不能替代 iOS 真机验收。[iPhone 真实窗口设置截图](assets/platform-background/ios-settings.png)。

[按平台自动化测试与开发安装](mobile-testing.md)：区分共享逻辑、真实窗口、系统 API 与物理手势；不会以 PC 画面冒充移动端验收。
