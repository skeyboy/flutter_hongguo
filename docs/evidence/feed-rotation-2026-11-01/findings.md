# 首页每次启动都是同一页 — landpage 的确定性与冷启动续位（2026-11-01 探测，2026-11-02 定方案）

驱动（全部匿名只读，不读会话、不下载媒体，输出只有条数、ID 与重合数）：

```
cd packages/api
../../.fvm/flutter_sdk/bin/dart run tool/probe_feed_rotation.dart                 # 同参数、filter_ids、另一档排序、session_id
../../.fvm/flutter_sdk/bin/dart run tool/probe_feed_rotation.dart --offset 18     # 续位那一发落在哪
../../.fvm/flutter_sdk/bin/dart run tool/probe_landpage_depth.dart                # 列表能走多深
../../.fvm/flutter_sdk/bin/dart run tool/probe_feed_rotation.dart --windows 20     # 第一轮那个开关，2026-11-02 已从脚本与客户端撤掉
```

留样（`--windows` 那两份是第一轮的对照，机制已换，读数仍然成立）：

- [probe-baseline-windows0.json](probe-baseline-windows0.json) / [同名 log](probe-baseline-windows0.log)：`startupWindows=0` 那一组。
- [probe-windows20-launch1.json](probe-windows20-launch1.json)、[probe-windows20-launch2.json](probe-windows20-launch2.json)：同一脚本、两个独立进程，各带 `--windows 20`。
- [probe-depth.json](probe-depth.json)：offset 90/360/900/2000/5000 的窗口读数。
- [probe-first-pass.json](probe-first-pass.json)：本轮最早那一发的读数（当时脚本还没有 `--windows`，字段名不同）。
- [probe-session-20261102.json](probe-session-20261102.json) / [同名 log](probe-session-20261102.log)：2026-11-02 的 `session_id` 读数（numeric 与 uuid 两种写法）。
- [probe-resume-offset18.json](probe-resume-offset18.json) / [同名 log](probe-resume-offset18.log)：同一天的 `offset=18` 续位读数。


## 观众侧那句话

发现页每次启动都是同一批剧。链路上有两个嫌疑：本地快照，和上游本身。

| 假设 | 读数 | 结论 |
| --- | --- | --- |
| 上游按设备/会话给不同推荐 | 同一个匿名身份、同一请求体连发两次：`sameParamsIdenticalOrder: true`，`overlapWithAsk1.sameParams: 18`（18/18 同序）。`hot_score` 与 `online_time` 两档各自连发都是这个结果。2026-11-02 又量了 `session_id`（[probe-session-20261102.json](probe-session-20261102.json)）：换成随机数字 `numericSession: 18`、换成 UUID `uuidSession: 18`、两种 session 之间 `betweenSessions: 18`，与空串完全同页 | 否。这一跳对相同请求是确定性的，且不认 `session_id`；参考实现也是固定发空串（[client.js:1132](../../../references/hongguo-web/server/src/service/client.js#L1132)） |
| 再等一会儿，顶端页自己会换 | 昨天 12:37 两个间隔 36 秒的独立进程：顶端 18/18 相同。今天 02:03 与 02:18 两个进程的顶端首行分别是《太姑奶奶驾到》《富贵见孝心，千金归来掌家业》——同一个固定 deviceId，间隔 15 分钟就换了页 | 会换，但稳定窗口只夹在「36 秒」与「15 分钟」之间，本轮没有二分到位。「让客户多等一会儿再看」不是能交付的方案 |
| `filter_ids` 是「这些看过了，换一批」的开关 | [probe-baseline-windows0.json](probe-baseline-windows0.json)：`filterIdsInterpretation: "上游 re-sent the already-shown page; the client filtered it out"`。填了 18 个已展示 ID 后客户端回 0 条，但响应给的 `next_offset` 仍然走到 18——上游发回来的还是那一页，0 条是 [catalog.dart 的 `seen` 去重](../../../packages/api/lib/src/catalog.dart)造成的 | 否。参考实现确实把已展示 ID 填进这一字段（[client.js:1126](../../../references/hongguo-web/server/src/service/client.js#L1126)，由 :1052 的 landpage 问话调用），但它自己的注释也只把这当作翻页重叠区的去重（[web/app.js:390](../../../references/hongguo-web/web/app.js#L390)）而不是换内容的开关；线上读数是上游照旧回同一页，所以这个字段换不动内容 |
| 只有本地缓存造成 | 快照 <30 秒免刷新确实存在（[library_page.dart:936-942](../../../packages/app/lib/features/library_page.dart#L936-L942)），但把它绕开之后，网络回来的还是同一页 | 一半。免刷新让快速重启字面意义上复用同一次读数，根子却在请求参数 |
| `offset` 换得动内容，且换得起 | [probe-depth.json](probe-depth.json)：offset 90/360/900/2000/5000 每档都回满 18 条，与首页重合 `0`；样本标题（《我被亲戚误会破产了》《折栀入怀》《手握三十万死士，请陛下退位》）都是正常剧目 | 是。窗口是唯一杠杆，而且列表很深 |

## 第一轮（API 层随机窗口）的读数——机制已于 11-02 撤掉，读数仍然成立

两个独立进程、各 `--windows 20`（= 两次启动）：

| 读数 | launch1 | launch2 |
| --- | --- | --- |
| 顶端页（不滚）| 18 条，`cursor=18` | 18 条，`cursor=18` |
| 滚动窗口第 1 发 | 18 条，`cursor=144` | 17 条，`cursor=288` |
| 滚动窗口第 2 发 | 18 条，`cursor=270` | 17 条，`cursor=90` |
| 与顶端页的重合 | `rolledWindow: 0` | `rolledWindow: 0` |
| 两次滚动之间 | `roll1VsRoll2: 0` | `roll1VsRoll2: 0` |
| 首行标题 | 《一杯毒酒，贵妃入豪门》 | 《我嫁谁，谁才是大哥》 |

`cursor` 是响应的 `next_offset`，反推起始 offset = `cursor - 18`，即窗口 7、14、15、4——两次启动落在不同窗口，同一进程内两次刷新也不落在同一个窗口。对照组 `--windows 0` 里 `rolledWindow` 与 `roll1VsRoll2` 都是 18（不滚就还是同一页），所以换内容的确实是这个开关，不是上游自己在动。

launch2 的两发是 17 条：那一窗里有一行没有可用的 `series_id`（或与同窗重复），被 `_browse` 的取数条件丢掉。窗口本身照样是满页上游响应，客户端少画一行，不是空窗。

## 2026-11-02：为什么把随机窗口换掉，换成什么

用户的意见是「这种 API 的方式不是十分合理」。回看确实有三条不合理：

1. 随机 offset 是**客户端凭空发明的位置**——那一列按 `online_time` 排，顶端就是最新的一批，随机跳到第 7 窗等于把新的藏起来；
2. 状态藏在 `CatalogClient` 内部（`_lastWindow`），同一个客户端两次同参数问话会回不同的请求，破坏「参数定 = 请求定」这条让整个缓存/在途合并/重试都对得上的性质；
3. 没有落盘记忆，跨启动仍有 1/20 撞窗，而落盘又只是把随机改成 remembered random，仍然解释不了「为什么是这一窗」。

参考实现自己给了正统做法（[client.js:1046-1048](../../../references/hongguo-web/server/src/service/client.js#L1046-L1048)）：「**关键：offset 必须从已展示条数起步，否则上游每次都回第一页**」。所以现在的方案是把它原本用给翻页的规则，用到冷启动这一次问话上——位置来自这个 feed 自己的历史，不是抽签。

**现在落地的是两处，`packages/api` 回到「参数定 = 请求定」**：

1. [packages/api/lib/src/catalog.dart](../../../packages/api/lib/src/catalog.dart) — `startupWindows` / `windowDraw` / `_rollWindow` / `_lastWindow` 全部删除，`browse(cursor:)` 是纯透传；只保留 `sessionId`（默认空串 = 逐字节同旧请求），因为它是协议字段且上面那条 `session_id` 读数必须能被复现。
2. [packages/app/lib/features/library_page.dart](../../../packages/app/lib/features/library_page.dart) — 冷启动与下拉刷新的第一发用快照里**已经落盘的** `nextCursor` 起步，并把当前屏的 ID 作为 `seen` 一起带上（上游不认 `filter_ids`，客户端去重兜底）；这一发被去重清空时退回顶端再问一次；存储位置超过 90 行（约 5 屏）时不再续位，直接问顶端——这就是自然回卷，顶端正是最新内容。搜索列表没有「位置」可言，由 `query` 守卫排除。
3. 上一轮的 `force: true` 保留：磁盘快照只负责第一帧不空白，启动必须问到网络上。

续位为什么可用，同一天的实测：`offset=18` 那一发回满 18 条、`cursor=36`、与顶端重合 **0**（[probe-resume-offset18.json](probe-resume-offset18.json)）——上游翻页是连续无缝的，所以「接着上次的行号往下走」确实落在没见过的内容上。

## 诚实边界

- 上游的 0 字节节流仍在：launch2 的顶端页第一发就是 `IncompleteCatalogResponse`，第二发才成功（见 [probe-windows20-launch2.log](probe-windows20-launch2.log)）。探测脚本每一发最多试 5 次、每次之前等 3 秒，表里的读数是重试后拿到的成功发。产品侧不受影响：位置是调用方给定的 `cursor`，`NetworkRetry` 重发的是同一请求体，不会在同一次启动里改位置。
- 90 行（约 5 屏）这个界是**产品取舍**，不是协议边界：走完一轮就回顶端，为的是「顶端 = 最新的一批」不至于永远看不见。上游实测在 offset 5000 还能回满页，所以这个界不是被列表长度逼出来的。
- 内容池会在两次启动之间变动（今天的顶端页 15 分钟里就换过）。续位是按行号走的，上端插入新剧会让行号整体位移：位移回来的重复行由随请求一起发出的 `seen` 去重吃掉（少画一行），跳过的一两行看不出来。这是「按位置走」相对「按内容走」的固有代价，本轮接受。
- 上游顶端页的稳定窗口只夹在「36 秒」与「15 分钟」之间，没有二分到位；本轮不依赖它。
- 搜索那一支靠 `_resumeCursor` 里的 `query` 守卫排除，没有页面级测试（要点开搜索框打字才走到）；TV 的两个 feed 页面（`tv_feed_page.dart`、工作区里未提交的 `tv_library_page.dart`）没有接续位，本轮只改手机/桌面共用的 `library_page.dart`。
- 本轮没有实机截图验收：改动在「冷启动那一发的 offset」这一跳上，页面绘制没动。运行侧证据是上面的线上读数与 [network_cache_behavior_test.dart](../../../packages/app/test/network_cache_behavior_test.dart) 里的三条：续位（`cursor=18`、`seen=[1]`）、空答复回卷到顶端、越过 90 行直接问顶端。`packages/api` 侧没有新增测试——`catalog.dart` 回到了 HEAD，翻页/续位的原有断言（`catalog_retry_test.dart` 的「list 503 then success retains requested cursor, size and seen IDs」）就是「参数定 = 请求定」这条性质的守卫。
- `packages/app` 全量页面测试里 `tv_feed_test.dart` 有 3 条失败，属于工作区中另一份未提交的 TV 改动：把 HEAD 的干净 worktree 只换上 `packages/app/lib/features/tv/tv_library_page.dart` 就能复现同样 3 条（`search stays pinned…`、`theme cache displays…`、`a late first-page refresh…`），本轮改的文件都不在那条链路上（该测试用的是 `FakeCatalog`，不发真实 landpage 请求）。

## 门禁读数

钉住的 SDK（`.fvm/flutter_sdk`）跑，2026-11-02 换方案后重跑的读数（11-01 那一版的 api 115 / app +401 是含 6 条窗口测试时的状态）：

| 命令 | 2026-11-02 读数 |
| --- | --- |
| `packages/api`：`dart test` | 109 通过（第一轮的 6 条窗口测试随机制一起删除） |
| `packages/app`：`flutter test`（整包） | +403 通过、~1 跳过、−3 失败（就是上面那三条 TV 用例；纯 Dart 的 `dart test` 跑不了页面测试，会报 `dart:ui` 不可用，必须用 `flutter test`） |
| `packages/app`：`flutter test test/network_cache_behavior_test.dart` | 7 通过，含新的三条续位测试 |
| 根 `dart format --output=none --set-exit-if-changed packages tool` | 276 个文件、0 需改（277 → 276 就是那条被删掉的窗口测试） |
| 根 `dart analyze --fatal-infos` | 退出码 2，1 条告警：未提交的 `packages/app/integration_test/tv_live_data_test.dart:14` 有无用 import。该文件与它 import 的 `tv_library_page.dart` 都属于工作区里另一份 TV 改动，本轮没碰；HEAD 上这个文件还不存在，所以门禁变红不是本轮造成的 |

