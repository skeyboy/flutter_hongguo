# 投屏单例化 + 剧集队列 + 全局悬浮窗

参考图是市面 App 投屏后的遥控器页（设备名 + 换设备、弹幕/倍速/清晰度一行、±10s/暂停/±10s、进度条与首尾时间、左下角「选集」、右下角「下一集」）。本文只解决一件事：**投屏一旦开始，它是应用级状态，不是播放页的附属品**。

## 结论先行

1. **`CastController` 升级为应用级单例 `CastService`**，用现有 `Expando` 会话服务惯例按 runtime 取（同 `personalLibraryFor()`，`packages/app/lib/platform/runtime_contract.dart:132-136`）。播放页只借用它，不再创建/销毁它。
2. **单例里加剧集队列**：`DramaDetail + index + quality`，暴露 `playAt/next/previous/setQuality/switchTo`。协议层 `CastSession` 不变——切集就是再发一次 `SetAVTransportURI + Play`，这是 DLNA 唯一可靠的原语。
3. **悬浮窗是 App 内全局层，不是系统级悬浮窗**：挂在 `MaterialApp.router` 的 `builder` 上（`packages/app/lib/navigation/app_navigation.dart:150-169`），投屏中且投屏页不在栈顶时出现，点击回到遥控页，关闭才停止投屏。
4. **返回键语义反转**：今天遥控页被 pop 就顺手 `stop()`（`packages/app/lib/cast/cast_remote_page.dart:21-23`），本期改成「返回=收起，退出投屏=停止」。这是整个需求的支点，不改这一条，悬浮窗无从谈起。
5. **弹幕、倍速不进本期代码**：DLNA 侧没有弹幕通道，倍速依赖接收端实现 `Play(Speed)`（各家差异大，见后端配合清单）。UI 上先只落清晰度，不伪造可用状态。

## 现状：为什么现在做不到

| 事实 | 位置 | 后果 |
|---|---|---|
| 控制器随播放页创建 | `packages/app/lib/features/player_page.dart:366-369` | 每个播放页一个实例，彼此不可见 |
| 控制器随播放页销毁 | `player_page.dart:961-962` | 返回上一页即 `dispose()`：撤租约 pin、关 LAN HTTP 服务、放组播锁、断会话订阅 |
| dispose 不给电视发 Stop | `packages/app/lib/cast/cast_controller.dart:240-249` | 电视继续放到缓冲区耗尽才黑，手机侧状态与电视不一致 |
| 会话只认一个 `DidlItem` | `packages/cast/lib/src/session/cast_session.dart:23-28` | 没有 vid、没有集序、没有剩余队列，切集只能由调用方重新组织 |
| 投屏中禁止重新搜索 | `cast_controller.dart:73` | 没有「换设备」这条路 |
| 遥控页上一集/下一集是死代码 | `cast_remote_page.dart:150-181` + 调用点 `player_page.dart:624` 只传 controller | 按钮永远 null |
| 手机侧禁止切集 | `player_page.dart:1086`「投屏中请在电视端切换剧集」 | 把能力问题写成了产品规则 |
| 全 App 只有一个 OverlayEntry | `packages/app/lib/features/library_page.dart:35` | 悬浮层无先例可循，需要新建 |

## 目标形态

### 1. 所有权与生命周期

```
CastService（应用级，Expando 绑 runtime）
├── DeviceBrowser          设备登记表，跨页面复用，搜索过一次就缓存
├── MulticastLock          从「搜索期间」升级为「投屏存活期间」一直持有
├── LanMediaServer         一个进程只绑一次，切集只换 lease 不重绑端口
├── CastSession            一台电视一个会话；换设备才新建
├── PlaybackJob pin        当前正在被电视拉的那个文件
└── 队列：DramaDetail + index + quality + 起播位置
```

- **谁创建**：`castSupported(runtime)` 为真时，第一次用到才建（懒建，桌面/TV/web 永远不建）。
- **谁销毁**：只有 App 退出。播放页 pop、切页面、返回书架都不销毁。
- **进程被系统回收/用户划掉**：不做后台保活承诺。Android 上投屏是「手机当服务器」，进程死了电视就断流，这条要如实写进文案，不宣称锁屏可投。
- **释放时机**：`stop()`（用户点退出投屏）、队列播完且用户不再续播、切到别的剧重新 `open()`。每次释放都撤销 pin、revoke lease，并把 LAN 服务留给下一次复用。

### 2. 剧集队列

```dart
Future<void> open({required DramaDetail detail, required int index,
                   required KnownRenderer renderer, String quality, Duration? at});
Future<void> playAt(int index);      // 越界钳制；与当前同集则忽略
Future<void> next();                 // = playAt(index + 1)，末集返回 false
Future<void> previous();
Future<void> setQuality(String value);  // 记住电视当前位置，换清晰度后 seek 回去
Future<void> switchTo(KnownRenderer renderer);  // 换设备，保持同一集同一位置
```

- 标题沿用现有格式 `${drama.title} · 第 ${episode.index} 集`，与 `player_page.dart:611` 一致，避免两处文案分叉。
- 清晰度列表来源不变：`VideoQualityRuntime.videoQualities(vid)`；缓存模式仍走 `LocalMediaRuntime.localEpisodes()`（同 `player_page.dart:196-224` 的两分支）。
- **自动下一集**：电视播完上报 `STOPPED/NO_MEDIA_PRESENT`（`cast_session.dart:283-288`），且 `position` 已贴近 `duration` 时，按 `settings.autoNext` 决定续播下一集。必须区分「电视播完」与「用户按了停止」，用一个 `_userStopped` 标志位，否则会把停止误判成播完并自动开下一集。轮询在 stopped 时会自停（`cast_session.dart:251-254`），续播走重新 `cast()`，会自然重启轮询。
- 切集失败（该集没缓存、上游 302）不清空整个队列，只把这一集标失败并停在原地，错误文案走现有 `_describe()`。

### 3. 悬浮窗规格

| 项 | 规格 |
|---|---|
| 形态 | 底部右侧可拖动胶囊：投屏图标 + 集名（1 行省略）+ 设备名（1 行省略）+ 播放/暂停 + 关闭 |
| 出现 | `service.active` 且当前路由不是投屏遥控页 |
| 隐藏 | 投屏页在栈顶；未投屏；TV flavor；桌面/移动宽度 < 360 时收成图标态 |
| 点击 | 重新 push 遥控页（`AppScreen.cast`），不新建会话、不重新搜索 |
| 拖拽 | 纵向为主，松手吸附左右边，避开系统手势区与安全区；拖拽位移 > 8px 时不当作点击 |
| 关闭 | 等于「退出投屏」：`stop()` 并把电视位置交回本地播放页（若还开着） |
| 层级 | 位于路由内容之上、系统弹窗之下；用 `Stack` 叠在 `builder` 返回值上，而不是 `OverlayEntry`，避免路由切换时被顺带清掉 |
| 进度 | 只读电视上报的 `GetPositionInfo`，不做本地插值（沿用设计稿 §架构 的「不做假插值」） |

### 4. 遥控页对照参考图

| 参考图元素 | 本期 | 依据 |
|---|---|---|
| 顶部剧名 + 返回 | 做 | 返回=收起，投屏继续 |
| 设备名大字 + 换设备 | 做 | 单例允许 active 时 `browse()` |
| 清晰度（自动） | 做 | `setQuality` 重推 URL + seek 回原位 |
| ±10s、播放/暂停 | 做 | 现有 `seekTo`/`pause`/`resume` |
| 进度条 + 首尾时间 | 做 | 现有 `cast-scrub` |
| 选集 | 做，底部抽屉复用 `EpisodePager`（`packages/app/lib/playback/episode_pager.dart:31-45`，rows:3/cellExtent:100 与手机端一致） | 已有分页与焦点交接，不重造 |
| 下一集 | 做 | `next()` |
| 音量 | 保留（参考图无，但 DLNA 唯一可用的额外能力） | `setVolume` |
| 弹幕 | **不做** | 见后端配合清单 |
| 倍速 | **不做** | 见后端配合清单 |

## 后端配合清单

1. **弹幕**：投屏是「手机给电视一个 URL」，电视端播放器不认识弹幕协议。要做只有两条路——(a) 接收端内置我们的弹幕协议（需要电视端 App，国产电视不可控）；(b) 手机侧在悬浮窗/遥控页叠一层弹幕动画，与电视进度对齐后本地渲染。后者需要服务端提供按集索引的弹幕时间轴接口与延迟补偿口径，目前只有站内弹幕、无投屏时间轴。**本期 UI 不出现弹幕开关。**
2. **倍速**：UPnP AVTransport 的 `Play` 有 `Speed` 参数，但规范只保证 `1`，`2/4/8` 与 `1.5` 这类非整数倍各家实现不一，小米/海信实测行为不同；且我们的清晰度产物是固定码率文件，倍速还牵涉音画同步。需要协议侧先做接收端能力探测（`GetCapabilities`/试错），再决定档位集合。
3. **真 4K 投屏**：投的是已缓存文件，质量等于用户已缓存的质量；要 4K 需要下载侧先支持 4K 档位。
4. **锁屏/后台持续投屏**：Android 需要前台服务（`mediaPlayback` 类型）保住在跑的 LAN HTTP 服务与组播锁，否则 Doze/省电策略下断流。本期不做，文案不得承诺「锁屏继续投」。
5. **设备偏好持久化**：换设备后希望记住上次那台（`KnownRenderer` 只有 UDN + 描述 URL），需要存储层加一张表；本期仍每次现搜。

## 验收标准

- [ ] 投屏开始 → 返回书架 → 悬浮窗在；电视未断流（LAN 服务与 pin 仍在）。
- [ ] 点悬浮窗 → 遥控页回到栈顶，进度与电视一致，不重新搜索、不重新推流。
- [ ] 遥控页选集/下一集 → 电视换集，手机悬浮窗标题同步；末集时下一集禁用。
- [ ] 换设备 → 同一集同一位置在新电视继续，旧会话关闭。
- [ ] 清晰度切换 → 位置保持，误差 ≤ 轮询周期（2s）。
- [ ] 只有「退出投屏」会让电视 Stop；返回键不会。
- [ ] 退出投屏回到还开着的播放页 → 本地从电视位置续播（现有行为不回退）。
- [ ] TV flavor、桌面、web 不出现悬浮窗与入口。
- [ ] widget 测试覆盖：单例跨路由存活、悬浮窗点击重开、选集切集重推 URL、自动下一集不误触发于手动停止。

## 不在本期

系统级悬浮窗（`SYSTEM_ALERT_WINDOW`，跨 App，需权限与原生通道）、iOS AirPlay 视频投递、弹幕/倍速、锁屏后台投屏前台服务、投屏时本地继续预缓存下一集。
