# Mac 全局隐藏系统标题栏

| 调整前 | 修改后 | 原因 |
|---|---|---|
| 普通页面恢复系统标题栏 | 启动起一直隐藏系统标题、背景和原生红黄绿按钮 | 避免系统装饰层遮住 Flutter 内容 |
| 系统按钮可能覆盖页面 | 普通页面使用独立占位的 32pt Flutter 窗口操作区，无标题文字 | 控件与内容不重叠，保留基本窗口操作 |
| 播放页按路由切换沉浸样式 | 仅切换 Flutter 操作区，播放页仍占满窗口 | 保留视频自动隐藏控件和最大播放面积 |

普通页面顶部只提供关闭（隐藏窗口）、最小化、全屏三项，剩余区域可拖动，双击缩放。使用 Column 为操作区单独分配高度，页面主体位于其下方。播放页隐藏此操作区，继续使用播放浮层中的返回、置顶、最小化和隐藏操作。系统菜单、Dock 恢复与画中画保持原有行为。

原生仍保留 .titled/.resizable 样式以支持焦点、缩放、全屏；视觉上通过公开 titleVisibility、titlebarAppearsTransparent、fullSizeContentView 及隐藏标准按钮完成。窗口标题字符串保留用于系统菜单/任务切换，不在窗口顶部展示。

## 验证（2026-10-21）

全量 145 项应用测试通过，1 项条件跳过；静态分析无问题。

- 新增组件验证：普通页面顶部独立保留 32pt，正文不被覆盖；播放模式移除操作区，正文占满高度；切换保留原子页面实例，窗口按钮调用对应原生动作。
- 路由回归验证：设置往返保留导航状态和窗口操作区；窗口控件工具提示使用独立 Overlay，避免位于根 Navigator 外部时缺少 Overlay。
- 本机原生用例验证：启动、播放、设置往返和退出播放页始终保持系统标题栏/原生按钮隐藏；置顶、全屏、画中画与关闭恢复正常。
- 播放页沿用原有的浮层按钮与鼠标显示/隐藏逻辑；手机/其他桌面端不增加此操作区。

复现命令（在 packages/app 中）：

```sh
../../.fvm/flutter_sdk/bin/flutter test --no-pub
../../.fvm/flutter_sdk/bin/flutter test integration_test/offline_playback_test.dart -d macos --plain-name 'mac window close hides' --no-pub
../../.fvm/flutter_sdk/bin/flutter build macos --debug --no-pub
```
