# 窗口行为偏好开关：执行规划与方案

- 日期：2026-11-26
- 来源：issue #1 条目 4 的后续项（见 `docs/issues/issue-001.md`）
- 基线：`93edecd`（v0.3.31，DesktopWindow 统一封装已落地）
- 增补（2026-11-26）：关闭确认对话框交互设计，见「关闭确认对话框」一节

## 范围

设置页新增「窗口行为」分区（仅桌面端可见），包含两项：

1. **关闭按钮行为**：`每次询问`（默认）| `最小化到托盘` | `退出程序`
2. **记住窗口状态**：重启后恢复上次的窗口位置、大小与最大化状态（默认开启）

明确不在本轮：任务栏角标（无明确使用场景）、Linux 托盘（当前无 Linux 托盘实现）、启动时隐藏到托盘。

## 关闭确认对话框（交互性设计增补）

### 触发时机

点击系统的关闭入口（Windows 标题栏 ×、Alt+F4；macOS 红色关闭键）且当前偏好为
`ask`（默认）时，**先不执行任何关闭动作**，由原生层把 `closeRequested` 转发给
Dart，Dart 弹出确认对话框。偏好已是 `tray` / `exit`（包括用户勾选过「记住选择」）
时不弹窗，直接执行对应动作。

### 对话框内容

- 标题：**关闭窗口**
- 单选（二选一，默认选中推荐项「最小化到托盘」）：
  - **最小化到托盘** —— 影响说明：「播放和后台下载继续进行，托盘图标可随时恢复窗口」
  - **退出程序** —— 影响说明：「退出会中断正在进行的播放与后台下载，托盘图标同时移除」
- 复选框：**记住我的选择，下次不再询问** —— 辅助说明：「可随时在 设置 → 窗口行为 里改回每次询问」
- 按钮：取消 / 确定（确定执行所选动作）

### 状态机

```
close 请求（原生转发 closeRequested）
  ├─ 偏好 = tray  → 直接隐藏到托盘
  ├─ 偏好 = exit  → 直接退出
  └─ 偏好 = ask   → 弹确认对话框
        ├─ 取消            → 不做任何事，窗口保持
        └─ 确定
             ├─ 未勾选记住 → 执行本次所选动作，偏好不变（下次仍询问）
             └─ 勾选记住   → saveSettings(windowCloseBehavior = 所选)
                             并立即下发原生，再执行动作
```

### 边界与约束

1. **对话框需要 UI 能力**：仅桌面端注册 close 处理；TV/移动/Web 无此流程（原生层在这些平台上也不转发）。
2. **引擎未就绪的启动竞态**：设置异步加载完成前，Windows 原生回退到既有「有托盘则隐藏」行为，macOS 回退 `orderOut`——不阻塞、不弹窗。
3. **改回询问**：设置页「关闭按钮行为」提供 `每次询问` 选项，随时恢复弹窗。
4. **macOS「隐藏窗口」状态栏菜单**不参与关闭流程，永远是纯隐藏；红色关闭键按偏好走 ask/tray/exit。
5. **Windows 托盘右键「退出」**是显式退出意图，不弹确认，直接销毁窗口（与现状一致）。
6. **下载/播放中不额外加二次确认**：对话框内的「影响说明」已承担告知职责，避免两次弹窗。

## 现状与关键约束

| 平台 | 关闭路径 | 约束 |
|---|---|---|
| Windows | `flutter_window.cpp:93` 在**插件之前**拦截 `WM_CLOSE`：有托盘则 `ShowWindow(SW_HIDE)` 返回 0，window_manager 永远看不到关闭事件 | 关闭行为必须由**原生层**裁决，Dart 只能下发偏好；runner 目前没有任何 MethodChannel |
| macOS | `MainFlutterWindow.performClose` 重写为 `orderOut`（引擎常驻）；红色 caption 按钮与「隐藏窗口」菜单都走它；已有 `configure`（settingsAvailable）下发通道先例 | 退出需要绕过重写；`applicationShouldTerminateAfterLastWindowClosed` 固定为 false |
| 通用 | 设置在 `packages/core/lib/src/config/app_settings.dart`，异步加载（`appSettingsProvider` 为 FutureProvider），启动时原生层先于 Dart 拿到设置 | 存在启动竞态：设置加载完成前，原生层只能按默认（隐藏到托盘）行为响应关闭 |

## 设置层（packages/core）

`AppSettings` 新增字段，沿用现有 `toJson / fromJson / copyWith / validate` 模式：

- `String windowCloseBehavior`：`'tray'`（默认）| `'exit'`；`validate` 校验枚举值。
- `bool rememberWindowState`：默认 `true`。
- `String windowBounds`：持久化几何 `"x,y,w,h"`，默认空；校验为 4 个非负整数、宽 ≥ 400、高 ≥ 300、总长 ≤ 64；恢复时另行做屏幕可见性钳制（见风险）。
- `bool windowMaximized`：默认 `false`。

测试：`packages/core/test/settings_test.dart` 补枚举校验、非法 bounds 回退默认、copyWith 往返。

## 原生层

### Windows（`flutter_window.cpp` + 新通道 `hongguo/windows-window`）

1. runner 新增 MethodChannel（`OnCreate` 里 `RegisterPlugins` 之后注册），Dart→native 方法：
   - `hide`：`ShowWindow(SW_HIDE)`（托盘隐藏）；
   - `quit`：`DestroyWindow`。
2. native→Dart：通道就绪后置 `forward_close_ = true`；`WM_CLOSE` 分支改为——
   - `forward_close_` 为真：向 Dart 发 `closeRequested`（带当前托盘可用性），返回 0，**不做任何隐藏/销毁**，等 Dart 决策；
   - 否则（engine 未就绪/无控制器）：回退既有行为——有托盘则 `SW_HIDE`，否则走默认销毁流程。
3. 托盘右键「退出」保持 `DestroyWindow` 直退，不经过 Dart。

### macOS（`MainFlutterWindow.swift`）

沿用既有 `hongguo/macos-window` 通道：

- `setCloseBehavior`（`'ask' | 'tray' | 'exit'`，默认 `ask`）：存储到窗口成员；
- `performClose` 重写按偏好分派：`tray` → `orderOut`；`exit` → `NSApp.terminate`；`ask` → 通过通道向 Dart 发 `closeRequested`，自身不动；
- `hide` 方法与关闭**解耦**：直接 `orderOut`（「隐藏窗口」菜单与托盘语义保持不变）；
- 新增 `quit`：`NSApp.terminate`；
- 新增 `setRememberFrame(bool)`：开启时 `setFrameAutosaveName("HongguoMainWindow")` + `setFrameUsingName` 恢复；关闭时清除 autosave；
- 红色 caption 按钮改发 `close`（走偏好分派），tooltip 改「关闭窗口」；「隐藏窗口」状态栏菜单保持纯隐藏。

### 窗口状态恢复

- **macOS**：原生 autosave（见上），AppKit 自带多显示器裁剪，不经过 Dart 设置文件。
- **Windows**：用 window_manager（`packages/app` 已依赖）：
  - 启动：设置加载后 `setBounds` / `setMaximized`；
  - 持久化：注册 `WindowListener`，在 `onWindowMoveEnd` / `onWindowResizeEnd` / `onWindowMaximize` / `onWindowUnmaximize` 时防抖 500ms 读取 `getState()` 写回设置。

## Dart 接线（packages/app）

1. `DesktopWindow` 新增：
   - `applyPreferences({required WindowCloseBehavior behavior, required bool rememberWindowState})`：macOS 走 `MacWindow.invoke`，Windows 走新通道，移动/Web/测试环境吞 `MissingPluginException`（沿用现有模式）；
   - `hide` / `quit` 统一封装；
   - 入站 `closeRequested`：macOS 通道的既有 handler 由 RoutedApplication 独占，改为 `MacWindow` 内置入站分发（`onSettings` / `onCloseRequest` 回调），Windows 新通道独立注册 handler。
2. 新增 `WindowCloseCoordinator`（纯逻辑、可注入依赖，widget 测试无需通道）：
   - `resolve()`：按偏好分派 tray/exit/ask；`ask` 时弹确认对话框（`WindowCloseGate.navigatorKey` 的根 Navigator `showDialog`）；
   - 勾选记住时调 `saveSettings` 并重发 `applyPreferences`。
3. `WindowCloseGate`（MaterialApp.builder 内挂载）：初始化时恢复窗口几何（Windows），注册入站 handler，首次设置可用后下发 `applyPreferences`；设置变更（StreamProvider）时重发。
4. `rememberWindowState` 关闭时：清除已存 `windowBounds`/`windowMaximized`（写默认值），macOS 走 `setRememberFrame(false)`。

## 设置页 UI（`settings_page.dart`）

`_section('窗口行为', [...])`，条件与缓存目录一致：`desktopHost && !tvBuild`。控件均即时自动保存（沿用 themeMode 的 `saveSettings` 模式）：

- 「关闭按钮行为」：`SegmentedButton`（每次询问 / 最小化到托盘 / 退出程序）+ 辅助文案「每次询问：关闭窗口时弹出确认，可选择是否记住」；
- 「记住窗口位置和大小」：`Switch` + 辅助文案「重启后恢复上次的窗口位置、大小与最大化状态」。

## 执行顺序（每步独立可验证）

| 阶段 | 内容 | 验证 |
|---|---|---|
| P1 | core 设置字段 + 校验 + 测试 | `dart test`（core） |
| P2 | Windows runner 通道 + WM_CLOSE 分支 | Windows 实体机：关闭 → 托盘保留；切换为退出 → 进程结束、托盘消失 |
| P3 | macOS setCloseBehavior + frame autosave | macOS：两种关闭行为；重启恢复窗口位置/最大化 |
| P4 | DesktopWindow.applyPreferences + 状态跟踪 + bootstrap 接线 | `flutter test`（app，含吞异常路径）；防抖持久化单测（注入假 clock） |
| P5 | 设置页「窗口行为」分区 | widget 测试：桌面端可见、TV/移动不可见、切换后设置落盘 |
| P6 | 全量门禁 + 实体机清单 | 六包测试 + `dart format` + `flutter analyze`；Windows/macOS 手动清单（对齐 issue-001 验证格式） |

## 风险与取舍

1. **启动竞态**：设置异步加载完成前原生默认「隐藏到托盘」。选 `exit` 的用户在启动 1–2 秒内点关闭会先隐藏——在 P2/P3 里让 `setCloseBehavior` 成为一进 engine 就发的第一条消息，竞态窗口可忽略；不为它引入同步读文件。
2. **多显示器恢复**：Windows 侧保存的 bounds 在拔掉显示器后可能落在屏外；恢复前用 `screen` 信息钳制（窗口至少 50% 可见），macOS 交由 autosave 机制自带处理。
3. **退出语义与播放/下载**：`exit` 关闭时后台下载会被终止——辅助文案明确「退出程序会中断下载与播放」，不做二次确认弹窗（托盘右键退出已有先例，保持一致）。
4. **`WM_CLOSE` 双轨**：保持原生拦截优先于 window_manager 的 preventClose，不混用两套关闭裁决，避免回归 issue-001 中「关窗隐藏」的既有行为。
