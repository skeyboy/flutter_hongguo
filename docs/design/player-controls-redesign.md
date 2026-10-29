# 播放控制条重构（PC / 移动两套形态）

状态：本轮（2026-10-29）设计与执行，已提交并随 **v0.3.13** 发版（§9）。行号分两个基线，别混用：§2 的「现状」读数是**改动前那棵树**（`521aa33`，v0.3.12）的现读值——`playback_transport.dart` 259 行、`compact_controls.dart` 267 行、`player_page.dart` 1808 行、`episode_swipe.dart` 198 行；§6–§8 点到的位置是**本轮落地后**的现读值——同一批文件现在是 516 / 331 / 1931 / 198 行。

## 1. 诉求与本轮决策

用户诉求（原话）：「重新设计针对PC 和 mobile端的视频播放页中播放器底部对应的播放控制相关的功能，根据PC 和 mobile参照市面上通用的设计进行控制方面的重构。可以先进行分析，给出对应的设计然后再结合设计及对应的功能执行重构」。

三个分叉由用户选定（本轮问答）：

1. **点按语义**：PC 单击画面切播放/暂停（唤出靠鼠标移动，不靠点击）；移动端保持「隐藏时第一次点按只唤出操作、不意外暂停」这条既有契约（[immersive-playback.md:8](immersive-playback.md) 明写）。`offline_playback_test.dart:51-58` 的 `_wakePlayerControls` 原本靠点画面唤出，本轮改成直接走 chrome 自己的时钟（`CompactControlsState.show()`），因为单击语义换了以后「点一下必然唤出」在桌面上不再成立——触控宿主上点画面唤出那条契约本身没动，只是这个夹具不再依赖它。两端都新增双击中心=播放/暂停、双击左/右半屏=快退/快进 10s。
2. **范围**：全套——自绘进度条（已播/缓冲双层 + hover 时间气泡 + 拖拽预览 + 命中区加高）、PC 连续音量滑杆与静音、±10s 按钮、清晰度进控制条、暂停时中心大按钮、倍速弹层带选中态、时间戳 `h:mm:ss`、快捷键补齐、触控横向拖拽进度。
3. **移动端附加件**：只要长按 2× 临时快进。**不做**竖屏锁定。

## 2. 现状（代码现读，逐条可指到行）

> 本节是**重构前**的快照，行号指当时的树；落地后这些行已漂移，别再按它们导航，改后形态见 §4 与 §8。

| # | 现状 | 出处 | 通用形态 |
|---|---|---|---|
| 1 | 进度条是单个 `Slider`，只有「已播/轨道」两层，无缓冲层、无 hover 时间、拖拽时没有任何预览；命中高度就是 Slider 默认 | `playback_transport.dart:111-139` | YouTube/Bilibili/Video.js 都是「已播 + 缓冲 + 悬停加粗 + 时间气泡」 |
| 2 | 音量只在 `desktop && 宽度≥600` 出现，且是 0/25/50/75/100 五档 `PopupMenuButton`；没有静音切换；移动端完全没有音量入口 | `:182-199` | PC 是「图标 + 连续滑杆」，点击图标静音并记住上一档；移动端交给系统音量键 |
| 3 | 倍速是一枚写着 `1.0×` 的 `PopupMenuButton`，弹层没有当前档勾选态 | `:200-220` | 图标 + 当前档标签 + 带勾选的弹层；短剧 App 另有长按 2× |
| 4 | 控制条没有 ±10s，只有上一集/下一集，而且宽度 <600 时这两枚直接消失（手机上就没有切集按钮，只剩上滑手势） | `:142`、`:160` | ±10s 是标配；切集另有入口 |
| 5 | `第 N 集 · 选集` 用 `Expanded` 撑满整条中间，视觉重心压在最不需要面积的一项上 | `:168-181` | 选集是右簇的一枚按钮（或进度条上方的分集点） |
| 6 | 清晰度藏在选集面板的 `DropdownButton`（自动/720p/1080p，`cachedOnly` 时禁用），控制条上没有；TV 反而有 | `player_page.dart:1286-1323`、TV 侧 `:1629` | 清晰度在控制条右簇，与倍速同族 |
| 7 | 控制条上方挂了一枚 `expand_more`「隐藏播放操作」 | `compact_controls.dart:234-249` | 没有这个 affordance：点击空白/鼠标静止即收起 |
| 8 | 单击画面只负责显隐，从不切播放暂停；没有双击 seek；触控没有横向拖进度（竖向拖=切集） | `compact_controls.dart:177-185`、`episode_swipe.dart:147-151` | 见第 1 节决策 |
| 9 | 时间只有 `mm:ss`，且 `inSeconds.clamp(0, 360000)` | `playback_transport.dart:47-51` | 超过 1 小时切 `h:mm:ss` |
| 10 | 投屏中 `cast` 图标不变体；`player.stream.buffering`（在线流中途卡顿）在 UI 上完全没有表达，只有本页自己的 `preparing` 骨架 | `player_page.dart:1075`、`:1144-1183` | 投屏中显示设备名/激活态；卡顿显示缓冲圈 |
| 11 | 快捷键有 Space/←/→/PageUp/PageDown/F/I/Esc，但 tooltip 不写键位，也没有 K/J/L/M/↑↓ | `player_page.dart:1769-1786` | 键盘面是 PC 播放器的一半工作量 |
| 12 | 控制条**零单测**：没有任何用例挂载 `PlaybackTransport`（`grep PlaybackTransport packages/app/test` → 0 处），它只被 4 个真机夹具间接点按 | 夹具：`offline_playback_test.dart`、`desktop_episode_swipe_hint_test.dart:376-462`、`ios_episode_swipe_test.dart:503/515`、`macos_live_poc_test.dart:96-102` | —— |

第 12 条是本轮的工程前置：`media_kit` 的 `Player` 在 widget test 里构造不出来（现有单测里的 `_Player()` 是本地假类，见 `test/macos_picture_in_picture_test.dart:43`），所以控制条要一层窄接缝才能被测。

## 3. 行业参照（公开可观察的通用形态）

- **PC/网页**：一条通栏进度贴在最上方，下面左簇＝播放/暂停、±10s、上一集/下一集、音量（图标+滑杆）、`当前/总时长`；右簇＝清晰度、倍速、画中画、投屏、全屏。暂停时画面中心一枚大三角；鼠标在进度条上出时间气泡并把条加粗。既有文档已引用过 [Apple TV Mac 播放控件](https://support.apple.com/en-nz/guide/tvapp-mac/atv31d6caa7/mac) 与 [YouTube 全屏交互](https://support.google.com/youtube/answer/72689)，本轮沿用同一参照系。
- **移动端竖屏（短剧形态）**：底部一条＝播放/暂停 + 进度 + 时长 + 倍速 + 选集 + 转横屏；音量交给系统键；手势＝单击唤出、双击中心播放暂停、双击左右半屏 ±5~10s、横向拖进度、长按 2× 临时快进；竖向滑＝切集（本项目已有）。
- **移动端横屏**：与 PC 同族但去掉音量（系统键）与画中画（iOS 系统 PiP 另有入口），左上返回 + 标题，右侧允许一枚「下一集」大按钮。

本项目是竖屏短剧为主，所以移动端的「主形态」是竖屏那条，横屏是 PC 形态的减件；两者都从同一批原子组件里长出来，不各写一套。

## 4. 目标形态（规格）

### 4.1 分层

| 文件 | 职责 |
|---|---|
| `playback/transport_player.dart`（新） | 控制条用到的那一点播放器面：`position/duration/buffer/buffering/volume/rate/playing` 的流与读值 + `seek/setVolume/setRate/playOrPause`。`MediaKitTransport` 是唯一的 media_kit 适配器，单测里换成假实现。 |
| `playback/player_progress_bar.dart`（新） | 自绘进度条：轨道/缓冲/已播三层、hover 时间气泡、拖拽预览与落点 seek、命中区、`Semantics` 滑杆。 |
| `playback/player_center_overlay.dart`（新） | 暂停时中心大按钮、双击 seek 的 `±10s` 涟漪、`buffering` 缓冲圈。 |
| `playback/playback_transport.dart`（重写内部） | 组合器：标题行 / 提示行 / 进度条 / 按钮簇；按 `ControlSurface` 分派 PC 与移动两套簇。对外仍是 `PlaybackTransport`，`player_page.dart` 里 `controls: PlaybackTransport(...)` 那个调用点形状不变。 |
| `playback/compact_controls.dart` | 显隐时钟 + 画面手势（单击/双击/长按/横拖）；删掉 `expand_more` 那一行。 |

`ControlSurface` 只有四个取值，判定按宿主 × 方向 × 宽度，一处算好传给下游：`desktopWide`（桌面且 ≥720）、`desktopNarrow`（桌面 <720）、`mobilePortrait`、`mobileLandscape`；小窗/悬浮走 `desktopNarrow` 的降级序列（`player_page.dart` build 里那处 `compact` 判定保持）。TV 走 `TvPlayerSurface`，本轮不动。

### 4.2 进度条

- 轨道 3px，悬停/拖拽时 5px；命中高度 PC 20px、触控 28px（条本身仍细，扩的是热区）。
- 三层：轨道 `white24` → 缓冲 `white30`（`buffer` 未知或 ≥duration 时不画）→ 已播 `primary`；已播端点一枚 10px→14px 的圆点，静止时淡出（不遮挡画面）。
- hover：气泡显示目标时间点，位置跟随指针并夹在条内；拖拽：气泡常驻并显示落点，`onChangeEnd` 才 `seek`（沿用现有 `seeking` 只在结束时落盘的做法，避免边拖边 seek 打爆在线取址）。
- 时长未知（`duration == 0`）：整条退化成不确定态的细线，按钮仍可用。
- 拖拽与悬停在条上时不进入自动隐藏倒计时（`CompactControls` 已有 `onPointerSignal`/`pointers`，进度条要额外把 hover 计入）。

### 4.3 按钮簇

| 面 | 左簇 | 右簇 |
|---|---|---|
| `desktopWide` | 播放/暂停 · 退 10s · 进 10s · 上一集 · 下一集 · 音量（图标+滑杆） · `00:12 / 01:04:20` | 选集 · 清晰度 · 倍速 · 投屏 · 画中画 · 全屏 |
| `desktopNarrow` | 播放/暂停 · 退 10s · 进 10s · 音量图标（滑杆收进点击弹层） · 时间戳 | 选集 · 倍速 · 全屏 |
| `mobilePortrait` | 播放/暂停 · `00:12 / 01:04` | 倍速 · 选集 · 转横屏 |
| `mobileLandscape` | 播放/暂停 · 退 10s · 进 10s · 时间戳 | 选集 · 清晰度 · 倍速 · 投屏 · 全屏 |

- 降级顺序固定（宽度不够时按此丢弃）：时间戳的秒位 → 上一集/下一集 → 进/退 10s → 音量滑杆收进弹层 → 清晰度 → 画中画 → 投屏。播放/暂停、选集、倍速、全屏永不丢弃。
- 音量：连续滑杆 0–100，点击图标静音并记住上一档（`setVolume(0)` / 还原）；键盘 ↑/↓ 步进 5。移动端不放音量件。
- 倍速：`.5 .75 1 1.25 1.5 2` 弹层，当前档打勾；长按画面 2× 只在触控族生效，松手回到菜单里那一档。
- 清晰度：`自动 / 720p / 1080p`（与页面侧 `quality`/`_changeSourceQuality` 同一批取值，`cachedOnly` 时禁用并在标签上显示当前）。**面板里那一行 `清晰度` 下拉删掉**，避免同一状态两个入口；`连播` 仍在面板。（落地时改成条件保留，见 §8）
- `第 N 集 · 选集` 这个文案保留在选集按钮的 tooltip/标签上（真机夹具按文本找它：`ios_episode_swipe_test.dart`、`offline_playback_test.dart`）。

### 4.4 中心层与状态表达

- 暂停（非 `preparing`、非错误）→ 中心 64px（触控 56px）半透明圆 + 播放三角，点击=继续。
- 双击 seek → 被点的那半屏一次涟漪 + `+10s`/`-10s` 文字，800ms 内重复点击累加显示。
- `player.stream.buffering` 为真且本页没在 `preparing` → 右上角小圈 + 「网络波动，正在缓冲」，不动画遮挡画面。
- 投屏中 → 投屏图标变体 + tooltip 带设备名（页面侧 `castActive` getter 与 `castService?.target?.friendlyName` 已有状态，本轮只是把它接进控制条）。

### 4.5 键盘（PC）

新增 K（播放/暂停）、J（-10s）、L（+10s）、M（静音切换）、↑/↓（音量 ±5），与既有 Space/←/→/PageUp/PageDown/F/I/Esc 共存；这些键的 tooltip 里写出键位（`播放（空格 / K）` 这种形状），移动端 tooltip 不带键位。

## 5. 不变量（改完必须仍然成立）

- 键：`transport-play`、`toggle-episodes`、`enter-pip`、`cast-device`、`compact-playback-controls`、`player-exit`、`compact-player-picture`、`player-picture`、`episode-panel` 一律保留原名；新增 `transport-seek-back`、`transport-seek-forward`、`transport-volume`、`transport-quality`、`transport-speed`、`player-progress`、`player-center-play`。
- 文案/tooltip：`上一集`、`下一集`、`播放速度`、`全屏`、`退出全屏`、`投屏到电视`、`画中画`、`退出悬浮播放`、`第 N 集 · 选集` 保持；**只有 `隐藏播放操作` 随 `expand_more` 一起下线**，同步改掉 `compact_controls_test.dart` 里直接 tap 那个 tooltip 的用例（改成 `state.hide()`）与 `offline_playback_test.dart` 里靠它收起控件的步骤（改成等自动隐藏）。
- 显隐契约：暂停/加载/错误/弹层打开/选集打开/拖进度时保持可见；辅助功能模式不隐藏；键盘唤出后保持可 Tab（`immersive-playback.md:10`、`:11`）。
- 视频矩形不因控件显隐改变、不重建 Player（`compact_controls_test.dart` 的 `mobile controls overlay leaves video rectangle unchanged` 那条守的就是这个）。
- 竖向滑动切集（`episode_swipe.dart`）与新的横拖/长按互不抢占：竖向拖与横向拖由方向判定天然分开；长按与拖拽在同一竞技场里，移动超过阈值即放弃加速。

## 6. 验证口径

1. **单测（新面）**：`test/player_controls_test.dart` 用假的 `TransportPlayer` 挂载 `PlaybackTransport`，覆盖：四个 `ControlSurface` 的簇内容、降级顺序、缓冲层只在 `0 < buffer < duration` 时出现、hover 气泡、拖拽落点 seek、音量滑杆与静音、倍速勾选、清晰度禁用态、`h:mm:ss`、中心大按钮。这是第 12 条那个零单测面的补齐。
2. **既有面**：`compact_controls_test.dart`、`episode_workspace_test.dart` 全绿；4 个真机夹具的键位不改名，所以它们只可能因 `隐藏播放操作` 一处改动而红。
3. **实机取证**：新夹具 `integration_test/player_controls_live_test.dart` + `tool/verify_player_controls_live.sh`，macOS 真窗口（1280×800，真实上游在线集）与 iOS 模拟器各跑一遍，按标记截「展开态 / 进度条 hover（仅桌面）/ 倍速弹层 / 清晰度弹层（条上带清晰度的面）/ 音量（仅桌面）/ 暂停中心 / ±10s seek 反馈 / 窄窗降级（仅桌面）」。**改前改后各跑一次**（夹具只打标记、不断言新件，所以两棵树都能跑），前后对照进 `docs/evidence/player-controls/`。时序类结论按 [[project-recording-constraints]] 第 3 条：押夹具自报的状态采样，不押 ffmpeg 帧计数。**seek 反馈的实机帧走控制条的 ±10s 按钮，不走双击**：合成指针在这两台宿主上都敲不出真双击（详见 §8 末条），而两条路最终都汇到同一个 `_nudge` → `flashSeek`，所以帧里的反馈是同一枚；双击语义本身以第 1 条的单测为准。竖屏没有 ±10s 按钮，所以 `mobilePortrait` 的 seek 帧缺拍，iOS 那组只留「未唤出 / 展开态 / 暂停中心 / 倍速弹层」四张。
4. 门禁 `tool/verify_all.sh` 全量。

## 7. 本轮不做

- TV 端 `TvPlayerSurface`（另一套遥控器焦点形态）。
- 竖屏锁定、字幕/音轨选择（上游没有可用轨道面）。
- 投屏远控页（`cast_remote_page.dart`）的改版。
- 清晰度是否真有 720p/1080p 两档源：本轮只搬入口，不改取址策略；页面侧 `quality` 的可用性回落逻辑保持。

## 8. 落地补记（与上面规格的出入，均以实际代码为准）

- **§4.3 的「面板里那一行清晰度下拉删掉」改为条件保留**。清晰度进控制条只发生在 `desktopWide` 与 `mobileLandscape`（页面侧的 `_qualityInBar`）；`desktopNarrow` 与 `mobilePortrait` 的控制条没有清晰度件，面板那一行必须留着，否则这两个面根本没有切清晰度的入口。判据是「同一状态只有一个入口」，不是「面板永远没有清晰度」。`连播` 不受影响，一直在面板。
- **§4.3 表格里竖屏左簇的时间戳换行**。`mobilePortrait` 一行放不下 `播放 · 00:12 / 01:04 · 倍速 · 第 N 集 · 选集`（实测 `RenderFlex overflowed by 91 pixels`），改成 `00:12 / 01:04` 单独一行贴在进度条上方，选集标签用 `Flexible` 兜住；`desktopNarrow`/`mobileLandscape` 仍在左簇内。
- **§4.2 的横向拖拽只吃进度条自己的热区**（PC 20px / 触控 28px），没有做成「整片画面横拖 seek」。画面还要留给竖向切集（`episode_swipe.dart`）与双击/长按，整片横拖会让三者的方向判定互相干扰。
- **点按/双击/长按的识别器挂在「画面」那一层，不是整棵 chrome 的祖先**。实测把 `onDoubleTap` 注册成祖先会 hold 住手势竞技场直到自己放弃，后代 `IconButton` 的 tap 永不触发（`compact_controls_test.dart` 那条 exit 用例就是被这个打红的）。所以 `CompactControls` 的结构是 `Stack[ Positioned.fill(识别器 > compact-player-picture), center, IgnorePointer(chrome) ]`，控制条自己吸收落在条上的点击。
- **双击的实机帧取不到，是夹具的限制不是产品的缺陷**。桌面端：`tester.createGesture` 合成的鼠标按下会撞上真实引擎光标占用的 pointer id（换到高位 id 后从「挂死」变成 `arena.dart` 的 `isOpen` 断言）。触控端：同一个 id 第二次按下也无法重开已结算的竞技场，逐次换 id 后不再报错，但两次按压之间每次 `await` 都要等真实帧，模拟器在解 1080×1920 视频时把间隔拉到 300ms 双击窗之外——夹具跑完不抛异常，位置采样仍单调前进。所以第 6 条第 3 点的 seek 帧改由 ±10s 按钮触发，竖屏那一档缺拍；双击/半屏语义的证明留在 `player_controls_test.dart`（假时钟下 80ms 间隔的两击能过）。

## 9. 提交与发版（0.3.13）

- 设计与执行都落地后，本轮按用户指令「执行提交推送到远端git，并发布新版版本」随 **0.3.13+25** 发版，和上一轮的 PC 侧栏零动画（[discover-catalog-cascade-tabs.md](discover-catalog-cascade-tabs.md) §14）同批：两批改动在同一工作树里交织，所以按功能面各自成提交，`.idea/` 不入库。
- **证据帧提交排在切版本提交之前**，为的是让 `v0.3.13` 这棵树里就含全部帧——§13 第 12 条那次「标签树里的帧比 main 旧一轮」是上一轮把帧排在标签之后的既定代价，这次把顺序倒过来。推送仍走 `tool/push_pending_commits.sh` 逐提交排空（一张帧一个提交，单次 push 只带那一张的字节）。
- **发版前的门禁跑在分离 worktree 的提交树上**（`HONGGUO_FLUTTER_BIN` 给 `.fvm` 的绝对路径），读数以 `tool/verify_all.sh` 的退出码为准；数字写进 §14 第 7 条那种明细要现读，不抄本文件其它处的自报值。
- 取证脚本本轮补了第三条分派：`tool/verify_player_controls_live.sh` 认 adb 序列号（`adb exec-out screencap -p` 可直写工程卷），并在装包前现读机上 `com.example.hongguo_app` 的 versionCode 与本地 build 号比对，高于本地就停下——`HONGGUO_ANDROID_ALLOW_DOWNGRADE=1` 是唯一放行口，不设默认，因为 flutter 装包失败会去 `adb uninstall` 现有包。
- **本轮没有手机帧**：用户放开 Android 真机取证、设备也连通了，但指令随后转成提交发版，所以 `mobilePortrait` 的证据仍是 iOS 那四张；`mobileLandscape`（条上带清晰度与 ±10s 的那个触控面）至今没有实机帧，是这条链路留着的缺口，下一轮补。
