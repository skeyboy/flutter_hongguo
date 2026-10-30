# Windows 端验证（2026-10-30 轮）

本轮是「选集 → 播放页态」改造推送后的 Windows 侧验证。HEAD `c8beb8c`。
上一轮探针的悬而未决项（`windows-floating-probe-2026-10-29/findings.md`
「runner 是否有可用桌面会话尚未验证」）今天有了答案：**托管 runner 起不了窗**。

## 本机（ARM64 Windows）能跑的全部通过

在本地 NTFS 克隆 `C:\Users\lee\Documents\Codes\flutter_hongguo` 执行（SMB 盘
不能承载 Windows 构建：插件符号链接报 `ERROR_INVALID_FUNCTION`；UNC 工作目录
让 flutter_tools 直接崩）：

| 检查 | 结果 |
|---|---|
| `dart format --set-exit-if-changed packages tool` | 258 文件，0 变更 |
| `dart analyze --fatal-infos` | 首跑抓到 1 个真错（见下），修复后干净 |
| packages/core `dart test` | +117 全过 |
| packages/api `dart test` | +52 全过 |
| packages/update / packages/cast `dart test` | 全过 |
| packages/tv `flutter test` | +36 全过 |
| packages/app `flutter test` | +324 ~1 全过 |
| `verify_portable.dart` AOT exe（本机原生跑） | 103 向量全过 |
| dart2js + node 跑 web oracle | 103 向量全过 |
| `verify_media.dart` | 84 样本解密、0 残留密文，avc1+mp4a 轨 |

本机跑不了的（如实记录，不假装）：`-d windows` 集成测试——`media_kit_libs_windows_video`
只有 x64 导入库，ARM64 目标链接必败（`findings.md` 昨日已证，今天原样复现）；
`verify_cast_didl | python3` 环节——本机 python3 是商店占位符。

## 分析抓到的一笔真账

`27aa04a` 入库的 `packages/api/tool/rank_sample.dart` 写在未合并的
`catalog.rank(board:)` 形状上，`--fatal-infos` 报 `undefined_method`。
已在 `c8beb8c` 修：改用 `RankCatalogRepository.rankBoard`，条目按
`RankEntry`（position/heat/score/badge）展开，样本另留 `unrecognizedCards`
与 `updatedAt`。这是 Windows 验证轮顺手兜住的——Mac 侧当时没有全量分析。

## CI（x64）两条运行

- `Verify Windows desktop`（run `41070460844`，`c8beb8c`）：**success**。
  analyze + `flutter test` + `flutter build windows --release` 全过。
  这是 Windows 侧编译与单测的常规门禁，本轮再次为绿。
- `Probe Windows floating window`（run `41070669693`，`c8beb8c`）：**failure**，
  日志在 `floating-probe-run.log`。24 个 integration_test 文件全部
  `√ Built build\windows\x64\runner\Debug\hongguo_app.exe` 成功、随后
  `Error waiting for a debug connection: The log reader stopped unexpectedly,
  or never started` → `Unable to start the app on the device`。
  构建 24 次全绿、启动 24 次全灭，失败点与代码无关，是 windows-2022 托管
  runner 没有交互式桌面会话（sessions 0 隔离）。另注意：`--name` 过滤并没有
  少起进程——每个文件仍各自 build+launch，所以一次探针烧了 24 份构建。

## 缺口与下一步

Windows 原生运行时行为（悬浮窗外观、离线播放链路、`window_manager` 桌面分支）
仍未被任何流水线执行过。托管 runner 这条路已被证伪，剩下的诚实选项：

1. 自托管 x64 Windows runner（有登录会话的机器），把探针指过去；
2. 或在有桌面会话的 x64 Windows 上手工跑一次
   `flutter test integration_test/offline_playback_test.dart -d windows`
   并把日志补进本目录。

本机（ARM64）两条都替代不了，不要再用 `-d windows` 重试。
