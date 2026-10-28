# 播放取址改走匿名设备注册 — 线上只读探测读数（2026-10-28）

驱动：`cd packages/api && ../../.fvm/flutter_sdk/bin/dart run tool/probe_upstream.dart --recover --video`，输出用 `HONGGUO_PROBE_OUTPUT` 落到 `build/verification/`，本目录是它的入库副本。
探测匿名运行：不读 Keychain 会话，不下载媒体；交换记录只含状态码、body 字节数和「这一发是否带签名」（以请求头里有没有 `x-argus` 判据），不含 token、Cookie、签名头、媒体地址、`key_seed` 或内容密钥。
被测：本轮工作树（`packages/api/lib/src/playback_device.dart` 新增 + `video_model_client.dart` 取址匿名化）。

## 修前：三次运行，取址 POST 全为空包

| 运行（UTC 时刻） | 结果 | 交换序列（status/字节/是否带签名） |
| --- | --- | --- |
| [playback-probe-20261028.json](playback-probe-20261028.json) 02:44:57 | `ok:false`，`IncompleteCatalogResponse` | 64736 带签名 / 0 带签名 / 44647 带签名 / **0** / **0** / **0** |
| [playback-probe-20261028-b.json](playback-probe-20261028-b.json) 02:45:57 | `ok:false`，`IncompleteCatalogResponse` | 64734 / 0 / 44645 / **0** / **0** / **0** |
| [playback-probe-20261028-c.json](playback-probe-20261028-c.json) 02:48:28 | `ok:false`，`IncompleteCatalogResponse` | 61284 / 44649 / **0** / **0** / **0** |

最后三个连续空包是取址 POST 的初发加两次有界恢复——三次运行共 9 个 HTTP 200 + 0 字节。空包之前的浏览与详情正常返回（约 19–65KB，均带签名），所以传输、TLS 与签名算法本身没坏，坏的只是这一跳的准入条件。观众侧看到的 `FormatException: Unexpected end of input (at character 1)` 就是这些空 body 直接进 JSON 解码的结果。

## 修后：先注册再免签取址，一次拿到可播片源

| 运行（UTC 时刻） | 结果 | 交换序列 |
| --- | --- | --- |
| [playback-probe-20261028-e1.json](playback-probe-20261028-e1.json) 05:14:25 | `ok:true`，`episodes:17`，`definition:1080p`，`encrypted:true`，`checkedMediaUrl:true`，`contentKeyValid:true`，`mediaDownloaded:false` | 0 带签名 / 59538 带签名 / 19052 带签名 / **312 免签**（注册）/ **18795 免签**（取址 POST） |
| [playback-probe-20261028-e3.json](playback-probe-20261028-e3.json) 05:14:38 | 同上 | 0 带签名 / 59530 带签名 / 19052 带签名 / **283 免签** / **18938 免签** |

- 交换记录里注册之后只有一发取址响应，没有第二次 GET：这两次走的是新回答内联 `video_model.video_list` 的路径，`fallback_api` 那一跳被跳过。
- 取址那一跳带签名头数为 0，注册那一跳同样免签——本轮把它从签名链路里彻底移出。
- `checkedMediaUrl`/`contentKeyValid` 只做地址与密钥校验，`mediaDownloaded:false`，未下载或解密线上媒体。

## 真实 App 单集验收（macOS 带窗口，同一轮）

驱动：`./tool/verify_mac_live.sh 7697273659248872472 7697275565593611289`（`packages/app/integration_test/macos_live_poc_test.dart`，`-d macos`，真实窗口与真实播放器，非无头）。完整日志 [macos-live-playback.log](macos-live-playback.log)，机器可读结果 [macos-live-poc-result.json](macos-live-poc-result.json)。

| 读数 | 值 |
| --- | --- |
| 退出码 / 结论 | `0`，`00:08 +1: All tests passed!` |
| 剧目 | 《十年恩，一生还》第 1 集（`seriesId 7697273659248872472`，`vid 7697275565593611289`） |
| 取到的片源 | `best`，本地缓存 8,879,851 字节 |
| 播放器出帧 | 1080×1920、时长 66,780ms、音轨识别为已存在；seek 到 10s 后位置 10,000ms |
| 画面 | [macos-live-poc-frame.png](macos-live-poc-frame.png)（播放器纹理截图，1,872,096 字节，非黑帧） |

这一跑走的是 App 自己的装配：`NativeRuntime` 构造 `PlaybackDeviceRegistry` → 注册匿名设备 → 免签 POST 取址 → 选流 → 下载 → 本地解密播放。观众侧原来那句 `FormatException` 出现在取址之后的解码环节，本轮从取址到出帧整条链路在真实窗口里通过。

## 不在本轮结论内的事

- 题材/浏览仍间歇 200 + 0 字节：同日 05:13:51 的一次运行里题材连发三发全空并 `ok:false`（`build/verification/playback-probe-20261028-d.json`，属抖动，未入库），05:14 的两次都由有界恢复后成功（表里开头的单个 0 字节就是那次恢复）。这不算取址修复的成果，也不能当作恒定可用保证。
- 播放现在多依赖 `log5-applog-lf.fqnovel.com` 的注册端点；它不响应时取址一起失败，语言是「播放设备注册未返回数据，请稍后重试」，且失败不缓存。

## 离线对拍与回归

- [api-tests-playback.log](api-tests-playback.log)：API 包 `00:03 +90: All tests passed!`。其中 `playback_device_test.dart` 用 `tool/generate_register_vector.cjs` 生成的 `packages/api/test/fixtures/register_vector.json` 对拍注册信封（`746305100000` 前缀、32 字节明文随机段、AES 段解出的 `sha512(gzip) ‖ gzip` 框架、压缩前的明文 JSON、注册 URL，以及除 `x-ss-stub` 外的全部请求头），`video_model_client_test.dart` 断言取址请求带注册身份、不含 `x-argus`/`x-gorgon`/`x-khronos`/`x-ladon`/`x-ss-stub` 等签名与会话头，并且内联列表不产生第二跳。
- `python3 tool/check_upstream_protocol.py` → `status: baseline_matches`，钉在 `38418358fae6d41a37d397524a2d4c17d7a4afc8`（package 1.1.5），协议文件 12 个（含上游新增 `server/src/service/playback-device.js`）。
- `dart analyze` 无问题；`tool/verify_all.sh` 退出码 0（Core 117、API 90、Cast 52、TV 36、App 257 通过 / 跳过 1，AOT 与 dart2js 各 103 条离线向量，84 个媒体样本解密后密文样本归零）。

完整结论与迁移表见 [上游 API 维护 · 2026-10-28 一节](../../analysis/2026-10-21-upstream-api-maintenance.md)。

## CI 读数：本地门禁没抓到的那条

标签 `v0.3.8`（`026519c`）触发的 Release run `40641144401`：`preflight` 与 `build / plan` 通过，`build / verify` 失败（`00:04 +88 -2`），后面 `build / native`、`ios-signed`、`publish` 全 `skipped`，没有创建 Release、没有附件。失败的两条都是 `playback_device_test.dart` 的注册对拍，差异偏移 50（base64）正好是密文起点：前缀与会话随机段两边一致，分叉从 gzip 段开始——deflate 输出跟着二进制链接的 zlib 构建走，本机 macOS 上 Dart 与 Node 恰好逐字节相同，Linux runner 上不是。

也就是说：本地 `verify_all.sh` 全绿不等于提交树在 CI 上全绿，这条对拍按构造就不该钉整段 body。修法见上一节——夹具改存压缩前的明文，断言验框架、密钥派生与明文，`x-ss-stub` 单独对齐本机 body 的 MD5。
