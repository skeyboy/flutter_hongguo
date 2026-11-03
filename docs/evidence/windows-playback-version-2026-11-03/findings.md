# 「Android 能播、Windows 报空包」的三版本取址对照 — Windows ARM64 本机只读读数（2026-11-03）

观众的报据是：Android mobile 实测能正常在线播放，Windows 显示「暂时无法播放 / 播放信息未返回数据，请稍后重试」。上一轮分析把嫌疑放在平台差异上（系统代理、时钟、libmpv 硬解、发布段文件句柄），本轮把这些逐个当场读掉，结论是**成因不在平台，在装的版本**。

驱动（同一台机器、同一个 vid `7701334783946673176`，三份 `git archive` 导出的 NTFS 临时树）：

| 树 | 驱动 | 起读时刻（UTC） | 读数 |
| --- | --- | --- | --- |
| `v0.3.20` | `dart run tool/probe_asks.dart` | 05:49:34 | [asks-v20.json](asks-v20.json) |
| `v0.3.22` | 同上 | 05:48:52 | [asks-v22.json](asks-v22.json) |
| HEAD `b980432`（= 已发布的 v0.3.23） | 同上 | 05:48:13 | [asks-v23.json](asks-v23.json) |

`probe_asks.dart`（[随本目录留样](probe_asks.dart)，未入库）照 App 实际会产生的取址形状打两批：同一进程级 `PlaybackDeviceRegistry` 先**连问 3 发**（对应观众按「重新准备」和自动连播），再**并发 4 路**（对应播放 + 预取 + 下载队列同时在问），每批发起时截一段交互日志。矩阵是 7 发，每一发内部还有 `playbackRetry()` 的首发 + 3 次恢复。

生产客户端的整链另跑三轮：`HONGGUO_PROBE_OUTPUT=win-$i.json dart run tool/probe_upstream.dart --recover --video` → [probe-upstream-win-1.json](probe-upstream-win-1.json)、[win-2](probe-upstream-win-2.json)、[win-3](probe-upstream-win-3.json)（05:45:17Z 起）。

探测匿名运行：不读会话、不下载媒体。记录里只有状态码、body 字节数、`definition`/`encrypted`/`checkedMediaUrl`/`contentKeyValid` 这类判定值，不含 token、Cookie、签名头本身、媒体地址、`key_seed` 或内容密钥。

## 观众侧那句话（当前树 `b980432` 的行号）

「播放信息未返回数据，请稍后重试」= `IncompleteCatalogResponse`，只有两个出处，都在取址这一跳：HTTP 200 但 body 为空（[video_model_client.dart:535](../../../packages/api/lib/src/video_model_client.dart#L535)），和信封里 `data` 为空（同文件 [:285](../../../packages/api/lib/src/video_model_client.dart#L285)）。本轮 v0.3.20 撞的是前一个。播放覆盖层在 `error != null` 时把它和「暂时无法播放」一起打在黑底上（[player_page.dart:1314](../../../packages/app/lib/features/player_page.dart#L1314)）。

## 结论：0/7 对 7/7，差的只是版本

| 树 | 7 发取址 | 取址 POST 的回答 |
| --- | --- | --- |
| `v0.3.20` | **0 / 7** | 每一发的首发加 3 次恢复全是 `200 / 0 字节`（原始日志 28 条空体回答；4 发并发共用同一窗口，去重后 16 条），逐字抛「播放信息未返回数据，请稍后重试」 |
| `v0.3.22` | 7 / 7 | `200 / 24213~24258 字节`，`definition: 1080p` |
| `v0.3.23` | 7 / 7 | `200 / 24253~24583 字节`，`definition: 1080p` |

成因在准入，与 Windows 无关：v0.3.20 的取址一跳是免签形状——`buildRequest` 只发 `User-Agent`/`Accept`/`Content-Type`，注释还写着「the anonymous one is what answers」（`v0.3.20:packages/api/lib/src/video_model_client.dart:133`）；而 11-02 起这一跳重新按签名准入，形状与逐条对照见 [playback-sign-restore-2026-11-02](../playback-sign-restore-2026-11-02/findings.md)。恢复这条链路的提交 `f41351c` 用 `git tag --contains` 核过：在 `v0.3.21`、`v0.3.22`、`v0.3.23`，**不在** `v0.3.20`（`git merge-base --is-ancestor f41351c v0.3.20` → no）。

发布时刻取自 GitHub Releases API：v0.3.20 `2026-11-02T05:02:18Z`、v0.3.21 `2026-11-02T13:27:18Z`、v0.3.22 `2026-11-03T03:43:50Z`、v0.3.23 `2026-11-03T04:43:36Z`。v0.3.20 出门到修复出门之间隔着 8 小时，观众的 Windows 包正落在那 8 小时里；Android 那台手机上的包晚于 v0.3.21，于是「一个能播一个不能播」。

取址与解码这两段在两个平台上是同一份纯 Dart：`packages/api`、`packages/core` 里没有任何 `Platform.is*` 分支，本轮全树唯一命中的那一处在发布段（[media_cache.dart:778](../../../packages/api/lib/src/media_cache.dart#L778)），不参与取址。所以上表在手机上同样成立。

处置：Windows 升级到 **v0.3.23**（`Hongguo-0.3.23-windows-x64-setup.exe`；App 内「设置 → 检查更新」，页脚显示当前版本）。最低可用是 v0.3.21；直接上 v0.3.23 的理由是 v0.3.22 还修了只有 Windows 会犯的发布段句柄问题（`a36cf43`），v0.3.23 修了并发取址烧光恢复预算的问题（`b2fb6ac`）。

## 顺手排除的三条 Windows 嫌疑（都是当场读数，不是推理）

- 系统代理：`HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings!ProxyEnable = 0`，进程环境里没有 `HTTP_PROXY`/`HTTPS_PROXY`。这条本来最有嫌疑，因为 Dart 的 `HttpClient` 只在桌面读环境代理、Android 不读。
- 时钟：本机 UTC 与外部 `Date` 头差 1 秒。`ts`/`_rticket` 这类时效参数不可能因为这种偏移被判过期。
- 解码与密钥：同一台机器三轮 `probe_upstream --recover --video` 全绿——`ok: true`、`definition: 1080p`、`encrypted: true`、`checkedMediaUrl: true`、`contentKeyValid: true`。片源地址解得开、内容密钥合法，坏的一直是「根本没拿到 `data`」。

## 一条与本轮预期相反的读数

10-30 那轮记的是「一个注册身份在 ≥8 秒窗口里只答一次，重放即 200/0」，`b2fb6ac` 照那个形状改成每次取址换新身份。本轮没能在这台机器上让那个形状复现：v0.3.22 整个矩阵只注册一次（去重后交互日志里 1 次 `device_register`、4 次带数据的取址 POST），后面 6 发全是重放同一个身份，照样每发带回 24xxx 字节；v0.3.23 同一天、同一台机器、同一个 vid 则是 4 次注册对 4 次 POST——并发那 4 路在日志里只留下 1 次注册加 1 次 POST，与「共用同一次在途注册、URL 逐字节相同因而被请求合并吃掉」这个既有机制相符，但本轮没有专门为它取数，算推断不算读数。

也就是说本轮测到的是「一次一抛」每发多付一次注册的代价，测不到它的收益。边界要说满：单轮、单 vid、7 发在两秒内打完、一台机器、一个下午；10-30 的原始读数本身就是「同一台机器时好时坏、按秒聚集」，这种抽样既不能证伪它，也只能说明此刻不成立。要判这条修复留不留，得换一个正在聚集的时段用同一份矩阵复跑。

## 缺口（别当已验）

- **Windows 的真实窗口播放至今没有任何读数**。README 里那行「已验收」写的是构建与门禁（[README.md:166](../../../README.md#L166)），托管 runner 起不了窗（[windows-verify-2026-10-30](../windows-verify-2026-10-30/findings.md)），本机 ARM64 又链不动 `media_kit_libs_windows_video`（它构建时只拉 `mpv-dev-x86_64-20230924`）。本轮全部证据止步于取址一跳的 HTTP 读数，没有走到下载、解密发布与出帧；发布段的句柄问题（errno 32）本轮**未复现**，只由 `a36cf43` 的两枚回归用例钉着形状。
- 若观众升到 v0.3.23 后仍然报同一句，那就回到聚集窗口这条线：先跑本目录的矩阵复测取址，再考虑把目前共用一句文案的三种失败拆开——取址空包、信封明确拒绝、发布段被播放器句柄挡住（[media_cache.dart:765](../../../packages/api/lib/src/media_cache.dart#L765)）。它们在屏幕上长得一样，这是当前真实存在的可诊断性缺口。
