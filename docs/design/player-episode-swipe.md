# 播放页竖滑切集与首次提示

上下滑切集的手势在 `player_page.dart` 的 `_touchVideo()` 里已经存在，但只是「能用」：唯一的守卫是 `preparing`，鼠标竖向拖拽同样会切集，到边界静默无反馈，没有首次进入提示，投屏中滑动还会和本地播放打架。本页记录按市面惯例把这套手势收敛成可交付交互的口径。

## 市面依据

- 抖音/快手/B 站竖屏信息流：上下滑切换整条视频是最强的肌肉记忆。短剧 App 沿用同一手势，只是切换对象从「视频」变成「集」，方向不变——上滑进下一集、下滑回上一集。
- YouTube：Shorts 早就是上滑下一支；2017 年起在长视频全屏用双击左右半屏 ±10s 做进度手势；2024-11 又测试用滚动视频取代全屏手势。竖滑负责「换一个内容」，双击负责「跳进度」，两者不互相抢。
- Netflix/Hulu/Disney+：横屏长视频里手势只用于快退快进（双击 10/30s），切集走列表——横屏画面上下滑更像滚动，做成切集容易误触。
- PC（B 站/YouTube/腾讯视频网页版）：不用拖拽切内容，用快捷键（←→ 进度、PageUp/PageDown 或 J/K/L）。鼠标竖向拖拽会和选中、滚动冲突。

结论：竖滑切集在触屏上主流且低歧义，保留并加守卫；桌面不提供拖拽切集，改由按钮与 PageUp/PageDown，并把这一点写进桌面首次提示文案。本 App 的短剧是竖屏沉浸，横屏全屏播放时仍保留触屏手势（同一手指区域），但鼠标拖拽在任何平台上都不再切集。

## 手势规格

- 设备来源：只接受 `PointerDeviceKind.touch` 与 `stylus`。mouse/trackpad 的竖向拖拽直接丢弃，`kind == null` 也丢弃——现状是鼠标拖一下就越集，桌面端这是误触而不是功能。
- 阈值：沿用现有数值，位移绝对值 > 80 px 或主速度绝对值 > 800 px/s 才认定一次切集；位移为 0（纯抛掷）时用速度符号判定，保持既有手感。上滑（delta 为负）= 下一集。
- 互斥，丢弃且不提示：`preparing`、`error != null`、选集浮层 `sheetOpen`（移动端底部弹层压住画面）、`menuOpen`、`recommendationOpen`、悬浮窗/系统画中画。这些状态下控件或系统正占着画面与焦点，滑一下换集会同时改两处。桌面的选集面板不拦：它与画面并排，滑的是画面，效果等同点列表里的一行。
- 投屏中：丢弃手势但给提示「投屏中请在电视端切换剧集」。静默会让用户以为手势坏了；`CastController` 目前没有「换媒体」的远端指令，本地换集只会和电视端各播一集。
- 边界反馈放在 `_step()` 内：第一集下滑显示「已经是第一集」，最后一集上滑显示「已经是最后一集」，都不发起 `_play()`。放在 `_step()` 而不是手势里，PageUp/PageDown、传输条的上一集/下一集按钮、TV 遥控三路与手势一致。提示复用 `playbackNotice`，并调用 `compactControls.show()` 强制显形（notice 渲染在 chrome 内部，控件自动隐藏时看不见），2.6 秒后自动清除，避免一行状态文案悬挂到下一集。
- 切集成功后与按钮路径完全相同：`_play(target)` 负责取消旧任务、清理 `playbackNotice`、写观看记录、触发预缓存窗口。手势不额外做任何状态迁移。

## 首次进入提示

一次性，落盘 `AppSettings.episodeSwipeHintShown`。该字段不进 `protocolJson()`，不参与请求签名，与已有的 `backgroundPlaybackPrompted`/`floatingPlaybackPrompted` 同族。

- 展示位置：视频区叠加层，居上、避开标题与传输条，`IgnorePointer` 不吞掉点击显示控件的手势。提示浮层在 chrome 之外，控件自动隐藏时的 `ExcludeSemantics` 不会把它一起藏掉，读屏能念到整句话。
- 消失：3 秒后淡出；`disableAnimations` 时不做淡入淡出直接消失。用户提前完成一次切集，提示立刻让位。消失时才写盘——写失败静默，宁可下次再显示一次，也不在播放中弹错误。
- 中途打断：提示还在屏上时投屏、进悬浮窗或出错，页面把文案收回，提示立即消失并且**照样算展示过**——回到可滑状态不再重放，否则一句提示弹两次像 bug；收回时也不能让它继续留在树上，不然会渲染成一个没有文字的黑胶囊。
- 只有从未展示过才不消费标记：单集剧目（`episodes.length < 2`）、TV 端、一进播放页就已在投屏或悬浮窗/画中画。这些情况下要么没有可滑的对象，要么滑的人不是本机；一旦提示出现过，自己淡出、被首次滑动打断、被投屏收回都算用过。

文案按平台 × 设备族分派，不默认 PC 键盘文案：

| 环境 | 提示 |
| --- | --- |
| mobile 触屏（Android/iOS） | 上滑下一集 · 下滑上一集 |
| 桌面（macOS/Windows/Linux，非 mobile） | Page Up / Page Down 切换上下集 |
| TV | 不显示，选集走列表与方向键 |
| 悬浮窗 / 系统画中画 | 不显示 |

## 实现接缝

- `packages/app/lib/playback/episode_swipe.dart`：`EpisodeSwipeArea` 负责手势识别、设备族过滤、阈值、一次性提示浮层与它的计时。`player_page.dart` 只交出状态与文案——`blocked`（当前是否禁止切集）、`onStep`（±1，直接接到 `_step`）、`onBlocked`（被丢弃时给什么文案）、`hintText`（按设备族选文案、被各互斥条件抑制）、`onHintSeen`（落盘），不把计时与手势状态搬进播放页。
- `AppSettings` 新增 `episodeSwipeHintShown`：字段、构造默认值、`toJson`、`fromJson`、`copyWith` 四处，`validate()` 不校验 bool。

## 后端配合清单

本特性不需要接口改动：剧集列表来自详情页已有的 `episodes`，进度与记录全在本地。若后续要做「滑到最后一集后自动接下一部剧」，需要推荐接口给出同剧续推或关联剧，届时另立设计稿。

## 验收状态

已自动化：`packages/app/test/episode_swipe_test.dart` 12 例——设备族判定（touch/stylus 通过，mouse/trackpad/unknown/null 拒绝）、竖滑两个方向、横滑不切集、40px 快甩只靠速度切集、40px 慢拖两个阈值都不过、鼠标拖拽不切集、`blocked` 时丢弃并回报方向、提示等播放就绪（`hintText` 由 null 变非 null）才起计时器并在 3 秒 + 淡出后只上报一次、提示中途被收回即消费且不再重放、首次滑动立即消费提示、`disableAnimations` 时不淡出、提示在 chrome 的 `ExcludeSemantics` 之外仍能进语义树、未达阈值的滑动保留提示。合成手势要显式给绝对 `timeStamp`，否则 `flutter_test` 里所有事件同一时刻、速度估计恒为 0。`packages/core/test/settings_test.dart` 扩了一条断言：`episodeSwipeHintShown` 老配置默认 false、`copyWith`+JSON 往返保留、且不进 `protocolJson()`。

门禁读数（工作树同时带有另一条网络恢复线的在途改动，因此这些数不是本 commit 单独树的结果）：`packages/app` 191 例通过 / 1 skip，`packages/core` 117 例通过，`dart analyze --fatal-infos packages/app packages/core packages/tv packages/cast` 无 issue；本轮新增与修改的文件 `dart format` 干净（仓库里 `packages/app/test/macos_picture_in_picture_test.dart` 早就不合格，CI 没有格式门禁，与本轮无关）。

未覆盖：`player_page.dart` 一侧的接线——`_swipeHint()` 的设备族文案选择与单集/投屏/悬浮抑制、`_swipeDropped()` 的投屏文案、`_step()` 的边界提示与 2.6 秒自清。`packages/app/test` 里没有任何用例挂载 `PlayerPage`，它需要 media_kit 真实解码，只有 `integration_test/offline_playback_test.dart` 能在 macOS 宿主上跑到播放页；那条线目前由另一会话在改，本轮不动它。

未做：Android/iOS/桌面带窗口的人工验证。本层结论只到 widget 树，不代表真机触屏实测通过；投屏中「丢弃手势」那条要连真实 DLNA 接收端一起验。
