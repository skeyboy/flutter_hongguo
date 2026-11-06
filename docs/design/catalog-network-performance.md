# 内容请求恢复、取消与缓存

## 已实现行为

| 场景 | 旧行为 | 当前行为 |
| --- | --- | --- |
| HTTP 200 空体或必要字段缺失 | 等待 1/2/4 秒，最多 4 次请求 | 最多 3 次请求；两次等待分别随机 300–500ms、800–1000ms |
| 同上，但发生在播放取址这一跳 | 与目录请求共用 3 次/1.3 秒，重发的是逐字节相同的请求（同一注册身份、同一 body） | 最多 4 次请求；三次等待分别随机 700–900ms、2000–2300ms、4000–4500ms，且一回空包就重新注册、下一发改用新的 `device_id`/`iid` 提问 |
| 批量任务打到注册端点 | 每个未缓存的集各问一次注册，一趟批量就是一串同形状的 POST | 两次注册的**起点**之间至少隔 `registerInterval`（默认 800ms，走单调时钟，设置时钟与 NTP 跳变动不了它）；只限起点不限往返，慢注册不拖后一发；并发问话仍共享在途那一次，所以一趟批量默认只花一次注册 |
| 注册被拒之后的追问 | 每一次问都重发一发已知会被拒的 POST | 拒绝按住 `registerFailureCooldown`（默认 5 秒），窗口内的问话直接拿同一个错误；用户主动取消不算拒绝；冷却是暂停不是判决，窗口过后照样重新注册 |
| 同一 vid 的播放信息 | 每次取址与清晰度都问一次上游，每问一次就付一次注册加一次签名 POST | 按 vid 存 `trackTtl`（默认 3 分钟，刻意压在签名直链自身寿命之下，好让「复用到旧地址」最坏只是多问一次而不是播坏；直链的实际 TTL 本轮未实测，那条待议记在 [DLNA 文档](cast-dlna.md)），命中不注册不发 POST；表上限 256 条，满了先扔最先到期的那一枚；删文件（`MediaCache.evict` 回调 `onEvict`）、清空缓存、上游明确拒绝（`PlaybackUnavailable`）三处当场作废对应条目 |
| 连接/发送/接收超时、408、5xx | 最多 4 次请求 | 最多 2 次请求，并服从整体预算 |
| 明确业务错误、JSON 格式错误、401/403、证书错误 | 部分错误也会反复请求 | 不自动重试；保留手动重试或已有官网回退 |
| 429 | Retry-After 最多截断为 30 秒 | 支持秒数及 HTTP-date；不提前重发，超过剩余交互预算直接结束本轮 |
| 元数据超时 | 每阶段默认 60 秒，重试/回退累加 | 逻辑操作总计 12 秒；单阶段连接/发送最多 5 秒，接收最多 8 秒，按剩余预算继续缩短；播放取址这一跳单独 20 秒，多出的预算给被拒后重注册 |
| 详情/搜索回退 | 主来源耗尽长重试后再开始 | 详情主来源最多 7 秒、搜索官网首探最多 6 秒；回退共用原来的 12 秒截止时间 |
| 连续切换筛选 | 旧结果不显示，但请求仍继续 | 旧调用者退出；排队、退避和底层传输均响应取消 |
| 相同参数并发加载 | 多次传输 | 同客户端共用在途结果；最后一个调用者离开才取消传输 |
| 重复获取题材 | 每次联网 | 每个 genre 成功结果内存缓存 6 小时；错误不写入缓存 |
| 发现/分类短期回看 | 缓存后仍立即请求 | 30 秒内直接复用；过期先显示缓存再刷新；手动刷新绕过新鲜期；冷启动那一次同样绕过——磁盘快照只负责第一帧不空白 |
| 每次启动的内容 | 启动请求逐字节相同，上游把同样的请求回成同样的页 | 冷启动与下拉刷新的第一发用快照里已落盘的 `nextCursor` 起步（参考实现自己的规则：offset 从已展示条数起），并带当前屏的 ID 作 `seen` 兜底；该发被去重清空就退回顶端再问一次，位置越过 90 行（约 5 屏）直接问顶端。`packages/api` 保持「参数定 = 请求定」，见 [feed-rotation 证据](../evidence/feed-rotation-2026-11-01/findings.md) |
| 起播计时 | 下载/解密等待易被误认为 API 慢 | 单独记录排队、缓存查找、解析、下载、解密、校验和播放器打开 |

260ms 请求启动间隔保留，改用单调时钟；仍只限制启动频率，慢题材请求不会阻塞其他列表响应。视频下载的长接收超时保持独立，不套用元数据的 12 秒预算。TV 保留原有常驻页面的后台刷新策略，同时使用共享请求恢复、去重、题材缓存和取消机制。

## 实现位置

- `packages/api/lib/src/request_control.dart`：`CatalogRequestScope`、单调时钟 `RequestBudget`、引用计数在途共享、`MetadataTiming`。
- `packages/api/lib/src/network_retry.dart`：错误分类、短退避、服务端 Retry-After、预算感知等待；恢复次数按错误类型分派（`maxRecoveries` 默认 2，只有「必要字段缺失」类吃满）。
- `packages/api/lib/src/catalog.dart`：完整参数键、题材缓存、受限主来源及官网回退；`browse(cursor:)` 是纯透传，客户端内部不藏任何换内容的状态。
- `packages/api/lib/src/video_model_client.dart`：两个元数据请求共享截止时间；同时获取清晰度与播放地址可共用元数据；`playbackRetry()` 是取址一跳自己的更宽窗口，恢复整块挪在注册之后，回空包即换身份；`fetchVideoInfo` 之上是 per-vid 的应答表（`PlaybackInfoEntry = (expires, value)`），TTL、上限与三处作废见上表，表本体由调用方注入以便跨客户端重建共享。
- `packages/api/lib/src/playback_device.dart`：注册结算即弃——`get()` 只与在途那一次共享，之后的每次取址必拿全新身份（重放已花掉的身份只换来 HTTP 200 空体）；起点之间按 `registerInterval` 排队，被拒按 `registerFailureCooldown` 按住。
- `packages/app/lib/platform/runtime_native.dart`：运行时装有整张应答表，同时交给 `VideoModelClient(info:)` 与 `MediaCache(onEvict:)`，所以删集与清缓存能把答案一起作废，而设置变更重建客户端不会把已答过的集重新问一遍。
- `packages/app/lib/features/library_page.dart`：250ms 合并保留，切换立即取消旧作用域，30 秒新鲜期、强制刷新与过期缓存回退；`initState` 那一次带 `force: true`，起点由 `_resumeCursor`（快照里已落盘的 `nextCursor`，90 行为界）决定。
- `packages/app/lib/features/detail_page.dart`、`features/tv/tv_feed_page.dart`：页面释放/失活时取消旧作用域。
- `packages/api/lib/src/media_cache.dart`：媒体准备阶段计时，取消准备同时释放元数据调用者。
- `packages/app/lib/features/player_page.dart`：准备耗时与播放器打开耗时分开。

调用者不需要依赖 Dio 类型，也不需要改变现有 CatalogRepository 的实现签名：

```dart
final scope = CatalogRequestScope();
final result = scope.run(() => runtime.catalog.browse(genre: 'short_play'));
// 切换筛选或销毁页面时：
scope.cancel();
```

同客户端的身份、会话、协议配置形成共享命名空间，列表键包含 genre、sort、theme、cursor、seen；搜索键包含规范化 query 与 cursor；榜单键包含 board 与 cursor。同一在途操作后加入的调用者共享已有截止时间，不会不断延长总等待。

NativeRuntime 重建客户端前取消旧请求；已有协议/会话变更清理列表快照的行为保留。LibraryPage 也检测客户端替换，避免相同排序条件下继续使用旧请求状态。内存缓存不会跨客户端、会话复用。

## 观测方式

NativeRuntime 保留最近各 100 条 `metadataTimings`、`mediaTimings`、`playerTimings`，仅在内存中供调试及测试读取，不新增遥测上传，也不保存请求参数、签名、URL、会话或媒体密钥。

- 元数据：逻辑请求 ID、操作名、尝试次数、缓存命中、失败类型、总耗时及 queue/sign/transport/backoff。
- 媒体准备：cacheHit、background、失败类型、各阶段耗时。成功边界为经过校验的本地普通 MP4。
- 播放器：准备耗时、播放器打开耗时、整个启动调用耗时。**播放器 open 返回不等于首帧呈现**，这些字段不冒充首帧指标。
- 原生播放集成测试还检查实际解码尺寸为 160×288，确保计时对应真实本地视频链路。

显式上游诊断（匿名、不下载视频、不在 CI 自动请求上游）：

```bash
.fvm/flutter_sdk/bin/dart run packages/api/tool/diagnose_latency.dart
```

## 验证与限制

- API 单测覆盖：短重试边界、业务拒绝、长/日期 Retry-After、实际传输取消、排队/退避取消、多订阅隔离、分页请求键、题材过期、详情及视频两步回退共享截止时间、脱敏分段计时；另有取址一跳的恢复换身份（第二次提问的 `device_id` 与第一次不同）、首发命中不产生额外注册、`playbackRetry()` 的 3 段等待与 ≥5 秒散布；注册侧覆盖并发问话只花一次注册、下一发注册的起点付的是间隔而不是上一发的往返、被拒在冷却窗口内不再重发 POST 且窗口过后照样重注册、主动取消不进冷却；应答表侧覆盖命中即不注册也不发 POST、到期后重新问上游、共享表里删掉一枚就重新问、表到 256 上限时先扔最先到期的那一枚，以及 `MediaCache.evict` 把被删的那一集报给应答表的持有者（文件被 pin 住删不掉时同样报）。
- Flutter 单测覆盖：390/1280 宽度新鲜缓存无重复请求、显式刷新、过期缓存刷新失败保留内容、旧请求作用域释放、旧结果不覆盖新筛选、TV 短恢复期间的占位与手动重试。
- MediaCache 单测覆盖：完整下载/解密/校验的阶段划分，再次取用同集只命中本地文件。
- macOS 独立标识原生验证已通过；样本准备约 362ms、open 约 15ms，缓存再次命中不下载。Android 已生成独立测试 APK，但设备拒绝安装（INSTALL_FAILED_USER_RESTRICTED），不得标为真机通过。iOS 系统模拟器原生用例也通过，真实视口 1206×2622 / DPR 3，准备约 1027ms、open 约 40ms；首轮磁盘不足后已清理临时构建并复测。详见[实施与验证记录](../analysis/2026-10-21-network-latency.md#实施与验证结果)。

上游仍可能连续返回空响应。短恢复减少等待，不保证网络成功率；缓存只在有历史有效结果时兜底。首次加载无缓存且恢复耗尽时，显示可重试错误，不伪造空列表或覆盖有效缓存。分析阶段的 3 轮样本不能用来承诺 P95 或对比成功率。

取址一跳的空包是**按秒聚集**的：同一时间窗内重发逐字节相同的请求不会改变答案，所以那一跳的恢复既要把窗口拉开，也要换掉被拒的注册身份。2026-10-30 的修前/修后线上读数与排除法见 [播放身份取证](../evidence/playback-identity-2026-10-30/findings.md)；同一天带签名的题材/详情跳仍会整轮全空，那条链路本轮未改。

本次不改变 CENC 整集解密后的本地 MP4 播放架构；边下边播不在这次改动中。

> 2026-11-02：边下边播作为独立开关落地（默认关闭），整片解密链路仍是缺省路径与回退路径，实现与限制见 [下载解密缓存播放链路](../native-playback-pipeline.md)。

> 2026-11-06：批量取址的放大收敛落地——注册起点之间加间隔、被拒加冷却、每个 vid 的应答按 TTL 存进一张由运行时持有的共享表（表与作废口径见上表）。`registerInterval` 800ms 与 `registerFailureCooldown` 5 秒是照「一趟批量不该变成一串同形状 POST」这个形状定的默认值，本轮没有对注册端点做过限速阈值实测；上线后的实际收敛量待带网取证。本轮读数：`packages/api` `flutter test` 147 项全过、`packages/app` 全量 505 项通过 + 2 项按条件跳过（其中 TV 搜索弹层那两例为新增）、`flutter analyze`（api/app/core/tv）除两处既有 `library_private_types_in_public_api` 提示外无 issue、`dart format` 0 变更。TV 侧遥控器真机读数仍缺：`integration_test/tv_live_data_test.dart` 那份实数据用例要带 `HONGGUO_SYSTEM_DPAD=true` 经 `tool/verify_tv_device.py` 注入系统按键才成立，本机无 adb 设备，本轮未跑。
