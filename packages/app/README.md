# hongguo_app

主 workspace 的 Flutter 宿主应用。原生端通过共享 Dart 核心取内容、准备本地 MP4，再交给 media_kit 播放。

- `lib/main.dart`：正常 App 入口。
- `lib/bootstrap.dart`：GetIt / Riverpod 依赖装配。
- `lib/features/`：常驻筛选的首页/分类/搜索、设置、本地缓存剧集、详情选集和播放器。
- `lib/catalog/library_cache.dart`：缓存优先的目录快照与离线剧集元数据。
- `lib/platform/`：原生私有目录与媒体 runtime、平台契约及可选 Web 远程适配。
- `test/`：页面与交互测试。
- `integration_test/offline_playback_test.dart`：离线原生播放验收。
- `integration_test/macos_live_poc_test.dart`：显式启用的 Mac 真实上游单集验收。
- `android/`、`ios/`、`macos/`、`windows/`、`linux/`：原生宿主工程。

从本目录运行当前 Mac App：

```bash
../../.fvm/flutter_sdk/bin/flutter run -d macos
```

不要把集成测试入口当作正常 App 入口；Release 使用 `lib/main.dart`。

## Windows 后台运行

点击窗口右上角关闭按钮（或 Alt+F4）会隐藏窗口，进程继续运行。
在任务栏通知区域找到 Hongguo 图标（可能位于折叠图标中），双击恢复窗口；
右键菜单可选择“打开红果”或“退出”。“退出”会关闭窗口并结束进程。
托盘不可用时关闭按钮正常退出，避免留下无法恢复的隐藏窗口。
后台运行不阻止 Windows 睡眠或注销，也不改变应用已有的后台播放设置。

Windows 手工验收：关闭窗口后确认进程仍存在，双击托盘恢复；再次关闭后
用右键菜单打开；最后通过“退出”确认进程结束。另检查资源管理器重启后
图标可恢复，以及播放、下载在隐藏窗口前后的实际行为。

[文档总索引](../../docs/README.md) · [代码对应表](../../docs/project-map.md) · [当前 Mac 验收](../../docs/macos-independent-app-poc.md)

[0.2.1 交互、主题与缓存验收](../../docs/interaction-cache-validation.md)

[0.2.2 按剧目展示本地缓存](../../docs/local-library-grouping.md)

## 后台与平台验收

0.2.6 新增默认关闭的后台播放、后台下载与悬浮播放开关。移动端系统通知/媒体控制、Android/iOS PiP、桌面置顶小窗按平台实现；系统后台限制和真机验收范围见 [功能文档](../../docs/platform-background.md)。

[按真实窗口执行移动自动化及 ADB 安装](../../docs/mobile-testing.md)。测试保留 App（`--no-uninstall`），不再每轮当作首次安装；厂商授权不足时明确报错。
