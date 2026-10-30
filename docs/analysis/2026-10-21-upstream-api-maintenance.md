# 上游更新、空响应故障与协议维护

> 历史设计/验收记录。2026-10-21 的重试次数、总时限、取消与缓存新策略已由[请求性能设计](../design/catalog-network-performance.md)取代；下文旧策略及测试数字不代表当前行为。
>
> 2026-10-28 起播放取址那一跳不再带签名，改走匿名播放设备注册，见文末同名小节。下文“签名是必要修正”只适用于列表/搜索/详情，不再适用于 `multi_video_model`。

2026-10-21（Asia/Shanghai），Flutter 项目 `/Users/lee/Desktop/flutter_hongguo`。

## 本次结论与更新

参考子模块 `references/hongguo-web` 已从 `2d88d48` 快进更新到 [`407cf5d`](https://github.com/sunnysky123/hongguo-web/commit/407cf5d6d6f2e06a57ffcb00e561ad0004437198)。最新提交只将版本号收敛到 package.json，版本仍为 1.1.2；签名、取址与解密模块没有变化。子模块保持干净，没有直接修改上游源码。

抓取时发现远端 `v1.1.2` 标签已经从本地记录的 `68a1ddf` 移到 `407cf5d`。本次没有强行覆盖本地标签，按 main 的提交哈希更新。后续应以子模块提交哈希固定来源，不把可移动的标签或“版本号一样”当作协议源码一样。

确认的故障是 **列表免签假设不再可靠**。读取到的当前 App 协议设置为 `signLists=false`。匿名只读实测如下，未读取 Keychain 会话，也未输出请求签名、媒体地址或内容密钥：

| 探测 | 实际结果 | 能证明什么 |
|---|---|---|
| Node 上游列表免签 | HTTP 200，body 0 字节 | 传输成功不等于业务成功 |
| 同一列表加签 | HTTP 200，约 19KB，code=0，有题材和条目 | 当前签名实现仍能被上游接受 |
| 修改前 Dart 免签 | HTTP 200 空包，FormatException | App 的异常能在相同请求策略下复现 |
| 修改前 Dart 加签 | 成功返回 29 个题材选项 | 不必更换加解密算法即可取得数据 |
| 修改后签名及有界重试 | 成功取得题材、影视列表、详情及播放模型 | 本轮请求策略修复有效，但不是恒定可用保证 |
| 播放模型本地解析 | HTTPS 媒体地址校验、加密 URL 解析和 Spade 内容密钥校验通过 | 该样本的取址/密钥链路仍可用；没有下载或解密线上媒体文件 |

DNS/TLS 请求在数百毫秒内返回；响应 Date 与本机时钟差约 0–1 秒。不能把这次故障归因于一般连接超时或明显的时钟漂移。

**限制：带签名请求也出现过间歇性 HTTP 200 空包。** 本轮有一次旧配置尝试耗尽四次请求仍失败，后续签名请求经重试成功。签名是必要修正，但不能据此宣称全部限流、风控或授权问题都已解决，更不能把 HTTP 200 当作健康探测通过。

## 已落地的 Dart 修改

- `AppSettings.signLists` 与 `CatalogClient` 的新默认值改为 true。
- 旧安装显式保存的 false 不被擅自改写；遇到免签空响应时，在同一客户端内升级为签名请求，沿用首次请求加三次重试、1/2/4 秒退避的上限。后续列表请求直接签名。
- 每次重试重新构造 URL、时间戳、签名和 POST 数据流；不更换用户设备身份，不刷新或伪造账号令牌。
- 空包以 `IncompleteCatalogResponse` 处理，不再只暴露 JSON 解析异常；不会因为收到空包就认为是 AES/CENC 解密失败。
- HTTP 401 等认证拒绝不会被自动补签流程吞掉或无限重试，已有 Cookie/x-tt-token 保持原样。

现有安装可先在高级设置开启“列表接口也签名”并保存，原版本已经有这项开关。源码修复对已有安装生效仍需重新构建应用；更新参考子模块不会热更新已经安装的 Flutter 二进制。

Node 参考服务可使用其现有开关，不必把补丁直接改进参考子模块：

```bash
cd references/hongguo-web
HG_SIGN_LIST=1 npm start
```

这是显式启动命令，本次没有替用户启动或重启常驻 Node 服务。参考项目当前 `apiOnce` 还可能将空字符串解析成空对象，因此应检查业务字段和 body 长度，不能仅凭其未抛异常来判断数据正常。

## 签名、授权与解密是不同层

| 层级 | 代码入口 | 更新方式 |
|---|---|---|
| 端点、App 协议版本、视频 UA、超时、列表签名策略 | `AppSettings`、`CatalogClient`、`VideoRequestBuilder` | 在受支持范围内更新配置并重建客户端；域名白名单变更需代码审查 |
| 请求签名六个头 | JS `core/pure-sign.js` → Dart `crypto/pure_sign.dart` | 对比上游代码，迁移算法，重放离线向量和线上只读探测，重新发布 App |
| 媒体地址 AES 解码 | JS `app-source.js`、`util/crypto.js` → Dart `media_url.dart` | 校验 seed/常量/格式版本后迁移并发布，不能只改 UA |
| Spade 包装密钥与 MP4/CENC | JS `spade.js`、`mp4.js` → Dart `spade.dart`、`mp4.dart`、`file_decryptor.dart` | 用合成样本与已有兼容向量回归；更新代码并重新构建 |
| 上游账号会话 | `SessionCredentials`、`SystemSessionVault` | 使用有效且获授权的登录会话；失效时重新授权，安全存储 Cookie/x-tt-token |
| 自建 Web 服务访问控制 | Node `keystore.js` 的 x-api-key/admin_token | 只控制访问自己的服务，不赋予访问上游内容的授权 |

上游 `Client.refreshSession()` 只做 20 秒防抖，**没有真正的登录刷新实现**；Flutter `NativeRuntime.refreshSigning()` 只是重建客户端。二者都不能恢复失效的账号授权，也不能更新已编译的加密算法。当前项目没有可确认的官方 token-refresh 协议，不能承诺自动续期或自行生成有效授权。

若后续加入完整账号续期，应把 SessionProvider 独立于 Signer/Decryptor：由官方支持的登录/刷新流程提供会话、写入系统安全存储、在明确认证失败时提示重新授权；不要用反复换 device_id、把令牌写进协议配置或多次重签来掩盖授权失效。

## 后续同步流程

### 1. 更新参考来源前先看差异

在 Flutter 项目根目录：

```bash
git -C references/hongguo-web status --short
git -C references/hongguo-web fetch --no-tags origin main
git -C references/hongguo-web diff --stat HEAD..origin/main
git -C references/hongguo-web diff HEAD..origin/main -- server/src/core server/src/service server/src/util/crypto.js server/config/config.json
git -C references/hongguo-web merge --ff-only origin/main
python3 tool/check_upstream_protocol.py
```

新增 `tool/upstream_protocol.json` 固定本轮检查过的来源提交及 11 个协议相关文件 SHA256。`check_upstream_protocol.py` 默认离线、只读，不自动 fetch、不改 pin、不执行下载代码；协议文件或签名 Oracle 来源发生变化时以非零退出码提示人工审查。只匹配本地源码基线，不能替代线上探测或授权检查。

如果只改 README/发行版本而协议文件未变，不应随意重写 Dart 加密实现。注意“JS 签名源码一致”只验证签名模块来源，不等于全部请求策略同步：例如参考项目搜索已经 App 优先，当前 Dart 搜索仍有官网优先的历史行为，本次未调整搜索优先级。

### 2. 按变更层更新并回归

确认有签名/解密变更后，先做差异审查和 Dart 迁移，再生成参考向量并验证，不能只重写期望值让测试变绿：

```bash
node tool/generate_oracle.cjs references/hongguo-web
(cd references/hongguo-web && npm run selftest)
(cd packages/core && ../../.fvm/flutter_sdk/bin/dart test)
(cd packages/api && ../../.fvm/flutter_sdk/bin/dart test)
(cd packages/app && ../../.fvm/flutter_sdk/bin/flutter test --no-pub)
```

通过后再人工更新 `tool/upstream_protocol.json` 中的审查基线，提交 Dart 迁移、向量、协议配置和子模块指针。参数变更也要验证 query 编码、body 原字节、header/body 时间戳一致；不要在签名后改 URL 或二次序列化 body。

### 3. 用脱敏线上探测区分故障层

新增 `packages/api/tool/probe_upstream.dart`，显式运行才联网，不读用户会话：

```bash
cd packages/api
../../.fvm/flutter_sdk/bin/dart run tool/probe_upstream.dart --recover --video
```

默认对比免签/签名的题材请求；`--recover` 开启正常有界重试；`--video` 再读取一部已返回内容的详情与一集播放模型，仅解析 URL/密钥，不下载媒体。输出仅含状态码、响应长度、请求是否带签名、选项数量及校验结果，不输出 token、Cookie、签名头、媒体 URL、key_seed 或内容密钥。

- DNS/TLS/连接错误：先处理传输，不改解密算法。
- HTTP 200 空包：检查签名、版本和有效载荷，维持有界重试；持续失败保留错误，不伪装成“暂无内容”。
- 401/403、明确未登录：重新获取有效授权，不把本地 x-api-key 当作上游令牌。
- 429/风控业务码：停止高频请求，按服务策略退避，记录脱敏上下文。
- 播放模型成功但 URL/Spade/CENC 失败：分别检查对应解码阶段和版本，不清空全部用户数据来试错。

### 4. 发布与回退

Flutter 原生端的算法代码随 App 发布；参考 Node 项目的 JS 更新不会自动同步进 Dart。当前可动态保存的是已有受限的协议参数和会话，并不存在远程热加载签名/解密代码的机制。

后续如引入远程协议配置，应只接受签名校验过的版本化参数、限制域名/字段、保留最后可用配置及回退；算法仍通过可审计的 App 更新交付。无需向客户端下发任意可执行 JS/Dart 代码。

## 验证和证据边界

本轮离线与回归结果见 `build/verification/upstream-20261021-*.log`；线上对比见 `upstream-20261021-probe.json`、`upstream-20261021-dart-before.json`、`upstream-20261021-dart-after.json`；来源证据为 `upstream-20261021-git-evidence.json`。记录的是当次匿名只读请求，不能证明任意账号、网络、实体设备或全部付费/受限内容可访问。

本次没有更改现有会话、用户设备 ID、系统代理和 TLS 校验，也没有覆盖其他 macOS 开发改动。子模块指针、请求修复、诊断工具与本说明一并纳入 Git 提交；本轮未执行远端推送或安装包发布。

验证统计：上游 Node 自检 165/165、Core 117、API 51、App 145 项通过，协议漂移工具回归 1 项通过；静态分析及修改文件格式检查通过。

## 2026-10-28：播放取址不再带签名，改为匿名设备注册

观众侧的 `FormatException: Unexpected end of input (at character 1)` 复现在播放取址那一跳。同一份匿名只读探测里，取址之前的带签名请求正常返回约 45–65KB，而每次运行末尾都连着三个 HTTP 200 + 0 字节——取址 POST 的一次初发加两次有界恢复全部空包，合计 9 个（[playback-probe-20261028.json](../evidence/playback-protocol-2026-10-28/playback-probe-20261028.json)、`-b`、`-c`）。传输成功、状态码成功、body 为空，所以这不是解密或超时，而是上游换了准入条件。

参考子模块 `references/hongguo-web` 快进到 [`3841835`](https://github.com/sunnysky123/hongguo-web/commit/38418358fae6d41a37d397524a2d4c17d7a4afc8)（package 1.1.5）后，新增的 `server/src/service/playback-device.js` 记录了 2026-10-27 的实测：该接口开始校验请求里的 `device_id`/`iid` 是不是平台注册过的设备身份。此前每请求随机生成一对互不关联的合成 ID，加上六个签名头，上游就返回 200 + 0 字节软拦截；换成注册得到的身份、并去掉签名后，同一接口返回 code=0 与完整片源。

Dart 侧的迁移分四处：

| 变更 | 位置 | 说明 |
|---|---|---|
| ttEncrypt 注册 | [packages/api/lib/src/playback_device.dart](../../packages/api/lib/src/playback_device.dart) | 请求体 = `746305100000` 前缀 + 32 字节会话随机数 + AES-128-CBC(`sha512(gzip) ‖ gzip`)，key/iv 取 `sha512(sha512(random) ‖ KDF_SALT)` 的前 32 字节；只保留 `device_id`/`iid`/`cdid`，仅存进程内存，不落盘、不含令牌或 Cookie |
| 一次注册全进程复用 | 同上 `_pending`/`get()` | 并发调用共享同一个 Future；失败不缓存，下一次播放仍可再问，避免一次网络抖动把播放锁死到重启 |
| 取址请求匿名化 | [packages/api/lib/src/video_model_client.dart:92-139](../../packages/api/lib/src/video_model_client.dart#L92) | query 用固定设备模板加注册的 `device_id`/`iid`；请求头只剩 `User-Agent`/`Accept`/`Content-Type`，UA 固定为播放器自身的 `com.phoenix.read/71532`，不再有 signer 与会话头 |
| 内联片源列表 | 同上 [:256-267](../../packages/api/lib/src/video_model_client.dart#L256) | 新回答把 `video_list` 直接放进 `video_model`（数组），此时不再请求 `fallback_api` 第二跳；旧形状（以分辨率为键的对象）继续走第二跳 |

失败语言按“能不能靠重试改变”分成两类：信封缺失（空包/截断）仍是 `IncompleteCatalogResponse`，沿用同一请求自带 deadline 内的两次有界恢复；上游明确拒绝这一集（业务码、`status_code`、空 entry）改成 `PlaybackUnavailable`，一句就停，不再重复请求。注册环节的对应文案是「播放设备注册未返回数据，请稍后重试」与「播放设备注册失败，请稍后重试」。

注册协议没有可自证的入口，所以按 Node 侧做离线对拍：`tool/generate_register_vector.cjs` 把 `randomBytes` 换成固定种子的 LCG、`randomUUID` 换成计数器、`now` 固定，生成 3 组向量存进 `packages/api/test/fixtures/register_vector.json`；Dart 以同样的抽取顺序（`cdid` → `openudid`(8B) → `clientudid` → `req_id` → 会话随机(32B)）复现，比较 `746305100000` 前缀、32 字节明文随机段、AES 段解出的 `sha512(gzip) ‖ gzip` 框架、gzip 之前的那段明文 JSON、注册 URL，以及除 `x-ss-stub` 之外的全部请求头（stub 单独断言等于本机 body 的 MD5）。响应解析优先取 `device_id_str`/`install_id_str`：夹具里故意让数字 `device_id` 掉精度（`7661622467441479000`），字符串字段才是准值。

对拍不能钉整段 body，这条是 CI 教的：`026519c` 的第一次 Release 运行（run `40641144401`）在 Linux 的 `build / verify` 上挂住，差异偏移正好落在密文起点——前缀与会话随机段两边一致，分叉从 gzip 那段开始。同一份 Dart 代码在本机 macOS 与 Node 逐字节相同，在 Linux 上就不同了：deflate 输出跟着二进制链接的 zlib 构建走，不是协议的一部分。所以夹具改存压缩前的明文（`plaintextBase64`）而不再存整段 body，断言改成把密文解回来验框架与明文——密钥派生、IV、填充、框架、JSON 内容一项都没放松，跨平台的那一项被拿掉了。

修后线上读数（同日、匿名只读、未下载媒体）：[playback-probe-20261028-e1.json](../evidence/playback-protocol-2026-10-28/playback-probe-20261028-e1.json) 注册 200/312 字节（免签）+ 取址 POST 200/18795 字节（免签），解析出 17 集、`definition: 1080p`、`encrypted: true`、媒体地址通过 HTTPS 校验、Spade 内容密钥校验通过，且交换记录里没有第二跳，即走的是内联列表；`-e3` 同结论（283 字节 / 18938 字节）。

边界与遗留：

- 题材接口仍间歇 200 + 0 字节。同日一次运行三发全空并以 `IncompleteCatalogResponse` 结束（`build/verification/playback-probe-20261028-d.json`，未入库），重跑即恢复；这是上游抖动，不计入本次取址修复。
- 播放现在依赖 `log5-applog-lf.fqnovel.com` 的注册端点。它不响应时取址一起失败，错误语言已定为“注册未返回数据”，且失败不落缓存；域名不在现有白名单体系里，属代码固定常量。
- 高级设置里的「视频 User-Agent」只作用于片源回退第二跳（[video_model_client.dart:276](../../packages/api/lib/src/video_model_client.dart#L276)），取址第一跳用的是代码里固定的 71532 UA；这也是本轮在该字段说明里补的一句。
- `tool/upstream_protocol.json` 已重新钉到 `3841835`、package 1.1.5、`checkedAt 2026-10-28`，协议文件从 11 个增至 12 个（新增 `server/src/service/playback-device.js`）；`python3 tool/check_upstream_protocol.py` 回到 `baseline_matches`。

本轮证据与读数记录在 [docs/evidence/playback-protocol-2026-10-28/findings.md](../evidence/playback-protocol-2026-10-28/findings.md)。验证统计：API 90 项通过（含新的 `playback_device_test.dart` 与重写的 `video_model_client_test.dart`），`tool/verify_all.sh` 退出码 0，`dart analyze` 无问题；真实 macOS App 带窗口的单集验收（`tool/verify_mac_live.sh`）取到 8,879,851 字节片源并出帧 1080×1920、seek 与音轨均正常。这些是当次匿名请求的读数，不能证明任意账号、网络或全部受限内容可访问。

发布记录：修复提交 `0b5280d` 推到 main 后，标签没有硬搬——`v0.3.8`（`026519c`）作为一次未发布的记录留在历史里，版本改切 `0.3.9+21`（`9a0542c`，两处 pubspec 各一行）。提交树先在分离 worktree 跑 `tool/verify_all.sh` 到退出码 0，再推 main、打轻量标签 `v0.3.9` 触发 Release run `40643856179`：`preflight`、`build / plan`、`build / verify` 与五个 `build / native`（android、android-tv、macos、linux、windows）以及 `publish` 全 success，`ios-signed` 按默认跳过；run 从 `06:26:23Z` 跑到 `06:38:50Z`，`publish` 这一步只占 28 秒，发布在 `06:38:46Z`。也就是说这条 Linux 上的 zlib 分歧已被语义对拍吸收，本地 macOS 全绿不再是唯一依据。发布页 `draft: false`，15 个附件＝12 个安装包 + `iOS-signing-status.txt` + `SHA256SUMS.txt` + `release-manifest.json`；manifest 记 `version 0.3.9 / build 21 / commit 9a0542c9…`、`assets` 13 项（12 个安装包 + 状态文件），SHA256SUMS 共 14 行即那 13 项加 manifest 自身，12 个安装包逐条与 GitHub 给出的资产 `sha256` digest 对上，无错配、无 manifest 里有而附件缺的项。正文 25 条要点里第 6 条是本轮的「Playback URL acquisition」，措辞已随修复一起放宽：向量对拍验的是框架、密钥派生与压缩前的明文，不再声称逐字节。

## 2026-10-30：同一句空包文案换了成因——按秒聚集，被拒即换身份

观众侧又出现「暂时无法播放 / 播放信息未返回数据，请稍后重试」。这句文案只有两个出处，都在取址这一跳：HTTP 200 空 body（[packages/api/lib/src/video_model_client.dart:271](../../packages/api/lib/src/video_model_client.dart#L271)）和信封里 `data` 为空（同文件 [:525](../../packages/api/lib/src/video_model_client.dart#L525)），两者都抛 `IncompleteCatalogResponse`。这次它和 10-28 那次不是同一个病：那次是准入条件整体换了（合成身份 + 签名头一律软拦截，怎么重试都空），修完是「能问通」；这次是**同一台机器上时好时坏**，所以先把"看起来像"的三条逐个否掉，全部读数见 [docs/evidence/playback-identity-2026-10-30/findings.md](../evidence/playback-identity-2026-10-30/findings.md)。

- 不是解码：修前修后所有带回 `data` 的运行都是 `definition: 1080p` / `encrypted: true` / `checkedMediaUrl: true` / `contentKeyValid: true`，5 个成功样本无一失败。坏的是根本没拿到 `data`，不是拿到解不开。
- 不是版本回归：`git diff --name-only v0.3.9..HEAD -- packages/api` 只有 `media_cache.dart` 与其测试（下载车道那轮）；`video_model_client.dart`、`playback_device.dart`、`network_retry.dart` 自 `v0.3.9` 在提交历史里未动。「上一个版本正常」在这条链路上是成立的，也正因此成因不在我们的代码里。
- 不是身份被拉黑，也不是某一集被拒：同一个共享身份连问 8 发 `8/8` 带回数据，每发换新身份 `7/8`；3 部剧 × 首/中/末集共 9 个 vid 各问 3 次，`27/27` 全部带回数据。

剩下的是**按秒聚集的窗口**。07:27 那一轮里，4 次走到取址的尝试有 3 次各自连发 3 个 `200 + 0 字节`（合计 9 个空包），而同一次运行、同一进程、同一秒里，取址之前的带签名浏览/详情正常返回 36–60KB。旧恢复恰好帮不上忙：它在约 1.3 秒内重发**逐字节相同**的请求——同一个进程级注册身份（[runtime_native.dart:117](../../packages/app/lib/platform/runtime_native.dart#L117) 全进程只构造一个 `PlaybackDeviceRegistry`，[:221](../../packages/app/lib/platform/runtime_native.dart#L221) 注入取址客户端，[:138](../../packages/app/lib/platform/runtime_native.dart#L138) 还把它挂成下载车道的 `resolve`），同一个 body——等于在同一个窗口里把同一个问题原样再问两遍。

改法就顺着这个形状来，三处：

| 变更 | 位置 | 说明 |
|---|---|---|
| 取址跳自己的恢复窗口 | [video_model_client.dart:190](../../packages/api/lib/src/video_model_client.dart#L190) `playbackRetry()` | 3 次恢复，等待 700–900 / 2000–2300 / 4000–4500ms（合计 ≥5 秒，带抖动）；默认 deadline 由 12 秒放宽到 20 秒（[:175](../../packages/api/lib/src/video_model_client.dart#L175)）。目录请求维持原 3 发/1.3 秒，不受影响 |
| 被拒就换身份 | [:235](../../packages/api/lib/src/video_model_client.dart#L235)；[playback_device.dart:81](../../packages/api/lib/src/playback_device.dart#L81) `rotate()` | 恢复整块挪进注册之后：首发复用已持有身份，这一跳回空包就把该身份记为 `refused`，下一次尝试先重新注册、用新 `device_id`/`iid` 提问。`rotate(refusedDeviceId:)` 会核对当前已发放的身份，并发的恢复只多花一次注册而不是各注册各的 |
| 恢复次数按错误类型分派 | [network_retry.dart:109](../../packages/api/lib/src/network_retry.dart#L109) | 只有「必要字段缺失」类错误吃满配置的恢复；传输/服务端失败仍 1 次。新增 `maxRecoveries`（默认 2）保证其他调用方行为不变 |

`PlaybackUnavailable`（信封带业务码、`status_code` 或空 entry 的明确拒绝）继续一次就停——那是内容维度的答复，重复请求不改变答案。

线上复测：修后 6 连发里凡走到取址的运行都拿到 data（4/4，修前 1/4）。其中 `after/probe-6.json` 是这条修复的直接证据：`注册(384) → POST(0) → 注册(380) → POST(0) → 注册(384) → POST(22666)`，且这一发与上一发的时间戳相差 12 秒，而修前的三连发在 1 秒多点内打完。两次修后失败（`after/probe-2/3.json`）都没发出 POST，死在带签名的题材/详情跳——本轮没改那条链路的准入，既不算本修复的反例，也不列入本修复的成果。诚实边界：线上读数只能证明「轮换 + 更宽窗口」这个组合有效，无法把两项各自的作用分离开。

实机与离线：`./tool/verify_mac_live.sh 7701332919490448409 7701334783946673176`（真实窗口、真实播放器）取到 11,195,297 字节片源，出帧 1080×1920、时长 172,800ms、seek 10,000/10,000、音轨识别正常，`00:07 +1: All tests passed!`。离线：`playback_device_test.dart` + `video_model_client_test.dart` 合计 `+32` 全通过（新增断言含"第二次提问的 `device_id` 与第一次不同"「首发命中不产生额外注册」「`playbackRetry()` 3 段等待 / `maxRecoveries == 3` / 总散布 ≥5000ms」）；core、api、update、cast 的 `dart test` 与 tv、app 的 `flutter test` 本轮实跑退出码均为 `0`。

门禁缺口要说清：本轮拿不出一份退出码 0 的 `tool/verify_all.sh` 总读数。它第 12 行的整树格式检查与第 13 行的 `dart analyze --fatal-infos` 各被**不属于本轮**的在途工作挡住——`packages/api/tool/rank_sample.dart:422` 引用了尚不存在的 `CatalogClient.rank`，另有 `theme_rail_live_test.dart`、`desktop_fakes.dart`、`discover_desktop_layers_test.dart` 三个文件未格式化。本轮只保证自己那 7 个文件在这两项上干净，没有代别人收口。期间一次后台任务通知自称「退出码 0」，核对该任务自己的输出文件后判定不成立：那份输出只有 `Changed …` / `Formatted 252 files (8 changed)`，同一条检查重跑的真实退出码是 `1`——以后引用门禁结论以输出文件为准。

与参考实现的偏离（下一轮再动）：`references/hongguo-web` 1.1.6 之后把注册的 `REGISTER_UA` 从 `72232` 对齐到 `73932`（与 body 的 `version_code 73932` 一致），并加了注册失败冷却与 `resetPlaybackDevice`。Dart 本轮不跟：注册这一跳每次实测都是 `200 / 355–384` 字节，没有可归因的失败；而把 `tool/upstream_protocol.json` 推进到 1.1.8 需要重新生成 `packages/core/test/fixtures/node_oracle.json`（1.1.8 重构动了 `pure-sign.js`），属单独一轮更大的同步。另一件考虑过也没做的是「同一集短时间内复用一次取址结果」：它能削掉 App 自己造成的 POST 突发，但有把已签名的媒体地址用过期之险，收益不抵风险。

本轮未提交、未发布；工作树与其他在途工作共用，改动只落在上面 api 的 5 个源文件、2 个测试文件与 2 个只读探测工具。
