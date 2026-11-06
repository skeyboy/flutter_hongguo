# macOS 侧的播放缓存审计（2026-11-03）

上一轮把 Windows 的「播放器持有句柄 → 发布失败」这一类问题按住了（`packages/api/lib/src/media_cache.dart` 的 Windows 句柄重试段，已随 `a36cf43` 入库）。本轮只回答一个问题：**同一类缺陷在 Mac 上是什么形状，Mac 上有没有 Windows 没有的形状**。

本轮**没有改任何代码**，只出建议与验证口径。下面每条都标了「已核实」（读到了行）与「需实机确认」（只能推断）。

## 结论摘要

| # | 风险 | 级别 | 口径 | 建议动作 |
| --- | --- | --- | --- | --- |
| M1 | macOS **Release 沙盒没有 `com.apple.security.network.server`**，边下边播的回环源起不来；而起不来会让整集准备失败 | 高（条件触发：用户打开关） | 已核实（权限文件 + 调用链），后果需 Release 实机确认 | ①把「起不来」降级成「不走捷径」；②再决定是否加权限；③门禁补一条 Release 构建的 Mac 探针 |
| M2 | 死会话留下的 `.part` 只有 `prune()` 会清，而冷启动路径上没有任何一处调 `prune()` | 中 | 已核实 | 启动恢复之后补一次回收 |
| M3 | `.part` 的实际字节不进 `maxBytes`/`cacheBytes()` 口径 | 中 | 已核实 | 定一个口径并在设置页说明，或计入 |
| M4 | Darwin 上「删掉仍被播放器持有的文件」是**静默成功**，播放器继续读旧 inode，而回环源按路径重开 | 低（并发窗口窄） | 部分推断 | 加一条 Mac 侧回归说明，语义写进注释，不改行为 |
| M5 | AppleDouble（`._x.mp4`）与 `.DS_Store` 在三个枚举循环里被当成缓存文件 | 低 | 已核实（全仓 0 处理） | 枚举统一跳过这两类名字 |
| M6 | iOS 相邻：缓存目录无 skip-backup 标记；投屏需要的 `NSLocalNetworkUsageDescription` 不在 plist | 低（不在本轮范围） | 已核实缺键 | 单独一轮 |

## M1：回环源在 Release Mac 上是「起不来 + 直接失败」

**读到的事实**

- 回环源绑的是沙盒受管听的地址：`HttpServer.bind(InternetAddress.loopbackIPv4, port)` — [progressive_stream_server.dart:118](../../packages/api/lib/src/progressive_stream_server.dart#L118)。
- macOS 两份权限文件不对称：`DebugProfile.entitlements` 有 `com.apple.security.network.server`（第 11 行），`Release.entitlements` 只有 `app-sandbox` + `network.client`。`network.server` 自仓库初始化（`4711d2d`）起就没动过，而回环源是最后一个功能提交 `10a969d` 加的——**加了监听端，没跟分发权限**。
- 调用链没有兜底：`server: await _openStreamServer()` 直接写在 `ProgressiveLane` 构造参数里（[media_cache.dart:555](../../packages/api/lib/src/media_cache.dart#L555)），异常落到 `_run` 的外层 catch，所有 lease 一起失败；`_openStreamServer` 的 `catchError` 只把 `_bindingServer` 复位（[:255-258](../../packages/api/lib/src/media_cache.dart#L255)），于是每一集都重试、每一集都失败。
- 这个开关在 macOS 是**能打开的**：入口只排除 TV（[runtime_native.dart:161](../../packages/app/lib/platform/runtime_native.dart#L161) 的 `!tvBuild`，[settings_page.dart:889-896](../../packages/app/lib/features/settings_page.dart#L889)），默认为关（`app_settings.dart:58`）。
- Mac 验收从未覆盖它：`localServerUsed` 在两处工装里是**硬编码 false**（[mac_poc_probe.dart:22](../../packages/api/bin/mac_poc_probe.dart#L22)、[macos_live_poc_test.dart:151](../../packages/app/integration_test/macos_live_poc_test.dart#L151)），而 `tool/verify_mac_live.sh` 跑的是 `flutter test -d macos`（Debug 构建，带着 server 权限）；`tool/verify_all.sh` 没有任何 mac 集成段；CI 只有 `build.yml` 的 `flutter build macos --release`，没有 macos-verify 工作流（`.github/workflows/` 下只有 build/release/windows-floating-probe/windows-verify）。
- 沙盒下监听 socket 需要显式声明这一点由 Apple 文档给出（「传入连接（Server）」对应 `com.apple.security.network.server`），未声明的运行时表现是 `Operation not permitted`。

**不确定的一点（要实机才能定性）**：沙盒对**仅绑 127.0.0.1** 是否也一律拒绝。多数报告是拒绝，但这条我不肯只凭印象写进结论。所以顺序应该是：先做与答案无关的加固，再用一次 Release 探针定性，最后决定要不要动分发权限。

**建议**

1. **降级优先于加权限**（无论探针结论如何都成立）：一个「起播更快」的优化不能把播放本身变成失败。`_openStreamServer()` 绑定失败时，本集按整文件路径走完（等价于该集没开这个开关），并把原因记进 timing，而不是把异常抛给 lease。
2. 探针转红之后再补 `Release.entitlements` 的 `network.server`。这条会改变分发姿态（监听端 = 攻击面），值得单独一次提交说明。
3. 工装侧：`localServerUsed` 改成实测值，`verify_mac_live.sh` 增加一条 **release 构建**的探针（至少 `flutter build macos --release` + 容器里跑一次开开关的准备）。

## M2：冷启动不回收死会话的 `.part`

`.part` 的回收只住在 `_reclaimOrphanPartials()`（[media_cache.dart:1056](../../packages/api/lib/src/media_cache.dart#L1056)），而它只被 `prune()` 调用；`prune()` 的三个调用点是配置变更（`configure`，[:426](../../packages/api/lib/src/media_cache.dart#L426)）、作业成功收尾（[:718](../../packages/api/lib/src/media_cache.dart#L718)）、启动恢复（`adoptDownloaded`，[:916](../../packages/api/lib/src/media_cache.dart#L916)）。启动路径只有台账里**有**待恢复项时才会间接触发（[runtime_native.dart:231](../../packages/app/lib/platform/runtime_native.dart#L231)，`restore()` 在 journal 目录不存在时直接 return）。用户只看已缓存剧集的一趟会话，可以一次都不跑。

历史读数不是假想：2026-10-28 那轮在用户 Release 容器里记到 30 个已发布 mp4（正好顶到 `maxCacheFiles`）之外还有 **65 个 `.part` 合计 1,202,790,313 B、`du -sh` 1.5G**（[findings.md 缓存目录读数](../../docs/evidence/mac-download-lane-2026-10-28/findings.md)）。本机现在没装这个 app（`~/Library/Containers/` 下无 `com.example.hongguoApp`），所以那是**当时的读数，不是今天的**。

**建议**：`createRuntime()` 恢复台账之后无条件走一次回收；窗口期一小时的判断保持不变。

## M3：两个体积口径

`prune()` 只列 `.mp4` 做预算（[:1007-1009](../../packages/api/lib/src/media_cache.dart#L1007)），`cacheBytes()` 同样只加 `.mp4`（[:1128-1134](../../packages/api/lib/src/media_cache.dart#L1128)）。传输中的密文工作副本不进任何口径——除了自动预缓存有 `_reserved` 在限流（[:521-528](../../packages/api/lib/src/media_cache.dart#L521)），手动下载按设计完全 exempt。设置页那句「这一集会临时占用约两倍空间」说的是单集，不是目录。

**建议**：不动预算语义（动了会伤手动下载），只做口径披露——缓存管理页显示「已发布 X / 目录实占 Y」。要不要做由你定。

## M4：Mac 上「换文件」是静默的，这才是 Darwin 那一半

Windows 那类失败在 Mac **不可能以同样形状出现**：POSIX 允许删/改仍被打开的路径，`_retryWhileHeld` 里的 `Platform.isWindows` 闸门是对的（[:778-788](../../packages/api/lib/src/media_cache.dart#L778)），注释里那句「macOS and Linux rename an open file freely」也站得住。Mac 侧真正剩下的是两件相反的安静事：

- 播放器握着旧 inode 继续放，磁盘名字已经指向新文件；此时若还有一个**按路径**重开的读者——回环源正是（每次请求 `File(path).open()`，[:60](../../packages/api/lib/src/progressive_stream_server.dart#L60)）——同一个会话会跨到另一个 inode。窗口很窄：边下边播发布后 lane 交给 pin 持有，而同 key 重发布要先有清单不匹配。
- 删掉但没关的文件不释放块，`prune()` 之后目录里看不见它，`cacheBytes()` 于是少报真实占用。

**建议**：这两件都不该改行为（改了会牵动 Windows 那侧刚定型的复用规则），但应把「Mac 的失败形状是静默换 inode，不是报错」补进那段注释，并加一条 Mac 语义的回归说明。属可选。

## M5：枚举里没有挡 macOS 的伴生文件

`prune()`（[:1009](../../packages/api/lib/src/media_cache.dart#L1009)）、`cacheBytes()`（[:1132](../../packages/api/lib/src/media_cache.dart#L1132)）、`clear()`（[:1168](../../packages/api/lib/src/media_cache.dart#L1168)）按后缀匹配，`._<key>.mp4`（AppleDouble，出现在 exFAT/网络卷上）会一起被计数，删的时候只删 `<key>.mp4.json`，`._` 兄弟永远留下；`.DS_Store` 匹配不到任何后缀，也永远留下。`entries()` 安全（要求名字与清单严格一致）。全仓对 `._`/`.DS_Store` 零处理（已 grep）。

生产路径在容器内的 APFS 上概率低，外接卷/网盘场景真实。**建议**：三个循环统一跳过 `._` 前缀与 `.DS_Store`，一行条件，无行为风险。

## 顺带排除的（Mac 上不用管的）

- 解密是纯 Dart、`FileMode.append` 单句柄、`finally` 里 `closeSync()`（`packages/core/lib/src/media/file_decryptor.dart:44-71`），无平台分支、无 FFI/通道；`hongguo_native.dart` 只是导出桶。
- `sleep()` 的微重试只在 Windows 走到，Mac 不会因此堵 isolate。
- 原生 PiP 交接给的是 `Uri.file(...)`（`playback_platform_native.dart:310-313`），且提前起播 URL 明确绕开 PiP（`player_page.dart:859` 的 `!keepPip`），所以 AVPlayer 拿不到 `http://127.0.0.1`；media_kit/libmpv 自己走 socket，不经 ATS。
- 投屏在桌面不显示入口：`castSupported()` 要求 `mobileHost`（[cast_service.dart:19-20](../../packages/app/lib/cast/cast_service.dart#L19)），`mobile` 只含 Android/iOS（runtime_native.dart:172），所以 `LanMediaServer` 绑 `0.0.0.0` 那件事与 Mac 无关（iOS 另说，见 M6）。

## 本轮没做的事

没有编辑任何文件（除本说明），没有跑构建。要动手的话，我建议的先后是：**M1 的降级 + M2 的启动回收 + M5 的枚举过滤**（三条都低风险、可单测覆盖），M1 的权限与 Release 探针作为第二步单独一轮，M3/M4 等口径决定。
