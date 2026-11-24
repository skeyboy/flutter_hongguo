# issue #1：全网为数不多的 flutter 红果播放器，还需完善

- 来源：https://github.com/skeyboy/flutter_hongguo/issues/1
- 分析日期：2026-11-24
- 基线：`fff0415`（取源三层化 + CDN 逐跳白名单已落地）

## 原始诉求

1. 视频无法播放了，无法获取片源。
2. 缓存目录无法单独设置目录，默认保存在 `AppData\Roaming\com.example` 目录了。
3. 便携版用户设置也保存在 `AppData\Roaming\com.example` 目录，而不是程序目录内。
4. 任务栏图标、最小化开关等；参考 flutter 的 bilibili 端，还有许多可改进之处。

## 分类与结论总表

| 条目 | 分类 | 根因 | 处理 | 状态 |
|---|---|---|---|---|
| 1 片源失败 | **bug 修复** | 取源层的 `StateError('No compatible media URL/key')` 被 `PlaybackFailure.classify` 判成 `localMissing`，用户看到「本地缓存读不出来」；TV 错误卡片直接用 `error.toString()`，无分类文案 | 新增 `sourceRejected` 分类；TV 卡片接入 classify；补分类测试 | 已完成，测试通过 |
| 2 缓存目录 | **优化** | `MediaCache.directory` 在 `NativeRuntime` 构造时写死 `${root}/media-cache`，`AppSettings` 无路径字段，`MediaCache.configure` 不支持换目录 | 新增 `cacheDir` 设置项 + 选目录入口；启动时按配置解析目录，改目录提示重启生效 | 已完成，测试通过 |
| 3 便携版数据 | **优化** | `createRuntime` 只用 `getApplicationSupportDirectory()`，Windows 由 EXE `VERSIONINFO` 的 `CompanyName=com.example` + `ProductName=hongguo_app` 拼出 AppData 路径；便携 ZIP 无标记文件也无切换分支 | 新增便携标记检测 + 数据根解析，覆盖 settings/缓存/下载 journal/更新暂存；Windows 便携打包写标记 | 已完成（Windows 实体机待验） |
| 4 任务栏/最小化 | **建议**（大部分已具备） | Windows 已有任务栏与托盘图标（原生 `IDI_APP_ICON`、`Shell_NotifyIconW`），macOS 有状态栏；缺统一窗口控制入口，播放页桌面按钮仅 macOS 有 | 抽出 `DesktopWindow` 统一封装 minimize/maximize/hide/show，Windows/Linux 播放页补齐按钮；窗口偏好开关列为后续 | 已完成，测试通过 |

## 条目 1：视频无法播放 / 无法获取片源（bug 修复）

### 现状

取源已是官网直链 → App 签名 → 旧接口三层（`video_model_client.dart:424-478`），今天刚补齐 CDN 302 逐跳白名单（`fff0415`）。失败卡片按七类异常给文案（`playback_failure.dart`）。

### 确定的错误分支

- `selectTrack` 在所有候选都过不了白名单/解密时抛 `StateError('No compatible media URL/key')`（`video_model_client.dart:832`）。这在**取源阶段**发生，却被 `PlaybackFailure.classify` 的 `error is StateError` 分支（`:97-104`）归为 `localMissing`，提示「本地这份缓存读不出来了 / 离线播放只认本地文件」——对联网取源失败是误导，且 `retryable=false` 让用户看不到重试按钮。
- TV 播放页错误直接传 `error?.toString()`（`player_page.dart:1820`），绕开分类，TV 用户看到原始异常文本。
- 「签名失败」「业务码 110001 授权失败」目前只进入详情字符串，没有独立文案类；让用户无从判断该重试还是该反馈。

### 方案

1. `PlaybackFailureKind` 增 `sourceRejected`：`StateError` 且消息含 `No compatible media URL/key` / `media URL` → 「片源地址不被支持」，可重试，建议换清晰度或升级版本。
2. 其它 `StateError`（本地缓存文件缺失）保持 `localMissing`。
3. TV 错误卡片改传 `PlaybackFailure.classify(error!).headline`，保留「详情」由原文本承担。
4. 业务码 `110001` / HTTP 403 这类授权失败的识别留在 `noSource.detail`，文案里明确「可能是上游授权变化」，避免误判为本地问题。

### 不在本轮

上游协议是否再次变更、官网直链是否仍有效、v5 签名族与端点轮换是否需要启用，都需要显式真网探测（`./tool/verify_mac_live.sh SERIES_ID VID`、`packages/api/bin/mac_poc_probe.dart`），离线单测不能证明。参见 [上游 API 维护说明](../analysis/2026-10-21-upstream-api-maintenance.md) 与 [8.0 后端分析](../analysis/2026-11-23_hongguo-drama-API后端分析.md)。

## 条目 2：缓存目录可单独设置（优化）

### 现状

`runtime_native.dart:145-146` 写死 `Directory('${root.path}/media-cache')`；`AppSettings` 无缓存路径字段；设置页「缓存管理」只有数量/上限/清理。

### 方案

- `AppSettings` 增 `cacheDir`（默认空）：加入 `toJson` / `fromJson` / `copyWith` / `validate`（长度 ≤1024、无换行/NUL）。
- `NativeRuntime` 构造接收可选 `cacheDirectory`，默认沿用 `${root}/media-cache`；`createRuntime` 在 `store.load()` 之后按 `settings.cacheDir` 解析，空或无效回退默认。
- 设置页「缓存管理」加目录选择行（PC/移动可用，TV 保守隐藏），用已有 `file_picker` 的 `getDirectoryPath`，文案写明「更改后需重启应用，已有缓存不自动迁移」。
- `NativeDownloads.restore` 的媒体缓存定位从硬编码 `${root}/media-cache/$filename` 改为注入的 cacheDirectory，避免换目录后后台任务找不到文件。

### 取舍

运行期直接换目录需要处理正在播放/预缓存的文件与正在写的 journal，风险大于收益；选择「保存设置 + 下次启动生效」，并在 UI 明示。老缓存保留，用户可自行清理，不做静默迁移。

## 条目 3：便携版用户设置保存在程序目录（优化）

### 根因

`createRuntime()` 唯一入口是 `getApplicationSupportDirectory()`。Windows 上 `path_provider_windows` 读 EXE `VERSIONINFO` 的 `CompanyName` / `ProductName` 拼出 `%APPDATA%\com.example\hongguo_app`（见 `windows/runner/Runner.rc:92-118`）。便携 ZIP 与安装版共用同一 EXE，没有标记文件，也没有「数据根目录」抽象。`CompanyName` 不能直接改，否则已有用户的数据会失联（`docs/design/application-name-localization.md:26`）。

### 方案

1. 新增 `app/lib/platform/data_root.dart`：
   - `portableMarkerPath` 固定为 EXE 同目录的 `PORTABLE`（Windows）/`portable` 文件；
   - `appDataDirectory()`：检测到标记文件 → `<EXE 目录>/HongguoData`，否则 `getApplicationSupportDirectory()`；
   - 解析结果缓存，避免每次读盘；
   - 便携根创建失败（只读目录等）回退 support 目录并返回警告，不让应用起不来。
2. `createRuntime`、更新暂存目录 `stageDirectoryFor` 改用 `appDataDirectory()`；`NativeRuntime` 把 `download-journal` 也放进同一根。
3. Windows 便携打包 `tool/ci/package_desktop.py` 的 zip 阶段写入 `Hongguo/PORTABLE`；Inno Setup 安装版不带标记，数据仍进 AppData。
4. `AppSettings.dataRoot` 只读展示（从 runtime 暴露），设置页显示当前数据目录与是否便携模式。
5. 会话凭据仍走系统 `flutter_secure_storage`（Windows DPAPI），便携时不随目录搬走；文档明确这一点，避免「整包搬走即登录态也跟着走」的误解。

## 条目 4：任务栏图标 / 最小化开关（建议，大部分已具备）

### 现状

- Windows：`app_icon.ico` 已是窗口/`IDI_APP_ICON` 任务栏图标，`flutter_window.cpp` 已有托盘、`WM_CLOSE` 隐藏不退出、单击恢复、右键退出（`packages/app/README.md:23-33`）。
- macOS：`AppIcon.appiconset` + `NSStatusBar` 菜单栏；隐藏标题栏后自绘 caption 提供隐藏/最小化/全屏三个按钮。
- 缺口：桌面端控制能力散落在 `MacWindow.invoke` 与 `window_manager` 两处；播放页浮层按钮只对 macOS 显示，Windows/Linux 用户没有同样入口；设置页无「窗口行为」分区。

### 方案

1. 新增 `desktopWindow` 统一封装：`minimize()` / `toggleMaximize()` / `hide()` / `show()` / `restore()`，macOS 走 `hongguo/macos-window` channel，其余桌面走 `window_manager`，Web/移动为 no-op；plugin 缺失时吞掉异常便于 widget 测试。
2. 播放页浮层在 `desktopHost` 下提供最小化与隐藏按钮（macOS 保留置顶），键名沿用 `hide-player-window` 并新增 `minimize-player-window`。
3. 任务栏图标本身已由原生资源提供，无需新增依赖；不当作缺陷处理。
4. 后续建议（未落地）：设置页「窗口行为」分区——关闭时最小化到托盘 / 退出、记住最大化状态、任务栏角标；需要跨端偏好持久化与原生 `WM_CLOSE` 联动，单独排期。

## 验证清单

2026-11-24 在 macOS / Flutter 3.47.4 实测：

| 命令 | 结果 |
|---|---|
| `packages/core`: `dart test` | 140 通过（含 cacheDir 持久化与注入校验） |
| `packages/api`: `dart test` | 187 通过 |
| `packages/cast`: `dart test` | 52 通过 |
| `packages/update`: `dart test` | 37 通过 |
| `packages/app`: `flutter test` | 521 通过（含新分类、便携根、桌面控制 facade） |
| `packages/tv`: `flutter test` | 38 通过；app TV flavor 设置面 1 通过 |
| `python3 -m unittest discover -s tool/ci/tests` | 10 通过 |
| `dart format --set-exit-if-changed` | 0 处需改动 |
| `flutter analyze`（六包 lib） | 3 项既有告警，本轮无新增 |

仍需真机/真网（本轮环境做不到，不要当成已验证）：

- 真网取源：`./tool/verify_mac_live.sh SERIES_ID VID`、`packages/api/bin/mac_poc_probe.dart`；离线 mock 不能证明官网直链当前仍有效。
- Windows 实体机：便携 ZIP 解压后 `PORTABLE` 被识别、设置写入 `<EXE>/HongguoData`、安装版仍写 AppData、托盘三步（关窗/单击/右键退出）、播放页新增的最小化/最大化/隐藏按钮。
