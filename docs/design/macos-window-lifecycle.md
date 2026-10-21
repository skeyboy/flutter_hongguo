# Mac 窗口驻留与沉浸播放

| 当前行为 | 修改后 | 原因 |
|---|---|---|
| 关闭主窗口退出进程 | 红色关闭和 ⌘W 隐藏，⌘Q / 菜单退出结束进程 | 保留播放、下载、路由状态 |
| 隐藏后无稳定恢复入口 | Dock 与菜单栏图标唤起同一窗口 | 不重新创建引擎或播放页 |
| 播放页有系统标题栏 | 透明标题栏、全尺寸内容、隐藏红黄绿按钮 | 视频占满窗口，保留系统窗口语义 |
| 窗口样式跟随全局配置 | 仅可见播放路由使用沉浸样式，进入设置/返回恢复 | 不影响日常浏览与设置 |

菜单栏图标按主窗口状态处理点击：窗口隐藏、最小化或应用被隐藏时恢复主窗口；窗口已显示时展示“显示主窗口 / 隐藏窗口 / 设置 / 关于 / 退出”菜单。左右键使用同一状态规则，避免窗口唤起与菜单弹出冲突。原生菜单按系统语言提供英文、简体与繁体中文。设置复用现有 auto_route 页面，连续点击不重复压栈；尚未初始化时禁用。应用菜单 ⌘, 同样进入设置。

播放浮层左侧返回，空白标题区域可拖动，右侧提供最小化与隐藏窗口。操作浮层继续采用现有三秒隐藏与鼠标唤出。隐藏窗口保留当前播放和下载策略；退出应用才结束进程。播放页保留系统 .titled / .resizable 样式，以维持键盘焦点、窗口缩放和原生全屏；使用公开 fullSizeContentView 与 titlebarAppearsTransparent 实现视觉沉浸，不使用私有视图层级。

只有 PageRoute 切换改变窗口外观；音量、倍速等弹出菜单不触发标题栏闪现。窗口外观采用播放页所有权集合，避免旧页面释放时覆盖新播放页状态。关闭窗口保留原尺寸，恢复会解除最小化并激活同一 Flutter 窗口。

原生参考：[Apple Dock 重新打开事件](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:))、[NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)。

## 验证（2026-10-21，macOS 27.0.1）

- Flutter 静态分析无问题；137 项应用测试通过，1 项条件跳过。新增窗口样式所有权释放顺序、原生设置入口路由与重复点击回归。
- 本机 3 项原生集成测试通过：系统画中画与最小化持续播放；真实 NSWindow 关闭隐藏、恢复同一播放器、菜单栏图标及菜单构造、播放内容高度覆盖完整窗口、设置往返恢复样式、倍速弹出不改变样式；鼠标唤出、自动隐藏、全屏 Esc 与返回操作。
- Dock 接入 AppKit reopen 回调；集成测试通过同一恢复函数验证窗口/播放器保留，本轮未自动点击系统 Dock 和菜单栏。
- 不新增第三方依赖；手机、TV 保留现有窗口与界面逻辑。

复现命令（`packages/app`）：

```sh
../../.fvm/flutter_sdk/bin/flutter test --no-pub
../../.fvm/flutter_sdk/bin/flutter test integration_test/offline_playback_test.dart -d macos --name 'mac window close|desktop picture in picture|immersive player' --no-pub
../../.fvm/flutter_sdk/bin/flutter build macos --debug --no-pub
```

后续画中画连播和鼠标隐藏规则见 [Mac 连播与交互](macos-pip-continuation.md)。
