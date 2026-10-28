# macOS 与移动端播放差异：0.3.9 在线加载失败根因与修复

结论：macOS 上「后台下载」把视频传输交给了 `background_downloader` 的纯 Dart 桌面实现，该实现在同一 URL 上会静默停在固定字节、既不报错也不超时，两个并发准备槽被死任务长期占用后，后续集永不发布，播放页只剩 0×0 的画面矩形，观感即「无法加载在线视频」。移动端把同一开关交给系统下载器，是另一条链路，不受影响。本轮修复让桌面端始终使用应用内（Dio）下载通道，并补上回收遗留工作文件的缓存清理。

## 两端到底哪里不同

| 环节 | Android / iOS | macOS / Windows / Linux |
| --- | --- | --- |
| 传输通道（`backgroundDownloads` 打开） | 系统下载器：原生 URLSession / WorkManager，系统级进度通知与断点续传 | `background_downloader-9.6.4` 无 `macos/` 原生目录，条件导入落到 `lib/src/desktop/desktop_downloader.dart`：纯 Dart isolate + 自定义队列（见 `file_downloader.dart:20` 的 `if (dart.library.io)`） |
| 传输通道（开关关闭） | 应用内 Dio | 应用内 Dio（与修复后的桌面默认一致） |
| 后台可播/可准备 | 需要设置项打开：`allowBackgroundPlayback(enabled:)` | 桌面恒允许（遮挡是窗口状态，不是移动端的挂起），见 [host_policy.dart:11](../../packages/app/lib/platform/background/host_policy.dart#L11) |
| 取址、解密、校验 | 同一套 Dart 实现（`MediaCache.prepare` → 下载 → `FileDecryptor.decrypt` → `validateClear` → 原子改名） | 相同 |
| 播放器 | media_kit/libmpv，纹理由平台插件提供 | 同为 media_kit，纹理走 `TextureGL`；日志特征是 `VideoOutput.Resize` + `NativeVideoController: Texture ID` |
| 缓存位置 | 应用沙盒 Application Support | `~/Library/Containers/com.example.hongguoApp/Data/Library/Application Support/com.example.hongguoApp/media-cache` |

关键差别只有一处：**桌面端「交给系统」其实是交给一个 Dart isolate 队列**，它没有系统下载器的停滞检测，也没有可见错误。

## 现象与证据

- 用户实机日志（16:10–16:12）里出现三次 `VideoOutput.Resize`，只有第一次后跟 `TextureGL: resize: 1920.0x1080.0`，其余两个实例的矩形停在 `width: 0.0, height: 0.0`——播放器建好了，但没有可解的内容可喂。
- 复现（同一台 Mac、同一个 Release 容器、`backgroundDownloads: true`）：`tool/verify_mac_live.sh` 的预缓存断言 `Expected: <3> Actual: <1>`，900×200 ms 的等待窗口内其余集从未就绪；重跑一次则整体「did not complete」（EXIT=79）。同一 URL 在三次独立会话里停在同一字节位置，且除 `running`/`complete` 外没有任何一次状态回调。
- 打通道标记的追踪日志证明桌面确实走了系统通道：`LANE macos 769159…_best.mp4.…part TaskStatus.running`（`TaskStatus` 只来自 `background_downloader`）。
- 同一台机器把通道换回应用内 Dio：7.2 MB、8.9 MB、12.0 MB 的选集都能下完、解密、出帧。
- 附带缺陷：`MediaCache.prune()` 过去只清理 `.mp4`，永不回收 `.part`。用户缓存里一次读数就有 192 个死工作文件、约 2017.8 MB 不可用密文（下载台账 240 条全部 `failed`、0 字节）。

以上原始日志与结果 JSON 见 [证据目录](../evidence/mac-download-lane-2026-10-28/findings.md)；用户实机日志逐字入库为 `user-device-log.txt`。两处数字来自会话中的即时读数、原始输出未入库，只作量级参考：同一 URL 停在 3,256,800 字节，以及修复前缓存里的 192 个 `.part` / 约 2,017.8 MB。

## 修复

1. 桌面不再交给系统通道。新增谓词 [host_policy.dart:18](../../packages/app/lib/platform/background/host_policy.dart#L18)：`useSystemTransferLane({required bool enabled}) => mobileHost && enabled;`，下载分派改为 [native_downloads.dart:142](../../packages/app/lib/platform/background/native_downloads.dart#L142)。开关在桌面仍然有意义——它继续控制「切换应用时是否准备缓存」，只是不再改变传输实现。
2. 回收死工作文件。`prune()` 首行后调用 [media_cache.dart:659](../../packages/api/lib/src/media_cache.dart#L659) → `_reclaimOrphanPartials()`（[media_cache.dart:706](../../packages/api/lib/src/media_cache.dart#L706)）：只删没有对应活跃 job、且 1 小时内未再写入的 `.part` / `.part.json`，正在传输的工作文件落在该窗口内不会被误删。`prune()` 在每次准备成功、每次释放租约和每次入队后都会跑，因此清理是增量发生的。
3. 测试：新增 `packages/app/test/native_download_lane_test.dart`（通道谓词按平台取值 + mac 上真实 `HttpServer` 下载证明走应用内通道）、`packages/api/test/media_cache_test.dart` 增加「prune 回收死会话留下的工作文件」用例。
4. 验证工装：`packages/app/integration_test/macos_live_poc_test.dart` 在点击「下一集」前补一次 transport chrome 复位——修复后预缓存常在 10 秒内就绪，控制条已自动隐藏，旧夹具会找不到 `toggle-episodes`。这是工装时序问题，不是产品问题。

## 修复前后读数

| 项目 | 修复前 | 修复后 |
| --- | --- | --- |
| mac 预缓存 POC（全无缓存的新剧《凡人百世书》`7641246517595999257`） | `Expected: <3> Actual: <1>`；重跑不完成（EXIT=79） | `00:27 +1: All tests passed!`，EXIT=0 |
| 在线选集 | 停在固定字节，永不发布 | ep1 `7641248554081602585` → ep2 `7641248476080114713`，12,020,592 B、1920×1080、112,103 ms |
| 出帧 / seek / 音轨 | 无（0×0） | `frameBytes 1,810,598`；seek 10,000→10,000 ms；`audioTrackRecognized: true` |
| 切集体验 | 卡在「正在下载」 | `switchMs 307`，`switchStages ["正在排队","已就绪"]`，`prefetchedEpisodes 3`，`localServerUsed false` |
| 缓存目录（本次读数时刻） | 192 个 `.part` / 约 2.0 GB | 30 个已发布 `_best.mp4` + 65 个 `.part`（1,202,790,313 B），目录 1.5 GB；剩余 `.part` 时间戳集中在 16:11–16:12，最后一轮 prune 时尚未满 1 小时窗口，将在下一次清理中回收 |

门禁：`HONGGUO_FLUTTER_BIN=.fvm/flutter_sdk/bin ./tool/verify_all.sh` EXIT=0；`packages/app` 全量 `flutter test -j 1 --reporter expanded` 46 个套件、`+259 ~1: All tests passed!`（含新增 2 项通道用例）；`packages/api` `+91`。注意默认并发下 expanded reporter 的日志会丢失部分套件归属（同一轮 259 个用例只在日志里出现 27 个文件名），所以按文件名 grep 全量日志不能作为覆盖率口径，`-j 1` 才是。

## 仍然存在的风险

- 移动侧系统通道没有「字节停滞看门狗」：`transfer.dart` 在 `waitingToRetry` 且判定离线时会置 `holdReason=offline/waitingForWiFi`，`base_downloader.dart:921-935` 让任务无限期挂住，`transfer.file` 可能永远不返回。本轮只让桌面避开这条链路，没有替移动端加超时。
- 桌面设置项文案「后台下载」现在实际只表示「切到后台继续准备缓存」，不再表示交给系统下载；是否改名待定。
- 用户下载台账里 240 条 `failed` 记录仍会展示，需要一个显式清理入口。
- 本轮验证写入了用户 Release 容器的 `mac-prefetch-poc-result.json` 与 `mac-live-poc-*`，并且新回收逻辑删除了其中约 130 个超过 1 小时的死 `.part`（约 0.5 GB）。

## 复现

```bash
# 桌面：应用内通道回归（无需网络）
.fvm/flutter_sdk/bin/flutter test --no-pub packages/app/test/native_download_lane_test.dart

# 缓存回收回归
.fvm/flutter_sdk/bin/flutter test --no-pub packages/api/test/media_cache_test.dart

# mac 实机在线验收（需要网络与上游可用）
./tool/verify_mac_live.sh <seriesId> <vid> <预缓存集数>
```
