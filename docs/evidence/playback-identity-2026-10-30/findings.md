# 取址空包的聚集窗口与身份轮换 — 线上只读探测读数（2026-10-30）

驱动：
`cd packages/api && ../../.fvm/flutter_sdk/bin/dart run tool/probe_upstream.dart --recover --video`（`HONGGUO_PROBE_OUTPUT` 逐个落到本目录，修前 6 连发 + 1 发、修后 6 连发）、
`dart run tool/probe_identity.dart --rounds 8`、
`dart run tool/probe_refusal_matrix.dart --asks 3 --series 3`，
实机为 `./tool/verify_mac_live.sh 7701332919490448409 7701334783946673176`。
探测匿名运行：不读会话、不下载媒体；交换记录只有状态码、body 字节数和「这一发是否带签名」（以请求头里有没有 `x-argus` 判据），不含 token、Cookie、签名头、媒体地址、`key_seed` 或内容密钥。

## 观众侧那句话是从哪一跳抛的

「播放信息未返回数据，请稍后重试」只有两个出处，都在取址这一跳：HTTP 200 但 body 为空/信封缺失（[packages/api/lib/src/video_model_client.dart:271](../../../packages/api/lib/src/video_model_client.dart#L271)），以及信封里 `data` 为空数组（同上 [:525](../../../packages/api/lib/src/video_model_client.dart#L525)）。它属于 `IncompleteCatalogResponse`，播放器覆盖层在 `error != null` 时把「暂时无法播放」和这句原文一起打在黑底上（[packages/app/lib/features/player_page.dart:1263](../../../packages/app/lib/features/player_page.dart#L1263)），下面是「重新准备」。

## 排除法：三条都不是，剩下聚集窗口

| 假设 | 读数 | 结论 |
| --- | --- | --- |
| 视频数据解码坏了 | 修前修后所有带回 `data` 的运行都是 `definition: 1080p`、`encrypted: true`、`checkedMediaUrl: true`、`contentKeyValid: true`（下表 5 个 `ok:true` 运行，无一例外） | 否。有问题的是「根本没拿到 data」，不是拿到后解不开 |
| 上一个能播的版本之后代码回归 | `git diff --name-only v0.3.9..HEAD -- packages/api` → 只有 `media_cache.dart` 与其测试（下载车道那一轮）；`video_model_client.dart`、`playback_device.dart`、`network_retry.dart` 在提交历史里自 `v0.3.9` 未动 | 否。取址链路的代码与 10-28 发版时一致 |
| 某个注册身份被平台拉黑 | [identity-alternating-8.json](identity-alternating-8.json)：同一个共享身份连问 8 发 `8/8` 全带回 data；每发换一个新身份 `7/8`（第 1 发空包） | 否。身份不是决定项，新身份不比旧身份更容易被拒 |
| 某一集被平台明确拒绝 | [refusal-matrix-1.json](refusal-matrix-1.json)：3 部剧 × {首集/中集/末集} = 9 个 vid，每个连问 3 次，`27/27` 全部带回 data，且都带 `code: 0` 信封 | 否。不是内容维度的永久拒绝（那类走 `PlaybackUnavailable`，一句就停） |

剩下的形状是**时间窗内的聚集**：07:27 那一轮（修前），4 次走到取址的尝试里有 3 次各自连发 3 个 HTTP 200 + 0 字节（合计 9 个空包），而**同一次运行里**取址之前的带签名浏览/详情正常返回 36–60KB，同一进程、同一 IP、同一秒级时间窗。也就是说这一跳的准入是按窗口给的，而我们的恢复没有离开那个窗口——旧配置在约 1.3 秒内重发**逐字节相同**的请求（同一个进程级注册身份、同一个 body），等于把同一个问题原样再问两遍。

进程级身份共享的位置：[packages/app/lib/platform/runtime_native.dart:117](../../../packages/app/lib/platform/runtime_native.dart#L117) 构造唯一一个 `PlaybackDeviceRegistry`，[:218](../../../packages/app/lib/platform/runtime_native.dart#L218) 起把它注入取址客户端（[:221](../../../packages/app/lib/platform/runtime_native.dart#L221)），[:138](../../../packages/app/lib/platform/runtime_native.dart#L138) 又把 `fetchTrack` 挂成下载车道的 `resolve`——一次会话里的每次取址都问同一张身份证。

## 修前：一次注册，三发逐字节相同的空包

`R` = 注册响应（355/380/384 字节，免签），后面的数字 = 取址 POST 的 body 字节数。

| 运行（UTC） | 结果 | 取址尾部序列 |
| --- | --- | --- |
| [probe-20261030-a.json](probe-20261030-a.json) 07:22:06 | `ok:true`，30 集 | `R` → **22854**（首发命中） |
| [probe-1.json](probe-1.json) 07:27:09 | `ok:false`，`IncompleteCatalogResponse` | `R` → **0 → 0 → 0** |
| [probe-2.json](probe-2.json) 07:27:18 | `ok:false` | `R` → **0 → 0 → 0** |
| [probe-3.json](probe-3.json) 07:27:24 | `ok:false`，没走到取址 | —（在带签名的浏览/详情跳就 3 发全空） |
| [probe-4.json](probe-4.json) 07:27:31 | `ok:true`，30 集，`1080p` | `R` → **22652**（首发命中） |
| [probe-5.json](probe-5.json) 07:27:38 | `ok:false`，没走到取址 | —（同上） |
| [probe-6.json](probe-6.json) 07:27:45 | `ok:false` | `R` → **0 → 0 → 0** |

07:27 那一轮：走到取址的 4 次里 1 次首发命中、3 次把三次尝试全部烧在空包上。这 3 次在观众侧就是「播放信息未返回数据」。

## 修后：拒绝即换身份，窗口拉长到 5 秒以上

| 运行（UTC） | 结果 | 取址尾部序列 |
| --- | --- | --- |
| [after/probe-1.json](after/probe-1.json) 07:51:20 | `ok:true`，30 集，`1080p`，`contentKeyValid:true` | `R` → **22753** |
| [after/probe-2.json](after/probe-2.json) 07:51:24 | 没走到取址 | —（题材跳 3 发全空，属带签名那一侧的抖动） |
| [after/probe-3.json](after/probe-3.json) 07:51:31 | `ok:false`，没走到取址 | —（同上，带签名详情跳 3 发全空） |
| [after/probe-4.json](after/probe-4.json) 07:51:38 | `ok:true`，30 集 | `R` → **22654** |
| [after/probe-5.json](after/probe-5.json) 07:51:44 | `ok:true`，30 集 | `R` → **22713** |
| [after/probe-6.json](after/probe-6.json) 07:51:56 | `ok:true`，30 集 | `R`(384) → **0** → `R`(380) → **0** → `R`(384) → **22666** |

- 修后凡是走到取址的运行都拿到了 data（4/4）；修前是 1/4。
- probe-6 是这条修复的直接证据：**空包 → 重新注册 → 再空 → 再注册 → 第三发带回 22666 字节**。这一发的整体耗时也留下了痕迹——它和上一发的时间戳相差 12 秒，而修前的三连发是在 1 秒多点内打完的。
- 两次修后失败（probe-2、probe-3）都没发出 POST：它们死在带签名的题材/详情跳。本轮没有改那条链路的准入条件，不能算作本修复的反例，也不在本轮成果里。

## 改了什么

| 变更 | 位置 | 说明 |
| --- | --- | --- |
| 取址这一跳的恢复窗口 | [packages/api/lib/src/video_model_client.dart:190](../../../packages/api/lib/src/video_model_client.dart#L190) `playbackRetry()` | 3 次恢复，等待 700–900ms / 2000–2300ms / 4000–4500ms（合计 ≥5 秒，带抖动）；默认 deadline 从 12 秒放宽到 20 秒（[:175](../../../packages/api/lib/src/video_model_client.dart#L175)）。目录请求保持原来的 3 发/1.3 秒不变 |
| 被拒就换身份 | 同上 [:235](../../../packages/api/lib/src/video_model_client.dart#L235)；[packages/api/lib/src/playback_device.dart:81](../../../packages/api/lib/src/playback_device.dart#L81) `rotate()` | 恢复被挪进注册之后：首发仍复用进程已持有的身份；一旦这一跳回了空包，下一次尝试先重新注册再用新 `device_id`/`iid` 提问。`rotate()` 带 `refusedDeviceId` 核对，并发的恢复只会多花一次注册，不会各注册各的 |
| 按错误类型给恢复次数 | [packages/api/lib/src/network_retry.dart:109](../../../packages/api/lib/src/network_retry.dart#L109) | 「必要字段缺失」类（`IncompleteCatalogResponse`）才用配置的全部恢复；传输/服务端失败仍只 1 次恢复，新增 `maxRecoveries`（默认 2）不改变其他调用方的旧行为 |

明确没改的：`PlaybackUnavailable`（信封里带业务码、`status_code` 或空 entry 的明确拒绝）依旧一次就停——那不是窗口问题，重复请求不改变答案。

## 实机 macOS 单集验收（带窗口，同一轮）

[macos-live-playback.log](macos-live-playback.log)：`00:07 +1: All tests passed!`，`ok:true`、`nativeDart:true`、`localServerUsed:false`；《湾区女子图鉴》第 1 集（`seriesId 7701332919490448409`、`vid 7701334783946673176`），本地片源 11,195,297 字节，出帧 1080×1920、时长 172,800ms，seek 目标 10,000ms 落在 10,000ms，音轨识别为已存在，帧数据 1,495,024 字节，`prefetchedEpisodes: 0`。走的是 App 自己的装配链路（注册 → 免签 POST 取址 → 选流 → 下载 → 本地解密播放）。

## 离线回归与门禁读数

- `cd packages/api && dart test test/playback_device_test.dart test/video_model_client_test.dart` → `00:00 +32: All tests passed!`。新增断言：恢复第二次提问的 `device_id` 与第一次不同且 `rotations == 1`；首发命中不产生额外注册（`rotations == 0`）；`playbackRetry()` 有 3 段等待、`maxRecoveries == 3`、总散布 ≥5000ms；`rotate()` 在身份已被别的恢复换掉时直接采纳、两个并发 `rotate` 合计只多一次注册。
- 全量离线各包：core、api、update、cast 的 `dart test` 与 tv、app 的 `flutter test` 退出码均为 `0`（本轮实跑）。
- `dart analyze --fatal-infos` 在本轮改动范围内干净。工作树里仍有**不属于本轮**的两处待收口：`packages/api/tool/rank_sample.dart:422` 的 `The method 'rank' isn't defined for the type 'CatalogClient'`（发现/榜单那路在途工作），以及 `packages/app/integration_test/theme_rail_live_test.dart`、`packages/app/test/desktop_fakes.dart`、`packages/app/test/discover_desktop_layers_test.dart` 三个文件的格式漂移。因为 `tool/verify_all.sh` 第 12 行的整树格式检查和第 13 行的 `--fatal-infos` 分析都会因此退出非 0，本轮**没有**一份退出码 0 的 `verify_all.sh` 总读数可报。本轮确实收到过一次「该后台任务退出码 0」的通知，但那份任务的输出文件（`b8dix9vyy.output`）只有 9 行，全是 `Changed …` 加 `Formatted 252 files (8 changed)`，停在这一步没有后续分析或测试输出；同一条检查本轮稍后重跑的真实退出码是 `1`。以输出文件为准，不采信通知里的自报退出码。

## 与参考实现的偏离（记下来，别当成已同步）

参考子模块 `references/hongguo-web` 在 1.1.6 之后把注册的 `REGISTER_UA` 从 `com.phoenix.read/72232` 对齐到 `73932`（与 body 里的 `version_code 73932` 一致），并加了注册失败冷却与 `resetPlaybackDevice`。Dart 侧本轮**没有**跟进：注册这一跳每次实测都是 200 / 355–384 字节，没有可归因的失败；而把 `tool/upstream_protocol.json` 的钉推进到 1.1.8 需要重新生成 `packages/core/test/fixtures/node_oracle.json`（1.1.8 的重构动了 `pure-sign.js`），那是单独一轮更大的同步。

## 结论的边界

- probe-6 只证明「轮换 + 更宽的窗口」这个**组合**把一次原本会失败的取址救回来了；线上读数无法把「换了身份」和「多等了 5 秒」这两项各自的作用分离开。
- 修后仍有取址之外的空包聚集（题材/详情跳）。本轮改善的是取址这一跳的自恢复，不构成上游可用性保证，也不覆盖带签名链路。
- 同一 `vid` 的并发取址仍然只发一份请求：`fetchVideoInfo` 以 `video:$vid` 为键共用在途结果（[packages/api/lib/src/video_model_client.dart:198](../../../packages/api/lib/src/video_model_client.dart#L198)），清晰度选择走的是同一份信息，不额外发 POST。因此本轮改动的作用范围是**恢复那几发**，不是首发数量；一次操作里真正各自成发的是不同 `vid`（连播预取、切集）。
- 所有读数都是本机、当次、匿名请求，不证明任意账号、网络或全部受限内容可访问。
