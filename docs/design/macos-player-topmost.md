# Mac 播放窗口置顶

| 调整前 | 调整后 | 原因 |
|---|---|---|
| 播放窗口可被其他普通窗口覆盖 | 顶部操作浮层增加图钉开关，选中高亮并可取消 | 按需保持视频在前方 |
| 所有页面共用窗口层级 | 仅当前可见播放页生效，设置/列表恢复原层级 | 不影响日常浏览 |
| 系统小窗和全屏已有独立行为 | 主窗口在画中画和全屏期间暂停置顶，返回恢复用户选择 | 避免与系统窗口/空间切换竞争 |

通过公开 AppKit NSWindow.Level.floating 保持在其他普通应用窗口上方，不使用弹出菜单或屏幕保护级别，不覆盖系统安全窗口。开关仅保存当前播放页的偏好；切集保留，退出页面释放。设置往返保留偏好；隐藏或最小化仍可由用户主动执行。图钉按钮随播放操作浮层自动隐藏，鼠标移动后恢复，工具提示区分“窗口置顶”和“取消窗口置顶”。

## 验证（2026-10-21）

- 静态分析通过；144 项应用单元/组件测试通过，1 项条件跳过。新增可见播放页的置顶所有权、设置往返和旧页释放回归。
- 本机 Mac 原生集成用例通过：点击图钉后检查实际 NSWindow 浮动层级与 window_manager.isAlwaysOnTop；全屏、画中画暂停置顶且返回后恢复；设置往返保留偏好；手动取消/重新置顶；退出页面恢复初始层级。所有过程保留同一播放器。
- 使用本地加密视频测试样本经过现有解密与播放链路，无新增依赖或权限。

复现命令（在 packages/app 中）：

```sh
../../.fvm/flutter_sdk/bin/flutter test --no-pub
../../.fvm/flutter_sdk/bin/flutter test integration_test/offline_playback_test.dart -d macos --plain-name 'mac window close hides' --no-pub
../../.fvm/flutter_sdk/bin/flutter build macos --debug --no-pub
```
