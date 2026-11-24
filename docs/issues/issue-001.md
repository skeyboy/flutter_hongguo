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
| 1 片源失败 | **bug 修复** | 取源层的 `StateError('No compatible media URL/key')` 被 `PlaybackFailure.classify` 判成 `localMissing`，用户看到「本地缓存读不出来」；TV 错误卡片直接用 `error.toString()`。另：Dart 3.47 起 `HandshakeException` 不再是 `SocketException`，Dio 把它包成 `type=unknown`，重试逻辑跳过、用户只看到原始异常 | 新增 `sourceRejected` 与 `tlsHandshake` 分类；TV 卡片接入 classify；握手失败纳入元数据与下载的一次有界重试 | 已完成，测试通过 |
| 2 缓存目录 | **优化** | `MediaCache.directory` 在 `NativeRuntime` 构造时写死 `${root}/media-cache`，`AppSettings` 无路径字段，`MediaCache.configure` 不支持换目录 | 新增 `cacheDir` 设置项 + 选目录入口；启动时按配置解析目录，改目录提示重启生效 | 已完成，测试通过 |
| 3 便携版数据 | **优化** | `createRuntime` 只用 `getApplicationSupportDirectory()`，Windows 由 EXE `VERSIONINFO` 的 `CompanyName=com.example` + `ProductName=hongguo_app` 拼出 AppData 路径；便携 ZIP 无标记文件也无切换分支 | 新增便携标记检测 + 数据根解析，覆盖 settings/缓存/下载 journal/更新暂存；Windows 便携打包写标记 | 已完成（Windows 实体机待验） |
| 4 任务栏/最小化 | **建议**（大部分已具备） | Windows 已有任务栏与托盘图标（原生 `IDI_APP_ICON`、`Shell_NotifyIconW`），macOS 有状态栏；缺统一窗口控制入口，播放页桌面按钮仅 macOS 有 | 抽出 `DesktopWindow` 统一封装 minimize/maximize/hide/show，Windows/Linux 播放页补齐按钮；窗口偏好开关列为后续 | 已完成，测试通过 |

## 条目 1：视频无法播放 / 无法获取片源（bug 修复）

### 现状

取源已是官网直链 → App 签名 → 旧接口三层（`video_model_client.dart:424-478`），今天刚补齐 CDN 302 逐跳白名单（`fff0415`）。失败卡片按九类异常给文案（`playback_failure.dart`）。

### 确定的错误分支

- `selectTrack` 在所有候选都过不了白名单/解密时抛 `StateError('No compatible media URL/key')`（`video_model_client.dart:832`）。这在**取源阶段**发生，却被 `PlaybackFailure.classify` 的 `error is StateError` 分支（`:97-104`）归为 `localMissing`，提示「本地这份缓存读不出来了 / 离线播放只认本地文件」——对联网取源失败是误导，且 `retryable=false` 让用户看不到重试按钮。
- TV 播放页错误直接传 `error?.toString()`（`player_page.dart:1820`），绕开分类，TV 用户看到原始异常文本。
- 「签名失败」「业务码 110001 授权失败」目前只进入详情字符串，没有独立文案类；让用户无从判断该重试还是该反馈。

### 方案

1. `PlaybackFailureKind` 增 `sourceRejected`：`StateError` 且消息含 `No compatible media URL/key` / `media URL` → 「片源地址不被支持」，可重试，建议换清晰度或升级版本。
2. 其它 `StateError`（本地缓存文件缺失）保持 `localMissing`。
3. TV 错误卡片改传 `PlaybackFailure.classify(error!).headline`，保留「详情」由原文本承担。
4. 业务码 `110001` / HTTP 403 这类授权失败的识别留在 `noSource.detail`，文案里明确「可能是上游授权变化」，避免误判为本地问题。

### 补充：TLS 握手被中断（`DioException [unknown]`）

用户随后报出 `DioException [unknown]: null / Error: HandshakeException: Connection terminated during handshake`。根因不在取源协议，而在异常层次：Dart 3.47 的 `HandshakeException extends TlsException implements IOException`，**不是** `SocketException`；Dio 的 IO adapter 只 catch `SocketException`，于是握手失败落到通用分支变成 `DioExceptionType.unknown`，真实原因藏在 `error.error`。结果：`NetworkRetry.transient` 不认它（不重试），`PlaybackFailure.classify` 只给通用「网络这边断了」，详情里是一串原生异常文本。

处理：

- `network_retry.dart` 新增 `isHandshakeFailure(Object)`，穿透最多四层 `DioException.error` 识别 `HandshakeException`；`NetworkRetry.transient` 把它列为瞬时故障（一次有界重试）。证书校验失败（`CertificateException`）刻意不重试——同一条不受信的链重问多少次都不会变好。
- `playback_failure.dart` 新增 `tlsHandshake` 分类：「加密连接没建立起来 / HTTPS 握手被中断，并不是片源失效。检查代理/VPN、系统时间和网络安全软件，换个网络再重试。」保留重试按钮。
- `media_cache.dart` 的逐跳下载循环同样加一次握手重试（握手发生在首字节之前，代价极小），避免偶发代理/CDN 抖动直接变成播放失败。
- 这是**连接层**修复，不能替代真网验证：若代理/安全软件持续切断握手，重试也救不回来，文案已引导用户换网络。

### 补充 2：只有前几集能播（2026-11-24 macOS 真网定位）

人工反馈「每个影视资源只能播放前几集」。用两部剧（`7710254424689495065` 45 集、`7701332919490448409` 30 集）在 macOS 上逐集探测，**分水岭都是第 6 集**，不是随机失败。

| 层 | 第 1/4/5 集 | 第 6 集及以后 |
|---|---|---|
| 官网 `/player/{series_id}` | `accessible_episode_cnt=5`，`vid_list` 是**全集**（45/30 个 vid），`contentUrl` 指向 `/video/public/{vid}/360p.mp4` | 同上，页面不缺 vid |
| 官网 `/api/video/protected/fallback-play-info` | 第 1 集 200 + `main_url`；第 4/5 集该接口 403，但另一路 ld+json 仍给出直链 | **403 `public_fallback_unavailable`** |
| `/video/public/{vid}/360p.mp4` | 206，可播 | **404** |
| App `multi_video_model/v1`（b/a/c 三主机、production/escaped-star/unsigned 三种形态、每次新注册） | **HTTP 200 / 0 字节** | **HTTP 200 / 0 字节** |
| 旧接口 `multi_video_model/preload/v1` | **HTTP 200 / 0 字节** | **HTTP 200 / 0 字节** |
| 最终 `fetchTrack` | `fromWeb=true`，正常下载出帧 | `IncompleteCatalogResponse: 播放信息未返回数据` |

结论（按证据排除）：

- **不是解析问题**：`vid_list` 含全集，index/vid 传递无错位；`accessible_episode_cnt` 被解析但从未被消费，所以 UI 也不知道「只有前 5 集可播」。
- **不是签名问题**：把六头签名去掉、把 `1280*2772` 的字面 `*` 改成 `%2A`、换 a/b/c 三台主机、每次换全新注册身份，App 层仍然稳定返回 200/0 字节——第 1 集也是 0 字节。签名偏差会表现为全量失败，不会整齐地卡在第 6 集。
- **不是鉴权/cookie 问题**：参考库播放链路同样是匿名的，设备池模式还会主动删掉 `cookie`/`x-tt-token`；当前 App 层空包与登录态无关。
- **真正根因**：上游官网只放前 `accessible_episode_cnt=5` 集；App 取址链路（当前签名的 `multi_video_model/v1` 与免签 `preload/v1`）此刻对所有 vid 都回空包，导致「限免前缀之外没有任何一层能接住」。这是上游协议/准入变化，客户端三层 fallback 的调度顺序本身正确。

用户另外贴出的 `DioException [bad response]: 302` 是**另一条下游症状**：`media_cache._downloadFollowingRedirects` 关掉了自动跳转，遇到 302 且响应没有 `Location` 或超过 5 跳时会把原始异常抛出去。当前失败集在取源阶段就停了，还没走到下载，所以 302 不是「前几集」边界的原因。

下一步（按优先级）：

1. 移植 8.0 的 App 层端点轮换与 v5 签名族（`video_tab`、`player/v1` b/a、`video_model/v1` a/c），这是让限免之外集恢复播放的唯一已知路径；见 [8.0 后端分析](../analysis/2026-11-23_hongguo-drama-API后端分析.md) §2.2–2.3。参考库 `references/hongguo-web` 1.1.x 仍是旧协议，不能直接照抄。
2. 把 `accessible_episode_cnt` 落到 `Episode`/UI：前 5 集正常展示，之后标注「当前来源不可播」，避免用户逐集试错；失败文案改成「上游未返回这一集取址数据，重试未必有效」。
3. 把本轮 `episode_boundary_probe` 收敛成常驻诊断工具，以后上游再变时一条命令区分「限免边界 / 签名 / 空包 / CDN 跳转」。

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
| `packages/api`: `dart test` | 191 通过（含握手重试与下载重试） |
| `packages/cast`: `dart test` | 52 通过 |
| `packages/update`: `dart test` | 37 通过 |
| `packages/app`: `flutter test` | 522 通过（含新分类、便携根、桌面控制 facade） |
| `packages/tv`: `flutter test` | 38 通过；app TV flavor 设置面 1 通过 |
| `python3 -m unittest discover -s tool/ci/tests` | 10 通过 |
| `dart format --set-exit-if-changed` | 0 处需改动 |
| `flutter analyze`（六包 lib） | 3 项既有告警，本轮无新增 |

macOS 本机额外验证（2026-11-24）：

| 检查 | 结果 |
|---|---|
| `flutter build macos --config-only` 与 integration 的 Debug 构建 | 均成功；仅 SPM 兼容性提示 |
| 本地真实 TCP 断开 TLS 握手 | `DioExceptionType.unknown`、内层 `HandshakeException`、`isHandshakeFailure=true`、`transient=true`、第二次调用成功（`build/verification/local-handshake-result.txt`） |
| `mac_poc_probe.dart --prepare`（真网） | catalog 14 → 45 集 → `fromWeb=true`、`v26-hgweb.qznovelvod.com`、360p → 本地 9,705,474 字节（同上目录 `mac-handshake-probe.log`） |
| 构建出的 `Hongguo.app` 启动 | 桌面出现「红果剧场」窗口，pid 26602 |
| `verify_mac_live.sh`（真窗口集成测试） | 未能通过：`Error waiting for a debug connection`，App 构建成功但测试框架无法附加；非播放失败，本轮未拿到出帧断言 |

仍需真机/真网（本轮环境做不到，不要当成已验证）：

- 真网取源：`./tool/verify_mac_live.sh SERIES_ID VID`、`packages/api/bin/mac_poc_probe.dart`；离线 mock 不能证明官网直链当前仍有效。
- Windows 实体机：便携 ZIP 解压后 `PORTABLE` 被识别、设置写入 `<EXE>/HongguoData`、安装版仍写 AppData、托盘三步（关窗/单击/右键退出）、播放页新增的最小化/最大化/隐藏按钮。
