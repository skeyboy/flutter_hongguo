# 取址重新签名与 `x-medusa` 的滚动字 — 线上只读探测读数（2026-11-02）

驱动：`cd packages/api && dart run tool/probe_playback_sign.dart 7701334783946673176 3 build/playback-sign-2026-11-02.json`（3 轮 × 3 形状），
再把 [packages/core/lib/src/crypto/pure_sign.dart:995](../../../packages/core/lib/src/crypto/pure_sign.dart#L995) 那一行在一次性 NTFS 克隆里注释掉、重跑两发（`... 2 build/playback-sign-frozen-di0.json`），改回来跑一发（`... 1 build/playback-sign-restored.json`）。
三份读数都是 2026-11-02 11:56 UTC；克隆里的 `pure_sign.dart` 与仓库文件在 A/B 前后逐字节比对过，只有那一行不同。

探测匿名运行：不读会话、不下载媒体；每发只做「注册一个设备身份 + 一次取址 POST」，记录里只有状态码、body 字节数、签名头数量、`_rticket`、分支号、`deviceId` 末 4 位，以及「信封有没有这一集的条数」——不含 token、Cookie、签名头本身、媒体地址、`key_seed` 或内容密钥。

## 观众侧那句话

「暂时无法播放 / 播放信息未返回数据，请稍后重试」仍只有两个出处，都在取址这一跳：HTTP 200 但 body 为空（[packages/api/lib/src/video_model_client.dart:550](../../../packages/api/lib/src/video_model_client.dart#L550)）和信封里 `data` 为空（同文件 [:296](../../../packages/api/lib/src/video_model_client.dart#L296)）。这次它是**全量、稳定**地出现：修前同一条请求无论怎么重试都是 0 字节，和 10-30 那次「同一台机器时好时坏」不是同一个病。

## 三发矩阵：签名头、query 字节、medusa 三样缺一不可

每发都先注册新身份，再对**同一个 URL 与同一个 body** 发三种形状（`production` = 当前代码；`escaped_star` = 只把 query 里的 `*` 换成 `%2A` 并重新滚动 `_rticket` 到分支 0 再签；`unsigned` = 去掉六个签名头，其余原样）。

| 形状 | 签名头 | query 里的 `*` | 分支 | 三发读数 |
| --- | --- | --- | --- | --- |
| `production` | 6 | 字面 `*` | 0 | `200 / 24209 / code=0 dataKeys=1 videoRows=5`、`200 / 24230 / 同`、`200 / 24217 / 同` |
| `escaped_star` | 6 | `%2A` | 0 | `200 / 0 字节`、`200 / 0`、`200 / 0` |
| `unsigned` | 0 | 字面 `*` | 0 | `200 / 0`、`200 / 0`、`200 / 0` |

即 2026-11-02 起这一跳重新按签名准入（`unsigned` 一律空包，10-27 起那条「注册身份 + 免签」的通道已经关掉），并且**校验的是收到的 query 字节**：同一个 body、同一套签名头，只把 `resolution=1280*2772` 的 `*` 按 RFC 3986 转义就变回空包。

## medusa：`hashF13` 分支 0 的扩展丢了滚动字

免签通道关闭后，签名必须逐字节对，此时 `x-medusa` 单独把这一跳打死。成因在移植时抄丢的一行：`hashF13` 分支 0 的消息扩展里 `di0` 被钉在 `di[0]`，112 轮里从不滚动，而线上接受的是「上一轮的 `di1` 滚动成下一轮的 `di0`」（等价于 `di[i] + di[i+9] + r1 + r2`）。`x-gorgon` 走的是 MD5 那条路径，不受这段扩展影响——这也解释了为什么只有 medusa 一处不对。

同一条代码路径做 A/B（注释掉 [pure_sign.dart:995](../../../packages/core/lib/src/crypto/pure_sign.dart#L995) 的 `di0 = di1;` 再原样重跑）：

| 运行（UTC） | `di0 = di1;` | `production` 读数 |
| --- | --- | --- |
| [playback-sign-frozen-di0.json](playback-sign-frozen-di0.json) 11:56:34 | 注释掉 | `200 / 0 字节`、`200 / 0`（`escaped_star`、`unsigned` 也全为 0） |
| [playback-sign-restored.json](playback-sign-restored.json) 11:56:53 | 恢复 | `200 / 24447 / code=0 dataKeys=1 videoRows=5` |

诊断阶段另有一组「只换 medusa 的头」的对拍（Dart 其余头 + 参考 JS 的 `x-medusa` → `200 / 0`；反向 → `200 / 24252`），当时用一次性 Node 脚本发出、未入库，结论与上表一致：出问题的只有这一个头。

## 整条链路：仓库里就有的只读探针

`HONGGUO_PROBE_OUTPUT=build/probe-20261102-a.json dart run tool/probe_upstream.dart --recover --video`（11:59:01Z，[probe-20261102-a.json](probe-20261102-a.json)）走的是生产客户端：浏览 58056 字节 → 详情 101471 字节 → 注册 384 字节（免签）→ 取址 POST **22674 字节**，`ok: true`、`episodes: 96`、`definition: 1080p`、`encrypted: true`、`checkedMediaUrl: true`、`contentKeyValid: true`、`mediaDownloaded: false`。同一次运行里 `themes` 那一发先 `200 / 0`（免签配置）、随后带签名的一发 19438 字节——与 10-30 记过的目录侧抖动同形状，不由本轮改动解释。

## 分集扫与那句服务异常

对 6 个历史上取到过片源的 vid 各发一次真实 `VideoModelClient.fetchTrack`（含恢复、身份轮换、内联列表与回退第二跳，不下载媒体）：3 个 `ok`——`7701334783946673176`（`1080p / 11114845 字节`，首发 843ms 命中，未动用恢复；连问三发同结果）、`7701334740283952152`（`16866879`）、`7700601650137812030`（`14200645`）；`7701332919490448409`、`7697273659248872472`、`7702094159468842009` 三集稳定回 `200 / 176 字节`、`code=101000 message=服务异常`、`data` 为空。这一类带明确业务码的信封按既有约定归 `PlaybackUnavailable`，观众侧那句是「这一集暂时不能播放，请稍后重试或换一集」，不是本轮修的「播放信息未返回数据」。同一集连问三次不变答复（`7701332919490448409` 于 11:45Z 三连发，861/1353/1131ms 各一次就停），换一集就正常——是上游按集给的答复，本轮没有理由也没有改动它的分类。这轮分集扫用的是当时的临时脚本、未入库；能在仓库里复现的等价入口是上一节的 `probe_upstream.dart --recover --video` 与 `probe_playback_sign.dart`。

## 离线对拍跟着改的部分

`packages/core/test/fixtures/node_oracle.json` 的 31 个分支 0 样本原本把「钉死 `di0`」的参考实现当基准，改完 `hashF13` 后全部对不上，且差集只有 `x-medusa`（逐头计数：`{'x-medusa': 31}`，其余头与 `spade`/`url`/`ctr` 段逐字节不变）。处理方式在生成器里：[tool/generate_oracle.cjs](../../../tool/generate_oracle.cjs) 的 `withRolledHashF13()` 在执行前把这一处补上，`sourceSha256` 仍然钉未打补丁的文件（`3186e62…`，与 `references/hongguo-web` `3841835` / package 1.1.5 一致），所以 `tool/check_upstream_protocol.py` 的上游漂移门禁照旧有效——补丁记在我们这边，不假装上游改了。参考实现若哪天自己修好，`withRolledHashF13` 直接返回原文，不叠加。

## 离线套件

在 NTFS 一次性克隆里跑（本机 ARM64 不适合原生构建，纯 Dart 套件在 C: 盘克隆执行）：[core-tests-20261102.log](core-tests-20261102.log) `+125 All tests passed!`、[api-tests-20261102.log](api-tests-20261102.log) `+139 All tests passed!`。core 那 125 项含重新生成后的 96 个签名样本；本轮改动文件的 `dart format --set-exit-if-changed` 退出码 0，`dart analyze` 对本轮文件无问题（两个包各剩一条 info 属在途的渐进下载工作）。

## 边界

- 本轮只覆盖取址这一跳的形状与 medusa。题材/详情/搜索等带签名链路本来就正常，未改动它们的准入。
- 目录类接口不校验 `x-medusa`（这条是从「丢了滚动字仍能返回 36–60KB」反推的观测，不是协议声明），所以这个缺陷直到签名重新生效才暴露。
- 注册请求的 UA 仍是 `com.phoenix.read/72232`、body 的 `version_code` 是 `73932`，与取址跳自己的 `71532` UA 是第三套；三者各自被各自那一跳接受，参考实现 1.1.6+ 只对齐了前者，本轮不动。
- 线上读数只证明 2026-11-02 当天这几个 vid、这台机器上的准入形状，不能外推到任意账号、网络或全部受限内容。
