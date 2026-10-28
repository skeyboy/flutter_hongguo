# mac 下载通道证据（2026-10-28）

同一台 Mac（macOS 27.0.0 / arm64）、同一个 Release 容器 `com.example.hongguoApp`、`backgroundDownloads: true`。所有读数由本轮 `tool/verify_mac_live.sh` 与实机 `ls` 产生，日志原文入库，未做删改。分析结论见 [../../analysis/2026-10-28-mac-vs-mobile-playback.md](../../analysis/2026-10-28-mac-vs-mobile-playback.md)。

| 文件 | 证明什么 | 关键行 |
| --- | --- | --- |
| `user-device-log.txt` | 用户实机原始日志（逐字入库）：第一个实例 `TextureGL: resize: 1920.0x1080.0` 正常出帧（16:11:00），16:11:35 与 16:11:49 的两个实例只到 `rect … width: 0.0, height: 0.0`，再无 resize | 第 5 行 vs 第 10、14 行；第 16 行 `error messaging the mach port for IMKCFRunLoopWakeUpReliable` |
| `prefetch-stall-before-fix.log` | 修复前：系统通道下预缓存永不就绪，产品缺陷可复现 | `Expected: <3> Actual: <1>`；`03:16 +0 -1: Some tests failed.` |
| `prefetch-stall-with-lane-trace.log` | 桌面确实走了 `background_downloader`（纯 Dart isolate），并且卡死不报错 | `LANE macos 7691595339815455769_best.mp4.1793176339741464.0.part TaskStatus.running err=null` → 同文件 `TaskStatus.complete`；此后到 `04:11` 仍 `+0`，只留下播放器控件的 finder 转储 |
| `prefetch-after-fix-ready3.log` | 修复后：已有缓存的剧 5 秒内出帧（0×0 → 1920×1080），失败点只是工装点击时序 | `28: rect: {width: 1920.0 … height: 1080.0}`；`31: Found 0 widgets with key [<'toggle-episodes'>]`（`macos_live_poc_test.dart:95`）；`EXIT=1` |
| `prefetch-after-fix-new-drama.log` | 修复后：全无缓存新剧在线预缓存 3 集并切集成功，全绿 | `00:27 +1: All tests passed!`、`EXIT=0`、`MAC_LIVE_POC_SUMMARY=` 一行 |
| `mac-prefetch-poc-result.json` | 上表的机器可读结果（从容器复制） | `ok: true`、`bytes: 12020592`、`1920x1080`、`durationMs: 112103`、`seekTargetMs/seekPositionMs: 10000`、`frameBytes: 1810598`、`prefetchedEpisodes: 3`、`switchMs: 307`、`switchStages: ["正在排队","已就绪"]`、`localServerUsed: false` |

验证资源：《凡人百世书》`seriesId 7641246517595999257`，起播 `initialVid 7641248554081602585`，切到 `vid 7641248476080114713`（`episodeIndex 2`）。修复前复现用的是用户正在看的 `7691595309494832153` / `7691595339815455769`。

## 缓存目录读数（本轮最后一次）

```
media-cache: 30 个 *_best.mp4（已发布，= maxCacheFiles 上限）
             65 个 *.part 合计 1,202,790,313 B
             du -sh 1.5G
     .part 时间戳集中在 16:11–16:12，最后一轮 prune 时尚未满 1 小时回收窗口
```

修复前的读数（会话中的即时 `ls`/`du`，原始输出未入库，只作为量级记录）：192 个 `.part`、约 2,017.8 MB 不可用密文，下载台账 240 条全部 `failed` / 0 字节；本轮两次验收后依次降到 125 → 65。可在自己机器上用下面两条命令复核同类状态。

```bash
C="$HOME/Library/Containers/com.example.hongguoApp/Data/Library/Application Support/com.example.hongguoApp/media-cache"
ls "$C" | grep -c '\.part$'; ls -l "$C" | grep '\.part$' | awk '{s+=$5} END {print s}'
```

## 门禁

- `HONGGUO_FLUTTER_BIN=.fvm/flutter_sdk/bin ./tool/verify_all.sh` → `EXIT=0`（格式、`dart analyze --fatal-infos`、core/api/cast/tv/app 测试、AOT/JS oracle、离线解密探针）。
- `packages/api/test/media_cache_test.dart`：`00:03 +91: All tests passed!`（新增「prune reclaims working files left by a dead session」）。
- `packages/app`：`flutter test --no-pub -j 1 --reporter expanded` → 46 个套件、`01:13 +259 ~1: All tests passed!`，其中包含新增的 `native_download_lane_test.dart`（2 项）。默认并发模式的 expanded 日志只出现 27 个文件名却同样是 259 个用例，因此不能用日志里的文件名 grep 结果当作覆盖口径。

## 副作用披露

- 验收运行改写了用户 Release 容器内的 `mac-prefetch-poc-result.json` 与 `mac-live-poc-*` 截图。
- 新增的回收逻辑在验收过程中删除了该容器缓存里约 130 个超过 1 小时的死 `.part`（约 0.5 GB）；均为不可解密的半截密文，无对应台账记录。
