# 上游 hongguo-web 1.3.5 鉴权签名与编解码对齐方案

日期：2026-11-25
上游：`sunnysky123/hongguo-web` @ `c8b6c61e`（v1.3.5，compare 基线 `3841835` / v1.1.5，ahead 67 commits）
目标：对比上游「核心逻辑更新」，修正当前 Flutter 项目在**鉴权签名 / 视频编解码 / 加密解密**上的实际差距。

## 0. 结论先行：可执行 / 不可执行二分

| 类别 | 项目 | 判定 |
|---|---|---|
| ✅ 真缺口 | BVC2（bytevc2）片源识别与播放拦截 | 当前会把 BVC2 交给播放器 → 黑屏无提示；上游 `stream.js:287-325` 有检测 |
| ✅ 可执行 | 空响应恢复：`video_tab` 签名 GET + `player/v1` gzip 回退 | 当前仅 preload 免签回退，缺上游两级恢复 |
| ✅ 加固 | key 自证改多探测样本、NAL 接受 Annex-B、spade 真值对拍 | 低风险，对齐 `mp4.js:789-845` / `spade.js:116-141` |
| ✅ 元数据 | 新增 `tool/upstream_protocol_1_3_5.json` 记录 1.3.5 核心文件 sha256 | 不覆盖现有 1.1.5 pin（oracle 基线），避免破坏漂移门禁 |
| ❌ 不可移植 | `thl-sign.js` v5 便携签名器（307KB vendor IIFE） | 上游明言手工移植会被判 HTTP 200 + 0 字节；纯 Dart 复刻成功率低 |
| ❌ 不引入 | 551 Argus/Ladon (`playback-sign.js`) | 上游当前未在用（11-11 引入、11-16 被 v5 取代），移植无收益 |
| ❌ 不引入 | ffmpeg / librempeg 转码 / ffprobe 三重校验 | Electron 服务端特有，`2026-11-23` 分析已定调 Flutter 端不引入 |
| 保持 | legacy 六头 `PureSign` | 与上游 `pure-sign.js` 逐字段同源（96 固定向量）；上游注册/搜索仍用；field 21=312 已对齐 |

## 1. 上游更新了什么（与本次相关的部分）

上游 67 提交里，与鉴权/编解码相关的核心变更：

- 新增 `server/src/core/thl-sign.js`（505 行，文件 307KB）：内嵌 `never88gone/THLRedGuo` 的便携 App 签名器 IIFE（GPL-3.0-only），产出播放三头 `x-khronos`/`x-helios`/`x-medusa`。上游注释明确：**手工移植的 v5 medusa 被判无效，整条 packet/extract/embed 封装必须一致**。
- 新增 `server/src/core/playback-sign.js`（276 行）：551 Argus + Ladon，11-11 引入、11-16 被 v5 取代，当前未在 `app-source.js` 的 require 列表中。
- 大改 `pure-sign.js`（+193/-123）、`mp4.js`（+275/-44）、`app-source.js`（+530/-111）、`stream.js`（+179/-270）。
- 取流链路演进（README:805-856）：b 域 `multi_video_model/v1` 六头 → 551 → a 域 `player/v1` gzip 三头 → 最新 a 域 `video_model/v1` 明文 POST + 三头（thl-sign）+ `video_tab` 空响应恢复。
- `stream.js:287-325`：新增 BVC2 文件识别（`bv2C` / `bvc2` / `vvc1` / `vvi1`），缓存命中也拒绝 BVC2，避免交给 `<video>` 黑屏。

## 2. 当前项目实际状态（agent 交叉核对）

### 2.1 签名认证

- 唯一实现：`packages/core/lib/src/crypto/pure_sign.dart`（1410 行），legacy 六头，96 固定向量（`node_oracle.json`）逐头锁定。
- 调用：`catalog.dart:483-599`（避开 branch=1）、`video_model_client.dart:103-167`（branch=0，b 域 `multi_video_model/v1`）。
- **与上游 `pure-sign.js` 的 legacy `buildMedusa` 逐字段同源**，包括 field 21=312（`pure_sign.dart:1315` == `pure-sign.js:767`）。这不是"移植错误"，是上游仍认可的路径。
- 无 v5 / thl-sign / 551 实现。
- 设备注册 `playback_device.dart` 已处理 HTTP 200 空响应根因（fresh-pair-per-ask + 800ms/5s 退避）。

### 2.2 编解码 / 加解密

- CENC AES-128-CTR（`mp4.dart`）、spade v1 解包（`spade.dart`）、边下边播（`progressive_lane.dart` + `progressive_stream_server.dart`）、逐跳下载（`media_cache.dart`）— 与上游 v1.3.5 **实质等价**，部分能力（Range 代理、线路回退、manifest/LRU）更强。
- spade v1/v2 判定、flag 语义与上游 `spade.js` 完全一致（双方都不支持 v2）。
- HTTP 200 空响应：取址层与设备注册层均已修，progressive Range 空响应另有防护。
- **唯一真缺口**：BVC2 识别与拦截 —— `packages/` 下 `grep bytevc2|bvc2|vvc1|vvi1` 零命中。
- 加固点：上游 `verifyVideoIv` 取 6 个探测样本，Dart 只验样本 0；上游 `avccSelfOk` 接受 Annex-B 起始码，Dart 只走 AVCC。

## 3. 实施项（按文件）

### S1 BVC2 识别与拦截（真缺口，P0）
- `packages/core/lib/src/media/mp4.dart`：新增只读探测 `Mp4Cenc.probeCodecFamily(Uint8List head)`，从 `stsd` 条目识别 `bvc2`/`bv2C`/`vvc1`/`vvi1`，返回是否仅 BVC2。
- `packages/api/lib/src/media_cache.dart`：缓存命中与 `_run` 发布前读文件头 1MB 探测；命中 BVC2 抛 `SourceUnavailable('该片源为 BVC2 编码，当前播放器不支持，请换其它片源')`，不写入缓存、不交给播放器。
- 测试：`packages/core/test/` 新增 BVC2 探测单测（构造最小 stsd box）；`packages/api/test/media_cache_test.dart` 新增拦截断言。

### S2 视频 key 自证多探测样本（评估后本轮不落地）
- 上游 `mp4.js:789-845` 取 6 个探测样本，但那是专门挑选的 IDR 样本。实测按序号盲取 `0,1,2,n/4,n/2,n-1` 会把 P 帧误判为密钥不匹配——`real.cenc.mp4` 真值 fixture 上 6 个 core 测试全部回归失败。保留单 IDR 首样本策略。

### S3 NAL 自证接受 Annex-B（加固，P1）
- `mp4.dart:483-507`：`validNalSample` 开头接受 `00 00 01` / `00 00 00 01` 起始码（取起始码后第一个字节做 forbidden_zero/type 检查），对齐 `mp4.js:770-774`。

### S4 spade 真值对拍（测试覆盖，P1）
- `packages/core/test/`：把 `spade.js:116-128` 的 5 组 TRUTH 搬为 byte 级断言。

### S5 空响应恢复两级回退（评估后本轮不落地）
- 上游新增 `video_tab` GET 与 a 域 gzip `player/v1` 两级恢复，但这两级依赖 thl-sign v5 三头签名（纯 Dart 无法复刻）；当前 Dart 的 b 域 legacy 路径实测可用，且已有 `retry.run` + fresh-pair 注册 + 预算退避与 progressive Range 空响应回退，具备等价防护。
- 在缺少真实端点验证与 v5 签名的前提下切换端点会破坏现状，故本轮只记录差距、不改取址链路。若未来 b 域全面失效，连同签名走服务端方案一起处理（见 §4）。

### S6 漂移基线（元数据，P2）
- **不覆盖** `tool/upstream_protocol.json` 的 1.1.5 pin。理由：`node_oracle.json` 的 96 向量由 1.1.5 的 `pure-sign.js` 生成，`check_upstream_protocol.py` 把两者绑在一起；1.3.5 把随机源换成不可注入的 `crypto.randomInt/randomBytes`，无法 byte 对拍重生成 oracle。旧 pin 继续作为算法回归基线有效。
- 新增 `tool/upstream_protocol_1_3_5.json`：独立记录 1.3.5 的 revision / 版本 / 核心文件 sha256（含 thl-sign / playback-sign），供后续迁移轮次使用，不参与现有门禁。
- `NOTICE.md` 补 thl-sign 的 GPL-3.0 来源链（作为对比依据记录，未移植代码）。

## 4. 不做的事（明确边界）

1. 不在纯 Dart 复刻 `thl-sign.js` v5 medusa（307KB vendor IIFE，含自定义 hash 变体位平面 extract/embed；手工移植正是上游判无效的那类）。如未来 b 域 legacy 全面失效，走受控服务端签名 + MethodChannel，属架构变更。
2. 不移植 551 Argus/Ladon（上游已弃用，无在用端点）。
3. 不引入 ffmpeg / librempeg / ffprobe（Electron 服务端特有，analysis 已定调不引入）。
4. 不改变现有 branch 抖动策略与 96 个 legacy 签名向量 —— 它们是算法回归基线。
5. 不切主端点到 a 域（当前 b 域 legacy 实测可用；v5 签名无法复刻时切端点反而破坏现状）。S5 的恢复只作为增量路径。

## 5. 门禁

- 每阶段：`dart analyze` 五包 + `flutter test` 全量（app 分批）。
- 关键回归：`oracle_test.dart`（96 签名向量）、`media_cache_test.dart`（缓存/解密）、`video_source_layers_test.dart`（三层取源）、新增 BVC2 / spade / 恢复测试。
- CI：合入 main 后由 `windows-verify` 验证。
- TV 真机回归：用户已指示暂时取消，本方案不含 TV 设备验证。

## 6. 执行状态

- [x] 上游差异分析（3 个并行探索 agent）
- [x] S1 BVC2 识别与拦截：`Mp4Cenc.isBvc2()` + core 9 单测 + `media_cache` 缓存命中/新发布双拦截
- [x] S2 评估后不落地（盲取多样本误伤 P 帧，见 S2 段）
- [x] S3 Annex-B NAL 支持：`validNalSample` 接受 3/4 字节起始码 + 单测
- [x] S4 spade 5 组真值已在 `node_oracle.json` 覆盖（无需新增）
- [x] S5 评估后不落地（缺 v5 签名，见 S5 段）
- [x] S6 新增 1.3.5 独立记录文件，保留 1.1.5 oracle 基线
- [x] 门禁 + 提交

## 7. 门禁结果（2026-11-25）

| 包 | 结果 |
|---|---|
| core | 164 通过（含新增 BVC2/NAL 9 项） |
| api | 325 通过 |
| cast | 52 通过（并发负载下一次时序 flaky，单跑 2× 绿） |
| tv | 38 通过 |
| app | 526 通过（分两批 252 + 274，各 1 skip） |
| dart analyze | 五包 No issues found |

TV 真机回归：用户指示暂缓，不在本轮范围。
