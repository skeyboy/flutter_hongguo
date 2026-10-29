# Windows 悬浮窗真机探针（2026-10-29）

本机读数：Windows 11 `10.0.26100.4349`、**ARM64**、Flutter `3.47.8 stable` / Dart `3.13.7`、工作树 HEAD `f4321e7`。上一轮分析在一台 Mac 上做，结论里写着"这台机器是 macOS，Windows 侧只能到 CI 编过为止"，并建议先做一次真机探针。本轮就是那次探针，结论是**本机探针跑不起来**，且原因与播放实现无关。

## 探针命令与结果

```
flutter test integration_test -d windows --name "desktop picture in picture restores playback and occlusion does not pause"
```

窗口从未创建，构建阶段即失败。原始日志见 [arm64-integration-test.log](arm64-integration-test.log)（该文件是运行输出的尾部 60 行，含全部 22 条链接错误）：

```
media_kit_video_plugin.dll : fatal error LNK1120: 22 个无法解析的外部命令
..\..\libmpv\libmpv.dll.a : warning LNK4272: 库计算机类型“x64”与目标计算机类型“ARM64”冲突
..\..\ANGLE\lib\libEGL.dll.lib : warning LNK4272: 库计算机类型“x64”与目标计算机类型“ARM64”冲突
..\..\ANGLE\lib\libGLESv2.dll.lib : warning LNK4272: 库计算机类型“x64”与目标计算机类型“ARM64”冲突
```

未解析符号全部来自 `mpv_*` 与 `egl_*/gl*`，即 `media_kit_video` 的 `angle_surface_manager.obj` 与 `video_output.obj`。根因是 `media_kit_libs_windows_video-1.0.11` 只提供 x64 导入库；Flutter 侧没有绕过的余地：

- `flutter_tools/lib/src/base/os.dart:155` 用 `Abi.windowsArm64 => HostPlatform.windows_arm64` 定档，取的是 Dart VM 自身 ABI，环境变量改不动。
- `flutter_tools/lib/src/windows/build_windows.dart:174-175` 只有 `windows_x64 => 'x64'` / `windows_arm64 => 'ARM64'` 两个映射，`flutter build windows` 不接受 `--target-platform`（`docs/evidence/mac-download-lane-2026-10-28/findings.md:45` 已经踩过一次：`Could not find an option named "--target-platform"`）。

已安装的正式版仍在运行：`C:\Users\lee\AppData\Local\Programs\Hongguo\hongguo_app.exe`（最后写入 2026-10-29 01:06），它是 x64 包，靠 Windows on ARM 的 emulation 跑。**能跑 ≠ 能造**：这台机器可以验证用户侧行为，不能产出可运行的本地 Windows 构建。

## 已经拿到的正面证据

mac 系统画中画的前提是"存在已解密的本地 MP4"。上一轮只能从 `MediaCache` 无平台门推断，本轮在本机直接读到产物：

```
%APPDATA%\com.example\hongguo_app\media-cache
30 个 *_best.mp4，合计 140M，时间戳 2026-10-29 16:24–16:45

00000000: 0000 001c 6674 7970 6973 6f6d 0000 0200   ....ftypisom....
00000010: 6973 6f6d 6973 6f32 6d70 3431 ...          isomiso2mp41...

7682274981752867864_best.mp4.json：
{"version":1,"size":8105492,"vid":"7682274981752867864","quality":"best"}
```

`ftyp isom/iso2/mp41` 是标准 MP4 容器而非密文；数量 30 与 `maxCacheFiles` 上限一致，和 mac 那轮记录（`mac-download-lane-2026-10-28/findings.md`）同形。**Windows 侧的解密产物已经在产出，缺的只有原生落点。**

## 覆盖面缺口

| 位置 | 实际执行内容 |
|---|---|
| `.github/workflows/windows-verify.yml:28` | `flutter test`（单元测试），无 integration_test |
| `.github/workflows/windows-verify.yml:31` | `flutter build windows --release`，只编译 |
| `.github/workflows/build.yml` windows 段 | build + `package_desktop.py`，无测试 |

全仓没有任何流水线跑过 `integration_test -d windows`。也就是说桌面 `else` 分支（`playback_platform_native.dart` 的 `window_manager` 路径）**从未在 Windows 上执行过**，尽管测试自己写着 `if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) return;`（`offline_playback_test.dart:1175`）。本轮新增 `.github/workflows/windows-floating-probe.yml`（手动触发、windows-2022 x64、上传日志）专门补这一格；先不做成 PR 门禁，因为 runner 是否有可用桌面会话尚未验证。

## 本轮改动

| 文件 | 改动 |
|---|---|
| `packages/app/lib/platform/background/playback_platform_native.dart` | 桌面 `else` 分支：小窗尺寸由写死的 `520x340` / `300x500` 改为按 `player.state` 真实比例取值（长边 520 逻辑像素，短边不足 200 时等比放大，不拉伸画面）；新增 `setAlignment(Alignment.bottomRight)` 贴到工作区右下角 |
| `packages/app/lib/platform/background/host_policy.dart` | Windows/Linux 的悬浮播放说明改为"按片源比例缩小，置顶到屏幕角落" |
| `packages/app/integration_test/offline_playback_test.dart` | Windows/Linux 分支补断言：外框宽高比等于片源比；右缘与底缘不小于原窗对应边。旧代码保持原位置只缩小，右缘会比原窗少约 760 像素，这两条会失败 |
| `docs/design/platform-background.md` | 能力表把 macOS 与 Windows/Linux 拆成两列；此前 macOS 的系统画中画被写成"窗口缩小并置顶" |
| `docs/platform-background.md` | 悬浮播放条目与实现表拆分 macOS / Windows·Linux，并写明后者不是系统画中画 |
| `.github/workflows/windows-floating-probe.yml` | 新增手动探针 |

`setAlignment` 的角落计算走 `window_manager-0.5.2/lib/src/utils/calc_window_position.dart`，它用 `visibleSize`/`visiblePosition` 并且按光标所在显示器取屏，因此避开任务栏、多显示器下跟随当前屏。长边取 520 是为了保住既有断言 `mini.width <= 525`。

刻意没做的一件事：用 `getTitleBarHeight()` 把标题栏高度补偿进去。`window_manager.cpp:931` 取的是 `WM_GETTITLEBARINFOEX` 的 `rcTitleBar`，单位是**物理像素**，而 `setSize` 经 `SetBounds`（`window_manager.cpp:742`）按 `devicePixelRatio` 把逻辑像素换成物理像素；两者直接相加在高 DPI 屏上会过量补偿，Linux 侧单位又未经验证。本机无法构建运行，无法验证任何需要真机读数支撑的补偿，因此外框按比例、内部保留少量黑边是当前能诚实交付的形态。

## 本机验证到什么程度

| 检查 | 结果 |
|---|---|
| `flutter analyze --no-pub` | `No issues found!`（117.9s） |
| `dart format`（改动文件） | `Formatted 2 files (0 changed)` |
| `flutter test test/capability_preferences_test.dart test/background_settings_test.dart test/macos_window_test.dart` | `+8 All tests passed!` |
| 悬浮窗真实外观、置顶是否生效、贴角是否避任务栏 | **未验证**，需要 x64 Windows 上跑 `windows-floating-probe.yml` |
