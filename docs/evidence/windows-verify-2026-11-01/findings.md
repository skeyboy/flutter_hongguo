# Windows 端验证（2026-11-01 轮）

被验对象是提交树 `94ee883` 加本轮未入库的工作副本改动（PC 对齐：`drama_card.dart`
`onSecondaryTap`、`local_cache_page.dart` 面板分形态、`ranking_page.dart` 页头刷新；
TV 输入框焦点：`packages/tv/lib/src/environment.dart`；以及 Android 自动安装那条）。
执行位置仍是本地 NTFS 克隆 `C:\Users\lee\Documents\Codes\hg-verify-dl`——SMB 盘不能承载
Windows 构建（插件符号链接 `ERROR_INVALID_FUNCTION`、UNC 工作目录让 flutter_tools 崩），
这条与前几轮相同。克隆里参与验证的每个源文件都与 \\Mac 工作副本 `cmp` 逐字节一致。

## 全部门禁读数

| 检查 | 结果 |
|---|---|
| `dart format --output=none --set-exit-if-changed packages tool` | 272 文件，0 变更 |
| `dart analyze --fatal-infos packages tool` | `No issues found!` |
| `packages/core` `dart test` | +117 全过 |
| `packages/api` `dart test` | +100 −9（9 项全是既有的 Windows 侧文件占用，见下） |
| `packages/update` `dart test` | +32 −1（既有的路径分隔符断言，见下） |
| `packages/cast` `dart test` | +52 全过 |
| `packages/tv` `flutter test` | +38 全过（本轮 +2：单行框交还上下、多行框保留上下） |
| `packages/app` `flutter test` | +399 ~1 全过（本轮 +3：页头刷新、卡片右键开面板、TV 搜索框走得出去） |
| `dart compile exe tool/verify_portable.dart` 后本机原生跑 | 103 向量全过（含 96 条六段签名） |
| `dart compile js -O2` 后 node 跑同一份产物 | 103 向量全过 |
| `dart run tool/verify_media.dart` | 84 样本解密、0 残留密文，avc1 + mp4a 两条轨 |
| `dart run tool/verify_cast_didl.dart` | 输出了带转义的 DIDL（标题里的 `&`、引号、URL 里的 `&`） |

## 九 + 一项失败都是旧账，不是本轮引入

- `packages/api`：`media_cache_test.dart` 7 项 + `prefetch_scheduler_test.dart` 2 项。首条异常
  `PathAccessException: Deletion failed, path = 'C:\Users\lee\AppData\Local\Temp\hongguo-cache-1c473bf3'`
  `（OS Error: 另一个程序正在使用此文件，进程无法访问。, errno = 32）`——Windows 的临时目录删除被
  仍在关闭的句柄挡住，POSIX 平台没有这一步。同一组失败记在
  `docs/evidence/discover-ranking-2026-10-30/findings.md`；本轮一行代码都没碰 `packages/api`。
- `packages/update`：`release_downloader_test.dart` 的「a matching hash lands the file and reports what it is」。
  `Expected: '...\hongguo-update-7bac2be0/Hongguo-0.4.0-linux-x64.deb'` /
  `Actual: '...\hongguo-update-7bac2be0\Hongguo-0.4.0-linux-x64.deb'`——断言里写死了 POSIX 分隔符，
  在 Windows 上拼出的是 `\`。同样是旧账。

两项都用 `--reporter expanded` 复跑取过完整名称清单。上一轮记录的是「9 条失败全部落在
`media_cache_test.dart` / `prefetch_scheduler_test.dart`」（`+95 -9`，当时通过数较少），本轮按文件名与条数
与之一致：同两个文件、同 9 条；更早那份记录没有留具体用例名，所以逐条对齐到此为止，不再往前比。

## 本机跑不了的（如实记录，不假装）

- **`-d windows` 原生构建与集成测试**：本机是 Windows ARM64，`media_kit_libs_windows_video`
  只有 x64 导入库，链接必败（`LNK4272`/`LNK2019`，见 `docs/evidence/windows-floating-probe-2026-10-29/findings.md`）。
  这条路只能由 x64 CI 走：`windows-verify.yml`（analyze + `flutter test` + `flutter build windows --release`）
  在推送 main 后触发。**本轮没有提交也没有推送**（未获授权），所以这一轮没有新的 CI 绿灯可引。
- **DIDL 的严格 XML 复核**：门禁里那一步是 `| python3 tool/verify_didl_namespaces.py`，本机
  `python3` 是 Microsoft Store 的占位 stub，跑不了。上面一行只证明了 `verify_cast_didl.dart` 自身的输出，
  未证明严格解析器接受它。
- **`ffprobe` / `ffmpeg` 校验解密产物**：两者都不在 PATH，`verify_all.sh` 里那段是按 `command -v` 条件执行的，
  本机自然跳过；`build/verification/offline-decrypted.mp4` 已生成但未做容器级复检。
- 一句执行细节，给后来人省一次假失败：`dart compile exe` 之前必须 `mkdir -p build/verification`，
  脚本里那步 `verify_all.sh` 自己有，手工复跑时漏掉会报 `PathNotFoundException ... errno = 3`，
  与被验代码无关（本轮第一次就撞上，补目录后 103 向量全过）。

## 与设备无关的结论

本轮 Windows 侧的读数全部来自 Dart/widget 层测试与两份可移植 oracle。它证明的是：PC 对齐那几条
（右键手势、面板按 `MediaQuery` 分形态、页头刷新目标）与 TV 输入框交还上下键，在本轮改动后
全仓静态门禁与 Dart 测试仍然成立。它**不**证明 macOS 真窗口、iPhone、Android 真机或 Android TV
模拟器上的交互——那些分别需要各自的设备取证，本轮没有。
