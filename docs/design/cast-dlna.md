# 投屏（DLNA）设计与独立 module 方案

手机把正在看的短剧投到同一 Wi-Fi 的电视/盒子上。本文先给结论，再给市面依据、协议选型、module 边界、平台×设备差异、后端配合清单和验收标准。所有行号与文件名均为本次实读核对。

## 建议结论

1. **主通道 = 自研纯 Dart DLNA/UPnP 控制点（DMC）+ 手机内置局域网 HTTP 媒体源**。不做屏幕镜像，不接 Google Cast，不默认接乐播 SDK。
2. **只投「本机已缓存并就地解密完成的明文 MP4」，不投上游加密直链**。电视端没有 `spade_a` 密钥，把 CENC 地址推过去必然放不出来；而本项目播放产物恰好是整文件解密后就绪的标准 MP4（`packages/api/lib/src/media_cache.dart:398`、`:402`），电视可直接拉、无需转码。这条决定了投屏的前置条件是缓存命中，UI 必须表达出来。
3. **功能落在独立包 `packages/cast`（pub 名 `hongguo_cast`），纯 Dart、零 Flutter 依赖**；UI 仍留在 app 侧，通过新增的 `CastRuntime` 能力接口注入。纯 Dart 包可用 `dart test` 在 Linux 1x 门禁跑，不额外消耗 macOS/Windows 的 10x 分钟。
4. **iOS 本期只做「DLNA 推送 + 系统屏幕镜像引导」**。App 级 AirPlay 视频投递对自建渲染引擎不可得（见下文 Apple 官方约束），不要为它设计 UI。
5. **合规是一道门槛而不是一个提示**：把已解密内容经局域网中继给电视，需先确认内容权利链。未确认前，对上游加密内容一律「检测即拒」并给明确文案，不做静默降级。
6. **不做主动清晰度降级**。爱奇艺因把会员投屏从 4K 锁到 480P 被判违约补偿，本项目投的是已缓存文件本身，质量等于用户已拥有的质量，天然不降级。

## 市面 App 的做法（调研摘要）

| 对象 | 实际做法 | 置信度 |
|---|---|---|
| 红果短剧 / 番茄 | 多方实测称 App 内**没有** DLNA/AirPlay 投屏入口，也无 TV 版，只能整机镜像 | 低-中（来源互相矛盾，有一处疑为 AI 生成内容） |
| 抖音 / 快手 | 竖屏短视频 feed 基本只能镜像；横屏长视频与直播间才有推送式投屏 | 中 |
| B站 / 爱奇艺 / 腾讯 / 优酷 | 内置 DLNA（部分走乐播 lelink），投屏后手机变「遥控器页」，可拖进度、调音量、切清晰度 | 中 |
| 华为生态 | Cast+（Miracast 扩展）属镜像通道，覆盖约 15-20% 手机份额；华为智慧屏不支持 AirPlay | 中 |

行业级事实：Google Cast 在中国大陆无正规行货、国产电视基本无 GMS，官方与索尼文档直接建议大陆用户改用本地支持的设备；2023 年爱奇艺 4K→480P 投屏限制在 2024 年一审被认定违约；投屏失败最常见原因是不同网段、路由器 AP 隔离、电视 DLNA 服务默认关闭、iOS 未授予「本地网络」权限、电视不支持 HEVC/AV1，以及**流本身是加密的**。

**机会与风险同时成立**：短剧赛道普遍没有投屏按钮，这是差异化空白；但也意味着没有可照抄的 UX 惯例，遥控器页、进度同步、失败文案都要自己定义。

## 协议选型矩阵

| 方案 | 国内接收端覆盖 | 与 mpv 自建渲染兼容 | Flutter 支持 | 成本/商务 | 形态 | 结论 |
|---|---|---|---|---|---|---|
| 自研 DLNA/UPnP | 国产电视/盒子绝大多数内置 | 无关（推 URL，不碰本地渲染） | 纯 Dart 可做 | 0 | 推流控制，手机可锁屏 | **本期主线** |
| 乐播投屏 SDK | 最好（大量电视预装其接收端） | 兼容 | 无官方插件，需自写 MethodChannel | 宣传免费但计费不透明、有停服先例、2025 起个人端也收费 | 推流+镜像+云投屏 | 商业备选，不进主线 |
| Google Cast | 大陆基本不可用 | 兼容 | 有插件但仅 Android/iOS | 需 GMS 生态 | 推流 | 只留抽象接口位 |
| AirPlay | 苹果生态好 | **不兼容** | — | 需申请 multicast entitlement | 视频投递只给 AVPlayer 或 AVSampleBuffer 渲染器 | iOS 只做系统镜像引导 |
| Miracast / Cast+ | 电视侧较广 | 镜像，锁屏中断、通知泄露、竖屏黑边 | 无 | 0 | 镜像 | 不做 |

Apple 的约束需要精确记录：官方只给三条路径——`AVAudioSession.playback` + `.longFormAudio`、`AVRoutePickerView` 做选择器、"fast streaming" 只支持 `AVPlayer`/`AVQueuePlayer` 或 `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer`。mpv 走自己的 Metal/OpenGL layer，不属于后两类，因此**选中路由也送不出画面，只有音频跟随**；`MPRemoteCommandCenter` 只管遥控命令与锁屏元数据。结论是 iOS 若非要 AirPlay 视频，只能在投屏时切到 AVPlayer 播同一 URL，等于放弃本项目播放内核，本期不做。

## 架构

```
packages/cast/                     纯 Dart，零 Flutter
  lib/hongguo_cast.dart            对外导出
  lib/src/protocol/ssdp.dart       SSDP M-SEARCH 组播搜索 + NOTIFY 监听，MulticastLock 由调用方持有
  lib/src/protocol/description.dart 设备描述 XML 解析（friendlyName/UDN/serviceId/controlURL/DML 能力）
  lib/src/protocol/soap.dart       AVTransport + RenderingControl 客户端
  lib/src/source/media_source.dart dart:io HttpServer 绑定 LAN，服务明文 MP4，支持 HEAD/Range
  lib/src/session/cast_session.dart 会话状态机与位置轮询
  lib/src/discovery.dart           设备登记表、去重、离线判定
```

- 接缝按现有惯例：投屏没有新加 `CastRuntime` mixin，能力直接用现成的 `runtime is LocalMediaRuntime` 探测再叠加平台门槛，即 `packages/app/lib/cast/cast_controller.dart` 的 `castSupported()`（移动端宿主 + 非 TV 版 + 运行时能给解密本地文件）；web runtime 不实现 `LocalMediaRuntime`，入口自然隐藏。
- 投屏源只取**已就绪**缓存文件，走 `MediaCache.prepareCached` 的只读租约与 pin 机制，保证电视拉流期间文件不被淘汰。
- 投屏开始时本地让位：复用 `_pausePlayback()`（`packages/app/lib/features/player_page.dart:513`，TV flavor 会自动分流到 `tvPlayback.pause()`）。
- 电视侧进度反向驱动 UI：`platformPlayback.onExternalProgress` 已有先例（`packages/app/lib/features/player_page.dart:357`），进度来自 SOAP `GetPositionInfo` 轮询，不做假插值。
- 入口按钮沿用可空回调惯法：`PlaybackTransport` 的 `floating` 就是 `if (widget.floating != null && ...) IconButton(key: ValueKey('enter-pip'), ...)`（`packages/app/lib/playback/playback_transport.dart:230`），投屏加的 `cast` 回调与 `ValueKey('cast-device')` 同构实现（同一文件 `:18`、`:223`）；`packages/app/lib/features/player_page.dart:1672` 那里按平台门槛传 null。

时序：点投屏 → 检查该内容是否已缓存为明文 → 启动 LAN HTTP 源 → SSDP 搜索（≤8s）→ 设备列表 → `SetAVTransportURI` + `Play` → 本地 `_pausePlayback` → 轮询 `GetPositionInfo`/`GetTransportInfo` → 遥控（暂停/继续/seek/音量走 SOAP）→ 退出投屏时 `Stop` 并按电视位置在本地续播 → 释放 HTTP 源与租约 pin。

## 手机与桌面、TV 的适配（平台 × 设备族）

| 平台 | 入口 | 关键约束 |
|---|---|---|
| Android 手机 | 显示 | 需 `CHANGE_WIFI_MULTICAST_STATE` + 运行期 MulticastLock（`hongguo/multicast` 通道，见 `packages/app/android/app/src/main/kotlin/com/example/hongguo_app/MainActivity.kt`）；明文不必配 `network_security_config.xml`：设备描述与 SOAP 控制走 `dart:io` 的裸 socket，Android 的 cleartext 策略只拦 Java 侧 HttpURLConnection/WebView；服务端 socket 要绑 `0.0.0.0` 不能绑 `127.0.0.1`；长时投屏需评估前台服务，否则 Doze 回收导致「投着投着就断」。以上两条都还没在真机上验证 |
| Android 平板 | 显示 | 同手机；横屏遥控器页可用两栏 |
| iOS iPhone/iPad | 显示，但失败率更高 | SSDP 组播需 `com.apple.developer.networking.multicast` entitlement（Explicit App ID、单独审批）+ `NSLocalNetworkUsageDescription` + iOS 14 本地网络授权；拿不到 entitlement 时降级为「引导系统屏幕镜像」并说明原因 |
| macOS | 不显示入口 | 桌面自身就是大屏，投屏无意义；保留接口 |
| Windows / Linux | 不显示入口 | 同上 |
| TV flavor（`--dart-define=HONGGUO_TV`） | 不显示 | TV 本身就是接收端 |

文案按设备族分派，不得出现 PC 键盘导向措辞：手机为「选择附近的电视/盒子」，Android 无 multicast 权限失败时为「请在系统设置里允许「本地网络」后重试」，iOS 为「若列表为空，可改用系统控制中心的屏幕镜像」。路由器 AP 隔离这类环境问题要给可操作提示而不是笼统「投屏失败」，并提供手动输入 IP 的兜底。

## 后端配合清单

以下缺口不在前端绕开，UI 按「后端真实能力」渲染，做不到就不显示该选项：

1. **明文/HLS 直轨**。协议上并不排斥 clear 流（`VideoTrack.encrypted = spadeA.isNotEmpty`，`packages/api/lib/src/video_model_client.dart:167`，`selectTrack` 允许 `spade_a` 为空），但仓内没有拿到明文直链的实证。若后端能给明文轨，DLNA 可直接推远端 URL，省掉中继与整文件等待——这是最值得争取的一条。
2. **签名直链的 TTL**。DLNA 是电视稍后自己拉流，短 TTL 直链会在电视开始播放时已过期；若走远端推送需要 TTL ≥ 10 分钟或支持续期。
3. **`castable` 权利标记**。合规门槛需要内容维度的可投屏标记（自有版权链/可中继），不能靠前端猜。
4. **投屏权益开关**。是否允许投屏、并发设备数、清晰度上限，应由服务端下发而非本地写死，避免日后单方下调构成违约。
5. DIDL-Lite 元数据（标题、集数、海报）用本地 catalog 字段即可，**不需要**后端改动。

## 状态与持久化

`AppSettings` 增加：`lastCastDevice`（UDN + host，便于重连）、`castAutoReconnect`（默认 true）、`castNoticeAckaged`（首次合规提示确认）。走非敏感的 `FilePreferencesBackend` 原子 JSON 路径，不进钥匙串。服务端下发开关优先于本地偏好。

## Flutter 实现建议

- `packages/cast/pubspec.yaml`：`name: hongguo_cast`、`resolution: workspace`、`publish_to: none`、`version: 0.2.0`、`environment: sdk: '>=3.13.0 <4.0.0'`（与 `packages/core/pubspec.yaml` 一致）；依赖 `xml: any`（根 `dependency_overrides` 锁 7.1.0，该版本已在 `pubspec.lock` 中，属提升为直接依赖，不引入新版本）；dev 依赖 `test`、`lints`。**不引入 shelf**，`dart:io HttpServer` 足够；**不引入 Flutter**，保持可 `dart test`。
- 硬编码包清单需同步：根 `pubspec.yaml` workspace 列表、`tool/verify_all.sh` 的逐包测试行、`.github/workflows/build.yml` 的 analyze/test 步骤、`docs/README.md`、`docs/project-map.md`、`README.md`。
- 测试基线：设备描述用真实电视的 XML 样本作 fixture（含命名空间、GBK、缺字段的脏样本）；SOAP 客户端用假 HTTP server 断言 envelope 与 SOAPAction；媒体源用 loopback `HttpServer` 断言 HEAD、Range 分段与 416；会话状态机断言「投屏后本地暂停、退出后按电视位置续播」。假网络沿 `packages/app/integration_test/offline_playback_test.dart:60-84` 的 `HttpClientAdapter` 惯法。

## 验收标准

1. 同网段、接收端开启 DLNA 时，从点击到设备列表出现 ≤ 8s；无设备时给出可操作的排查文案而非空列表。
2. 选中设备后电视在 15s 内出声画，本地播放暂停且不残留双声。
3. 遥控器页拖动能让电视在 ±2s 内到位；音量、暂停、继续、切集全部生效。
4. 手机锁屏或切后台 5 分钟，电视不中断；回前台进度与电视一致。
5. 未缓存或仍为加密态的内容点投屏，明确提示「该内容暂不支持投屏，请先缓存」，不出现静默失败。
6. 路由器开启 AP 隔离时，手动输入 IP 仍能连接。
7. 退出投屏后本地从电视当前位置续播，误差 ≤ 3s。
8. HEVC 电视播不出来时给出「换清晰度」引导（HEVC 绿边分析另见 `docs/design/tv-hevc-green-edge-analysis.md`）。

## 分阶段实施

- P1：`packages/cast` 协议核心 + 单测 + 门禁登记（本 module 范围）。已完成：SSDP、设备描述、SOAP、DIDL、时间格式、设备表、局域网媒体源与会话状态机，52 个 `dart test` 用例进 `tool/verify_all.sh` 与 CI `verify` job；DIDL 命名空间另有一道独立解析器校验（`tool/verify_cast_didl.dart | tool/verify_didl_namespaces.py`），因为 Dart 的 XML 读取器不报错于未声明前缀；未接任何 UI，未做真机验证。
- P2：app 接线（入口、设备面板、遥控器页、会话交接）+ Android 真机与一台接收端验证。接线已完成：播放页控制条 `cast-device` 入口（仅 `castSupported()` 为真时出现，即移动端宿主 + 非 TV 版 + 运行时可提供解密本地文件）、设备面板 `cast_device_sheet.dart`（发现中/空列表排障文案、不可播控设备只展示不可选）、遥控器页 `cast_remote_page.dart`（`AppScreen.cast` 路由，暂停/继续/REL_TIME 拖动/音量/退出）、会话交接 `CastController`：投屏成功后本地暂停，退出时把电视位置交回播放页续播并写历史；本地文件由 `MediaCache.prepareCached` 钉住、退出或切集时释放，Android 侧 `CHANGE_WIFI_MULTICAST_STATE` + `hongguo/multicast` 通道持有组播锁。`packages/app/test/` 新增 15 例（loopback 媒体服务器 + 假 SOAP 电视：`cast_controller_test.dart` 11 例、`cast_ui_test.dart` 4 例）。**未做**：真机与真实接收端验证，因此端到端投屏成功率仍是未知；遥控器页切集按钮（`onPrevious/onNext`）留空，上次设备记忆与自动重连在 P3，iOS 本地网络权限在 P4。
- P3：兜底能力（手动 IP、DIDL 协商、断连重连、前台服务）。
- P4：iOS entitlement 与本地网络权限引导。
- P5：后端明文轨与权益开关落地后，远端推送分支替换本地中继。
- P6：出海版本再评估 Google Cast，本期只保留接口位。

## 风险与未决

- **合规**：中继已解密内容必须落在自有权利链内，否则触碰《著作权法》第 49 条关于规避技术措施的规定；`castable` 标记未落地前，P2 的投屏范围应限制在本地自制/已授权样本内容。
- **接收端实现差异**：部分电视对 Range、无限流、DIDL 解析实现粗糙；本方案推完整文件 URL，是兼容性最好的一种。
- **无可测接收端时不得声称端到端通过**：P1 只能证明协议与状态机正确，投屏成功率必须在真机 + 真电视上验证。
- Android 14+ 前台服务类型与通知权限、多网卡/VPN 下 LAN IPv4 选择、组播被 IGMP snooping 吞掉等，都要在 P2/P3 实机暴露。
