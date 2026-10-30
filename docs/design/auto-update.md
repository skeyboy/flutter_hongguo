# 自动更新（GitHub Releases 检查 + 按平台分派的更新方式）

状态：本轮（2026-10-29）设计与执行，代码已进 `main`，并按用户后续指令「执行推送发布新版本」随 **0.3.14+26** 发版（§9 末节）。基线现读（`HEAD=df90538`，即本轮动手前）：`pubspec.yaml` 与 `packages/app/pubspec.yaml` 均为 `0.3.13+25`、`packages/app/lib/features/settings_page.dart` 863 行、`packages/core/lib/src/config/app_settings.dart` 295 行、`packages/app/lib/platform/runtime_native.dart` 453 行、`tool/verify_all.sh` 35 行、`packages/update` 本轮新建。本轮改后同一批文件：1005 / 336 / 453 / 36 行，两处 pubspec 42 / 52 行。

## 1. 诉求与本轮决策

用户诉求（原话）：「分析一下怎么增加自动更新的功能：1 设置中增加更新的检测入口，用户点击后执行下载 2 app启动后者从后台激活后异步检测版本更新 3 检测到新版本更新后给出弹框提示新版本更新，提示版本更新内容 新的版本，用户可以选择更新后者忽略本次更新。同时当更新内容过多时弹窗内部可以滑动查看更新内容 …… 综合分析给出方案，根据平台特性给出不同的更新方式。可以采用新module的方式来实现更新功能。更新文件地址可从github对应的releases中获取。分析之后给出方案按照方案执行」。

三条诉求分别落在：设置页新增「更新」段（手动检查 + 下载 + 交给系统安装）、`UpdateController` 在首帧后与 `AppLifecycleState.resumed` 各自异步检查一次（24 小时节流，失败只 `debugPrint` 不打扰）、根页挂载的弹窗宿主给出「新版本号 + 可滚动正文 + 立即更新 / 忽略本次更新 / 以后再说」。

本轮决策（不追问，按最小惊讶取默认）：

- **更新内核独立成模块**：新纯 Dart 包 `packages/update`（`hongguo_update`），只用 `dio` + `crypto`，`dart test` 直接跑；Flutter 侧编排、UI 与安装动作留在 `packages/app/lib/update/`。这样版本比较、feed 解析、选件与校验都能离线回放真实响应，不牵进 widget 测试。
- **当前版本以提交进仓库的 Dart 常量为唯一源**：`packages/app/lib/update/app_release.dart` 写 `0.3.14` / `26`，由 `tool/ci/release_meta.py:version()` 与两处 pubspec 一起校验（同一函数 `:13-38` 现在除了「两处 pubspec 必须一致」还比对这两个常量，见 §9）。不引入 `package_info_plus`——五个平台的原生包元数据里，Linux/Windows 并不保证带 pubspec 版本号，把「我是什么版本」押在上面会让本地调试与真实发版读到不同答案。
- **macOS 保持 `com.apple.security.app-sandbox = true`**（`packages/app/macos/Runner/Release.entitlements`），因此**不做静默自替换**：下载 → 校验 → 交给系统打开 `.dmg`，装新版仍是用户把 app 拖进「应用程序」。关掉沙箱才能自动替换，那是分发姿态变更，见 §7。
- **Android 用 `PackageInstaller` 会话安装已校验的 APK**，新增 `hongguo/update` 通道与 `REQUEST_INSTALL_PACKAGES`；不用 `FileProvider`（那要 androidx.core 出现在编译类路径上，今天只有传递依赖）、也不用 `file://` URI（targetSdk 24+ 会抛 `FileUriExposedException`）。系统安装确认框由用户点，属于「未知来源」路径。
- **TV 版本轮不进更新链路**：`tvBuild` 既不做静默检查也不显示设置行——遥控器焦点下的弹窗与安装确认是另一套交互，没有取证设备。
- **iOS 只提示不安装**：商店分发之外没有自装路径，弹窗给出可读的发布页地址（不引入 `url_launcher`）。

## 2. 现状：仓库里一条更新链路也没有

现读结论，作为方案的起点而不是猜：

- 全仓 `grep` 不到 `api.github.com` / `update` / `version-check` 的运行期代码；`artifacts/macos/latest-release.txt` 只是 `tool/package_macos_release.sh:15` 给本机脚本写的路径指针，无人读取。
- 运行期**没有任何地方读取自身版本号**：`AppSettings` 里的 `catalogVersion` / `videoVersion` 是上游协议参数，和本 app 的 `0.3.13+25` 无关（`packages/core/lib/src/config/app_settings.dart:33-36`）。
- 发布侧已经把校验输入准备好了：`tool/ci/release_meta.py` 的 `checksums` 子命令产出 `release-manifest.json`（`{version,build,commit,assets:[{name,bytes,sha256}]}`）与 `SHA256SUMS.txt`，两者都会作为 Release 附件上传。
- GitHub feed 的真实形状（本轮 2026-10-29 现读 `GET https://api.github.com/repos/skeyboy/flutter_hongguo/releases/latest`，HTTP 200）：`tag_name = v0.3.13`、`prerelease = false`、`published_at = 2026-10-29T08:05:54Z`、15 个 assets，每个 asset 带 `name` / `size` / **`digest`（形如 `sha256:d08501…`）** / `browser_download_url` / `content_type`；`body` 长 **12357 字符**——这条直接决定第 3 点的弹窗正文必须可滚。**附件顺序不按平台排**：`assets[0]` 是 `Hongguo-0.3.13-android-arm64-v8a.apk`（36,447,668 字节），本机真正会装的 `.dmg` 是 22,547,501 字节，所以「这个发布多大」必须按选件算，不能读 `first`（见 §9 的缺陷 3）。响应头带 `etag` 与 `cache-control: public, max-age=60, s-maxage=60`，未认证配额 `x-ratelimit-limit: 60` / 小时 / IP，所以检查必须带 ETag 且默认 24 小时最多一次。ETag **不是稳定的**：同一轮里先后读到过 `W/"22def166…"`（夹具记录的那次）与 `W/"40fe3697…"`（实机跑的时候 app 存进 `updateFeedEtag` 的那次），发布说明一改它就换，所以它只能当「这一问的答案没变」用。
- 形状已钉成离线向量：`packages/update/test/fixtures/github_release_latest.json`（同一轮真响应，只删掉 per-asset 噪声键，`body` 原样保留），测试回放它，不再依赖网络。

## 3. 模块边界

| 面 | 落点 | 职责 |
| --- | --- | --- |
| 纯 Dart 内核 | `packages/update/lib/src/{release_version,release_info,update_target,release_feed,update_policy,release_downloader}.dart` | 版本号解析与比较、feed 解析（含 ETag/304/未认证错误）、按 os+arch 选附件、下载到 `.part` → sha256 校验 → 改名、决策枚举 |
| 编排 | `packages/app/lib/update/update_controller.dart` | 注入 `dio` / 当前版本 / `target` / 读写 `AppSettings`；节流、`WidgetsBindingObserver` 的 resumed 触发（先例 `packages/app/lib/downloads/download_manager.dart:89,534,554`）、下载进度、失败语言 |
| 安装策略 | `packages/app/lib/update/install_strategy.dart` | 按平台把校验完的文件交给系统：见 §5 表 |
| UI | `packages/app/lib/update/update_dialog.dart` + `settings_page.dart` 新段 + 根页挂载 | 弹窗（正文可滚）、「检查更新」行、忽略语义 |
| 原生 | `packages/app/android/app/src/main/kotlin/.../MainActivity.kt` 新通道 + `AndroidManifest.xml` 权限 | `abi` / `stageDir` / `install` |

持久化跟着现有链路走，不新开文件：`AppSettings` 增**四**字段 `updateChecksEnabled`（默认开）、`ignoredUpdateVersion`、`lastUpdateCheckAt`（epoch 毫秒）、`updateFeedEtag`（上一问的校验子），改齐字段、`toJson:88`、`fromJson:114`、`copyWith:168` 与 `validate:240` 五处（`validate` 限长 120 且拒绝换行，防写入失控的响应头）；写盘仍是 `settings/settings_store.dart` → `FilePreferencesBackend`（tmp+rename）。

注册点：根 `pubspec.yaml` 的 workspace `:10` 加 `packages/update`、dev_dependencies `:42` 加 `hongguo_update: any`、`tool/verify_all.sh:14-17` 的逐包测试块加一行 `(cd packages/update && "$SDK_BIN/dart" test …)`（新行是 `:16`）、`.github/workflows/build.yml` 的 verify job（`:40-77`）加同步的一步（`:64-66`）。

## 4. 检查与决策语义

1. 检查：`GET /releases/latest`，带 `If-None-Match`（存上一轮的 ETag）与 `Accept: application/vnd.github+json`；304 视为「没有新版本」并刷新节流时间；403/429（配额或 abuse 限流）与其它异常都只 `debugPrint`，静默检查永不弹错误。手动检查才把错误回给设置页。**ETag 只在「用户不欠任何东西」时才留**（`update_controller.dart` 的 `_retain(keepEtag:)`）：弹窗还挂着未装也未忽略的新版时，304 会被读成「自上次检查以来没有新版本」，把用户欠的那一版说没了；所以有 offer 站着时清空 ETag，让下一次检查付整份 body，直到 立即更新 / 忽略本次更新 把它结清。
2. 比较：去掉前导 `v`，按 `+build` 拆成数字段逐位比；任何一段非数字就当更小的版本。`0.3.13+25` vs `0.3.13` 是同一发布版（不比 build，除非版本号相等而 build 更大——本轮按「三段版本相等即最新」处理，避免同一 tag 重发布把用户拖进循环）。
3. 忽略：`ignoredUpdateVersion == 新版本` 时静默检查不再提示；设置页手动检查仍会告知「你已忽略 v0.3.14」，并给一个「重新提醒」出口。
4. 节流：`lastUpdateCheckAt` 距今不足 24 小时则跳过；手动检查不受节流限制，且会写入 `lastUpdateCheckAt`。
5. `prerelease == true` 的发布不进入提示（`/releases/latest` 本身不返回 prerelease，这条只是防御）。

## 5. 按平台分派的更新方式

| 平台 | 选中的附件 | 装法 | 本轮验证口径 |
| --- | --- | --- | --- |
| Windows | `Hongguo-<v>-windows-x64-setup.exe` | 下载 → sha256 → 写一条 `start "" "<setup>" /VERYSILENT /NORESTART /SUPPRESSMSGBOXES` 的临时 cmd 并 detached 起 → `exit(0)` 让正在运行的 exe 解锁。`tool/ci/windows-installer.iss` 是 `PrivilegesRequired=lowest` + `DefaultDirName={localappdata}\Programs\Hongguo` + 固定 `AppId`，所以原地升级不要 UAC、也不会开出第二份安装 | 单测覆盖选件/校验；**没有 Windows 设备**，静默装成功与否不做实机断言 |
| macOS | `Hongguo-<v>-macos-arm64.dmg`（v0.3.13 实测 22,547,501 字节 ≈ 21.5 MB） | 下载（沙箱内 app support 的 `updates/`）→ sha256 → `open <dmg>`；`open` 失败再退到 `open -R` 并在弹窗里给出可选中的完整路径 | macOS 真窗口跑通「检查 → 下载 21.5 MB dmg → 校验 → 弹出 dmg」，见 §9；本轮取不到窗口像素，所以只有运行期结论、没有画面结论 |
| Android（mobile flavor） | `Hongguo-<v>-android-<abi>.apk`，`abi` 取 `Build.SUPPORTED_ABIS` 首个，回落 `arm64-v8a` | 下载 → sha256 → 通道 `install` 用 `PackageInstaller` 会话写盘并 `commit(pendingIntent.intentSender)`，系统弹安装确认 | 逻辑与选件走单测；**本轮不做真机安装**（HyperOS 安装策略与 split 包 versionCode 降级门仍在），所以不声称装机成功 |
| Linux | `Hongguo-<v>-linux-x64.deb`，无 deb 时 `linux-x64.tar.gz` | 下载 → sha256 → `xdg-open <deb>` 交给系统包管理器；tar.gz 只落到「文件已备好，请按现有方式替换」 | 无 Linux 设备，只有单测 |
| iOS | 无（不选附件） | 只提示，弹窗给出发布页 `html_url` 供复制 | 不发版本，无验证 |
| Android TV | 不参与 | `tvBuild` 全部跳过 | — |

附件名即协议：`tool/ci/package_desktop.py:19-90`（`macos()` / `windows()` / `linux()` 三段各自的 `Hongguo-{RELEASE}-<平台>-<arch>` 名字）与 `plan_build.py` 决定名字，选件逻辑只按「前缀 `Hongguo-<version>-` + 平台段 + 期望后缀」匹配，任一名字变了 CI 的 `validate_release.py` 与本模块会同时挑不出来——这是有意留的双保险。

## 6. UI

- **设置页**（行号按本轮落地后的文件）：`anchors`（`settings_page.dart:45-56`）里加「更新」一段，段体 `_section('更新', …)`（`:274`，`_section` 本身在 `:384`）依次给出「当前版本 v… （构建 …），新版本来自 GitHub Releases。」、`updateHandoffDescription` 那句按平台的说法、`SwitchListTile.adaptive`（key `自动检查更新`，`:287`）控制 `updateChecksEnabled`（副标题写清「一天最多询问一次；没有新版本时不打扰」），再由 `ListenableBuilder` 包住「检查更新」（`:338`，忙碌时写「正在检查…」）与「立即下载并安装」（`:345`）。
- **弹窗**：`AlertDialog`，标题「发现新版本 v0.3.14」，正文列当前 → 新版本、发布时间与附件体积，**更新说明放进固定高度（≤360 逻辑点）的 `Scrollbar + SingleChildScrollView`**——真实正文 12357 字符，不滚就看不见「修复了什么」；按钮三枚：`立即更新`（→ 下载 + 进度 + 交给平台策略）、`忽略本次更新`（写 `ignoredUpdateVersion`）、`以后再说`（只记本次节流）。
- **挂载**：不新开全局 Navigator key。宿主 `UpdatePromptHost` 包住非 TV 的 `home`（`packages/app/lib/main.dart:94-102`），用 `ModalRoute.of(context)!.isCurrent` 只在根页可点时弹——推到播放页/详情页时不抢画面；`resumed` 观察者由控制器持有，`dispose` 摘掉（先例同 `download_manager.dart:89,534,554`）。

## 7. 后端/分发配合清单（本轮不改上游，只记录约束）

1. Release 附件名与 `Hongguo-<version>-` 前缀是接口；改名要同批改 `package_desktop.py`、`validate_release.py` 与本模块的选件表。
2. 每个附件必须带 `digest`（GitHub 现给）或让 `SHA256SUMS.txt` 可查——两者都缺时本模块**不装**，只报「无法校验」。
3. `body`（发布说明）就是用户看到的更新内容：`tool/ci/validate_release.py:29-63` 写出的那条滚动列表要能被当成 changelog 读，否则弹窗里滚的是无意义长文。
4. macOS 若要真正的静默自替换，需要放弃 `app-sandbox` 并改用带公证的签名（现在只是 ad-hoc 签名，见发布说明尾注）。这是分发姿态决定，不在本轮。
5. 未认证 GitHub 配额 60/小时/IP：共享出口 IP 的用户群变大会撞限流，届时给 `flutter build` 传 `--dart-define=HONGGUO_UPDATE_TOKEN=…`（CI secret）并加 `Authorization`，本模块已把请求头组装留在一个位置。

## 8. 验证计划

- `dart test`（packages/update）：夹具回放解析、版本比较、每平台选件、ETag/304、sha256 不符与 `.part` 清理、忽略与节流语义。
- `flutter test`（packages/app）：弹窗正文可滚（长 body 断言滚动条存在）、三个按钮各自的写入与不写入、设置页「检查更新」行的忙碌/结果态、根页挂载在推入播放页时不弹。
- 门禁：`tool/verify_all.sh` 全量（含新包一行）。
- 实机：macOS 真实窗口跑一次手动检查 → 下载 → 校验 → 弹出 dmg，帧入 `docs/evidence/auto-update/`；Windows/Linux/Android 无设备，不写任何装机成功结论。

## 9. 本轮结果（2026-10-29 执行）

代码全部落地：`packages/update`（`lib/src/` 六个文件 + 钉死真响应的夹具）、`packages/app/lib/update/`（controller / dialog / host / install_strategy / android_update_channel / app_release）、`AppSettings` 四字段、设置页「更新」段、Android 通道与 `REQUEST_INSTALL_PACKAGES`、注册点（根 `pubspec.yaml:10` 与 `:42`、`tool/verify_all.sh:16`、`.github/workflows/build.yml:64-66`）。

门禁（`.fvm` 钉的 SDK，`HONGGUO_FLUTTER_BIN` 给绝对路径）现读：`dart format` 233 files 0 changed、`dart analyze --fatal-infos` No issues found、core 117 / api 91 / update 33 / cast 52 / tv 36 / app 296（外加一条早有的 skip）全绿，`tool/ci/tests/test_release.py` 10/10（含新增的「Dart 版本常量不许落后 pubspec」那条）。

实机 macOS：取证前按 `tool/verify_auto_update_live.sh` 的要求把 `AppRelease.version` 临时降到 `0.3.12`，跑完还原当时工作树的 `0.3.13+25`（发版时再一起升到 `0.3.14+26`）。第五轮 marker 全序（`build/verification/auto-update/run5.log`）：`armed` → `dialog-prompt` +3.0s（**启动检查自己弹的，没按任何按钮**）→ `dialog-scrolled` +5.6s → `install-ready` → 心跳 `bar=1 texts=[正在下载 2%, 正在下载…]` → `downloading` +8.6s → `settings-handoff` +13.2s → `settings-check` +16.9s → `done` +18.9s，`flutter test` 退出 0。22,547,501 字节的 dmg 落进沙箱 `updates/`、sha256 对得上、被 `open` 挂载；`settings-check` 这一步是「装了但没重启」的同一会话里第二次手动检查，它仍然回答「发现新版本 v0.3.13」，即 §4 那条 ETag 规则真的在生效。

实机跑出来的五个缺陷，每一个都是合成测试给不出的：

| # | 现读症状 | 根因 | 修法与回归用例 |
| --- | --- | --- | --- |
| 1 | 第一屏弹窗之后崩溃 `The Scrollbar's ScrollController has no ScrollPosition attached` | dialog 路由没有 `PrimaryScrollController`，`Scrollbar` 的淡出计时器在没附 position 的控制器上断言；widget 测试不复现，因为合成测试不跑那条淡出计时 | `UpdateDialog` 改 `StatefulWidget`，正文的 `Scrollbar` 与 `SingleChildScrollView` 共用它自己的 `ScrollController` |
| 2 | 弹窗挂着未结清时，下一次检查把用户欠的那版说成「自上次检查以来没有新版本」 | 无 offer 与否都缓存 ETag，304 就顶掉了整份 body | `_retain(keepEtag:)` 只在 `upToDate` / `unchanged` 时留校验子 → `test/update_prompt_test.dart`「only a settled check gets to cache the feed」 |
| 3 | 下载 5–9 秒里弹窗一次 rebuild 都没有，进度条从未出现（心跳 `bar=0`） | 进度回调拿每一片和**上一片**比，22 MB 分成 4,129 片、每片只差 0.2 点，「差满 1 点」永远不成立 | `reportProgress` 与「上次宣布过的位置」比、满 100% 强制宣布 → `test/update_controller_test.dart`（4,129 片 → 一百次量级通知，且到达 1.0）+「a download in flight shows its own bar and its own bytes」 |
| 4 | macOS 弹窗写「安装包约 34.8 MB」 | 读的是 `release.assets.first`，即 Android APK 的 36,447,668 字节；dmg 其实是 22,547,501 | 改读 `currentUpdateTarget().installer(release)`，文案「本机安装包约 …」 |
| 5 | 交接成功后同一会话还会再弹一次 | `unseenOffer` 只在 以后再说 / 忽略 时清，install 的路径没清，`finally` 的 notify 又把弹窗推回来 | `install()` 成功路径清 `unseenOffer` |

**本轮没有画面证据**：这台 shell 的 `screencapture -x` 只写得出桌面壁纸——两张 1920×1080 原帧里没有任何窗口或菜单栏（同一时刻 `osascript` 报告 GUI 会话确实在跑，所以是采集侧的权限/会话限制，不是 app 的问题），驱动脚本按 `HGWIN` 裁出来的只是空背景；那两张废帧已删、未入库，`docs/evidence/auto-update/` 本轮为空。macOS 侧的结论因此只到「运行期 marker + 断言」这一级，像素级 UI 结论留给下一次能取到窗口画面的轮次。

发版状态：用户先要求「执行完成后进行git提交推送到远端」，两个提交已快进进 `main`（`8107c8f`）；随后要求「执行推送发布新版本」，于是切 **0.3.14+26**——根 `pubspec.yaml:4`、`packages/app/pubspec.yaml:5`、`packages/app/lib/update/app_release.dart:8-9` 三个面一起动，`tool/ci/validate_release.py` 的滚动发布说明加了自动更新一条（写清只有 macOS 实机链路与本轮无帧）。Windows/Linux 的静默安装与 deb 交接、Android 的 `PackageInstaller` 真机安装、iOS 弹窗、TV 排除仍只有单测。

### 9.1 发版补记（同一日，标签 `v0.3.14`）

- 切版本提交 `a62423a`（5 文件），先推 `main`（`8107c8f..a62423a`，push 包 3.2 KB 单帧），再打**轻量**标签 `v0.3.14` 指向同一提交并推标签。
- 该提交的树在分离 worktree 里过全量门禁：`Formatted 233 files (0 changed)`、`No issues found!`、core 117 / api 91 / update 33 / cast 52 / tv 36 / app 296~1 全绿、`VERIFY_EXIT=0`；`tool/verify_all.sh` 不含的 `tool/ci/tests` 另跑 **10/10 OK**。
- 发布运行 `40883459556`（event=push，`gh run view` 的 jobs 现读）：`preflight / build-plan / build-verify / native(macos) / native(android-tv) / native(windows) / native(android) / native(linux) / publish` 九条 **success**，`ios-signed` **skipped**；`gh release view v0.3.14` 给 `prerelease=false`、`publishedAt=2026-10-29T13:48:48Z`、正文 14,290 字符、**15 个附件**且每个都带 `sha256:` digest（`macos-arm64.dmg` 22,586,894 字节）。
- **这是更新链路第一次面对一个真实可装的发布**，所以用随本轮入库的 `packages/update/tool/live_feed_check.dart`（跑线上 feed，不属于任何门禁）读了一遍 shipped kernel 的判断：`viewer on v0.3.13 -> available`、同一个人忽略该 tag 后 `-> ignored`、`v0.3.14 -> upToDate`；选件按平台各自命中 `Hongguo-0.3.14-{macos-arm64.dmg, windows-x64-setup.exe, linux-x64.deb, android-arm64-v8a.apk}`，`ios -> NONE`，全部 `host=github.com`，`SHA256SUMS.txt` 与 `release-manifest.json` 都在。
- **标签树的既定不对称**：这份补记与那个 live 检查工具排在 `a62423a` 之后，所以 `v0.3.14` 这棵树里没有它们——和历轮「帧排在标签之后」是同一笔代价，要看读数取 `main`。

### 9.2 发版补记（2026-10-30/31，标签 `v0.3.15`）

- 切版提交 `faf3e2c`（4 文件）：三处版本常量同步 **0.3.15+27**（根 `pubspec.yaml:4`、`packages/app/pubspec.yaml:5`、`packages/app/lib/update/app_release.dart:8-9`，`release_meta.version()` 的口径），滚动发布说明补五条——鼠标族分层筛选与榜单目的地、触屏族吸底尾栏/排序弹层/榜入口、选集落在正在看的那一集、被拒播放身份先换再问，外加一条把验证口径写死的说明：**本轮只有单测/组件态与 `docs/evidence/ranking-fields/` 的实机词表，没有任何 macOS 窗口帧或 iPhone 帧，所以正文不声称实机验证**，那一步仍属 Mac 验收。
- 中间夹一笔纯文档提交 `298421d`（发现/榜单原型加 TV 遥控器视图 + §6.2 逐层表），不碰 `packages/**/lib`，所以发布树里的代码与切版前验证过的树等价。
- 切版前在本地 NTFS 克隆跑的读数：`Formatted 1 file (0 changed)`、`flutter analyze` = `No issues found!`、`test/update_prompt_test.dart` +8 全过；版本三处一致性用 node 现读核对为 `0.3.15+27 / 0.3.15+27 / 0.3.15+27`。全量门禁的绿是上一格 `2ad9643` 那轮记的（core 117 / api 52 / update / cast / tv 36 / app 324~1、双 oracle 103 向量、`verify_media` 84 样本）。
- **发布范围的一次取舍**：工作树里另有触屏下载选集改 `TvGrid` 与 TV 库页两路在途改动，实测把 3 个既有 `tv_feed_test` 打破（`Tried to build dirty widget in the wrong build scope`，回退 `tv_library_page.dart` 后 18 个全过），按「只发已验证内容」留在树内，没进 `faf3e2c`，因此也不在 `v0.3.15` 里。
- 发布运行 `41086909414`（event=push，jobs 现读）：`preflight / build-plan / build-verify / native(macos-15) / native(android-tv) / native(android) / native(linux) / native(windows-2022) / publish` 九条 **success**，`ios-signed` **skipped**。Release `v0.3.15`：`draft=false`、`prerelease=false`、`publishedAt=2026-10-30T16:23:40Z`、正文 15,946 字符、**15 个附件**且每个带 `sha256:` digest（`Hongguo-0.3.15-macos-arm64.dmg` 22,646,177 字节）。
- shipped kernel 的线上读数（`cd packages/update && dart run tool/live_feed_check.dart 0.3.14 0.3.15`）：`viewer on v0.3.14 -> available`、同一人忽略该 tag 后 `-> ignored`、`v0.3.15 -> upToDate`；选件按平台各自命中 `Hongguo-0.3.15-{macos-arm64.dmg 22646177, windows-x64-setup.exe 26787270, linux-x64.deb 9875086, android-arm64-v8a.apk 36579184}`，`ios -> NONE`，全部 `host=github.com`，`SHA256SUMS.txt` 与 `release-manifest.json` 都在。
- **同一笔不对称**：这份补记排在 `faf3e2c` 之后，所以 `v0.3.15` 树里没有它；标签指向 `faf3e2c` 本身，读数要看 `main`。
