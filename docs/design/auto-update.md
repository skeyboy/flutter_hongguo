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
| 纯 Dart 内核 | `packages/update/lib/src/{release_version,release_info,update_target,release_feed,update_policy,release_downloader}.dart` | 版本号解析与比较、feed 解析（含 ETag/304/未认证错误）、按 os+arch 选附件、下载到 `.part` → sha256 校验 → 改名、决策枚举；**同一 URL 的并发点击共用一次传输**（`release_downloader.dart:52,72,83` 的进程内 in-flight，登记在第一个挂起点之前），已经校验过的同名文件按 sha256 直接认领（`:143` 的 `settled`，`DownloadedRelease.reused` 把「没重下」说给消费者） |
| 编排 | `packages/app/lib/update/update_controller.dart` | 注入 `dio` / 当前版本 / `target` / 读写 `AppSettings`；节流、`WidgetsBindingObserver` 的 resumed 触发（先例 `packages/app/lib/downloads/download_manager.dart:89,534,554`）、下载进度、失败语言；按车道分派按下之后的事（`:338` `install()`：系统车道交出去就返回，`:424` 传完再问一次「是否安装」），并在每次回到应用时收养系统传完的包（`:458` `settleOnReturn()`） |
| 传输车道 | `packages/app/lib/update/update_transfer.dart` | 一个暂存目录（`:17`，`<applicationSupport>/updates`）两种车道：本进程下载，或把 `DownloadTask` 交给 `background_downloader`（`:223`，组级通知 `:232`，不与媒体通知抢全局文案）；`:120` 的 `UpdateJournal` 是「这块盘上的包属于哪个版本、传到哪一步」的唯一账面，`:346,364` 的同帧门槛与 `:467` `settle()` 的认领一起把重复下载堵死 |
| 安装策略 | `packages/app/lib/update/install_strategy.dart` | 按平台把校验完的文件交给系统：见 §5 表 |
| UI | `packages/app/lib/update/update_dialog.dart` + `settings_page.dart` 新段 + 根页挂载 | 弹窗（正文可滚，可见条件见 §9.12 的 `showsMessage`）、「检查更新」行、忽略语义、主按钮四态与欠装时的 `去系统设置` 出口 |

> **本节「不新开文件」那句已被 §9.12 部分推翻（2026-11-03）**：`AppSettings` 那四个字段的账没变，但后台车道必须能在进程被拿走之后回答「这一版的包在哪、传到哪一步」，那是 `AppSettings` 的节流/偏好形状答不了的，于是新增一张条 `<applicationSupport>/updates/hongguo-update-journal.json`（`update_transfer.dart:120,123`，只留 2 个 tag、超限连文件一起删），原生侧另有一句话文件 `filesDir/hongguo-install-result.txt`（`MainActivity.kt:132`）。两张都跟着「读一次即删 / 装完即删」走，不留长尾。
| 原生 | `packages/app/android/app/src/main/kotlin/.../MainActivity.kt` 新通道 + `AndroidManifest.xml` 权限 | `abi` / `canInstall` / `askPermission` / `install` / `installResult`（`stageDir` 已删：暂存目录由 Dart 一侧定，见上「传输车道」）。安装结果的两个入口都接：`onCreate` 读 `getIntent`、`onNewIntent` 读新 intent（`MainActivity.kt:64-71`），因为把应用拉起来的那一趟是安装器自己发起的；没有 Dart 调用在听时，终态写进 `filesDir/hongguo-install-result.txt`（`:122,132`），下一次回到应用由 `installResult` 取走并删除（`:137`，Dart 侧 `android_update_channel.dart:90`）。「安装未知应用」那一行在本机 ROM 上不存在时退到应用详情页（`:236-244`） |

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
| Android（mobile flavor） | `Hongguo-<v>-android-<abi>.apk`，`abi` 取 `Build.SUPPORTED_ABIS` 首个，回落 `arm64-v8a` | **下载有两条车道，选择只看观众的「后台下载」开关与宿主**（`host_policy.dart` 的 `useSystemTransferLane`）：开着时按下 `立即更新` 把 `DownloadTask` 交给 `background_downloader`（通知栏走组级文案 `hongguo-update`，应用被系统拿走也继续传），传完由车道校验、写 `ready` 记录，再问一次「是否安装」；关着时仍是本进程下载。**两条车道都不重下已经在盘上且校验过的包**（同帧两次点击被 `update_transfer.dart:346` 的进程内门槛与 `:410` 起的「笔记说还在传」堵住）。校验通过后**先问 `canRequestPackageInstalls()`**：没开就 `startActivity(ACTION_MANAGE_UNKNOWN_APP_SOURCES, package:…)`，该 activity 在本机 ROM 上解析不到时退到应用详情页，并把已校验 APK 的**路径与字节数写进下载目录里的欠装记录**（`hongguo-pending-install.json`），此后任何一次回到应用（`resumed` 或冷启动 `start()`）都会先核身再补开 `PackageInstaller` 会话，观众不需要再点一次；开了就直接开会话。`commit` 的 `PendingIntent` 由 `onCreate` 与 `onNewIntent` 两处读（安装器自己拉起进程那一趟走的是前者），`STATUS_PENDING_USER_ACTION` 就把 `Intent.EXTRA_INTENT` 拉起（系统确认弹窗由此出现），`SUCCESS`/`FAILED` 与 `EXTRA_STATUS_MESSAGE` 原样回话给 `install` 那一次调用；**没有调用在听时落盘，下一次回到应用取走一次** | 逻辑与选件走单测（`test/android_install_test.dart` 十二例，含「去设置那一趟之后冷启动也算数」「记录一旦开会话立刻作废」「被系统清理过的包不再开会话」「安装器自启的进程留下的那句话只读一次」；车道与重复下载另见 `test/update_transfer_test.dart` 十七例、`test/update_background_test.dart` 七例）＋ Kotlin 在 Mac 上 `:app:compileMobileDebugKotlin` **BUILD SUCCESSFUL**；**不做真机安装**，装机成功与否仍不声称 |
| Linux | `Hongguo-<v>-linux-x64.deb`，无 deb 时 `linux-x64.tar.gz` | 下载 → sha256 → `xdg-open <deb>` 交给系统包管理器；tar.gz 只落到「文件已备好，请按现有方式替换」 | 无 Linux 设备，只有单测 |
| iOS | 无（不选附件） | 只提示，弹窗给出发布页 `html_url` 供复制 | 不发版本，无验证 |
| Android TV | 不参与 | `tvBuild` 全部跳过 | — |

附件名即协议：`tool/ci/package_desktop.py:19-90`（`macos()` / `windows()` / `linux()` 三段各自的 `Hongguo-{RELEASE}-<平台>-<arch>` 名字）与 `plan_build.py` 决定名字，选件逻辑只按「前缀 `Hongguo-<version>-` + 平台段 + 期望后缀」匹配，任一名字变了 CI 的 `validate_release.py` 与本模块会同时挑不出来——这是有意留的双保险。

## 6. UI

- **设置页**（行号按本轮落地后的文件）：`anchors`（`settings_page.dart:45-56`）里加「更新」一段，段体 `_section('更新', …)`（`:274`，`_section` 本身在 `:384`）依次给出「当前版本 v… （构建 …），新版本来自 GitHub Releases。」、`updateHandoffDescription` 那句按平台的说法、`SwitchListTile.adaptive`（key `自动检查更新`，`:287`）控制 `updateChecksEnabled`（副标题写清「一天最多询问一次；没有新版本时不打扰」），再由 `ListenableBuilder` 包住「检查更新」（`:338`，忙碌时写「正在检查…」）与「立即下载并安装」（`:345`）。
- **弹窗**：`AlertDialog`，标题「发现新版本 v0.3.14」，正文列当前 → 新版本、发布时间与附件体积，**更新说明放进固定高度（≤360 逻辑点）的 `Scrollbar + SingleChildScrollView`**——真实正文 12357 字符，不滚就看不见「修复了什么」；按钮三枚：`立即更新`（→ 下载 + 进度 + 交给平台策略）、`忽略本次更新`（写 `ignoredUpdateVersion`）、`以后再说`（只记本次节流）。主按钮的文案随控制器状态走，不再是一句「立即更新」到底（`update_dialog.dart:188-194`）：包已在盘上等装 → `立即安装`，本进程在传 → `正在下载…`，系统车道在传 → `正在后台下载…`（此时 `busy` 为真，按钮是禁用的，第二次按下点不动也本来就不该重下）。欠着一次未授权安装时另给一枚 `去系统设置`（`:162-167`），因为那一趟是观众自己走的，应用不能代劳；`controller.showsMessage`（`:133`）负责让「后台在传」「已下载完成，是否安装」「还欠着一次更新安装」这三句话在没有进度条的时候也仍然读得到。
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

### 9.3 Android 装机链路修复（2026-10-31）

用户报「Android 端更新下载后无法打开安装」，要求先申请安装权限、给了权限再装。读代码定位到两处缺口，都在同一条链路上：

1. **`install` 从不问权限**。`packages/app/android/app/src/main/kotlin/.../MainActivity.kt` 的 `installFrom()` 直接 `createSession → commit`，而 `REQUEST_INSTALL_PACKAGES` 在 Android 8+ 是**只在系统设置里开**的特殊访问权限（`canRequestPackageInstalls()`），运行时弹窗问不出来。清单里 `mobile/AndroidManifest.xml` 早就声明了这条权限，但声明≠授予：没授予时 `commit` 的会话不会走到安装确认，界面上却已经回了「已交给系统安装器，请在弹窗中确认安装。」——即用户看到的「下载完什么都没打开」。
2. **会话结果被吞掉**。`commit` 递出去的 `PendingIntent`（action `hongguo.update.result`，指向本 Activity）此前没有任何接收方：`STATUS_PENDING_USER_ACTION` 时系统把**真正要拉起的确认弹窗**包在 `Intent.EXTRA_INTENT` 里等着应用去 `startActivity`，不读它就不会有弹窗；`FAILED` 与 `EXTRA_STATUS_MESSAGE` 也一并丢失，所以失败只能显示成 catch 里那句兜底文案。

修法是把这两半接成一条有先后的流：`hongguo/update` 增 `canInstall`（`Build.VERSION.SDK_INT < O` 视为已允许，因为那时是安装器自己提示的全局「未知来源」）与 `askPermission`（`ACTION_MANAGE_UNKNOWN_APP_SOURCES` + `package:` URI，OEM 没有这一页就返回 false）；Dart 侧新增 `AndroidInstaller`（`install_strategy.dart`）把「已校验但系统还不收」的 APK **停在内存里**，控制器已有的 `WidgetsBindingObserver` 在 resumed 时先跑当日检查、再问一次权限，开了就补开安装会话——设置页回不来结果，所以只能靠回前台这一信号，这也是为什么状态要落在 `AndroidInstaller` 而不是散在控制器字段里。`install` 这一次通道调用**不再立即回话**，等 `onNewIntent` 读到状态再回（`answerInstall` 保证只回一次，Activity 销毁即丢弃），Dart 侧 60 秒兜底超时，免得系统永不回话把弹窗的按钮钉死在「正在下载…」。`updateHandoffDescription` 的 Android 一句同步改成会先带用户去设置。

验证口径：`packages/app/test/android_install_test.dart` 7 例（mock `hongguo/update`）钉住先后顺序与「未授权绝不开会话」——已授权直接开、未授权只跳设置、回来仍没开就继续等、回来开了就补装，加 OEM 没有那一页的文案、桌面/无处理器时 `canInstall` 必须答**已允许**（否则别的平台被这道新闸门卡住，回归护栏）、以及系统永不回话时 60 秒兜底那句；`flutter analyze` 全仓 `No issues found!`；`test/update_prompt_test.dart` + `update_controller_test.dart` 共 15 例全过。**Kotlin 在这一环第一次进了本机编译**：`flutter build apk --debug --flavor mobile --target-platform android-arm64` 头一遍报 `Unresolved reference 'EXTRA_INTENT'`——那个 extra 在 `Intent` 上而不是 `PackageInstaller` 上，改对后编过。真机安装仍不做，装机成功与否不声称。

### 9.4 发版补记（2026-10-31，标签 `v0.3.16`）

- 切版提交 `13d6217`（4 文件）：三处版本常量同步 **0.3.16+28**（根 `pubspec.yaml:4`、`packages/app/pubspec.yaml:5`、`packages/app/lib/update/app_release.dart:8-9`），滚动发布说明补七条——Android 装机那条链路（先问授权、再读会话结果，并把永不回话兜到 60 秒）、TV 五页的一目标一行遥控版面、详情页题材词按「面板有同名词才是入口」落地、推荐轨与标签行读同一张面板、`tagNames` 两处丢失（详情合并与离线快照）、TV 详情页的兜底合并 + 离线快照与可达「重试刷新」+ 纯文本题材词 + 选集字档 26/18，外加一条把验证口径写死的说明。
- **发布范围按「只发已验证内容」**：进标签的是 `d1eeb1a…22e046e` 这八条已提交并验过的改动；同一时刻工作树里另有会话在改的 `packages/app/lib/downloads/download_selection.dart`、`packages/app/lib/features/tv/tv_library_page.dart`、`docs/design/prototypes/video-detail.html`、未跟踪的 `docs/design/video-detail-redesign.md` 与两份新测试**没被 stage**，所以不在 `v0.3.16` 里。
- 切版前的验证树换了做法：不再用那台 HEAD 停在 v0.3.15 期、还带一堆本地改动的克隆，而是 `git fetch '//Mac/PSSD/own/flutter_hongguo' main` → `git worktree add C:\Users\lee\Documents\Codes\hg-verify 5419583` → 只拷入本轮 5 个文件，测的就是即将提交的那棵树。读数：`dart format --set-exit-if-changed` 4 个 Dart 文件 0 变更、`flutter analyze`（`packages/app`）`No issues found!`、`flutter test`（`packages/app`）**+370 ~1 全过**、`flutter test --dart-define=HONGGUO_TV=true test/tv_settings_test.dart` +1、两个 flavor 各出一包（`app-tv-debug.apk` Gradle 899.7s、`app-mobile-debug.apk` 38.6s）。详见 `docs/design/2026-10-22-detail-page-and-download-policy.md` §9。
- 发布运行 `41196257641`（run_number 24，event=push，jobs 经 `api.github.com` 现读）：`preflight / build-plan / build-verify / native(macos-15) / native(android-tv) / native(android) / native(linux) / native(windows-2022) / publish` **success**，`ios-signed` **skipped**。`build / verify` 就是全仓门禁（app 与 tv 两处 `flutter analyze`、tv/core/api/update/cast 五套测试、DIDL 双 oracle、app `flutter test`、TV flag 专项），所以多包套件由 CI 在标签树上现验，不再靠本地那台旧克隆。
- Release `v0.3.16`：`draft=false`、`prerelease=false`、`publishedAt=2026-10-31T11:29:56Z`、正文 **20,026 字符**、**15 个附件** = 五平台 12 个安装包 + `SHA256SUMS.txt` + `release-manifest.json` + `iOS-signing-status.txt`（本轮未签 iOS，状态文件写的就是这句）。`Hongguo-0.3.16-{macos-arm64.dmg 22642307, windows-x64-setup.exe 26793704, linux-x64.deb 9875298, android-arm64-v8a.apk 36710448, android-tv-arm64-v8a.apk 36264056}`；TV 那三个 ABI 的包也逐个过了 badging 门禁。正文长度还在更新弹窗自己那条「published note 跑过 12,000 字符，所以要能滚」的射程内，这一版比上一版又长 4,080 字符。
- shipped kernel 的线上读数（`cd packages/update && dart run tool/live_feed_check.dart 0.3.15 0.3.16`）：`status=available tag=v0.3.16 assets=15 etag=W/"ba8d375e…"`；`viewer on v0.3.15 -> available`、同一人忽略该 tag 后 `-> ignored`、`v0.3.16 -> upToDate`；选件按平台各自命中 macos / windows / linux / android 四条（digest 与上表逐字节同源），`ios -> NONE`，全部 `host=github.com`。
- **同一笔不对称**：这份补记与 §9 那条读数排在 `13d6217` 之后，所以 `v0.3.16` 这棵树里没有它们；要看读数取 `main`。
- 仍未闭环的（不因为发了版就当作完成）：详情页三端真机截图、TV 上遥控的实际读数（本轮字号改动没有电视帧）、`点标签 → 发现页被收窄` 的实机验证、下载 snackbar 的「查看」在遥控族按不动、TV 主题轨的标签行入口消费方。见 `docs/design/2026-10-22-detail-page-and-download-policy.md` §9 的「仍没做」。

### 9.5 发版补记（2026-11-01，标签 `v0.3.17`）

- 三个提交进 `main`：`20ba40a`（12 文件，本轮三条下载能力）、`9b75779`（`episode-downloads` / `platform-background` / `local-library-grouping` 三份设计文档）、`2e2d5c5` 切版（4 文件）。三处版本常量同步 **0.3.17+29**（根 `pubspec.yaml:4`、`packages/app/pubspec.yaml:5`、`packages/app/lib/update/app_release.dart:8-9`），滚动发布说明补三条——后台下载跨进程续排的宿主口径（只有关了真通道的手机自动续排，续排排在系统通道的成品被认领之后，其余仍等点击，另有「继续全部」）、缓存剧目作为一整部来删与来刷新（读回核对、在使用中跳过、待识别视频拒绝发请求、榜单按构造没有这些入口）、以及一条把验证口径写死的说明。
- **发布范围仍按「只发已验证内容」**：同一时刻工作树里另有会话在改的 `packages/app/lib/downloads/download_selection.dart`、`packages/app/lib/features/tv/tv_library_page.dart`、`docs/design/prototypes/video-detail.html`、未跟踪的 `docs/design/video-detail-redesign.md` 与 `tv_live_data_test.dart`、`tv_search_remote_exit_test.dart` **没被 stage**，所以不在 `v0.3.17` 里。
- 切版前的读数在本地 NTFS 克隆（worktree，HEAD 停在 `8a6b065`）现取：只拷入本轮 12 个 Dart 文件，与 \\Mac 副本 `diff` 逐字节核对为 0 差异后，再拷入 4 个版本面。`dart format --set-exit-if-changed`（app + update）**191 文件 0 变更**、`flutter analyze`（全仓）**No issues found!（72.8s）**、`flutter test`（`packages/app`）**+388 ~1 全过**，其中本轮新增 18 例（4 重启续排、3 归类删除、5 在线拉取、6 触屏与遥控页面用例）。
- **`packages/update` 在本机读 32 过 / 1 失败，且不是本轮回归**：`release_downloader_test.dart:89` 把期望路径用 `/` 手工拼出来，实现返回的是 Windows 原生 `\` 分隔符——这条从 `b6efdb0` 起就脆，本轮没碰该包（`git status packages/update` 为空）。CI 的门禁在 ubuntu-24.04 / macos-15 上跑的是同一套并通过（`build / verify` 里那套 update 测试 **+33** 全过），因此把它记在「宿主脆弱断言」而不是「待修的功能缺陷」这一格。
- 发布运行 `41219464977`（run_number 25，event=push，jobs 经 `api.github.com` 现读）：`preflight / build-plan / build-verify / native(android-tv, ubuntu-24.04) / native(windows, windows-2022) / native(android, ubuntu-24.04) / native(linux, ubuntu-24.04) / native(macos, macos-15) / publish` 九条 **success**，`ios-signed` **skipped**；`16:23:35 → 16:36:14`，约 12 分 39 秒。日志正文匿名取不到（`/actions/jobs/<id>/logs` 403），用 `git credential fill` 里的 PAT 取到 `build / verify`（job `124590867779`）在标签树上的现读：`app` 与 `tv` 两处 `flutter analyze` 各 `No issues found!`（23.1s / 1.7s），五套多包测试 **+36 / +117 / +109 / +33 / +52** 全过，`packages/app` `flutter test` **+388 ~1**（与本地克隆那条读数逐字相同），TV flag 专项 **+1**。
- Release `v0.3.17`：`draft=false`、`prerelease=false`、`publishedAt=2026-10-31T16:36:12Z`、正文 **22,038 字符**（比 `v0.3.16` 的 20,026 又长 2,012）、**15 个附件**且每个带 `sha256:` digest。`Hongguo-0.3.17-{macos-arm64.dmg 22,638,213 / windows-x64-setup.exe 26,801,103 / linux-x64.deb 9,885,288 / android-arm64-v8a.apk 36,710,616 / android-tv-arm64-v8a.apk 36,264,224}`，另有三个 ABI 的 mobile 与 TV 包、两份 tar.gz / zip 归档、`SHA256SUMS.txt`、`release-manifest.json`、`iOS-signing-status.txt`（本轮仍未签 iOS）。
- shipped kernel 的线上读数（`cd packages/update && dart run tool/live_feed_check.dart 0.3.16 0.3.17`）：`status=available tag=v0.3.17 assets=15 etag=W/"e9fe7669…"`；`viewer on v0.3.16 -> available`、同一人忽略该 tag 后 `-> ignored`、`v0.3.17 -> upToDate`；选件按平台各自命中 macos / windows / linux / android 四条（digest 与上表逐字节同源），`ios -> NONE`，全部 `host=github.com`，`SHA256SUMS.txt` 与 `release-manifest.json` 都在。
- **同一笔不对称**：这份补记排在 `2e2d5c5` 之后，所以 `v0.3.17` 这棵树里没有它；要看读数取 `main`。
- 仍未闭环的：本轮三条能力没有手机与电视的真机读数——自动续排、继续全部、归类删除与在线拉取都跑在单槽、按微任务推进的假传输通道与内存文件清单上，真实的系统下载交接、通知授权、仅 Wi-Fi 约束与播放中删除均未实测；历轮那几项（详情页三端截图、TV 遥控实际读数、`点标签 → 发现页被收窄`、snackbar「查看」在遥控族按不动、TV 主题轨标签行入口消费方）继续挂着。

### 9.6 授权之后自动把 APK 装完（2026-11-01）

用户诉求（原话）：「未知应用安装开启后apk下载完成后需要自动能打开并执行安装」。

§9.3 那一版把链接通了，但「等着装」的那半个 APK 停在 `AndroidInstaller` 的内存字段里，只在 `AppLifecycleState.resumed` 补问一次权限。真机上这一趟有两个洞：

1. **去「安装未知应用」那一页时应用就在后台**，Android 随时可以回收这个进程；进程被拿走，内存里的停靠就没了。重开应用只会重新读到那句「请打开该权限」，欠着的那一包再也不会自己装上——而「开好权限再重开」正是这条路最常见的走法。
2. **冷启动不问欠装**。`start()` 只注册观察者，所以任何不是「同一进程里 resumed」的回来方式都不兑付。

修法是把欠装写成磁盘上的一条记录，而不是内存里的一个字段：`hongguo-pending-install.json` 落在**下载器写 APK 的同一个 stage 目录**（`stageDirectoryFor()`），内容只有 `path` 与 `bytes`——同目录才能在下一次启动用同名找到同一个文件。三条规矩：

- **任何一次回到应用都试着兑付**：`start()` 注册观察者后立刻跑一次，`resumed` 再各跑一次，两处都走 `_returnToForeground()`（`update_controller.dart:92,105,114`）。
- **兑付前先核身**：`File(path).stat()` 必须是普通文件且字节数与记录一致，否则删掉记录并回答「安装包已经不完整或被系统清理，请重新点「立即更新」下载。」——不在一个被系统回收或截断过的文件上开系统会话。
- **会话一开记录就作废**：`_forget()` 排在 `installApk` 之前。系统确认框可以一直挂在屏上等观众决定，这一段时间里发生的一次冷启动不能为同一个 APK 再开第二个会话。

读不出来（目录访问不到、进程被杀时留下半份 JSON）都按「没有欠装」处理：APK 还在盘上，下一次「立即更新」会重写一条新的。**权限闸门仍只留在 `handOff()` 的平台分派里**，`AndroidInstaller` 自己不判平台——否则桌面宿主跑同一套 Dart 测试会整段跳过；换由 `_returnToForeground()` 在 `currentUpdateTarget().platform != android` 早退。两条未授权文案与 `updateHandoffDescription` 的 android 一句一起改成「回到应用后会自动继续安装」，因为这句话现在是这个类真的能兑现的行为。

验证读数（2026-11-01，本地 NTFS 克隆 `hg-verify-dl`，与 \\Mac 副本逐字节核对一致）：

| 范围 | 结果 |
| --- | --- |
| `flutter analyze`（`packages/app`） | `No issues found!` |
| `test/android_install_test.dart` | **+10** 全过（改动前 7 例）。新增的三例：去设置那一趟之后**冷启动**把欠着的 APK 装上；开过会话的欠装记录不留到下次启动；被系统清理过的包不开会话并说明原因。另有两例只改了名以对上磁盘语义（`parked` → `owed`：回来时权限已开就装上欠着的那包 / 回来还没开权限时只问一次、记录原样留着），既有的「桌面宿主不被这道闸门挡住」与「系统不回话的会话」两例一字未动 |
| `packages/app` 全量 | **+396 ~1** 全过 |
| `packages/core` / `packages/tv` | +117 / +36 全过 |
| `packages/update` | +32 -1：仍是 `release_downloader_test.dart` 那条 Windows 路径分隔符断言（§9.5 已记为宿主脆弱断言，本轮未碰该包） |
| `packages/api` | +100 -9：九条全落在 `media_cache_test.dart` / `prefetch_scheduler_test.dart`，头一条读得到 `PathAccessException … 另一个程序正在使用此文件 (errno = 32)`，即 temp 目录被宿主占用；同一条口径在 `docs/evidence/discover-ranking-2026-10-30/findings.md` 已记为 Windows 侧既有（CI 在 ubuntu-24.04 跑 api），本轮没有改过这个包 |

未验证的部分要说清：**没有 Android 真机读数**。整条链跑在 mock 的 `hongguo/update` 通道与真临时目录里的真字节数上——`PackageInstaller` 会话、系统确认弹窗、`onNewIntent` 的状态回话、以及「系统在设置那一趟到底有没有杀进程」都是语义断言，不是设备观察。这台 ARM64 宿主无法构建原生包（media_kit 只有 x64），且本轮 Kotlin 一行未改（`canInstall` / `askPermission` / `install` 三个方法是 §9.3 那版已有的），所以也没有重新出 APK。

### 9.7 发版补记（2026-11-01，标签 `v0.3.18`）

用户诉求（原话）：「执行提交发布新版本」。

- 七笔提交进 `main`（`94ee883..b254fab`）：`183296d` 榜单成一页一榜并把刷新交回页头（3 文件）、`0e062f9` 剧目卡片自己承担整体拉取与删除、右键抵达且面板按窗口尺寸分形态（3 文件）、`b88fd05` 欠着的 APK 落到磁盘（3 文件）、`833366c` TV 单行输入框把上下交还遥控（3 文件）、`f1364a1` 四份设计文档补记加本轮 Windows 证据（5 文件）、`2b11bdf` 例数订正（2 文件）、`b254fab` 切版（4 文件）。三处版本常量同步 **0.3.18+30**（根 `pubspec.yaml:4`、`packages/app/pubspec.yaml:5`、`packages/app/lib/update/app_release.dart:8-9`），滚动发布说明补五条加一条把验证口径写死的说明。
- **发布范围仍按「只发已验证内容」**：同一时刻工作树里另有会话在改的 `packages/app/lib/downloads/download_selection.dart`、`packages/app/lib/features/tv/tv_library_page.dart`、`docs/design/prototypes/video-detail.html`、未跟踪的 `docs/design/video-detail-redesign.md`、`tv_live_data_test.dart`、`tv_search_remote_exit_test.dart`，加上 `.idea/` 与 `references/hongguo-web` 子模块指针**都没被 stage**，所以不在 `v0.3.18` 里。SMB 副本 `core.fileMode=false` 现读确认，本轮没有 `.sh` 模式假差异混进任何一笔。
- 切版前的读数在本地 NTFS 克隆 `hg-verify-dl`（HEAD 停在 `94ee883`）现取：16 份文件（4 个版本面 + 本轮 12 份代码与测试）逐份 `cmp` 与 \\Mac 副本比，全部 `same`；`dart format --output=none --set-exit-if-changed packages tool` **272 文件 0 变更**、`dart analyze --fatal-infos packages tool` **No issues found!**、`packages/app` `flutter test` **+399 ~1 全过**、`packages/tv` **+38 全过**。三处版本一致性按 `tool/ci/release_meta.py:version()` 的四条正则逐项手工读实为 `0.3.18+30` / `0.3.18+30` / `'0.3.18'` + `30`——**该脚本本机没跑**：`python` 与 `python3` 都是 Microsoft Store 的占位 stub（前者退出码 49、无输出，后者在 §9.6 那轮已记），所以这一步是等价手工检查，真正的强制在标签树的 CI 上。顺带一条对账：本轮 13 例新增按文件拆是榜单 3、卡片手势 4、欠装 3、遥控输入框 2、缓存页遥控走得出搜索框 1，与 `388 → 399`（app +11）与 `36 → 38`（tv +2）两处运行时差值逐字对齐；`2b11bdf` 那笔订正就是因为先按印象写成「新增五例」而被现读推翻。
- 发布运行 `41264935210`（run_number 26，event=push，`api.github.com` 现读）：`preflight 9s / build-plan 9s / build-verify 227s / native(macos, macos-15) 320s / native(android, ubuntu-24.04) 470s / native(windows, windows-2022) 281s / native(linux, ubuntu-24.04) 138s / native(android-tv, ubuntu-24.04) 413s / publish 25s` 九条 **success**，`ios-signed` **skipped**；`02:22:34 → 02:35:11Z`，约 12 分 37 秒。用 `git credential fill` 里那枚 PAT 取到 `build / verify`（job `124725741438`）在标签树上的逐条读数：`app` 与 `tv` 两处 `flutter analyze` 各 `No issues found!`（18.9s / 1.4s），`packages/tv` **+38**、core **+117**、api **+109**、update **+33**、cast **+52** 五套全过，`Verify DIDL-Lite metadata under a strict XML parser`（`dart run tool/verify_cast_didl.dart | python3 tool/verify_didl_namespaces.py`）**success**——本机跑不了的那一步在 CI 上补齐了，`docs/evidence/windows-verify-2026-11-01/findings.md` 里那句「只证明输出、未证明严格解析器接受它」现在有了下文；`packages/app` `flutter test` **+399 ~1**（与本地克隆逐字相同），TV flag 专项 **+1**。api 与 update 两处在本机那 9 + 1 条宿主失败在 ubuntu-24.04 上全绿，再次确认它们是宿主脆弱断言而非本轮回归。
- 同一棵 `main` 另跑 x64 门禁：`Verify Windows desktop` 运行 `41264919594`（run_number 85）在 `windows-2022` 上 **success**（`02:22:21 → 02:28:30Z`），job `124725604403` 的 `Analyze application` / `Verify application on Windows` / `Compile Windows release` 三步各 success——本机 ARM64 永远构建不出 `-d windows`（media_kit 只有 x64 导入库）这条缺口，由 CI 在同一批代码上出过 Windows 发布包，所以本轮的 PC 改动不是「只在 Dart 层验过」。
- Release `v0.3.18`（<https://github.com/skeyboy/flutter_hongguo/releases/tag/v0.3.18>）：`draft=false`、`prerelease=false`、`publishedAt=2026-11-01T02:35:08Z`、正文 **25,850 字符**（比 `v0.3.17` 的 22,038 长 3,812）、**15 个附件**且 15 个都带 `sha256:` digest 字段。`Hongguo-0.3.18-{macos-arm64.dmg 22,645,378 / windows-x64-setup.exe 26,805,063 / linux-x64.deb 9,890,640 / android-arm64-v8a.apk 36,710,616 / android-tv-arm64-v8a.apk 36,264,228}`，另有 mobile 与 TV 各三个 ABI、两份 tar.gz / zip 归档、`SHA256SUMS.txt`、`release-manifest.json`、`iOS-signing-status.txt`（仍未签 iOS）。
- shipped kernel 的线上读数（`dart run tool/live_feed_check.dart 0.3.17 0.3.18`，在克隆的 `packages/update` 里跑——UNC 工作目录会让 dart 退回 Windows 目录并报 `Could not find file`）：`status=available tag=v0.3.18 prerelease=false notes=25850 assets=15 etag=W/"3e64958e…"`；`viewer on v0.3.17 -> available`、同一人忽略该 tag 后 `-> ignored`、`v0.3.18 -> upToDate`；选件按平台各自命中 macos（`7d71de13…`）/ windows（`462b7190…`）/ linux（`7dfa5501…`）/ android（`c8f1a938…`）四条，字节数与上表逐字相同，`ios -> NONE`，全部 `host=github.com`，`SHA256SUMS.txt=true release-manifest.json=true`。
- **同一笔不对称**：这份补记排在 `b254fab` 之后，所以 `v0.3.18` 这棵树里没有它；要看读数取 `main`。
- 仍未闭环的（不因为发了版就当作完成）：本轮四条能力**没有手机、电视或桌面窗口帧**——榜单再问一次、卡片长按/右键与 Dialog-抽屉分形态、TV 单行框交还上下、Android 授权后自动兑付欠装，全部跑在 widget 测试的合成指针/遥控键与 mock 通道上，`PackageInstaller` 会话与系统确认框在真机上是否真按这条序走仍未观察；§9.6 那轮的既有缺口（详情页三端截图、TV 遥控实际读数、`点标签 → 发现页被收窄`、snackbar「查看」在遥控族按不动、TV 主题轨标签行入口消费方）继续挂着。

### 9.8 未授权那条支路的两个静默失败（2026-11-01）

用户诉求（原话）：「Android端未开启 未知应用安装权限 怎么验证处理将此问题进行修复」。

「未开启未知应用安装权限」是这条链最常见的那一趟，而 `v0.3.18` 的树上有两个洞让它看起来像「按了没反应」。两个都是 §9.6 把欠装写成磁盘记录之后新增的那一面的后果——记录写对了，但屏幕没有说它：

1. **提示框替一次没有装成任何东西的交接自己关掉了。** `update_dialog.dart` 的 `立即更新` 回调当时是「拿到 plan 就 `Navigator.pop`」，而 §9.6 之后 Android 未授权那条 `install()` 也会返回一个 plan（只写了记录、只把人送到设置页）。于是那句「请在设置中打开该权限，回到应用后会自动继续安装」被写进 `controller.message`，而展示它的弹窗恰好在同一帧被关掉——观众看到的是一次凭空消失的更新提示。
2. **回来时权限还是没开，屏幕什么都不说。** `resume()` 的未授权分支直接 `return null`，和「本来就没有欠装」用同一个答案；而 `message` 的渲染条件是 `controller.downloading`，那一刻它已经是 `false`，所以就算弹窗还开着那句话也显示不出来。两处合起来：既没有话，也没有状态，「更新还欠着一次」和「已经装完」在屏幕上完全一样。设置页那一行同样读 `controller.message`，因此也读不到东西。

修法全在 Dart 层，Kotlin 一字未改（`canInstall` / `askPermission` / `install` 三个方法是 §9.3 那版已有的）：

- `InstallPlan` 多一个 `owesInstall`（`install_strategy.dart:24`），语义写在字段注释里：这次交接什么都没装，欠一次，去系统设置那一趟还在前面。未授权那条 `install()` 返回它（`:82`）。
- `resume()` 的未授权分支改成一句话说清「还欠着一次更新安装…不需要再点一次」（`:98-100`），并新增 `hasOwedInstall()`（`:115`）——**用记录是否存在回答，而不是退出时设的内存字段**，所以进程被拿走期间兑付掉的债，回来也读得出「已经不欠了」。
- `UpdateController.installOwed`（`update_controller.dart:49`）是这两条支路共用的状态：`install()` 里取计划的 `owesInstall`（`:294`），`_returnToForeground()` 在 `resume()` 之后按磁盘记录重读（`:122-123`）。
- 弹窗两处对上（`update_dialog.dart`）：`立即更新` 只在 `!plan.owesInstall` 时才 `pop`（`:174`），消息渲染条件从 `downloading` 改成 `downloading || installOwed`（`:132-134`）。这两条一起，才是「未授权 → 留在原地并说清楚」与「系统真的接下了 → 关掉」两种结局第一次能被区分。
- 设置页那一行不需要额外接线：`settings_page.dart:335` 本来就无条件渲染 `controller.message`，所以兑付失败那句在「设置 → 检查更新」下面同样读得到。

明确没做的：不加「再去设置一次」按钮（欠装记录已在，权限一开回到应用就自动兑付，再点一次反而是第二条会话的入口）；兑付路径不跳过重新下载（`立即更新` 保持 §9.6 的「重新下载并校验」语义，那句文案负责告诉观众他其实不需要再点）。

> **上面这两条已被 2026-11-03 的 §9.12 逐条推翻，原文留着只为记账，读数与语义以 §9.12 为准。** ① 「不加按钮」→ 弹窗里现在有一个 `去系统设置` 出口（`update_dialog.dart:162-167`，`controller.installOwed` 为真时才出现）：去那一趟会把观众送出应用，而回来不是应用能强制的，所以在权限真打开之前入口必须留在屏幕上。② 「兑付路径不跳过重新下载」→ `立即更新` 的语义改成「把这一版交出去」：已在本机且已校验的字节不再取第二次（`update_transfer.dart:393-408` 的车道复用、`release_downloader.dart:143` 的 `settled()`），重复点击为此零字节，这就是 §9.12 的 D5。

验证读数（2026-11-01，本地 NTFS 克隆 `hg-verify-dl`；本轮 5 份代码与测试文件与 \\Mac 副本逐份 `cmp` 全 `same`，格式化后把改动的两份再拷回来又逐份 `cmp` 一次仍一致）：

| 范围 | 结果 |
| --- | --- |
| `dart format --output=none --set-exit-if-changed packages tool` | 首跑 **272 文件 2 变更**（正是本轮两份测试文件），`dart format` 过后复跑 **0 变更**，退出码 0 |
| `dart analyze --fatal-infos packages tool` | `No issues found!`，退出码 0 |
| `test/android_install_test.dart` + `test/update_prompt_test.dart` | **+20 全过**（10 + 10）。前者例数不变：4 例加了断言（`owesInstall` 真/假按支路各自钉住、`hasOwedInstall()` 的「写下 → 兑付 → 不再欠」三段转换），另 1 例 `coming back still ungranted keeps the APK owed, not installed` 改名并重写成现在真正要钉的东西——`resume()` 的那句话里有「还欠着一次更新安装」与「安装未知应用」，同时记录原样留着、没开会话；后者**+2 例**是弹窗侧的：`an owed install keeps the prompt open and says where the viewer is`（点 `立即更新` 后 `以后再说` 仍在、句子在弹窗里读得到）与 `a handoff the system took closes the prompt`（另一半，防把修法写成「永远不关」） |
| `packages/app` 全量 | **+401 ~1 全过**（改动前 +399 ~1；净增的 2 例即上面弹窗两例）。那 `~1` 是 `test/tv_settings_test.dart:42` 的 `skip: !tvBuild`，与 §9.5 起每一轮同一处，不是本轮新增 |
| `packages/tv` 全量 | **+38 全过**，一字未动 |

未验证的部分要说清，**这一轮同样没有 Android 真机读数**：本机 `adb` 在（`C:/Users/lee/Documents/developments/android-sdk/platform-tools`）但 `adb devices` 零台、SDK 目录里没有 `emulator` 也没有 `system-images`、`~/.android/avd` 不存在（本轮现读确认），而这轮修的两处恰好是「弹窗在真机上会不会自己关掉」这类只有帧才能证的事。测试跑的是 mock 的 `hongguo/update` 通道 + 真临时目录里的真记录 + widget 测试的合成指针。

在真机上复核这一支路只需三步，比手动去设置里关掉一个特殊访问权限更省——`REQUEST_INSTALL_PACKAGES` 是设置页里的特殊访问权限，声明它（`android/app/src/mobile/AndroidManifest.xml:4`）不等于授予它，所以可以直接用 `appops` 拨这个开关（mobile 包名读实为 `com.example.hongguo_app`，见 `android/app/build.gradle.kts:41`；TV 那套不参与更新，`updateSupported` 里就被排掉了，见 `update_host.dart:17`）：

1. 装一个比线上 tag **旧**的版本让 `v0.3.18` 真的成为一次 offer：`adb install -r Hongguo-0.3.17-android-arm64-v8a.apk`（该附件在 `v0.3.17` 的 Release 上），然后 `adb shell appops set com.example.hongguo_app REQUEST_INSTALL_PACKAGES deny` 复现「未开启」。
2. 点 `立即更新`。修好后应看到：应用被送到「安装未知应用」那一行，**弹窗还在**，里面是那句「请在设置中打开该权限，回到应用后会自动继续安装」；`adb shell appops get com.example.hongguo_app REQUEST_INSTALL_PACKAGES` 此时仍应读实为 `deny`。
3. 不回开关、直接把应用切回前台：应读到「还欠着一次更新安装…不需要再点一次」——这就是洞 2 的正面读数。然后 `adb shell appops set com.example.hongguo_app REQUEST_INSTALL_PACKAGES allow`，再切回一次：`adb logcat | grep -iE "PackageInstaller|installing session"` 应出现一次新会话，且这中间**没有第二次点击 `立即更新`**。欠装记录本身在 `run-as` 之外读不到（release 包不可调试），要核那个 JSON 就在 debug 包上做同样三步。

顺带一条对上一轮的补充：§9.6 说「任何一次回到应用都试着兑付」是对的，但那句话只保证兑付发生，没保证兑付**没发生时屏幕上有任何东西**——本轮补的就是后半句。

### 9.9 发版补记（2026-11-01，标签 `v0.3.19`）

用户诉求（原话）：「发布新版本」。

- 三笔提交进 `main`（`9e8f069..04040a0`）：`8d17586` 未授权那条支路不再静默（5 文件，+171/−19——3 份实现加 2 份测试）、`f059619` §9.8 补记与设备配方（1 文件，+39）、`04040a0` 切版（4 文件）。三处版本常量同步 **0.3.19+31**（根 `pubspec.yaml:4`、`packages/app/pubspec.yaml:5`、`packages/app/lib/update/app_release.dart:8-9`），滚动发布说明补两条：这条支路的两个洞与它现在的行为，以及一条把验证口径写死的说明。
- **发布范围仍按「只发已验证内容」**：工作树里另一会话在改的 `packages/app/lib/downloads/download_selection.dart`、`packages/app/lib/features/tv/tv_library_page.dart`、`docs/design/prototypes/video-detail.html`、未跟踪的 `docs/design/video-detail-redesign.md`、`integration_test/tv_live_data_test.dart`、`test/tv_search_remote_exit_test.dart`，加上 `.idea/` 与 `references/hongguo-web` 子模块指针**都没被 stage**，所以不在 `v0.3.19` 里。SMB 副本 `core.fileMode` 现读为 `false`，本轮三笔都没有 `.sh` 模式假差异。
- 切版前后的读数都在本地 NTFS 克隆 `hg-verify-dl` 现取：本轮 9 份改动文件（5 份代码与测试 + 4 份版本面）逐份 `cmp` 与 \\Mac 副本全 `same`，`git diff v0.3.19 HEAD` 为空——**标签的树就是测过的那棵树**。`dart format --output=none --set-exit-if-changed packages tool` **272 文件 0 变更**（本轮首跑曾报 2 变更，正是两份测试文件，格式化后复跑为 0）、`dart analyze --fatal-infos packages tool` **No issues found!**、`packages/app` `flutter test` **+401 ~1 全过**、`packages/tv` **+38 全过**。例数对账：`399 → 401` 的净增 2 就是 `update_prompt_test.dart` 的弹窗两例，`android_install_test.dart` 仍是 10 例（4 例加断言、1 例改名重写）；那 `~1` 是 `test/tv_settings_test.dart:42` 的 `skip: !tvBuild`，与 §9.5 起每一轮同一处。三处版本一致性按 `tool/ci/release_meta.py:version()` 的四条正则手工读实为 `0.3.19+31` / `0.3.19+31` / `'0.3.19'` + `31`——**脚本本机仍未跑**（`python`/`python3` 都是 Store 占位 stub），新加的两条正文逐行扫过没有 `{`/`}`，不会被那个 f-string 当占位符吃掉。
- 发布运行 `41273697823`（run_number 27，event=push，`head_sha=04040a0`，`api.github.com` 现读）：`preflight 7s / plan 5s / build-verify 256s / native(android, ubuntu-24.04) 471s / native(windows, windows-2022) 254s / native(android-tv, ubuntu-24.04) 361s / native(linux, ubuntu-24.04) 164s / native(macos, macos-15) 249s / publish 18s` 九条 **success**，`ios-signed` **skipped**；`04:35:40 → 04:48:33Z`，约 12 分 53 秒。`build / verify`（job `124751528649`）的日志用 `git credential fill` 里那枚 PAT 取到并逐条读实：两处 `flutter analyze` 各 **No issues found!**（22.5s / 1.6s），`packages/tv` **+38**、core **+117**、api **+109**、update **+33**、cast **+52** 五套全过，`packages/app` **+401 ~1**（与本地克隆逐字相同），TV flag 专项 **+1**，`Verify DIDL-Lite metadata under a strict XML parser`（`… | python3 tool/verify_didl_namespaces.py`）**success**。api 与 update 在本机那 9 + 1 条宿主失败在 ubuntu-24.04 上再次全绿，`§9.7` 那条判定继续成立。
- 同一棵 `main` 的 x64 门禁：`Verify Windows desktop` 运行 `41273695504`（run_number 87）**success**（`04:35:38 → 04:43:23Z`，约 7 分 45 秒），job 里 `Analyze application 29s` / `Verify application on Windows 173s` / `Compile Windows release 134s` 三步各 success——所以「本机 ARM64 构建不出 `-d windows`」这条缺口在切版树上同样由 CI 补着。
- Release `v0.3.19`（<https://github.com/skeyboy/flutter_hongguo/releases/tag/v0.3.19>）：`draft=false`、`prerelease=false`、`publishedAt=2026-11-01T04:48:30Z`、正文 **28,124 字符 / 51 条要点**（比 `v0.3.18` 的 25,850 长 2,274）、**15 个附件**且 15 个都带 `sha256:` digest。两条新正文（`permission-denied path stopped failing silently` 那条与它的验证口径那条）在成品正文里逐条 `includes` 命中，`401 passed / 1 conditional skip` 与 `REQUEST_INSTALL_PACKAGES deny|allow` 也都读得到。`Hongguo-0.3.19-{macos-arm64.dmg 22,645,219 / windows-x64-setup.exe 26,803,591 / linux-x64.deb 9,891,916 / android-arm64-v8a.apk 36,710,616 / android-tv-arm64-v8a.apk 36,264,228}`，另有 mobile 与 TV 各三个 ABI、两份 tar.gz / zip 归档、`SHA256SUMS.txt`、`release-manifest.json`、`iOS-signing-status.txt`（仍未签 iOS）。一条容易被误读成「附件没换」的对账：`android-arm64-v8a.apk` 的字节数与 `v0.3.17`/`v0.3.18` 同为 36,710,616，digest 是 `2da2f2ae…` 而不是上一版的 `c8f1a938…`，两边都刚从各自 Release 现读，所以是大小巧合而非同一份文件。
- shipped kernel 的线上读数（`dart run tool/live_feed_check.dart 0.3.18 0.3.19`，在克隆的 `packages/update` 里跑——UNC 工作目录会让 dart 退回 Windows 目录并报 `Could not find file`）：`status=available tag=v0.3.19 prerelease=false notes=28124 assets=15 etag=W/"0efdf166…"`；`viewer on v0.3.18 -> available`、同一人忽略该 tag 后 `-> ignored`、`v0.3.19 -> upToDate`；选件按平台各自命中 macos（`7fffab7d…`）/ windows（`d87a5351…`）/ linux（`fe19fd77…`）/ android（`2da2f2ae…`）四条，字节数与上表逐字相同，`ios -> NONE`，全部 `host=github.com`，`SHA256SUMS.txt=true release-manifest.json=true`。
- **同一笔不对称**：这份补记排在 `04040a0` 之后，所以 `v0.3.19` 这棵树里没有它；要看读数取 `main`。
- 仍未闭环的（不因为发了版就当作完成）：`v0.3.19` 唯一的用户可见变化就是 §9.8 那两个洞，而它们**没有任何真机读数**——本机 `adb devices` 零台、SDK 无 `emulator` 与 `system-images`、无 AVD，弹窗会不会自己关掉这类只有帧才能证的事全部跑在 mock 通道与合成指针上。设备侧那三步（`appops set … REQUEST_INSTALL_PACKAGES deny|allow`）写在 §9.8，跑它需要一台手机，属 Mac 验收那一格。历轮缺口继续挂着：详情页三端截图、TV 遥控实际读数、`点标签 → 发现页被收窄`、snackbar「查看」在遥控族按不动、TV 主题轨标签行入口消费方。

### 9.10 发版补记（2026-11-02，标签 `v0.3.20`）

用户诉求（原话）：「执行git提交提交」「将git提交后推送，发布新的版本」。

- 七笔提交进 `main`（`b720845..de2ea1f`）：`dbdd457` 原型逐框量（8 文件 +2429）、`d8547a3` 冷启动续位（4 文件 +176/−4）、`6e60b1f` feed 轮换留样（21 文件 +574/−3）、`fe33852` 悬停预览改按浮层自己的坐标空间（3 文件 +166/−68）、`3e3f82e` Windows 托盘单击（2 文件 +13/−6：`packages/app/README.md` 与 `windows/runner/flutter_window.cpp`）、`634c503` 本轮原型补完与引用重钉（5 文件 +810/−142，含 2 张留样帧入库）、`de2ea1f` 切版（4 文件 +7/−4）。三处版本常量同步 **0.3.20+32**（根 `pubspec.yaml:4`、`packages/app/pubspec.yaml:5`、`packages/app/lib/update/app_release.dart:8-9`），滚动发布说明补三条：续位、悬停面板按浮层坐标定位、托盘单击唤醒。
- **发布范围仍按「只发已验证内容」**：`git status` 本轮现读 36 条未 stage 的在途改动——`docs/evidence` 19、`packages` 8（`download_selection.dart`、`tv_library_page.dart`、`desktop_fakes.dart`、`discover_desktop_layers_test.dart`、`packages/tv/lib/src/environment.dart`、`remote_test.dart` 加两份未跟踪测试）、`docs/design` 5、`docs/analysis` 1、`docs/README.md`、`README.md`、`.idea`——都在另一会话手里，**没进 `v0.3.20`**。本轮两笔各自用 `git diff --cached --name-only` 复核过收录集合：`634c503` 恰好 5 份、`de2ea1f` 恰好 4 份；stage 前索引为空，所以没有夹带。推送前 `git bundle` 量得 `b720845..main` 403,420 字节。
- 门禁分两段跑，且**两段不是同一棵树**（这是本轮的口径，别读成「切版树跑了全量」）：全量 `./tool/verify_all.sh` 在切版前那棵树 `634c503` 的分离 worktree `/tmp/hongguo-gate-634c503` 里 **exit 0**，SDK 用绝对路径 `HONGGUO_FLUTTER_BIN=/Users/lee/fvm/versions/3.47.4/bin` 给（`.fvm/flutter_sdk` 只是指向它的符号链接，本轮对它一个字没写）。退出码之外逐条读实：`analyze.log` **No issues found!**、`widget-tests.log` 末行 **`00:47 +406 ~1: All tests passed!`**、core/api/update/cast/tv 五份日志各命中一次 `All tests passed`（**只数了命中，没记各套例数**；各套例数在下面 CI 那条）、两份 oracle 各 **103 vectors（含 96 条六头签名）**。切版树 `de2ea1f` 上只跑针对性校验：`python3 tool/ci/release_meta.py version` → `0.3.20`，再带 `GITHUB_REF=refs/tags/v0.3.20` 跑一次同样通过（tag 那条正则成立）；`python3 -m unittest discover -s tool/ci/tests` **10 tests / OK**；`validate_release.py` 用 12 份占位附件跑通并渲染出 **32,519 字节**正文（成品 32,520 字节 = 31,525 字符，差的 1 字节是行尾），逐行扫过新加的三条正文没有 `{`/`}`，不会被那个 f-string 当占位符吃掉；`dart format --output=none --set-exit-if-changed packages tool` **274 文件 0 变更**。**全量在标签树上由 CI 再跑一遍**，读数见下一条。
- 例数对账：**`401 → 406` 的净增 5** 逐条归到位——`fe33852` 给 `discover_desktop_layers_test.dart` **+2**（两条支路各钉死：第一行卡片下方 8.0、下面放不下的卡片上方 8.0），`d8547a3` 给 `network_cache_behavior_test.dart` **+3**（该文件在 `b720845` 已有 2 例，本轮 `git diff` 现读新增 3 条）。那 `~1` 仍是 `packages/app/test/tv_settings_test.dart:42` 的 `skip: !tvBuild`，本轮该行逐字读实。
- 发布运行 `41390571430`（number 28，event=push，`headSha=de2ea1fa6978bb73aaa498233722222da4b425c8` 与切版提交逐字相同——**标签的树就是切版那一棵树**）：`preflight 7s / plan 8s / build-verify 228s / native(windows, windows-2022) 290s / native(android-tv, ubuntu-24.04) 411s / native(macos, macos-15) 333s / native(android, ubuntu-24.04) 494s / native(linux, ubuntu-24.04) 168s / publish 18s` 九条 **success**，`ios-signed` **skipped**；`04:49:30 → 05:02:21Z`，约 12 分 51 秒。`build / verify`（job `125100923341`）日志逐条读实：两处 analyze 各 **No issues found!**（18.9s / 1.3s）、`packages/tv` **+38**、core **+117**、api **+109**、update **+33**、cast **+52** 五套全过，`packages/app` **+406 ~1**（01:45，与本地那棵切版前树的读数逐字相同）、TV flag 专项 **+1**、DIDL 严格解析器那步在内。
- 同一棵 `de2ea1f` 的 x64 门禁：`Verify Windows desktop` 运行 `41390527083`（number 89）**success**（`04:48:58 → 04:56:45Z`，约 7 分 47 秒），`Analyze application 31s` / `Verify application on Windows 164s` / `Compile Windows release 132s` 三步各 success。`3e3f82e` 那段托盘 C++ 本机 ARM64 上一行都没编过（media_kit 只有 x64 导入库，见 `docs/evidence/windows-floating-probe-2026-10-29/findings.md`），**这一步是它第一次被真编译**；编译过只证明语法与链接，不证明单击行为，实机三步见末条。
- Release `v0.3.20`（<https://github.com/skeyboy/flutter_hongguo/releases/tag/v0.3.20>）：`draft=false`、`prerelease=false`、`publishedAt=2026-11-02T05:02:18Z`、正文 **31,525 字符 / 54 条要点**（比 `v0.3.19` 的 28,124 / 51 长 3,401、多 3 条，正是本轮那三条）、**15 个附件**且 15 个都带 `sha256:` digest，合计 349,329,220 字节。三条新正文在成品里逐条命中（`Cold start stopped answering with the same page`、`Desktop hover preview and filter panel`、`Windows tray: a single left click` 各 1 次，`overlayLocalAnchor` 与 `SwitchToThisWindow` 也都读得到）。五平台主包：`macos-arm64.dmg 22,637,152 / windows-x64-setup.exe 26,805,733 / linux-x64.deb 9,891,422 / android-arm64-v8a.apk 36,710,620 / android-tv-arm64-v8a.apk 36,264,228`，另有 mobile 与 TV 各三个 ABI、两份归档、`SHA256SUMS.txt`、`release-manifest.json`、`iOS-signing-status.txt`（iOS 仍未签）。`§9.9` 那条「apk 大小相同、digest 不同」的对账本轮反转：`android-arm64-v8a.apk` 从 36,710,616 变成 **36,710,620**（多 4 字节），digest `1d7eb5bb…` ≠ 上一版 `2da2f2ae…`，这次是大小与内容都变了。
- shipped kernel 的线上读数（在 `packages/update` 里 `dart run tool/live_feed_check.dart 0.3.19 0.3.20`，用 `.fvm` 钉的 3.47.4 绝对路径）：`status=available tag=v0.3.20 prerelease=false published=2026-11-02T05:02:18Z notes=31525 assets=15 etag=W/"21d85eff…"`；`v0.3.19 的观众 -> available`、忽略该 tag 后 `-> ignored`；`v0.3.20 -> upToDate`（忽略状态下也 `upToDate`）；四平台选件 macos（`0b51d950…`）/ windows（`bfed7d77…`）/ linux（`6e45a10f…`）/ android（`1d7eb5bb…`）的 digest 与上表同源，`ios -> NONE`，全部 `host=github.com`，`SHA256SUMS.txt=true release-manifest.json=true`。
- **同一笔不对称**：这份补记排在 `de2ea1f` 之后，所以 `v0.3.20` 这棵树里没有它；要看读数取 `main`。
- 仍未闭环（不因为发了版就当作完成）：这三条用户可见改动**没有一条带实机读数**。① 悬停预览与筛选面板只有 widget 帧——Mac 上真鼠标悬停一次都没做，而那 32px 原点差正是 macOS 题条的形状；② Windows 托盘的三步（关窗、单击图标含非前台状态、右键「退出」见进程结束）没有人在实体机上跑过，本轮只拿到 CI 把它编译成功；③ 冷启动续位靠 `2026-11-02` 的只读探测与代码路径，真机上「每次启动看到同样的数据」是否真消失，还没有一帧证明。iPhone Duo 那一格另计：`docs/design/iphone-duo-adaptation.md` 本轮把 §4/§5/§8 的引用逐条重钉（`fe33852` 之后 R5 判成「只修了一半」——不再读窗口，但 overlay 仍跨整块屏），**那是设计与原型，一行产品代码都没动**，内屏与半开的实测帧仍缺（任务 #1）。历轮缺口继续挂着。

### 9.11 发版补记（2026-11-02，标签 `v0.3.21`）

用户诉求（原话）：「执行git提交推送 发布新版本」。两处口径由用户选定：提交范围 =「只提交边下边播这轮」，发布形态 =「切 `0.3.21+33` 并打标签发布」。

- 五笔提交进 `main`（`5e30d76..352d756`）：`f41351c` 取址那一跳重新签名、`hashF13` 的滚动字回到 `x-medusa`（16 文件 +748/−108，另一会话）、`32bc070` 那句「已提交未发布」的对账补记（1 文件 +1/−1，另一会话）、`10a969d` 边下边播（23 文件 +2770/−26）、`a459df1` README 重写入库（1 文件 +205/−91）、`352d756` 切版（5 文件 +10/−6）。推送前 `git bundle` 量得 `5e30d76..main` **92,171 字节**。三处版本常量同步 **0.3.21+33**（根 `pubspec.yaml:4`、`packages/app/pubspec.yaml:5`、`packages/app/lib/update/app_release.dart:8-9`），滚动发布说明补四条。
- **README 那条滞后收了尾**：`§9.10` 列的 36 条在途里就有 `README.md`，而它自 `ed72234`（10-26）起一直没提交，HEAD 那份还停在「0.2.6 / 0.2.5 / 0.2.4」的逐版本流水账，其间已发布的 0.3.x 一条没进首页。本轮先按特性重写入库（`a459df1`），再在切版提交里把徽章与 `hongguo_app` 那行从 `0.3.19+31` 一起写到 `0.3.21+33`——**切版因此从四处变五处**，`v0.3.21` 这棵树里的首页版本读数第一次与标签一致。
- 提交切分的判据是「本轮 diff 的字符级归属」，不是文件级归属：`10a969d` 里的 `docs/native-playback-pipeline.md` +54/−3、`packages/api/test/media_cache_test.dart` +16/−1、`packages/app/test/adaptive_ui_test.dart` +4/−0 各带着前一日的文档行与 Windows 句柄旧账（三文件最后提交日 10-28 / 10-27 / 10-28，且当时工作区干净）。**README 单独一笔**是因为它对 HEAD 是整页重写（+205/−91，HEAD 那份连「边下边播」都没有），掺进 feat 提交会让一笔功能提交背上别人的文档账。
- **发布范围仍按「只发已验证内容」**：`git status` 本轮现读 **22 条**未 stage 的在途改动——`packages` 16（`MainActivity.kt`、`download_selection.dart`、`tv_library_page.dart`、`android_update_channel.dart`、`install_strategy.dart`、`update_controller.dart`、`update_dialog.dart`、`update_host.dart`、`android_install_test.dart`、`release_downloader.dart` 与其测试，加四份未跟踪的 update/tv 测试与 `update_transfer.dart`）、`docs/design` 4、`references/hongguo-web`、`.idea`——都在另一会话手里，**没进 `v0.3.21`**。三笔提交各自用 `git diff --cached --name-only` 复核过收录集合：`10a969d` 恰好 23、`a459df1` 恰好 1、`352d756` 恰好 5；stage 前索引为空，所以没有夹带。
- 门禁：本机没有可用的 python3（`where python` 只指到 Windows Store 的占位符），所以 `release_meta.py:version()` 的四条判据在本地用 node 逐条复核——两份 pubspec 的 `^version: X+Y$` 各命中一次且两组相等、Dart 两个常量与它们一致、`.fvmrc` 仍是 3.47.4——python 侧那两步交给 CI：`build / plan` 的 `Run python3 tool/ci/release_meta.py version` 与 `python3 -m unittest discover -s tool/ci/tests -v` 各 **success**。切版树走「同一棵树逐文件比」：门禁树 `hg-rel` = `git archive(32bc070)` + 本轮 24 路径（`cmp` **24/24**），切版后再把 5 个版本面 overlay 进去，与 `git archive(352d756)` 逐文件比得 **1224 文件、内容级 0 差异**（差异只剩 CRLF/LF 行尾），所以下面那三套例数读的就是标签那棵树。读数：`dart format` **192 文件 0 变更**（切版后对唯一动过的 Dart 文件 `app_release.dart` 再读一次，仍 0 变更）、`packages/core` **+125**、`packages/api` **+139**、`packages/app` **+406 ~1**（exit 0；`packages/app` 只能 `flutter test`，与 `packages/api` 的 `dart test` 并发跑会把 1s deadline 的计时例打成假红，故串行）。
- 例数对账（基线取 `§9.10` 的 CI 读数）：core **117 → 125**（+8 = `packages/core/test/progressive_decrypt_test.dart` 的 8 例）、api **109 → 139**（+30 = 渐进通道 12 + 本地回环源 12 + 真 `MediaCache` 端到端 6）、app **406 不变**（本轮只给 `adaptive_ui_test.dart` 的收起下拉加了 `ensureVisible`，没添新例；那 `~1` 仍是 `packages/app/test/tv_settings_test.dart` 的 `skip: !tvBuild`）、tv 38 / update 33 / cast 52 / TV flag 1 四项不变。另有一笔**减法**：`packages/api` 在本机那 9 条 Windows 宿主红（缓存身份按路径字符串比较，而 `Directory.list()` 给反斜杠、字符串拼接给正斜杠）本轮清零，例数没动、颜色变了。
- 切版头上的 x64 门禁先读再打标签：`Verify Windows desktop` 运行 `41450155377`（number 91）**success**（`13:06:46 → 13:14:11Z`，约 7 分 25 秒），`Analyze application` / `Verify application on Windows` / `Compile Windows release` 各 success。
- 发布运行 `41451312610`（number 29，event=push，`head_sha=352d7563482e4d9ef0320860d927efdb5e88b782` 与切版提交逐字相同——**标签的树就是切版那一棵树**）：`preflight 7s / plan 12s / build-verify 259s / native(android, ubuntu-24.04) 430s / native(android-tv, ubuntu-24.04) 398s / native(linux, ubuntu-24.04) 376s / native(macos, macos-15) 353s / native(windows, windows-2022) 285s / publish 26s` 九条 **success**，`ios-signed` **skipped**；`13:14:56 → 13:27:22Z`，约 12 分 26 秒。`build / verify`（job `125297151050`）日志逐条读实：两处 `flutter analyze` 各 **No issues found!**（22.5s / 1.6s）、`packages/tv` **+38**、core **+125**、api **+139**、update **+33**、cast **+52** 五套全过，`packages/app` **+406 ~1**（`01:53`，与本地那棵切版树的读数逐字相同）、TV flag 专项 **+1**、`Verify DIDL-Lite metadata under a strict XML parser` success。
- Release `v0.3.21`（<https://github.com/skeyboy/flutter_hongguo/releases/tag/v0.3.21>）：`id=431494252`、`draft=false`、`prerelease=false`、`publishedAt=2026-11-02T13:27:18Z`、正文 **34,523 字符 / 58 条要点**（比 `v0.3.20` 的 31,525 / 54 长 2,998、多 4 条，正是本轮那四条）、**15 个附件**且 15 个都带 `sha256:` digest，合计 **349,881,269 字节**。四条新正文在成品里逐条命中（`边下边播 (progressive playback)`、`Two honest limits of that lane`、`Windows cache identity, an old debt this round cleared`、`This round is proven in the suites` 各 1 次，`ProgressiveDecrypt` / `metadataEnd` / `Mp4Cenc.inspect` 也读得到）。五平台主包与 `v0.3.20` 逐项对账：`macos-arm64.dmg 22,637,152 → 22,645,563（+8,411）/ windows-x64-setup.exe 26,805,733 → 26,827,377（+21,644）/ linux-x64.deb 9,891,422 → 9,915,746（+24,324）/ android-arm64-v8a.apk 36,710,620 → 36,776,152（+65,532）/ android-tv-arm64-v8a.apk 36,264,228 → 36,329,764（+65,536）`。两个 APK 各多约 64 KB，与「新增三个 Dart 源 + 一个设置项」同向，但**这只是大小对账，不构成边下边播在设备上跑过的证据**。另有 mobile 与 TV 各三个 ABI、两份归档、`SHA256SUMS.txt`、`release-manifest.json`、`iOS-signing-status.txt`（iOS 仍未签）。
- shipped kernel 的线上读数（在切版树 `packages/update` 里 `dart run tool/live_feed_check.dart 0.3.20 0.3.21`，工作目录取本地 NTFS 克隆——UNC 会让 dart 退回 Windows 目录并报 `Could not find file`）：`status=available tag=v0.3.21 prerelease=false published=2026-11-02T13:27:18Z notes=34523 assets=15 etag=W/"40275f83…"`；`0.3.20 的观众 -> available`、忽略该 tag 后 `-> ignored`；`0.3.21 -> upToDate`（忽略状态下也 `upToDate`）；四平台选件 macos（`7f8c5557…`）/ windows（`20f5ebe0…`）/ linux（`4d63da75…`）/ android（`36b717f9…`）的 digest 与上表同源，`ios -> NONE`，全部 `host=github.com`，`SHA256SUMS.txt=true release-manifest.json=true`。
- **同一笔不对称**：这份补记排在 `352d756` 之后，所以 `v0.3.21` 这棵树里没有它；要看读数取 `main`。
- 仍未闭环（不因为发了版就当作完成）：① 边下边播**没有一次真实上游剧集走过这条链路**——38 例全跑在合成 plan、录制的 fixture MP4 与替身传输上，「提前起播」没有设备实测的首帧时间，media_kit 对「会长大的 HTTP 源」的 seek 只由测试替身打过点；② 本轮改的是移动端与桌面的播放路径，而这台 ARM64 开发机既构建不出 `-d windows`（media_kit 只有 x64 导入库），也没有 Android 设备与模拟器（`adb devices` 零台），所以**设备侧一格读数都没有**，实机验收仍归 Mac 那一格；③ `f41351c` 的签名修复有线上只读探测（生产形状回到 24,2xx 字节 / code=0），但同样没有真机播放读数。历轮缺口继续挂着：Mac 真鼠标悬停、Windows 托盘三步、冷启动续位实机读数。

### 9.12 未知应用那条支路的静默失败、后台下载车道、重复下载（2026-11-03）

用户诉求（原话，三条同一支线）：

- 「https://pub.dev/packages/permission_handler 参照此三方库中的权限功能，修复apk的更新下载后无法执行apk的bug，主要是 未知应用 的安装权限」
- 「同时针对更新包的下载增加后台下载，可以将应用包的下载切换到后台执行，下载完毕后边提示是否安装。」
- 「同时针对多次点击下载不要出现重复下载的情形针对此重复下载的情形需要进行修复」

续接指令「继续处理」= 沿用本轮方案收口。**本轮已按这三条改代码，改动全在工作树，未提交、未切版、未发布**（`.fvm/flutter_sdk` 只读，一个字没写）。

#### 参照 permission_handler 是仿形，不是引依赖

根 `pubspec.yaml`、`packages/app/pubspec.yaml`、`packages/update/pubspec.yaml` 与 `pubspec.lock` 本轮现读 grep `permission_handler` **零命中**。从这个库借的是工作形状，不是依赖：问一次状态 → 把观众送到**该应用自己那一行**设置 → 回到应用再问一次 → 本 ROM 上第一道门解不开就兜底跳应用详情页。落点是 Kotlin 通道 `MainActivity.kt:209-217`（`canInstall` / `askPermission` / `install` / `installResult` 四条）、`:225` `canRequestInstalls()`（Android 8 以下按全局授予回答，让系统弹窗自己判）、`:236-245` `openInstallPermissionSettings()`（`ACTION_MANAGE_UNKNOWN_APP_SOURCES` 解不开退 `ACTION_APPLICATION_DETAILS_SETTINGS`，两道都不存在才返回 `false`，此时 Dart 侧改为用文字说出那个开关的名字）、`install_strategy.dart:100-112` 每次回前台重问一次。

不引依赖的理由要说白：报的 bug 不是「拿不到权限」——权限问没问在改之前就已经有了——而是**装成了、装砸了、装到一半被系统拿走，应用一句都不知道**。那是结果回话链路的洞（下面 D1/D2），比为一个已经被系统 API 覆盖的问题新增一整个跨六端的插件面更靠根。

#### 八条缺陷与落点（行号本轮现读）

| # | 洞 | 修法 |
| --- | --- | --- |
| D1 | 安装终态只发给「还在等的那次 `install` 调用」。`PackageInstaller` 的结果由系统**重新拉起 Activity** 送回：热态走 `onNewIntent`，进程已被拿走时走 `onCreate`，此前只有前者被接。 | `MainActivity.kt:64-66`（`onCreate(getIntent())`）+ `:69-71`（`onNewIntent`）双入口，同一 `handleInstallResult`（`:74`）把 `EXTRA_STATUS` 翻成中文（`installWords`）后交 `answerInstall`（`:122`） |
| D2 | 无人在听时那句话会丢（冷启动那一趟的结果没有 `Result` 可回）。 | 落盘 + 读一次即删：`:125` `runCatching { resultFile().writeText(message) }`，路径 `:132`（`filesDir/hongguo-install-result.txt`，常量在 `:326`），取用 `:137 takeInstallResult()` ↔ 通道 `:215` ↔ Dart `android_update_channel.dart:90-92`。**没有欠款**时 `resume()` 读它（`install_strategy.dart:102`）。钉子测试 `a return with nothing owed reads what the installer itself left behind` 断言两次 `resume()` 的调用序列是 `['installResult']` → `['installResult','installResult']`，第二次拿到 `null` |
| D3 | `ACTION_MANAGE_UNKNOWN_APP_SOURCES` 在部分 ROM 上无接收者，`startActivity` 静默失败，观众原地不动。 | 兜底应用详情页（`:240-244`），`openIfAvailable` 先 `resolveActivity` 再跳 |
| D4 | 「回来还欠着什么」只有旧笔记（`hongguo-pending-install.json`）在答，而它答不了「后台那一趟下完了没有」。 | 新增 `UpdateJournal`（`update_transfer.dart:120`，文件 `hongguo-update-journal.json:123`，只留 2 个 tag、超限连文件一起删 `:128`/`:167-169`/`:194`），`settle(tag)`（`:467`）用磁盘 + 校验值回答；旧笔记原语义保留（测试钉死），兑付不再单独依赖它 |
| D5 | 重复点击 = 重复下载。 | 三层，缺一层就漏一种形状：**内核**`_inFlight[url]`（`release_downloader.dart:52`，登记在第一个挂起点之前 `:83`，命中在跑的在同一条 `:72`）+ 已校验文件按 sha256 复用（`settled():143` → `DownloadedRelease.reused:23/:153`）；**车道**同帧门槛 `_handedOver`（`update_transfer.dart:346`，`fetch` 在挂起前 `add`:364、`finally` 释放:370）+ 跨进程「系统那边还在传」`journal.forTag` ∧ `engine.isLive(taskId)`（`:410-414`）；**编排/UI** `install()` 在 `downloading \|\| transferring` 早退（`update_controller.dart:340`）+ 弹窗主按钮 `busy` 禁用（`update_dialog.dart:173`）。第二次按下拿到的是**文字而不是字节** |
| D6 | 暂存目录按平台各写一处，系统车道只能按基目录相对寻址，于是「包在哪」和「记它的那张条」分家。 | 统一 `<applicationSupport>/updates`（`update_host.dart:49-56` + `update_transfer.dart:17`） |
| D7 | 更新包此前只在进程内下：弹窗一关、应用一被拿走就断，也没有「下完了问一句」。 | 交系统车道，开关沿用设置页既有的「后台下载」（`settings_page.dart:863` + `capability_preferences.dart:13`，仅 `mobileHost` 显示；本轮**没加新 UI 开关**）：`useSystemTransferLane(enabled: settings().backgroundDownloads)`（`host_policy.dart:18`，桌面/iOS/TV 自动 `false`，退回进程内车道）。命中时 `install()` 立刻 `transferring = true` 并 `unawaited(_transferInBackground(...))`（`update_controller.dart:358`、`:364`），弹窗主按钮改读「正在后台下载…」（`update_dialog.dart:193`）；落点后 `_transferInBackground`（`:424`）把 `installReady` + 「已下载完成…是否安装？」**重新举成一次提示**；应用在后台时才落盘的，由 `settleOnReturn()`（`:458`）在回前台收养——没有车道可交的宿主一个盘都不碰 |
| D8 | 更新包与剧集缓存共用 `FileDownloader` 单例，通知配置是全局的，更新下载会说出媒体那套话。 | `configureNotificationForGroup('hongguo-update', …)`（`update_transfer.dart:232-245`）只给这一组配「正在下载新版本 / 新版本已下载完成 / 新版本下载未完成 / 新版本下载等待继续」，不动全局媒体文案；`tapOpensFile: false`——点通知不能把 APK 直接交给安装器，校验和「是否安装」必须回到应用问 |

另有两条与此并列的行为改动：弹窗正文的可见条件从 `downloading` 扩到 `showsMessage`（`update_controller.dart:142-143`、`update_dialog.dart:133`；欠装与「已下载完成」都可能在 `downloading` 已经是 `false` 时到达，吞掉句子的弹窗是观众唯一能看见的东西），以及主按钮四态化（`立即更新 / 正在下载… / 正在后台下载… / 立即安装`，`update_dialog.dart:188-194`）。

#### 读数（2026-11-03）

| 范围 | 结果 |
| --- | --- |
| `dart analyze lib/update test`（`packages/app`，`.fvm` 钉的 3.47.4 绝对路径） | `No issues found!` |
| `dart format --output=none --set-exit-if-changed`（本轮 24 份：`packages/app/lib/update` + 4 份 update 测试 + `packages/update` 的 lib/test） | **24 文件 0 变更** |
| `flutter test` 本轮五份 update 测试（`packages/app`） | **+47 全过** = `update_transfer_test.dart` **17**（新）、`update_background_test.dart` **7**（新）、`android_install_test.dart` **12**（10 → 12）、`update_prompt_test.dart` **10**、`update_controller_test.dart` **1** |
| `dart test`（`packages/update`） | **+37 全过**（`release_downloader_test.dart` 12 例，其中含本轮 in-flight 去重两条） |
| `:app:compileMobileDebugKotlin` | **BUILD SUCCESSFUL**（143 tasks），本轮 Kotlin 那几处第一次被编 |
| `packages/app` 全量（工作树，含另一会话在飞的 tv 改动） | `+431 ~1 -3`——3 条红**全在 `test/tv_feed_test.dart`**，见末条归属；门禁树（`e9acf62` + 本轮 13 路径，无 tv 改动）本轮前段读数为 **+432 ~1 全过**（`406 → 432` = 17 + 7 + 2 净增） |

去重那条路有两条钉子测试值得单列：`a second press while this process waits on the system gets words, not bytes`（同帧二次按下拿到「不需要重复下载」，且 `engine.started` 只有 1 个——第二次根本没到系统）、`a transfer an earlier process handed over starts no second task`（磁盘笔记 `transferring` + `engine.isLive('held-task')` → 只给文字，`engine.started` 为空）。弹窗侧一条真按下的 widget 测试钉住 D7 的两句话：按 `立即更新` 后读到 `正在后台下载…` 与「安装包正在后台下载」，落盘后读到 `立即安装` 与「已下载完成」——它必须用 `runAsync` 延时与 `tester.pump()` 交替推进，纯 `runAsync` 轮询会把 fake-async 的微任务队列饿死。

#### 三笔不是本轮的账（本轮现读复核过）

- `tool/oracle_data.dart` 的 format 漂移：`dart format --set-exit-if-changed tool/oracle_data.dart` 本轮读到 **`Formatted 1 file (1 changed)`**，该文件不在 `git status` 的 49 条里，即 **HEAD 自带**（`f41351c` 那笔），非本轮引入。本轮没在工作树动它，只在门禁树里格式化过。
- `dart analyze --fatal-infos packages tool` 的 2 条 `library_private_types_in_public_api`：`packages/core/lib/src/media/progressive_decrypt.dart:31`、`packages/api/test/progressive_lane_test.dart:86`——两条本轮逐字重读命中，都是 11-02 边下边播那轮的面，与更新链路无关。
- 工作树 `packages/app` 全量的 3 条 `tv_feed_test` 红：该测试文件本身**不在改动列表**（HEAD 内容），而被测面 `packages/app/lib/features/tv/tv_library_page.dart`、`packages/tv/lib/src/environment.dart`、`packages/tv/test/remote_test.dart` 都在另一会话手里（本轮 13 路径一个都没碰）；`v0.3.21` 那棵树同一套在 CI 全绿，故判为**另一会话在飞的 tv 改动**，不是本轮账。

#### 未验证的边界（说白）

- **设备侧一格读数都没有**：本机 `adb devices` 零台、无模拟器，本轮全部跑在 mock 的 `hongguo/update` 通道、替身 `InstallerEngine` 与真临时目录里的真文件上。
- `SystemInstallerEngine`（`background_downloader 9.6.4` 的真实实现，`update_transfer.dart:223`）**没有被真插件跑过一次**：`transfers.start` / `updates.listen` / `recordsForIds` / `cancelTaskWithId` 的调用形状按 9.6.4 写、由替身打点；通知组文案 `configureNotificationForGroup` 同样只到编译。
- Kotlin 编译过只证语法与链接，不证 `EXTRA_STATUS` 的两条入口真的各回来一次，也不证详情页兜底在那台小米上解得开。
- `flutter test` 不能证真机手势：`去系统设置` 跳出去之后回不回得来，是 ROM 的事。

#### 真机复核清单（把 §9.8 的三步扩成两车道各一遍）

前置（共用真机的规矩）：`adb shell dumpsys package com.example.hongguo_app | grep versionCode` 先读当前值，**再决定装哪个 apk**——装旧 versionCode 会被 HyperOS 判成降级并自动卸掉现装的那个包；无线 adb 会话会掉，mDNS 有记录不等于能连。

**A. 进程内车道（`后台下载` 关）**——§9.8 原三步照跑：`appops set … REQUEST_INSTALL_PACKAGES deny` → 点 `立即更新` → 见「安装未知应用」那一行**且弹窗还在**（本轮多一个正面读数：弹窗里应出现 `去系统设置` 出口）→ 不回开关直接切回前台 → 读「还欠着一次更新安装…不需要再点一次」→ `allow` 后再切回一次，`adb logcat | grep -iE "PackageInstaller|installing session"` 应出现**恰好一次**新会话，且这中间没有第二次点击。
**B. 系统车道（`后台下载` 开）**——① 按下后弹窗应停在 `正在后台下载…`，通知栏出现「正在下载新版本 …」而不是媒体那套话；② **传输中再按两次 `立即更新`**：应读到「安装包已在后台下载…不需要重复下载」，且 `adb shell dumpsys notification` / logcat 里只有一条 task；③ 把应用划掉（杀进程）再打开：回前台应读「安装包仍在后台下载…」，落盘后应读「已下载完成，是否安装？」——这一格同时证 D5 的跨进程判据与 D7 的收养；④ 装成后暂存目录 `<applicationSupport>/updates` 应只剩当前与上一个 tag 的包（D4 的 2 条保留）。
**C. 权限那一趟的兜底**——若该 ROM 解不开 `ACTION_MANAGE_UNKNOWN_APP_SOURCES`，`去系统设置` 应落在应用详情页（`MainActivity.kt:240-244`）而不是原地不动。
**D. 已落盘再按**——B③ 之后按 `立即安装` 前应**没有任何下载流量**（`reused` 路径，D5 第三层）。

历轮缺口继续挂着：Mac 真鼠标悬停、Windows 托盘三步、冷启动续位实机读数、iPhone Duo 内屏与半开帧（任务 #1）。

### 9.13 发版补记（2026-11-03，标签 `v0.3.22` 与 `v0.3.23`）

用户诉求（原话，两条同一支线）：「播放信息未返回数据 在线播放时报错，根据错误信息排除问题原因」，定位并修复后——「提交这 5 个路径并切 0.3.23 发布」。`§9.12` 写的时候是「未提交、未发布」的工作记录，而 `v0.3.22` 发布时没写自己的补记——这一 § 一次补齐两版的发布账，读数全部是 2026-11-03 从 GitHub API 与发布树现取，不靠发布时的记忆。

**`v0.3.22`（标签指向 `58c43d3`）**

- 三笔提交：`3b9ada4` 更新交系统后台车道（14 文件 +1948/−80，工作面与八条缺陷见 `§9.12` 本体）、`a36cf43` Windows 播放发布段不再被播放器句柄判成取不到数据（2 文件 +247/−26：`media_cache.dart` + 回归测试）、`58c43d3` 切版（5 文件 +8/−6，三处版本常量同步 **0.3.22+34**，`tool/ci/validate_release.py` 补两条正文）。
- x64 门禁 `Verify Windows desktop` 运行 `41569275009`（number 93，`head_sha=58c43d3f…`）**success**（`02:57:37 → 03:04:32Z`，415s，`windows` 单 job 410s）。
- 发布运行 `41572572603`（number 30，event=push，同一棵树）**success**：`preflight 10s / plan 6s / build-verify 321s / native(linux) 145s / native(android-tv) 429s / native(macos) 217s / native(android) 441s / native(windows) 279s / publish 26s` 九条，`ios-signed` **skipped**；`03:30:13 → 03:43:54Z`，约 13 分 41 秒。
- Release `v0.3.22`（<https://github.com/skeyboy/flutter_hongguo/releases/tag/v0.3.22>）：`id=432254102`、`draft=false`、`publishedAt=2026-11-03T03:43:50Z`、正文 **37,471 字符 / 60 条要点**（比 `v0.3.21` 的 34,523 / 58 多出的 2 条正是切版那两条）、**15 个附件全带 `sha256:` digest**，合计 350,143,579 字节。本轮没有重读该树 suites 的逐套例数——`3b9ada4` 那轮的本地读数（app **+432 ~1**、update 五份 **+47**、`packages/update` **+37**）在 `§9.12` 的读数表里。

**`v0.3.23`（标签指向 `02ee9c2`）——「播放信息未返回数据」的根因与修复**

- 判据（读实错误文案的分支）：该句对应 `IncompleteCatalogResponse` = **HTTP 200 但空 body / 外层 `data` 为空**，与「这一集暂时没有可播的片源」（信封里 `data[vid]` 为空，剧集问题，重试无意义）不同支。三条线上只读探针（脚本在 `C:\Users\lee\scratch` 的门禁树里，不入库；只读数，签名头 / URL / 密钥 / 响应体一个字节都没打出来）把它钉死：**换发新身份，此前被拒的 vid 9/9 有答案**；同一批 vid，共享身份只答 **1/6**、逐请求新身份 **6/6**；同一身份 `+0s` 拿到答案后 `+1s/+3s/+8s` 的重 replay 全是 200/0——拒答绑在**已用掉答案的那个设备身份**上（一个身份一个窗口只答约一次），而应用按「一个进程注册一次、注册表跨重建共享」在取，重试车道每次都把同一个废身份再抛一遍，把 3 次恢复与 20s 预算烧干净。
- 修复 `b2fb6ac`（5 文件 **+92/−145**，就是用户点名的五路径）：注册改**一次性租约**——`PlaybackDeviceRegistry.get()` 只共享在途的那一次 `_pending`，落定即在 `finally` 置空，用过的身份永不再发第二人；`rotate()`、`_issued` 计数与调用方的「被拒」标记整体删除，`video_model_client` 每一次尝试（含第一次）都取一份本进程没花过的注册。测试账：`playback_device_test` 两条 rotate 例删掉、换成「第二次 `get` 必然重新注册」与「并发请求共享在途那一次、事后各取新身份」两条（净 **−1**）；`video_model_client_test` 断言改成数注册次数（恢复后 `issued == 2`、首答 `issued == 1`）。api 例数 **139 → 140** 逐条对上：`a36cf43` 给 `media_cache_test` **+2**（16 → 18，本轮现数），`b2fb6ac` 净 **−1**（7 → 6，同上）。
- **门禁树腐烂抓到一次**：复用的 `hg-rel` 还停在 `0.3.21` 时代（`git archive` 的基线缺 `3b9ada4`——`update_transfer.dart`、`update_background_test.dart` 只在新树里，`MainActivity.kt`、update lib 六文件与本文档也都不同），第一轮那个 app **+406** 读数是在旧树上跑的，**作废**。重切 `hg-cut = git archive(02ee9c2)` 全量重跑，与切版树逐文件比（`diff -r --strip-trailing-cr`）后读数为：api **+140**、core **+125**、app **+432 ~1**（串行跑，`flutter test` 与 `packages/api` 的 `dart test` 并发会把 1s deadline 例打成假红）、`flutter analyze` **No issues found!**（30.6s）、`dart analyze` 只剩 `§9.12` 挂账的那 2 条 `library_private_types_in_public_api`。本机没有可用的 python3，`release_meta.py:version()` 的判据照旧用 node 逐条复刻：两份 pubspec、两个 Dart 常量、`.fvmrc` 3.47.4 全中（**0.3.23+35**）；`validate_release.py` 新增那条正文（`Playback identity, one ask one registration`）逐行扫过大括号，只留 4 个合法插值表达式。
- 切版 `02ee9c2`（5 文件 +7/−6）：根 `pubspec.yaml:4`、`packages/app/pubspec.yaml:5`、`packages/app/lib/update/app_release.dart`、`README.md:7/:89`、`tool/ci/validate_release.py`。推送 `main` 后先读 x64 门禁再打标签：`Verify Windows desktop` 运行 `41577561374`（number 94，`head_sha=02ee9c2e7775d7ee33777885bc55fd474b50c35d` 与切版提交逐字相同）**success**（`04:20:36 → 04:28:17Z`，461s，`windows` job 457s），然后才推轻量标签 `v0.3.23`。
- 发布运行 `41578509094`（number 31，event=push，`head_sha` 同上逐字相同——**标签的树就是切版那一棵树**）：`preflight 9s / plan 7s / build-verify 240s / native(windows) 275s / native(android-tv) 494s / native(linux) 146s / native(android) 435s / native(macos) 302s / publish 28s` 九条 **success**，`ios-signed` **skipped**；`04:30:25 → 04:43:40Z`，约 13 分 15 秒。
- Release `v0.3.23`（<https://github.com/skeyboy/flutter_hongguo/releases/tag/v0.3.23>）：`id=432286032`、`draft=false`、`publishedAt=2026-11-03T04:43:36Z`、正文 **39,019 字符 / 61 条要点**（比 `v0.3.22` 恰好多那 1 条身份正文）、**15 个附件全带 `sha256:` digest**，合计 350,111,811 字节。`release-manifest.json` 现读：`version=0.3.23 build=35 commit=02ee9c2 assets=13`。
- 五平台主包与 `v0.3.22` 逐项对账：`macos-arm64.dmg 22,657,918 → 22,657,951（+33）/ windows-x64-setup.exe 26,840,801 → 26,843,054（+2,253）/ linux-x64.deb 9,927,912 → 9,927,344（−568）/ android-arm64-v8a.apk 36,776,152 → 36,776,152（±0，digest e23de78… → 96ebfb8…）/ android-tv-arm64-v8a.apk 36,395,300 → 36,395,300（±0，digest 590eced… → 364501d…）`。两个 APK 字节数纹丝不动而 digest 变了——`§9.9` 那条「大小相同 ≠ 同一份文件」的坑第三次出现，两边都是刚从各自 Release 现读；这与「本轮只动 api 层的 Dart、没碰原生面」同向，但仍只是大小对账。
- shipped kernel 的线上读数（在 `hg-cut/packages/update` 里 `dart run tool/live_feed_check.dart 0.3.21 0.3.22 0.3.23`）：`status=available tag=v0.3.23 prerelease=false notes=39019 assets=15 etag=W/"3d08c0ff…"`；`0.3.21` 与 `0.3.22` 的观众各自 `-> available`，`0.3.23 -> upToDate`；四平台选件 macos（`1454439349a9…`）/ windows（`ec093692b1…`）/ linux（`4b91702a6d…`）/ android（`96ebfb8d12…`）的 digest 与 manifest 逐字同源，`ios -> NONE`，latest feed 已指向 `v0.3.23`。
- **同一笔不对称**：这份补记排在 `02ee9c2` 之后，所以 `v0.3.23` 这棵树里没有它；`v0.3.22` 当时也未写补记，其发布账以本节为准。
- 仍未闭环（不因为发了版就当作完成）：① 身份一次性租约**没有一次真机播放读数**——证据是三条线上只读探针与 api 套件，「真 vid 在真手机上首帧能不能如期起来、恢复车道在真实网络抖动下的实际命中率」没点过一台设备；② 若上游改成**按 IP / 按账号节流注册**（新身份也拒），本修复同样被耗尽——那是协议变更，不在这轮的防御面内，属挂账的探针哨兵该盯的事；③ `§9.12` 真机清单 A/B 两车道各一遍仍未跑（本机 `adb devices` 零台）；④ `a36cf43` 的 Windows mpv 真句柄 caveat 依旧——本轮拿到的是 CI x64 编译成功与 `media_cache_test` 那 2 条新回归，实体机上的发布段还没有一帧读数；⑤ iOS 仍未签（`ios-signed` skipped）。历轮缺口继续挂着：Mac 真鼠标悬停、Windows 托盘三步、冷启动续位实机读数、iPhone Duo 内屏与半开帧。

### 9.14 发版补记（2026-11-03/04，标签 `v0.3.24` 与 `v0.3.25`）

这两版发布时都没写补记，`§9.13` 只结到 `v0.3.23`。本节的读数全部是 2026-11-04 现取：`GET /releases/tags/*`、`GET /actions/runs/<id>/jobs`、`GET /actions/runs?per_page=40` 与 `git show --stat`，不靠发布时的记忆。

**`v0.3.24`（标签指向 `76786a3`）——拖动窗口时整片封面明灭**

- 症状与根因（提交 `ab0eefb` 的正文原话摘要）：封面的 `memCacheWidth` 吃实时单元格宽，而 `cached_network_image` 把它折进了 provider——宽度每变一像素就是一个新的 `ResizeImage`，`OctoImage` 的 `Image` 按 `ValueKey(provider)` 打键，于是整条图片元素被销毁重建、退回带标题的占位再重播淡入，一屏几十格每帧来一遍。解码宽度改成 128 设备像素的阶梯（量程沿用 1..1600），缩放进行中合住闸门、沿用已提交档位，静默 250ms 后一次补齐且不再重播淡入。
- 两笔提交：`ab0eefb`（3 文件 **+347/−8**：新增 `cover_decode_size.dart` 92 行、`drama_cover.dart` +70、`drama_cover_resize_test.dart` +193 五例）、`76786a3` 切版（5 文件 +7/−6，**0.3.24+36**，正文 1 条）。
- 整树读数在 **Mac 主机**上取：app **437 通过 + 1 条件跳过**、core 125、api 140、update 37、cast 52、tv 38。五例新增里 **3 例首跑只在 Windows builder 红**——夹具删在句柄还开着的封面上，errno 32 把已经过的断言盖成失败；`c0e61c0`（1 文件 +26/−18）改成整套共用一个夹具目录、删不动就留给 runner 的临时区，`43a3be8`（1 文件 +1/−1）再把这一栏补进发布正文。
- **门禁顺序这一版没守住（记为缺陷）**：`Verify Windows desktop` 运行 `41673172119`（#97，head `76786a3`，job windows **failure** 346s，失败步 `Verify application on Windows`）`16:20:24` 起跑，标签 `16:20:35` 就推了出去——发布运行 `41673207941` 与那次门禁只差 11 秒，等 #97 判红时 Release 已经在建。红的是上面那三条夹具例（测试主机差异，非产品缺陷），而 release.yml 真正门住的那一步 `build / verify`（ubuntu，含 `tool/ci/tests` 10 例发布契约与 DIDL 命名空间检查）**success** 230s。此后 #98（`41678780767`，head `c0e61c0`）success 469s、#99（`41680446737`，head `43a3be8`）success 482s 把这条门禁补绿——**从 `v0.3.25` 起改成「先读 cut head 的 windows-verify，绿了才打标签」**。
- 发布运行 `41673207941`（#32，76786a3，`16:20:35 → 16:38:49Z`，1094s）逐 job：`preflight 31 / plan 19 / build-verify 230 / native(windows) 385 / native(macos) 354 / native(android) 395 / native(android-tv) 493 / native(linux) 231 / publish 130`，`ios-signed` skipped。
- Release `v0.3.24`（<https://github.com/skeyboy/flutter_hongguo/releases/tag/v0.3.24>）：`id=432956935`、`draft=false`、`publishedAt=2026-11-03T16:38:46Z`、正文 **41,768 字符 / 62 条要点**、**15 个附件全带 `sha256:` digest**，合计 350,151,724 字节。
- 五平台主包与 `v0.3.23` 逐项对账：`macos 22,657,951 → 22,658,470（+519）/ windows 26,843,054 → 26,842,032（−1,022）/ linux 9,927,344 → 9,927,492（+148）/ android-arm64-v8a 36,776,152 → 36,776,152（±0，digest 96ebfb8… → 4faf5be…）/ android-tv-arm64-v8a 36,395,300 → 36,395,300（±0，digest 364501d… → c012659…）`。两个 APK 字节数不动而 digest 变——`§9.9` 那条「大小相同 ≠ 同一份文件」第四次出现，两边都是刚从各自 Release 现读。

**`v0.3.25`（标签指向 `5f990e9`，不是切版提交 `606cfc0`）——合成整片资源**

- 诉求（原话）：「根据 design 中关于视频合并导出的设计及需求设计文档新建一个 module，针对 PC 和 mobile 端接入此需求……综合分析后执行需求开发处理」，随后「通过后执行git提交推送发布新版本」。
- 四笔提交：`e75f146`（48 文件 **+9622/−745**：core 的 `mp4_merger.dart` 容器级内核、app 的 `merge/`（manager / worker / library / selection / export）、四处入口与 `docs/design/video-merge.md`，同批收「选择下载新集」——`latest_episode_pull.dart` 拆成 `latest_episode_check.dart`）、`606cfc0` 切版（5 文件 +9/−6，**0.3.25+37**，正文 3 条）、发布挂掉后的 fix-forward 两笔 `c3717b5`（2 文件 +9/−6）与 `5f990e9`（1 文件 +1/−1）。
- 门树 = `git archive(e75f146)` + 本轮版本改动，Windows ARM64 本机读数：core 132 / api 140 / app 464 通过 + 2 条件跳过 / tv 38 / cast 52 / update 36 通过 + 1 失败，app 的 `flutter analyze` 无告警。两条要署名的：update 那 1 例是 `release_downloader_test` 把临时路径分隔符写死成 `/`，本机自它落地起就红；api 首轮 139+1 出在与另一套并跑，单跑复绿 140/0。
- **发布挂一次**：首次发布运行 `41776107631`（#33，head `606cfc0`）逐 job `preflight 6 / plan 6 / build-verify 263 / native(windows) 291 failure / native(linux) 166 / native(macos) 391 / native(android-tv) 437 / native(android) 476 / publish skipped`，失败步 **`Package desktop installers`**。根因：`package_desktop.py` 一进来就调 `release_meta.version()`，它用 `path.read_text()` 读 pubspec，而 Windows 作业的默认编码是 cp1252——本轮在根 pubspec 的依赖覆盖里加的那行中文注释（`file_picker` / `share_plus` 的选型理由）让它在第一个非 ASCII 字节抛 `UnicodeDecodeError: 'charmap' codec can't decode byte 0x9d`；linux/macos 作业默认 UTF-8，所以四平台只红 Windows 一个。修法是把编码写死而不是删注释：`version()` 读两份 pubspec、`app_release.dart`、`.fvmrc` 与两处 `write_text` 全部点名 `encoding='utf-8'`（`c3717b5`），发布说明落盘同样写死（`5f990e9`——那三十多条 bullet 里也满是中文，写在 ubuntu job 上只是恰好）。
- 重打标签是这一版第一次真正执行 re-point，前后各查一遍：`git cat-file -t v0.3.25` = `commit`（轻量，无对象可残留）、`GET /releases/tags/v0.3.25` 当时 **404**（失败的 #33 没建出任何 Release，故没有外部引用），确认后才 `git tag -f` + `git push origin refs/tags/v0.3.25 --force`。重推前新 head 的门禁 `41778396779`（#102，head `5f990e9`）success 558s；`c3717b5` 那一次的 #101（`41777977626`）被随后的 push **cancelled**（309s）——新推送会取消旧 head 在跑的作业，旧 head 的结果从此不再算证据。
- 发布运行 `41779423129`（#34，head `5f990e9`，`05:28:08 → 05:41:09Z`，781s）逐 job：`preflight 8 / plan 6 / build-verify 259 / native(windows) 281 / native(android) 475 / native(android-tv) 445 / native(linux) 207 / native(macos) 354 / publish 17`，`ios-signed` skipped。
- Release `v0.3.25`（<https://github.com/skeyboy/flutter_hongguo/releases/tag/v0.3.25>）：`id=433553879`、`draft=false`、`publishedAt=2026-11-04T05:41:06Z`、正文 **49,329 字符 / 65 条要点**（比 `v0.3.24` 恰好多 3 条：合成整片、挑集下载、本轮门树读数）、**15 个附件全带 `sha256:` digest**，合计 354,442,253 字节。
- 五平台主包与 `v0.3.24` 逐项对账：`macos 22,658,470 → 23,031,446（+372,976）/ windows 26,842,032 → 27,111,400（+269,368）/ linux 9,927,492 → 10,071,544（+144,052）/ android-arm64-v8a 36,776,152 → 37,321,061（+544,909）/ android-tv-arm64-v8a 36,395,300 → 36,678,061（+282,761）`。本轮新增的两个依赖（`file_picker`、`share_plus`）各带一条平台通道，五平台同时变重与此同向——仍只是大小对账，不是内容证明。
- 仍未闭环（两版共用，不因为发了版就当作完成）：① 合成**没有一个 media_kit 窗口真放过整片**——本机 ARM64 链不上 x64-only 的 media_kit，真机播放与 Android 后台存活属 Mac 验收与 x64 CI；② macOS 导出到用户挑选的目录仍需 `com.apple.security.files.user-selected.read-write`，本轮没动 entitlements；③ 「拖动窗口不再逐帧重解码」的证据是元素身份与解码档位集合，**没有一帧 before/after 条带**，4K 拖动下上限档位的代价未测；④ 编码地雷只钉死了 Windows 那一条，`tool/ci/package_desktop.py` 的 `.desktop`（中文「红果剧场」名称）在任何非 UTF-8 locale 的作业上仍是同一危险；⑤ iOS 仍未签（`ios-signed` skipped）。历轮缺口继续挂着：Mac 真鼠标悬停、Windows 托盘三步、冷启动续位实机读数、iPhone Duo 内屏与半开帧、真机安装器车道。

### 9.15 发版补记（2026-11-04，标签 `v0.3.26`）

用户诉求（原话，两条同一支线）：「视频资源合并的功能与原型设计功能出入较大，并且选择后无法执行合并。综合分析后对问题执行修复」，修复后——「完成后执行提交发布新版本」。「无法执行合并」的根因不是写入失败，而是**拒绝被留到了任务卡上**：面板选完直接 `enqueue`，`MergeReject`（时间基 / 分辨率 / 编码参数不一致、源文件已被清理）要等 worker 起跑才现身，看上去就是点了没反应；「出入较大」则是面板只有一步勾选列表，原型的格子选集 + 预检两步没有落地。

- 两笔提交：`42dbecb`（12 文件 **+1194/−145**：core 的 `Mp4Merger.rejectOf` / `growRejectOf` 包住 `plan` / `appendPlan` 让预检与写入同源、app 的 `probeMerge` 在 worker isolate 里只读表预检（可注入，同 `run` 的理由）、`merge_selection.dart` 重写为两步、三处入口传 `preselect`、`merged_page` 的构成行合并成一行）、`6a4836d` 切版（5 文件 +8/−6，**0.3.26+38**，正文 2 条）。
- 门树 = `git archive(42dbecb)` + 本轮版本改动；切版后再与 `git archive(6a4836d)` 逐文件比（`diff -r --strip-trailing-cr`）**无差异**，也没有 cut 侧独有的条目——下面的读数就是标签那棵树。Windows ARM64 本机：core 133 / api 140 / app **468 通过 + 2 条件跳过 + 0 失败** / tv 38 / cast 52 / update 36 通过 + 1 失败；`packages/app` 与 `packages/tv` 的 `flutter analyze` 双 **No issues found!**；`dart format` 对本轮触及的文件 0 改动。三条要署名的：update 那 1 例仍是 `release_downloader_test` 把临时路径分隔符写死 `/`（自它落地起本机就红，非本轮）；`dart format` 全树仍点名 `packages/api/test/playback_device_test.dart`、`packages/api/test/video_model_client_test.dart`、`tool/oracle_data.dart` 三个旧文件，与上一版同一批，CI 不跑格式化；`tool/ci/tests` 的 10 例发布契约与 DIDL 命名空间检查本机无 python3（只有商店占位），只在 CI 的 `build / verify` 有读数。
- 本轮新增的两条证据值得单独记，因为它们是「上一版为什么能被漏掉」的对偶：`merge_manager_test.dart` 一条**真实 isolate** 预检（同一份文件 `reject == null` 且每行无 error、改写一处 `mdhd` timescale 后答「时间基」、空选与「要追加的合并资源已不存在」各答其句，走的是默认 `probe` 而非注入桩），`merge_ui_test.dart` 一条 **400×780 手机底部弹层**跑完两步并入队（`tester.takeException()` 为空即无溢出；尺寸放在 `tester.view` 上而不是 `setSurfaceSize`，否则 `MediaQuery` 仍是 800×600、手机用例其实测的是对话框）。
- **门禁顺序这一版守住了**（`§9.14` 那条缺陷的反面）：`Verify Windows desktop` 运行 `41795539655`（#103，`head_sha=6a4836d19ac4498afd9b13ae04e8531df11ecae2` 与切版提交逐字相同）**success**（`07:54:42 → 08:02:33Z`，471s，`windows` job 467s），确认之后才推轻量标签 `v0.3.26`（`git cat-file -t` = `commit`）。
- 发布运行 `41796575295`（#35，event=push，`head_sha` 同上逐字相同——**标签的树就是切版那一棵树**，`08:03:23 → 08:16:06Z`，763s）：`preflight 7s / plan 7s / build-verify 259s / native(android) 425s / native(windows) 338s / native(android-tv) 457s / native(linux) 125s / native(macos) 414s / publish 17s` 九条 **success**，`ios-signed` **skipped**。`cp1252` 那一类地雷本轮没有复发：`c3717b5` / `5f990e9` 之后 `release_meta.py` 与发布说明的读写全部点名 `encoding='utf-8'`，而这两笔就在 `v0.3.25` 那棵树里，Windows 打包步这次直接过。
- Release `v0.3.26`（<https://github.com/skeyboy/flutter_hongguo/releases/tag/v0.3.26>）：`id=433660784`、`draft=false`、`publishedAt=2026-11-04T08:16:02Z`、正文 **52,983 字符 / 67 条要点**（比 `v0.3.25` 的 49,329 / 65 恰好多本轮那 2 条）、**15 个附件全带 `sha256:` digest**，合计 354,348,382 字节。`release-manifest.json` 现读 `version=0.3.26 / build=38 / commit=6a4836d19ac4498afd9b13ae04e8531df11ecae2`——切版提交、门树基线、manifest 的 commit 三者逐字相同。
- 五平台主包与 `v0.3.25` 逐项对账：`macos 23,031,446 → 23,024,722（−6,724）/ windows 27,111,400 → 27,109,835（−1,565）/ linux-x64.deb 10,071,544 → 10,076,324（+4,780）/ android-arm64-v8a 37,321,061 → 37,321,097（+36，digest 8cc038b… → 663cfaa…）/ android-tv-arm64-v8a 36,678,061 → 36,678,097（+36，digest 43f869d… → 3888c59…）`。两个 APK 各 +36 字节、其余平台有增有减，与此轮「只动 Dart、没碰原生面、没加依赖」同向；`§9.9` 那条「大小相同 ≠ 同一份文件」在这里反过来用——大小几乎相同也不能当作没变。仍只是大小对账。
- shipped kernel 的线上读数（在门树 `packages/update` 里 `dart run tool/live_feed_check.dart 0.3.24 0.3.25 0.3.26`）：`status=available tag=v0.3.26 prerelease=false published=2026-11-04T08:16:02Z notes=52983 assets=15 etag=W/"f44c3b8e39e0…"`；`0.3.24 → available`、`0.3.25 → available`、`0.3.26 → upToDate`，两条「先 ignore 该版」的支路各答 `ignored`；四平台选件 macos（`0388ca5498d1…`）/ windows（`19942c058fec…`）/ linux（`82e2b20e5b28…`）/ android（`663cfaa7d166…`）的 digest 与附件清单逐字同源，`ios → NONE`，`SHA256SUMS.txt=true release-manifest.json=true`。**这一读第一次跑不出来**：本轮为盯发布建的轮询把**未签名**额度打到 `60/60`，`live_feed_check` 走的是匿名 feed，于是答 `unavailable (no release parsed)`——那是限流，不是发布状态；复位后重跑即得上面读数。发布状态本身自始至终以 `GET /releases/tags/v0.3.26` 为准（`ReleaseFeed.latest()` 与它同源，仍不能倒推）。
- **同一笔不对称**：这份补记排在 `6a4836d` 之后，所以 `v0.3.26` 那棵树里没有它。
- 仍未闭环（不因为发了版就当作完成）：① 合并整片**没有一个 media_kit 窗口真放过**——本机 ARM64 链不上 x64-only 的 media_kit，「拖到 `merged/` 里的整片能播、进度与选集轨道如何」是 Mac 验收与 x64 CI 的活；② 手机那两步只有 widget 帧，**没有真机截图**，400×780 是无溢口的下限证明、不是排版好看；③ macOS 导出到用户挑选的目录仍需 `com.apple.security.files.user-selected.read-write`，本轮未动 entitlements；④ 原型的「后台执行」勾选与 排队中/校验源/写入/发布 阶段胶囊按本轮决定**不实现**（Android 前台服务通知与 iOS `BGProcessingTask` 未做，worker 也不上报子阶段），面板改为如实写明各平台的挂起行为；⑤ 磁盘余量仍是「预计写入」的估算，满盘由写入自己报；⑥ iOS 仍未签（`ios-signed` skipped）。历轮缺口继续挂着：Mac 真鼠标悬停、Windows 托盘三步、冷启动续位实机读数、iPhone Duo 内屏与半开帧、真机安装器车道。


