# 同时下载数量：调度器自记并发峰值的实机验收（2026-10-22）

被测提交：`ace6398`（Mac 两轮）／`4a6dbe6`（TV 两轮），两者只差本轮的 `tool/verify_download_concurrency_live.sh`
（flavor 与预构建），被测代码 `packages/api/lib/src/media_cache.dart` 的并发分道与高水位计数、
`packages/app/integration_test/download_concurrency_live_test.dart` 完全相同。
运行树是 `/Users/lee/Desktop/hongguo-dlcon-verify`（`git worktree`，detached），不含其他会话未提交的改动。

## 结论

| 设备 | 档位 | 入队 | 调度器峰值 | 断言 | 结果 |
| --- | --- | --- | --- | --- | --- |
| macOS | 5 | 6 | `peak=5` | 每 tick `peak ≤ 5`，跑完 `peak == 5` | 通过 |
| macOS | 3 | 4 | `peak=3` | 每 tick `peak ≤ 3`，跑完 `peak == 3` | 通过 |
| TV 模拟器 | 5 | 6 | `peak=5` | 每 tick `peak ≤ 5`，跑完 `peak == 5` | 通过 |
| TV 模拟器 | 3 | 4 | `peak=3` | 每 tick `peak ≤ 3`，跑完 `peak == 3` | 通过 |

`downloadConcurrent` 既被当作上界（任何一次 tick 都没越过），也被证明确实达到（峰值恰等于档位）——
这是 v0.3.2 那个「队列层 3 running、真实传输并发 1」缺陷（`mac-baseline-defect-reading.json`）的反面。

## 换仪表前后是同一批证据

17:33 那次（旧夹具，宿主机 500 ms 采样 `phase==running && bytes>0` 的条数）在 TV 上读到 `peak=0`，
而同一行日志里 6 集全部 `ready`、字节数与本次完全一致（`live-tv-emulator.log` vs `tv-limit5.log`：
`7697275473801251865:5736570b`、`7697275610569133081:7266834b`、`7697275545788107801:5776445b`、
`7697275563651648537:4870897b`、`7697275511717760025:6484655b`）。同一台设备、同一批集，唯一区别是
现在读的是调度器在 `_active.add(job)` 之后自己数出来的在传条数（`media_cache.dart` 的
`peakManualTransfers`），而不是宿主机采样碰巧看见的瞬时值。单集 4.8–8.9 MB、6 集 3–5 秒下完，
采样窗口看不见并发，产品并没有变化。

## 读数细节（原始行）

- `mac-limit5.log` 20:46:08 `runtime ready limit=3 cachedTasks=240` → 20:46:09 `enqueued=6 positions=[0,1,2,3,4,5]`
  → 20:46:12 `DOWNLOAD_CONCURRENT=5 peak=5`（5 ready，`7693760957545188377:failed:0b`）→ 20:46:14 `cleaned up; cachedTasks=240`
- `mac-limit3.log` 20:48:35 `enqueued=4 positions=[0,1,2,3]` → 20:48:39 `peak=3`（3 ready，`7693760947017501721:failed:0b`）
  → 20:48:41 `cleaned up; cachedTasks=240`
- `tv-limit5.log` 21:07:49 `enqueued=6` → 21:07:54 `peak=5`（5 ready，`7697275565593611289:failed:0b`）→ `cleaned up; cachedTasks=0`
- `tv-limit3.log` 21:09:09 `enqueued=4` → 21:09:14 `peak=3`（1 ready，其余 3 个 `failed:0b`）→ `cleaned up; cachedTasks=0`

`failed:0b` 是上游返回 0 字节，与被测并发无关（夹具要求「至少一个任务真的过了字节」+「队列已排空」才认这次峰值；
两个条件四轮都满足）。TV 3 档那轮 4 集里 3 集 0 字节，是这批验读里最弱的一轮：峰值 3 仍然成立（3 个传输确实同时在传），
但完整落地的只有 1 集。

## 残留

- Mac：`episode-downloads.json` 起始 240 条、结束 240 条（夹具只增删自己那几条），设置由夹具 `saveSettings(original)` 复原。
- TV 模拟器：跑完 `pm list packages -3` 为 0 条、`pm path com.example.hongguo_app.tv` 无输出，夹具自报 `cachedTasks=0`。

## 复跑

```
cd /Users/lee/Desktop/hongguo-dlcon-verify   # 或任何检出被测提交的树，先 flutter pub get
HONGGUO_FLUTTER_BIN=/Users/lee/fvm/versions/3.47.4/bin \
  ./tool/verify_download_concurrency_live.sh macos 7693758158602243097 5 <log>
HONGGUO_FLUTTER_BIN=/Users/lee/fvm/versions/3.47.4/bin \
  ./tool/verify_download_concurrency_live.sh emulator-5554 7697273659248872472 5 <log> tv
```

Mac 必须用 `7693758158602243097` 这类本机从未下载过的系列：夹具现在会跳过已有任务记录或已有文件的集，
凑不满 `档位+1` 个就拒跑，不再交出一个到不了上界的峰值。TV 用 PoC 系列 `7697273659248872472`（48 集，模拟器数据干净）。
Android 必须带 flavor，且脚本会先构建 APK（launcher 在 flavor 的 overlay manifest 里，没有 APK 时
`flutter test` 在加载夹具阶段就报 `launch activity not found`）。
