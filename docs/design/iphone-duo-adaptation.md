# iPhone Duo 折叠屏适配设计

日期：2026-11-01。源码基线 HEAD `b720845`（标签 `v0.3.19`）。分析对象 `packages/app`（手机/桌面主工程）、`packages/api`、`packages/core`；`packages/tv` 是另一个 flavor，不在本设计的姿势模型里。

本轮（同日第二轮）在 **Mac + Xcode 27.1 + iOS 27.1 iPhone Duo 模拟器**上做了原生取证，并把结论写回 §2/§3/§5.8；夹具是 `tool/duo_probe/`（`main.swift` + `build_and_run.sh`，读数落在 `tool/duo_probe/evidence/*.jsonl`）。**仍未修改任何生产代码**：§4 的现状盘点本轮逐条回到源码复核过，位置全部命中（见 §4.1 注）。第一轮的「本机没有真机、没有模拟器、没有 Xcode」在第二轮不成立，凡受影响处已逐处改写。原型见 [prototypes/iphone-duo.html](prototypes/iphone-duo.html)。

**取证只成功了一半，这件事写在最前面**：三帧共 479 个样本全部是**合上态**（外屏 466×678、`hinge = closed`），内屏与半开一条没采到——模拟器是 headless 起的、折叠姿势没有程序化入口，而 240s 窗口里探针在 100s 后被挂起（§8 有完整的原因清单与下轮的固定动作）。所以本轮坐实的是 §2 表里标「一手实测」的六行（倍率、外屏逻辑点、外屏尺寸级、右边带 84pt、两块摄像头遮挡几何、铰链回调可用），而**内屏 669×951 与 40pt 带仍是间接证据**。本轮同时补了 §5.10–§5.14 五个缺口（手势与带、可达性与缩放、溢出落面、挂点与测试挂载、连带面），它们全部来自源码现读，不依赖那次失败的采样。

## 0. 结论摘要

1. **官方规则本身可直接照搬，但它的前提在我们身上不成立。** Apple 两份文档（2026-09-09 同时上线）反复讲的是一条捷径：「用系统组件，折叠屏的适配自动送你」。我们是 Flutter 应用，发现页外壳的 `NavigationBar`/`NavigationRail`/侧栏、传输条、弹窗与抽屉全部自绘，`NavigationSplitView`、`ArrangementView`、`ReservedRegion` 一个都不存在。所以本设计的主体是：**把官方规则翻译成我们自己要写的东西**，而不是「换成系统组件就好了」。
2. **今天必须先解决的是阈值，不是折叠带。** 现读的官方口径把外屏定为 compact width、内屏定为 regular width；内屏竖屏宽约 669pt。而 `library_page.dart:3129`（`b720845` 上是 `:3101`）的 `size.maxWidth < 720` 会把 669 判成 compact——于是内屏全开时观众看到的是一块 6.7 寸手机布局（底部标签条 + 单栏 + 底部抽屉 + 由 `floor((621+10)/110)` 推出的 **5 列**分集，奇数列正被中带切），这正是官方明确反对的「把已有布局按可用空间放大」的反面。**这一条不需要折叠感知就能修**，是本设计的第一期。
3. **折叠感知不是「拿不到」，而是「Flutter 层还没接」——第一轮这句结论要改。** 本轮现读 iOS 27.1 SDK：`UIHinge`（`status = unknown/closed/partiallyOpen/fullyOpen` + `angle`）、`UIHingeInteraction`（事件回调）、`UIView.reservedRegions(of:)`（division / occlusion，含 `frame` / `margins` / `isActive` / `IncludeInactive` 查询项）全部是 `API_AVAILABLE(ios(27.1))` 的公开 API；探针已在 iPhone Duo 模拟器上真收到 `hinge = closed` 的初始回调，不是只有头文件。缺的只有 Flutter 侧：`MediaQuery.displayFeatures` 在 iOS 上仍是空表，提案 flutter/flutter#192515 与 PR flutter/flutter#193025 都仍 open、未合入，且该 PR 的引擎代码在 `#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 270100` 下、要等 Flutter 官方 CI 换到 Xcode 27.1 才会真的报。**因此折叠带仍然按「可插拔的一路输入」设计，但立论换了**：不再是「今天拿不到」，而是①这些 API 有 iOS 27.1 硬门槛，低版本 iOS 与非 iOS 折叠机仍拿不到；②上游语义还会变（§3）。结构性防御（分栏落中缝、网格取偶数列）继续保留，让位则在能读到时精确做。§7 的分期由此重排：P2 不再被上游 PR 阻塞，改为被「自写通道的工程量」阻塞。
4. **一期范围**：pose 模型与注入式 `LayoutEnvironment`、把 §4.1 现读出的 13 行字面量判据改成 pose 驱动、外屏与内屏横屏的竖排控制条、内屏的常规宽度双栏与偶数列网格、弹窗/抽屉口径、播放器的 overlay 分屏（立姿上半画面下半控件）、§5.10 的手势宽度喂法与 §5.11 的侧栏语义。**明确不做**：影像采集相关（本应用不采集）、Live Activities、Split View 多任务分屏、iOS 端画中画第二屏。

## 1. 官方依据：逐条原文与对本应用的含义

两份一手文档，均已抓成纯文本存证：Human Interface Guidelines《Designing for iPhone Duo》与 Technology Overviews《Preparing your app for iPhone Duo》，两份的变更记录同为 2026-09-09「New page」。下文「HIG」指前者、「PREP」指后者。

| # | 官方原文（逐字） | 出处 | 对本应用的含义 |
|---|---|---|---|
| R1 | "iPhone Duo is a foldable phone, with a compact outer display and a large inner display." | PREP | 两块屏，尺寸级（size class）是官方给的第一层抽象，不是像素宽。我们所有宽度判断必须改成「尺寸级」而非数字。 |
| R2 | "A compact width layout for the outer display and a regular width layout for the inner display give you the fundamentals for every pose." | HIG | 官方把「外屏=compact、内屏=regular」定为**所有姿势的地基**。§2 的阈值迁移就是这一条的直接落地。 |
| R3 | "Don't reinvent your app when it resizes; allow the existing layout to expand based on the available space instead." | HIG | 反对为每个姿势做一套定制 UI。本设计不新增页面，只改「同一页在不同宽度下取哪一档」。 |
| R4 | "Use size classes, layout margins, and safe area insets to lay out controls and content." | HIG | 与 R2 同族：safe area 是官方指定的第二层。我们要读的 `MediaQuery.paddingOf` 的每条边就是它。 |
| R5 | "Make layout calculations based on your scene or containing view's bounds rather than screen dimensions." | PREP | 直接命中现状：`detail_page.dart:339-340` 用 `MediaQuery.sizeOf(context).width` 而不是所在 sliver 的约束宽度。 |
| R6 | "Don't use `userInterfaceIdiom` or `UIInterfaceOrientation` for layout decisions in your UIKit app." | PREP | 我们的等价物是 `host_policy.dart:3-8` 的 `mobileHost`（平台判断）与 `player_page.dart:1811` 的 `size.width >= size.height`。后者是**长宽比不是方向名**，合规；前者只用来选策略，不用来定宽度档位，合规。 |
| R7 | "the system moves controls to the side to preserve vertical space for content" / "Controls on the side include both system and app elements: the Dynamic Island, the status bar, the toolbar (including navigation buttons), and the tab bar." | HIG | 竖排控制条是 Duo 的**核心范式**，且官方把「app 自己的 toolbar 与 tab bar」和系统元素排成同一列（自上而下：灵动岛 → 状态栏 → 工具栏 → 标签栏）。我们必须自绘这条侧栏。 |
| R8 | "The exception is the inner display in portrait, which has enough vertical space to keep standard horizontal bars." | HIG | 关键反例：**内屏竖屏不要改成竖排条**。所以侧栏只在「外屏任意方向」与「内屏横屏」出现，这一条直接决定 §5.3 的分派表。 |
| R9 | "This happens on the outer display when the device is closed, and for some views in the leading or trailing position on the inner display when the device is open." | PREP | 补充 R8：内屏全开时侧向条可以只出现在某个分栏（官方点名 detail view）上，不必整页翻转。 |
| R10 | "In a split view displaying multiple views, the system shows bars horizontally for the sidebar or content view, and vertically for the detail view." | PREP | 双栏页里详情栏的条是竖排、侧栏与内容栏横排。一期按 HIG 的例外保留横排，二期再做详情栏竖排（§5.3 末）。 |
| R11 | "On the outer display, the system presents bars vertically for sheets by default." | PREP | 外屏上的弹层（我们的下载选择、清晰度、缓存面板）默认也要竖排条——即抽屉的头部按钮在侧边而不是上下。 |
| R12 | "Reserve the top for primary navigation controls, like Back or Close, followed by prominent actions, such as Done." | HIG & PREP | 侧栏自上而下的排序契约：返回/关闭 → 强动作 → 其余。发现页外壳与播放页都要按这个顺序重排。 |
| R13 | "Items overflow from bottom to top by default. Assign each item a visibility priority to change that order." | HIG | 侧栏装不下时的丢弃方向是**从下往上**，且优先级的粒度是「先整组、再组内单项」。§5.3 用现成但没人消费的 `ControlSurface.dropOrder` 落实。 |
| R14 | "The system uses an icon for an item it presents vertically. … If your item has a title and doesn't have an icon, the system doesn't present it vertically. If your item uses a custom view rather than a title or icon, the system doesn't present it vertically." | PREP | 竖排只吃图标。所以侧栏里的每个条目必须「图标 + 标题」齐备（横排与溢出菜单用得上标题），纯文字条目和纯自定义 view 条目无法进入侧栏。 |
| R15 | "Preserve frequently used actions first, like Compose in Mail or New Note in Notes, and keep controls that convey important status, like items with badges, visible longer." | HIG | 优先级不能只按视觉权重拍：带徽章（我们的「下载中」「更新」红点）的条目要比同组其他项更晚被收起。 |
| R16 | "Group related toolbar items instead of spacing them manually." | HIG | 侧栏用分组而不是手摆间距；这条把传输条现有的硬编码 `SizedBox` 间隔判成了需要改的东西。 |
| R17 | "Locate controls near the content they affect. … controls that affect the list of emails in Mail stay above the leading pane." | HIG | 双栏时不要把两栏的控件都塞进同一条侧栏。详情栏控件跟详情栏，列表栏控件留在列表栏头部。 |
| R18 | "In general, don't override the default bar placement." | HIG | 不要提供「把侧栏切回底部」的开关。设置页里不加这一项。 |
| R19 | "Consider using the full display width for interfaces where bars aren't necessary… as long as nothing conflicts with the Dynamic Island or the status bar." | HIG | 播放器画面允许占满整块屏（Calculator 先例），前提是让开灵动岛与状态栏——这正是 §5.6 播放页的立论。 |
| R20 | "A division occurs when a folding region divides a large view into smaller views. An occlusion is an area of a view where a hardware element, such as the camera, covers your content." | PREP | 预留区分两类，处理方式根本不同：division 把一块布局切成两块（要选边界落点），occlusion 只是盖住（要选避让）。 |
| R21 | "the inner front-facing camera is hidden when not in use" / "the outer front-facing camera always occludes your view" | PREP | 外屏摄像头**常遮挡**、内屏摄像头**只在工作时**出现。本应用不采集影像，所以只有前者对我们成立（§5.9）。 |
| R22 | "A reserved region can be active or inactive. For example, a reserved region that represents the fold is active when iPhone Duo is partially open, but inactive when it is fully open." | PREP | 折叠带是一条**条件区域**，不能用「有没有这条带」判断设备型号，只能用「它现在是否 active」判断当前姿势。 |
| R23 | "Prefer a layout container that adapts automatically, like the split view in Notes that adjusts the width of each pane to stay clearly visible as the device folds. In a grid-style layout, prefer an even number of columns so content divides cleanly." | HIG | 两条硬约束：分栏的边界要为折叠带让位（不是等宽），网格**优先偶数列**。§5.4 与 §5.7 分别是它们的落地。 |
| R24 | "Avoid extreme layout changes as people fold the device. Move only what's necessary to keep elements visible and easy to tap. Controls that disappear or shift dramatically are harder to find and track, so favor small adjustments over rearrangement." | HIG | 反对「半开就换一套 UI」。这条直接否决了「检测到折叠就切到一个专门的立姿页面」这种设计。 |
| R25 | "An arrangement view… represent an arrangement view, which is a layout container for a primary view and a secondary view"；"splits horizontally when the arrangement is wider than it is tall" | HIG & PREP | 新的布局原语：split = 主副两栏（宽于高时横向分栏）。我们的「侧栏 + 内容」双栏正是它。 |
| R26 | "the overlay arrangement places the primary view in the trailing or bottom part of the display relative to the fold, and the secondary view in the leading or top part of the display relative to the fold" | PREP | overlay = 主视图叠在副视图上；半开时主视图落到折叠带的**近侧（下/后）**。播放页（画面叠在信息流上）正好是它，§5.6 播放页据此定「画面推到近半屏」。 |
| R27 | "Avoid placing an arrangement view inside a navigation split view, list, scroll view, or other container that might cause part of your view to become inaccessible." | PREP | 约束：分栏容器不能嵌进可滚动列表里。我们的 `EpisodePager`、发现页瀑布流都得遵守——折叠让位逻辑不能写在 sliver 内部。 |
| R28 | "When you build with Xcode 26 and earlier, your app doesn't extend under the status bar and camera." | PREP | 用旧 Xcode 构建时系统不给全屏，safe area 的边也就不是最终值。这决定了 §8 的验收必须用 Xcode 27.x 重新读一遍。 |
| R29 | "Because not every pose places controls vertically on the side, and there isn't always the same amount of space available, it's important to keep controls' relative positions as similar as possible so people don't have to relearn where actions live as they change between poses." | HIG | 跨姿势的**相对位置一致性**优先于每个姿势的局部最优。§5.3 的侧栏条目顺序因此与底部条的顺序共用一份声明。 |
| R30 | "If two apps share the inner display with Split View multitasking, each one places controls along its outer edge, so the left app has controls on the left." | HIG | 侧栏贴哪一边取决于我们占内屏的哪一半，这不是能从 Dart 猜出来的，属于系统事件（§5.9 列为不做，但 §5.3 的分派表把它写成「侧边取自主机上报的 band 边」而不是常量）。 |
| R31 | "Because controls sit along one edge, the space for content is asymmetrical. Use safe areas to make sure controls don't cover your content, including controls on the opposite edge." | HIG | 侧栏让内容是**不对称**的。我们的 `Row` 外壳必须把侧栏当作一条边而不是上下边，且两侧都要读 padding。 |
| R32 | "The rate and granularity of angle updates are system policy… If you only need to know whether the hinge is closed, partially open, or fully open, prefer `status` over `angle`." | iOS 27.1 SDK 头文件 `UIHinge.h`（本轮现读，非两份文档） | 姿势只用三档枚举，**不许**把连续角度接进 Dart。§5.8 的通道形状因此没有 `angle` 字段。 |
| R33 | `UIViewReservedRegion.frame`：「the rect of the region in the view's coordinate space, **including the margins**」；`.margins`：「the margins included in the frame around the reserved rect **for interactive content**」 | 同上，`UIViewReservedRegion.h` | 系统给的是**两个**矩形而不是一个：`frame` 是「可交互内容该让开的范围」，`frame` 内缩 `margins` 才是「硬件本体」。§5.4 的让位与 §5.10 的手势死区按 `frame`，卡片图案能不能压线按内缩后的本体。 |
| R34 | `UIWindowSceneGeometry.interactivelyResizing`（iOS 26+） | 同上，`UIWindowScene.h` | R24「别把控件位置绑在瞬时值上」的一手判据：交互式改尺寸期间冻结档位切换。本轮所有帧该字段为 `false`（没发生换屏），故只是 API 面成立，行为未证。 |

## 2. 设备事实与推算（含来源分级）

| 项 | 数值 | 分级 | 来源与说明 |
|---|---|---|---|
| 外屏像素 | 1398×2034 | 官方，本轮现读 | App Store Connect 截图规格页直接 curl 读取，页面内 "iPhone Duo" 出现 5 次，四个数字逐个命中。 |
| 内屏像素 | 2007×2853 | 官方，本轮现读 | 同上。 |
| 两块屏的倍率 | **scale = 3、nativeScale = 3** | **一手，本轮 Mac 现读** | 两个独立来源同一结论：① `/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone Duo.simdevicetype/Contents/Resources/capabilities.plist` 里 `displays[0].scale = 3`、`displays[1].scale = 3`（外屏 `hdpi/vdpi = 460`，内屏同）；② 探针在 iPhone Duo 模拟器（iOS 27.1）实读 `screen.scale = 3 / nativeScale = 3`。**§2 原来那条「@3 是推的」保留声明作废。** |
| 外屏逻辑点 | 466×678 pt | **一手实测（本轮 Mac）** | 探针在 iPhone Duo 模拟器读到 view 与 screen 均 466×678 pt；与设备类型定义 1398×2034 ÷ 3 自洽。原「像素÷3 折算推断，待核」升级为实测。 |
| 内屏逻辑点 | 669×951 pt | 一手定义 + 第三方实测**互证**，实机帧待补 | 设备类型定义 `displays[1]` = 2007×2853 @scale 3 → 669×951；另有第三方在 iOS 27.1 iPhone Duo 模拟器里读实为 "the inner display is 951x669pt"（PR #193025 正文）。两侧独立得出同一数字；本轮探针的外屏帧已验证这套「定义 ÷ 倍率 = 逻辑点」的换算在该设备上成立，内屏帧见 §8（需手动展开模拟器）。 |
| 折叠带宽度 | 40 pt | 第三方模拟器实测 | PR #193025 正文："a 40pt division that is inactive while flat and keeps its 40pt frame while inactive"。注意「inactive 时仍保留 40pt 框」与 Flutter 团队在同一议题下的意见一致（inactive region 应报非零尺寸）。本轮探针在**合上态**读到 `division` 为空数组（外屏无带，符合预期），带宽本身要等展开帧。 |
| 外屏系统侧边预留 | **右侧 84 pt** | **一手实测（本轮 Mac）** | 探针在合上态读 `safeAreaInsets = (t 0, l 0, b 34, r 84)`。R31 说的「非对称安全区」在外屏有确切数字：**右边 84pt**，且它恰好等于下面那条摄像头遮挡模块的宽度——即系统把「竖排 bar 的那条边」和「摄像头遮挡」放在同一条右边带上。`MediaQuery.paddingOf` 能否原样透出这 84pt 仍待 Flutter 侧帧验证（§8 第 2 项）。 |
| 外屏摄像头遮挡几何 | 37×37 @ (400, 29) 与 84×170 @ (382, 0)，**两块都 `isActive = true`**，margins 全 0 | **一手实测（本轮 Mac）** | 探针经 `UIView.reservedRegions(of: occlusion)` 读得，坐标系是根 view 的 466×678pt。R21「外屏摄像头常遮挡」在 iOS 27.1 模拟器上有了一手几何；原型旧的 96×28pt 示意角已删，遮挡层现在按这两块真数画（本轮量到框内 52.1×105.4px 与 22.9px 圆点，即 84×170pt 与 37×37pt ÷ 0.62）。 |
| 铰链读数 | `UIHinge.Status = closed`、`angle = 0.0`，`UIHingeInteraction` 的 handler **收到初始回调** | **一手实测（本轮 Mac）** | 证明这条路在 iOS 27.1 模拟器上真的可用（不是只有头文件）。`fold`/`posture` 的一手来源由此成立。 |
| 屏幕尺寸 | 外 5.4 寸 / 内 7.6 寸 | 社区提案正文 | flutter/flutter#192515 正文；与像素/倍率折算自洽，非一手官方。 |
| 尺寸级归属 | 外屏 compact width、内屏 regular width | 一手官方（R2）+ **外屏本轮实测** | 探针在合上态读 `traitCollection` = **H=compact / V=regular**，R2 的外屏半边坐实；内屏半边待展开帧（§8 第 3 项）。这是 §5.2 阈值迁移的根据。 |
| 上市 | 2026-10-23 出货，2026-09-09 发布 | 社区提案正文 | 用于判断资料新鲜度，非设计输入。 |
| 折叠带轴向 | 竖持（书立）→ 竖带；横持（笔记本/帐篷）→ 横带 | 由 R26 与几何推得；**新增一手旁证** | 铰链在物理中线，带垂直于铰链轴；官方未逐字给「竖屏时带是竖的」。**本轮新增**：设备类型定义里 `displays[1].nativeOrientation = 270 / nativeRotation = 270`，而外屏 `displays[0].nativeOrientation = 0`——内屏面板的**原生方向是横的**，这与「铰链沿长边、竖持时被竖带分左右」自洽，是该推断目前最硬的一条旁证；仍要展开帧确认。 |

> 换算口径：本设计中所有 pt 一律指 Flutter 的逻辑像素（`MediaQuery` 的单位），前提是 iOS 侧 `devicePixelRatio` 为 3.0。若 Mac 现读到别的倍率，§5.2 的档位边界要按逻辑点重新标定，而不是改倍率后继续用。

## 3. Flutter 侧能力边界：官方给的三样，我们能拿到几样

| 官方给的 | 我们能不能拿到 | 依据 |
|---|---|---|
| size class（compact/regular） | **间接能**：Flutter 没有 size class API，只能用逻辑宽推；而推出来的档位必须与 R2 的归属一致（外 compact / 内 regular） | 无 `horizontalSizeClass` 暴露；`host_policy.dart` 只有平台判断 |
| safe area / layout margins | **能**：`MediaQuery.paddingOf` 的每条边；第三方提案正文称「the asymmetric safe area (iOS moves its system controls to one side on this device) is correctly reported through `MediaQuery.paddingOf` per edge」 | flutter/flutter#192515 正文（**属第三方断言，§8 需在 Mac 现读**） |
| `ReservedRegion` / division / occlusion | **原生能，Flutter 层不能（今天）**：iOS 27.1 SDK 已公开 `UIView.reservedRegions(of:)` 与 `UIHinge`/`UIHingeInteraction`（见下「原生 API 面」），本轮已在 iPhone Duo 模拟器实读回调；缺的只是 Flutter 把这条路接到 `MediaQuery.displayFeatures` | `MediaQuery.displayFeatures` 在 iOS 上为空（PR #193025 未合入） |
| `ArrangementView` / `UIArrangementViewController` | **没有等价物**：Flutter 只有 `Row`/`Column`/`Stack`，split 与 overlay 语义要自己实现 | 仓库现状 |
| 系统自动的竖排 bar | **没有**：全部自绘（§4） | 仓库现状 |

**原生 API 面（本轮现读 Xcode 27.1 的 iOS 27.1 SDK 头文件，全部 `API_AVAILABLE(ios(27.1))`）**——这把 §0 第 3 条从「双重阻塞、只能等」重判成「原生今天可得，Flutter 语义层待接」：

| 头文件里的声明 | 语义 | 对本设计的作用 |
|---|---|---|
| `UIHinge.Status`：`unknown / closed / partiallyOpen / fullyOpen` | 铰链离散档位 | 直接就是 §5.1 `DuoPosture` 的另一半：`closed`→用外屏；`partiallyOpen`→带 active；`fullyOpen`→带 inactive。文档原来只能靠第三方 PR 的 `postureHalfOpened` 字面含义，现在有一手枚举 |
| `UIHinge.angle`（弧度） | 连续角度 | **不要用**。头文件 `UIHinge.h:66-67` 原文：「The rate and granularity of angle updates are system policy **and can change based on system state**, so don't depend on a particular update frequency or precision. If you only need to know whether the hinge is closed, partially open, or fully open, prefer `status` over **the angle**」→ 记为 R32 |
| `UIHingeInteraction(updateHandler:)` | **事件驱动**：handler 收到初始状态并在每次变化时再收；`update.hinge == nil` 表示该 view 离开提供 hinge 的层级 | §5.8 的 `poseChanged` 有了一手事件源，不必只靠 layout pass 轮询。`hinge == nil` 正是 §5.1 `fold == unknown` 的非 Duo 判据 |
| `UIView(ReservedRegion) reservedRegionsOfKind:` / `…options:` | 按 view 坐标系返回区域数组 | division/occlusion 的读取入口，且**是逐 view 查询**——意味着可以让页面级 `LayoutBuilder` 对应的原生 view 直接报，而不是全局一条带 |
| `UIViewReservedRegion.kind`：`occlusionRegionKind` / `divisionRegionKind` | 两类预留区，与 R20 的措辞逐字对应 | §5.4 的两行表各有一手类别 |
| `UIViewReservedRegion.frame` | 「in the view's coordinate space, **including the margins**」 | 让位计算直接用 `frame`，不需要自己再猜带宽——但要知道它已经比硬件本体宽（见下一行） |
| `UIViewReservedRegion.margins`（`UIEdgeInsets`） | 「the margins included in the frame around the reserved rect **for interactive content**」 | 本设计原来没有的概念：系统给的不是「一条不能画的带」，而是**硬件本体 + 一圈给可交互内容的避让边距**，且 `frame` 是外圈。所以「带多宽」有两个答案：可交互让位取 `frame`，图案可否压线取 `frame` 内缩 `margins`。记为 R33 |
| `UIViewReservedRegion.isActive` | 与 R22 逐字对应的条件性 | §5.1「fold 与 posture 必须分开」有了一手读数支撑 |
| `UIViewReservedRegionQueryOptionsIncludeInactive` | 查询时可含不活动区域 | §5.1 要求 `fold` 读 inactive region 的非零尺寸而不是「列表非空」——这个 option 就是它的实现手段 |
| `UIWindowSceneDelegate windowScene:didUpdateEffectiveGeometry:`（iOS 26+，注释原文「Always called when a `UIWindowScene` moves between screens」） | 换屏事件 | 外屏↔内屏切换有了一手通知，§5.8 不必自己比较宽度猜换屏 |
| `UIWindowSceneGeometry.interactivelyResizing`（iOS 26+） | 用户正在交互式改尺寸 | R24「别把控件位置绑在瞬时值上」有了一手判据：`interactivelyResizing == true` 期间冻结档位切换，记为 R34 |

同时本轮实测到一个**桥接层的坑**：`windowScene:didUpdateEffectiveGeometry:` 在 scene 创建时也会回调一次，且此时 `previousEffectiveGeometry` 为 nil；Swift 若按头文件的 nonnull 审计把它当非可选桥接，会在进函数体之前就 `EXC_BAD_ACCESS`（崩溃帧停在 `swift_getObjectType`）。§5.8 的通道实现必须把该参数声明为可选。

`UIScreen.main` 自 iOS 26 起弃用（提示改读 `view.window.windowScene.screen`）、`UIScreen.screens` 自 iOS 16 起弃用（提示改读 `UIApplication.shared.openSessions` 找其他屏的 scene）——§5.8 的原生侧不允许出现这两个符号。


折叠感知缺失的具体状态（2026-11-01 现读 GitHub API，存证 `duo192515.json` / `pr193025.json`）：

- flutter/flutter#192515 [iPhone Duo] Proposal: populate MediaQuery.displayFeatures on iOS —— **state=open**，`closed_at=null`，2026-09-09 创建，最后更新 2026-10-08，标签含 `platform-ios`/`engine`/`P2`/`triaged-ios`，6 条评论。
- 唯一实现它的 flutter/flutter#193025 "[iOS] Populate display features from the iPhone Duo hinge and reserved regions" —— **state=open、merged=false**，7 commits、+586/-0，最后更新 2026-10-25。
- 该 PR 的引擎侧代码在 `#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 270100` 下，正文自述「CI builds with Xcode 26.2, which does not declare these types」，旧 SDK 下 monitor 返回 nil。**结论：这是双重阻塞**——既要 PR 合入，又要 Flutter 官方 CI 升到 Xcode 27.1 才能产出真的会上报的引擎二进制。
- 同一议题里 Flutter 团队（hellohuanlin）的意见：`DisplayFeatureState` 不该被拿来表达 active/inactive（内屏摄像头也有 active/inactive，与折叠无关）；inactive region 应报非零尺寸。也就是说**语义还会变**，本设计不把任何逻辑钉在「state==postureHalfOpened」这一个读数的字面含义上。
- 已知时序缺陷（同一 PR 正文实测）：hinge 状态立即、region 的 `isActive` 滞后（放平后 2–15ms 才清，折起后约 1s 才置位），且 region 变化没有专门通知，靠 layout pass 重读。**因此 pose 状态机必须容忍「posture 说全开、division 还 active」的短暂矛盾**（§5.1）。
- 现成第三方过渡：pub.dev `foldable` 1.0.5（2026-09-26 发布），`flutter.plugin.platforms` 只声明 **ios**（`pluginClass: FoldablePlugin`），依赖 `plugin_platform_interface`，环境 `sdk ^3.5.0` / `flutter >=3.24.0`；自述给 hinge 角、折叠姿势与折叠/摄像头区域。作者与 PR #193025 同一人，且 PR 正文承认该包先跑通了同一条 API 路径。**引入与否是 §9 的待定项**：它是一个月龄、单一维护者的新包，而我们要的能力（读一条 40pt 带 + 让位）足够小，自写一个 3 方法的 `MethodChannel` 更符合本仓库把平台能力收在 `platform/background/` 的既有做法。

## 4. 现状盘点（全部为源码可核对事实）

### 4.1 宽度阈值：13 行按字面量比较的判据（本轮用 §8 的守门正则现读）

`packages/app/lib` 里与布局有关的 `720` 字面量。先把清晰度串排除：本轮现读它们是 `local_playlist.dart:49`、`settings_page.dart:944`、`player_page.dart:1411/:1412/:1871`、`download_selection.dart:206` 共**六处** `'720p'`（第一轮漏登记最后那处集合字面量）。剩下的用 §8 那条守门正则跑出现读结果：**13 行含字面量比较的判据、共 16 个字面量**（`720` 九次、`400` 四次、`850`/`1100`/`280` 各一次）。另有三处**正则抓不到但同样按整块容器（而不是所在栏）定尺寸**，只能靠人读：`download_selection.dart:25` 的 `width: 720`、`episode_workspace.dart:220` 的 `math.min(340.0, size.maxWidth * .8)`、`anchored_panel.dart:52/:110` 的 `right: 12` 与 `below < 200`（后者确实是比较式，只是左边不叫 `.width`/`.height`，正则同样漏）。两张表共 14 格但只有 13 行进得了正则，账这样对：表一 8 格出 9 行（`detail_page.dart` 那格横跨 `:339` 与 `:340`），表二 6 格里只有 `:740`、`:3130`（原 `:3102`，本轮漂移）、`:1748`（`player_page.dart`，本轮没动过这个文件）、`:40` 四格是行，`episode_workspace.dart:220` 与 `anchored_panel.dart` 两格正是上面那「三处」里的。9 + 4 = 13。前 8 行是第一轮登记过的：

| 位置 | 现在的判据 | 内屏全开竖屏（669pt）会得到什么 |
|---|---|---|
| `features/library_page.dart:3129`（`b720845` 上是 `:3101`） | `size.maxWidth < 720` → `compact` | 底部 `NavigationBar`（R2 说这里该是 regular） |
| `features/player_page.dart:1746` | `(size.width < 720 && size.height >= size.width) \|\| floating` → `compact` | 精简播放器 chrome |
| `features/player_page.dart:1816` | `!compact && size.width >= 720` → `desktopWide`（仅非移动端分支） | ——（移动端不取此支路） |
| `features/detail_page.dart:339-342` | `MediaQuery.sizeOf` 宽 `< 720 ? rows:3 / cellExtent:100 : rows:4 / cellExtent:120` | **列数不在这一行里**：`episode_pager.dart:255-259` 由 `floor((约束宽+10)/(cellExtent+10))` 推出。669 整屏（左右各 24 内边距，`detail_page.dart:332`）配 cellExtent 100 → **5 列**，奇数（R23 反对）；951 → **7 列**，同样奇数 |
| `features/local_cache_page.dart:102` | `width >= 720 && height >= 400` → 对话框，否则底部抽屉 | 底部抽屉 |
| `features/local_cache_page.dart:321` | `constraints.maxWidth < 720 ? 16.0 : 28.0` | 窄边距 |
| `downloads/download_selection.dart:20`（与 `:25` 的 `width: 720`） | `width >= 720 && height >= 400` → 对话框 | 底部抽屉 |
| `cast/cast_device_sheet.dart:19` | `width >= 720 && height >= 400` → 对话框 | 底部抽屉 |

**第三轮（11-02）基线漂移，先登记再读表**：本节与 §5 的行号是在 `b720845`（`v0.3.19`）上现读的，而仓库 HEAD 已经走到 `6e60b1f`。`git diff --stat b720845..HEAD -- packages/app/lib` 本轮现读：只有两个文件动过——`features/library_page.dart`（`d8547a3`，三个 hunk：`:719` +3、`:942` +11、`:978` 后插 17 行，净 +31）与 `platform/runtime_native.dart`（+1）。**所以除 `library_page.dart` 之外的所有引用仍然有效，本轮逐条不重读**（**这句当场就被推翻了一半，见下面「第四轮」那段**：HEAD 在同一工作日又前进两笔，`anchored_panel.dart` 也被改了）；`library_page.dart` 里 `:719` 之后的引用全部右移，本轮按下表逐条重钉（右移量随区段不同是 +28～+31，不是同一个数，所以只能逐条钉、不能加一个常数）：

| 本节/§5 里的旧锚 | 本轮在 `6e60b1f` 现读 | 锚点内容 |
|---|---|---|
| `:3101` / `:3102` | **`:3129` / `:3130`** | `this.compact = size.maxWidth < 720` / `final wide = size.maxWidth >= 1100`（守门正则本轮重跑，**仍是 13 行 / 16 个字面量**，只是这两行的行号变了） |
| `:3104-3122`（外壳 pager） | `:3132-3150` | `AutoTabsRouter.pageView`（`animatePageTransition: !desktopHost` 在 `:3139`） |
| `:3123-3142`（四条目的地） | `:3151-3172` | `const destinations = [`，四条 `NavigationDestination` 分别在 `:3152/:3157/:3162/:3167` |
| `:3153-3231`（三条支路） | `:3181-3260` | `bottomNavigationBar: compact` 起，到 `NavigationRail` / `VerticalDivider` |
| `:3161-3162`（`body: SafeArea(child: Row(`） | `:3189-3190` | §5.3 那条争边的现场 |
| `:3166-3167`（`SizedBox(width: 200)`） | `:3194-3195` | 桌面 200 侧栏 |
| `:3219-3231`（`NavigationRail`） | `:3247-3259` | `labelType: NavigationRailLabelType.selected`（`:3249`） |
| `:1402`（push 详情路由） | `:1430` | `DetailPage(runtime:…, initial:…)` |
| `:1748-1764`（`showAnchoredPanel` 唯一调用方） | `:1776-1792` | `filterPanelEntry = showAnchoredPanel(` |
| `:1839`（`filterChipFocus.requestFocus()`） | `:1867` | 键盘/焦点同类件 |
| `:2208`（`Icons.fiber_new_rounded`） | `:2236` | 「徽章是画出来的」那条证据 |
| `:2420-2426`（`_themeChips`） | `:2448-2450` | `limit = desktopHost ? _desktopRowMax : …` |
| `:2848-2854`（`_innerPages`） | `:2876-2883` | 类型级横滑 |
| `:2861-2872`（`_slotPage`） | `:2889-2900` | 题材级横滑 + `physics: _handoverPhysics` |
| `:2762/:2861/:2883`（`viewportWidth` 链） | `:2790/:2889/:2911` | 行宽一路当参数传下去 |
| `:3250`（`_onRowScroll` 挂载） | `:2805` | `onNotification: (n) => _onRowScroll(pane, n)` |
| `:47`、`:383`、`:391`、`:468`、`:491`、`:505`、`:532`、`:582` | **不变** | 都在 `:719` 之前，没吃到插入 |

本轮另在 `library_page.dart:2842` 现读到一条与 §5.10 同族、此前没登记的：非 compact 分支的题材搜索框宽 `(viewportWidth * .42).clamp(240.0, 440.0)` —— 它的**分母已经是栏宽**（合规），但那条 240 下限是**按整屏调出来的**：双栏时栏宽 315pt，`.42` 只有 132pt，被钳回 240 → 一根占掉**栏宽 76%** 的搜索框，行头剩下的空间放不下那组图标。归进 §5.10 的「喂宽」那一类，不改判据、只改钳位（下限要跟着栏宽走，而不是钉在 240）。

**上面那句「除 `library_page.dart` 之外仍然有效」在同一个工作日内被推翻了**，这是本轮最该记住的一笔：写它时 HEAD 是 `6e60b1f`，重读时已经走到 `3e3f82e`，中间多了两笔提交，其中 `fe33852 fix(discover): anchor the hover preview in the overlay's own space` 重写了 `widgets/anchored_panel.dart`（`git diff --stat 6e60b1f..HEAD -- packages/app/lib` 本轮现读：仅此一个文件，+90/−67）。于是本设计与 §5.12 那两格引用的行号全部右移，且**语义也变了**，不是简单换个数字：

| 本文旧引 | `3e3f82e` 现读 | 变的是什么 |
|---|---|---|
| `anchored_panel.dart:50` 的 `right: alignRight ? 12 : null` | `:52` | 位置没变的意思，仍是「贴 overlay 右边 12pt」 |
| `:53` 的 `maxWidth: width ?? 380` | `:55` | 面板那条 380 硬上限**依旧成立**：`showAnchoredPanel` 的调用方（`:1776`）不传 `width`；悬停那条走 `showAnchoredPeek` 的声明式默认 `double width = 300`（`:99`），调用方（`:1876`）同样不传 |
| `:101` 的 `size` 取 `MediaQuery.sizeOf(context)` | `:107` `final size = space.biggest;`（来自 `:105` 的 `LayoutBuilder`） | **这条是实质改动**：可用高/宽改读浮层自己的盒子，不再按窗口高度猜。R5 违例因此**减了一半**——不再读屏，但 overlay 本身跨整块屏，所以 Duo 双栏时它仍会跨过折叠带 |
| `:104` 的 `flip = below < 200 && above > below` | `:110` | 判据本身没改，只是分母换成了上面那个盒子 |
| 新出现：`overlayLocalAnchor(overlay, anchor)`（`:182-185`，两条支路各在 `:28`/`:102` 调一次） | —— | 锚点先换算进 overlay 坐标（提交说明给了 PC 帧的一手读数：旧代码报 −170.3/+108.0，新代码在 macOS 与 Windows 两种帧下都是 8.0）。**这条恰恰是 §5.1 要的「读所在容器而不是整块屏」的现成先例**，比 `detail_page.dart:339` 更接近我们要的形态 |
| `showAnchoredPeek` 的调用方 | `library_page.dart:1876`（`peekEntry = showAnchoredPeek(`） | 本文旧版只登记了 `showAnchoredPanel` 一个调用方，漏了这个悬停预览；两者在 Duo 上都会按 overlay 全域定位，必须一起进 §8 第 5 项 |

本轮回到源码逐行重读，**上一版写在这里的行号有 3 处已经漂了**（`3098` 实为 `3101`；`3150-3228` 实为 `3153-3231`；`:3158` 实为 `:3161`，已在 §4.2 改正）——注意那三个「实为」是 `b720845` 面上的读数，到 `6e60b1f` 又各自右移一次（`3101→3129`、`3153-3231→3181-3260`、`3161→3189`），以本节上面那张漂移表为准。**同一句话这轮又说了一遍**：两轮前那句「上一版有 3 处漂了」现在描述的是上一版的上一版，而这一轮它自己又成了那个「上一版」。下表是**第一轮没进这张表的判据**：`850` 与 `1100` 两条桌面档线（`1100` 第一轮只在 §4.2 出现过），加四条本轮新登记的、同样会在 669pt 上做出决定的判据——最后那条（`:40` 的高度线）是本轮为 §8 写守门正则时才现读出来的，说明**按数字找阈值一定会漏**：

| 位置 | 现在的判据 | 为什么属于本设计 |
|---|---|---|
| `features/settings_page.dart:740` | `size.maxWidth < 850` 直接返回内容（无侧栏锚点） | 669 与 466 都 <850 → 内屏全开也没有锚点列，双栏时设置页只剩一栏 |
| `features/library_page.dart:3130`（原 `:3102`） | `size.maxWidth >= 1100` → `wide`（`SizedBox(width: 200)` 侧栏，`:3194-3195`） | 桌面档的第二条线。§8 的守门 grep 若只挡 `720/850`，这条会漏过去继续裸着 |
| `features/player_page.dart:1748` | `platformPlayback.restoringPip && size.width < 280` | 浮窗恢复时的极窄档。**本轮按 §5.7 那张栏宽表重算，这条在 Duo 上够不着**：内屏横双栏 = (951 − 侧栏 68 − 带 40)/2 = **421.5pt**，最窄的书立竖带栏 = (669 − 40)/2 = **314.5pt**，两个数都在 280 之上（原型第 7 节按档现算，九档最小值即 314.5）。第一轮写的「可能落到 280 以下」是错的，已改（§5.2 同条） |
| `playback/episode_workspace.dart:220` | `math.min(340.0, size.maxWidth * .8)` | 选集面板宽度。半开时它按整屏宽算，会盖住折叠带（R23 的反例） |
| `widgets/anchored_panel.dart:52 / :107-110`（`6e60b1f` 上是 `:50 / :101-104`） | 锚 overlay 右 `12pt`；`flip = below < 200 && above > below`，`size` 取 `:107` 的 `space.biggest`（`:105` 的 `LayoutBuilder`） | 悬停预览面板按**整块 overlay**而不是所在栏定位，双栏/半开时会跨过折叠带。**本轮更新**：`fe33852` 已把 `size` 从 `MediaQuery.sizeOf` 换成浮层自己的盒子，所以「读屏」这半条已修；但 overlay 仍跨整块屏，R5 剩下的那一半（按所在栏）没修，200 这条翻转线在 669×951 与半开两半上仍无人校过 |
| `downloads/download_selection.dart:40` | `size.height * (size.height < 400 ? .95 : .78)` | 抽屉高度也按整块屏算。本轮为 §8 写守门正则时才现读到的**第 13 行**，第一轮完全没登记 |

三条独立的证据链说明这不是「差不多」的问题：`720` 与 `720 && 400` 的**同一规则被抄了三份**（`download_selection.dart:20`、`cast_device_sheet.dart:19`、`local_cache_page.dart:102`），改一处必然漏两处；`detail_page.dart:339` 用屏幕尺寸而不是所在约束宽度（违反 R5）——同一条链上的 `anchored_panel.dart` **本轮被 `fe33852` 改了一半**：`size` 已从 `MediaQuery.sizeOf` 换成浮层 `LayoutBuilder` 的盒子（`:107`），但那个 overlay 仍跨整块屏，所以 R5 在 Duo 上还没修完（§4.1 上面那张新表、§5.12 同条）；而 `integration_test/v032_detail_shots_test.dart:54-55` 与 `integration_test/ios_episode_swipe_test.dart:445` 又把 720 这条线**钉进了测试**，所以阈值迁移必须连测试一起改，否则改完是绿的、语义是旧的。

### 4.2 自绘的控制条，且没有任何竖排形态

`library_page.dart:3181-3260`（`b720845` 上是 `:3153-3231`）：compact → `bottomNavigationBar: NavigationBar`（`:3181-3187`）；720–1100 → `NavigationRail(labelType: selected)`（`:3247-3259`）；≥1100 → `SizedBox(width: 200)` 侧栏（`:3194-3195`）。三条支路都是**横向或左侧纵向的桌面形态**，没有一条是「贴着一条边、自上而下排开、装不下就从底部开始溢出」的 Duo 侧栏。外层是 `body: SafeArea(child: Row(...))`（`:3189-3190`），也就是说系统给的那条边 padding 会被当成「内容要避开」的空隙，而不是「控制条该长在里面」的位置（R31 要求的是后者）。

### 4.3 `ControlSurface` 四值 + 一条没人用的丢弃顺序

`playback/playback_transport.dart:8-31` 定义 `desktopWide / desktopNarrow / mobilePortrait / mobileLandscape`，`:22` 定义 `static const List<String> dropOrder = ['clock-seconds','episodes-pair','skip-pair','volume-slider','quality','picture-in-picture','cast']`，注释写明「行内放不下时的丢弃顺序，播放、选集、倍速、全屏永不丢弃」。**全仓库对 `dropOrder` 的 grep 只有这一处命中——它被声明了，从未被消费。** 而 R13 要的恰好就是这条（溢出顺序），所以 §5.3 是把它接上，而不是新写一套。

传输条自身（`:451` 的 `SafeArea`）是 `SafeArea(top: false, minimum: EdgeInsets.symmetric(horizontal: 6))`——上下留白、左右各 6pt，**没有为任何一条边留出控制条带**。R31 的不对称在这条 bar 上现在是缺失的。

### 4.4 折叠感知为零

`packages/**` 里 `DisplayFeature` / `displayFeatures` 的引用本轮在 Mac 上重 grep 为 **0 处**（含测试与 TV flavor）。SDK 侧：`.fvmrc` 钉 `3.47.4`，`.fvm/flutter_sdk` 是指向 `~/fvm/versions/3.47.4` 的软链（**只读，不要在里面跑 format**），该版本引擎 revision `06a2e2a110` 日期为 2026-09-03——**早于 §3 那条 PR 的最后更新（2026-10-25）**，所以「Dart 侧读不到带」在当前钉住的版本上是确定的，不是猜测。原生侧的对照结论见 §3 与 §5.8：同一天、同一台 Mac、同一个 iOS 27.1 模拟器里，`UIHinge` 与 `reservedRegions` 读得到，`MediaQuery.displayFeatures` 读不到。

### 4.5 iOS 宿主事实

- `packages/app/ios/Runner/Info.plist`：`UIApplicationSupportsMultipleScenes = false`；`UISupportedInterfaceOrientations`（iPhone 段）不含 `PortraitUpsideDown`，而 `~ipad` 段含；**没有** `UIRequiresFullScreen`（这一条对内屏多任务/分屏是必需的，现状为「未禁用」，符合方向）；`UIBackgroundModes = [audio]`；`IPHONEOS_DEPLOYMENT_TARGET = 15.0`。
- `Runner/SceneDelegate.swift` 是空的 `class SceneDelegate: FlutterSceneDelegate {}`——**天然的 trait / 预留区观测挂点**，不需要新造文件。
- `AppDelegate.swift` 在 `hongguo/platform-playback` 通道里注册 `HongguoPictureInPicture`，浮窗 frame 硬编码 `UIView(frame: CGRect(x: 8, y: 64, width: 120, height: 214))`（约 63 行）——一个和侧栏带、灵动岛都不相干的位置，列为 §9 风险项而不是本设计目标。

### 4.6 已被测试钉住的尺寸

`test/adaptive_ui_test.dart:61-77` 循环 `Size(390,844)`、`(800,900)`、`(1280,900)`，断言「宽度<720 才有 `NavigationBar`，720≤宽度<1100 才是 `NavigationRail`」；`test/download_ui_test.dart:13-17` 含 `Size(740,360)`（`height>=400` 那条门槛的受害者）；`test/horizontal_filters_test.dart:81-85` 含 `Size(600,340)`；另有约 25 处 `setSurfaceSize(Size(390,844))` 散在各套件。**这些测试是阈值迁移的回归网，也是它必须按 §5.2 分期的原因**：一期只让「已知是 Duo 的 pose」走新档位，未知 pose 保持今天的行为，现有 390/600/740/800/1280 的读数一字不动。

## 5. 设计

### 5.1 pose 模型与 `LayoutEnvironment`

唯一新增的抽象。形状照抄仓库里已经成立的 `packages/tv/lib/src/environment.dart:21-30`（`TvEnvironment extends InheritedWidget` + `of(context)` + 可注入用于测试），因为那套已经被 TV 证明「生产读真实环境、测试塞假环境」两条腿都能走。

```dart
enum DuoScreen { unknown, cover, inner }        // 哪块屏；unknown = 非 Duo 主机
enum DuoFold { unknown, none, present }         // 这台设备有没有折（R22：不能用「当前有没有带」来判型号）
enum DuoPosture { unknown, flat, halfOpen }     // 现在折没折

class DuoPose {
  final DuoScreen screen;
  final DuoFold fold;
  final DuoPosture posture;
  final Rect? division;        // 折叠带；fold==none 时恒为 null
  final List<Rect> occlusions; // 摄像头等遮挡
  final EdgeInsets band;        // 主机上报的系统侧边带（R31）

  bool get barsVertical;   // §5.3 分派表
  bool get regularWidth;   // §5.2 档位；来自尺寸级而不是像素比较
  bool get splitsAtFold;   // posture==halfOpen && division != null
}

class LayoutEnvironment extends InheritedWidget { /* of(context) 同 TvEnvironment */ }
```

三条设计约束直接来自官方：

- **`DuoFold` 与 `DuoPosture` 必须分开**（R22）。本轮实测把这条分开坐实了：合上态下铰链报 `closed`，而 `reservedRegions(of: .division)` 在整段 404 帧里始终是空数组（§2 铰链行、§8）——外屏根本没有带，所以「有折」与「现在带 active」是两件事。Flutter 层今天仍读不到这两路（`MediaQuery.displayFeatures` 在 iOS 上是空表），所以一期 `fold` 由 §5.8 的自写通道给出；将来上游落地，`fold` 应读 inactive region 的**非零 frame** 而不是「列表非空」（inactive 时框仍在、只是 `isActive=false`，PR 正文那句 40pt 说的正是这个）。这一条写进注释，因为它决定了 R23 的偶数列能不能稳定成立。
- **状态机要容忍矛盾读数**（§3 的滞后实测）：`posture==flat` 而 `division!=null` 时**继续按半开让位**，直到下一次 layout 读到带消失为止；反向（折起约 1s 延迟）则**宁可多让一会儿**。两种情况都不许把控件位置绑在瞬时值上（R24）。
- **`LayoutEnvironment` 是唯一出口**。页面只允许问 `pose.barsVertical` / `pose.regularWidth` / `pose.division`，不许再比较宽度数字，也不许读平台名定档位（R6：档位与 `mobileHost` 无关）。

非 Duo 主机上 `screen/fold/posture` 全为 `unknown`、`division` 为 `null`、`regularWidth` 由现读的 `MediaQuery` 宽度按 §5.2 的「未知支路」算，行为与今天逐字一致。

### 5.2 阈值口径迁移：把 §4.1 的 13 行判据改成两级口径

统一到一个文件 `packages/app/lib/layout/duo_breakpoints.dart`，并规定：**任何新的宽度判断只能读 `LayoutEnvironment`，不能读裸数字**（守法见本节末条与 §8 本机项——按比较式守，不按数字守）。

| 抽象 | 定义 | 一期取值 |
|---|---|---|
| `regularWidth` | 已知 Duo：读主机尺寸级；拿不到级时的过渡支路 = 内屏逻辑宽实测值下界 600pt（466 与 669 之间取中，写明为标定值不是常量魔法） | `screen==inner` → true；`screen==cover` → false；`unknown` → 今天的 `width >= 720` |
| `wideSidebar` | 桌面窗口的三档（rail 200 / sidebar）继续用现读的 720 / 1100 | 不变（Duo 不取这条支路） |
| `dialogHost` | 「居中对话框 vs 底部抽屉」的判据 | `regularWidth`（原 `width>=720 && height>=400`）；`cover` 屏永远 false；桌面沿用今天 |
| `gridColumns` | §5.7 | `regularWidth && fold!=none` → 强制偶数 |
| `pageMargin` | `local_cache_page.dart:321` 的 16/28 | 读 `regularWidth` |

要点：

- **一期不改动 `unknown` 支路的任何数字**。这是 §4.6 那批测试能保持原读数、以及 Android 折叠屏/桌面窗口回归为零的前提；等 §5.8 的桥能给 `screen` 之后，`regularWidth` 才会真的离开 720。
- `settings_page.dart:740` 的 `850` 一并归入 `wideSidebar`，不再单独留字面量。
- `detail_page.dart:339` 必须把 `MediaQuery.sizeOf(context).width` 换成所在 `LayoutBuilder`/sliver 约束（R5），否则双栏时它读的是整块内屏宽而不是自己那一栏。同一处判据还有两个同族违例：`anchored_panel.dart:101`（面板按整块屏定位并贴屏幕右 12pt）与 `episode_workspace.dart:220`（选集面板 `min(340, 屏宽×0.8)`）——它们与 §5.10 的手势裁决是同一件事的两面：**给组件喂进去的宽必须是「所在栏去掉带之后的宽」**。
- `player_page.dart:1748` 的 `size.width < 280`（浮窗恢复时的极窄档）**本轮改判为「Duo 上永不触发」**：内屏横双栏那一栏 (951 − 68 − 40)/2 = 421.5pt，最窄的书立竖带栏 (669 − 40)/2 = 314.5pt，原型第 7 节九档扫下来的最小值就是 314.5。第一轮写的「完全可能落到 280 以下」不成立，已更正。这条仍然纳入 env 的理由变了：不是它会响，而是**它一旦跟着 §5.2 改成读栏宽，读的是「分栏后再减掉条」的那个数**——今天书立档保留底部横排（§5.3 的档位表），若将来把它也换成侧栏，同一栏剩 314.5 − 68 = 246.5pt 就会真的掉到 280 以下。所以登记它、但不按它设计任何形态。
- 守门测试的形状因此要改：第一轮写的是「grep 掉 `720`/`850` 两个数字」，那既漏掉 `1100`（`library_page.dart:3130`，本轮从 `:3102` 漂移）与本轮补登记的 `400` 高度线与 `280`，又会在 `'720p'`、`Duration(milliseconds: 200)` 这类无关字面量上误报。改成**按比较式守**，三条正则（本轮已在 `packages/app/lib` 上实跑，命中恰为 §4.1 那 13 行、零误报）：`maxWidth\s*[<>]=?\s*[1-9][0-9]{2,}`、`\.width\s*[<>]=?\s*[1-9][0-9]{2,}`、`\.height\s*[<>]=?\s*[1-9][0-9]{2,}`（`[1-9][0-9]{2,}` 这一段是为了放过 `q.width > 0` 这类合法性检查——不加它，`player_page.dart:243` 会误报）。唯一豁免文件是 `layout/duo_breakpoints.dart`。**它抓不到非比较式**（`width: 720`、`min(340.0, …)`、`below < 200`），所以 §4.1 那三处只能靠人读，登记在表里。

### 5.3 竖排控制条（`SideControlBand`）

分派表（R7/R8/R9/R30）：

| 姿势 | 内容档 | 控制条 |
|---|---|---|
| 外屏（合上），任意方向 | compact | **侧栏**，自上而下：系统带（灵动岛/状态栏）→ 工具栏（返回/强动作）→ 标签栏（4 个目的地） |
| 内屏全开 · 竖屏 | regular | **横排**（R8 明文例外）：保持今天的底部 `NavigationBar` 与页内横排工具栏 |
| 内屏全开 · 横屏 | regular | **侧栏**（HIG：跨屏切换时控件保持同一竖直高度） |
| 内屏半开 · 竖持（书立） | regular，被竖带分两半 | 同「内屏竖屏」→ 横排；但双栏边界让位（§5.4） |
| 内屏半开 · 横持（笔记本/帐篷） | regular，被横带分两半 | 同「内屏横屏」→ 侧栏 |
| 未知主机 | —— | 今天的行为，一字不改 |

实现规则，逐条对应官方：

- **侧栏要「长进」系统那条边，不是排在它旁边**（R31 + R19 的 Calculator 先例）：外壳从 `body: SafeArea(child: Row(...))`（`library_page.dart:3189-3190`）改成 `Row[SafeArea(child: content), SideControlBand]`——**本轮把这条顺序改过来了**：合上态实测的是 `safeAreaInsets = (t 0, l 0, b 34, r 84)`，那条边在 **trailing（右）**，而第一版文档和原型都按桌面习惯把它画在左，同一个框里就成了「侧栏在左、遮挡在右」，与实测相反。规则不是「画在右边」，而是**跟着主机报出的那条边贴**（R30/R31：`insets.left` 与 `insets.right` 谁非零贴谁，两侧都非零时贴当前 `layoutDirection` 的 trailing）；原型已把这条做成断言（夹具的 `bandEdge` 检查 `:scope > .band` 的右边与屏框右边对齐，三档实测姿势 `gapRight` 全为 0）。侧栏自己吃掉主机给出的那条边 padding 加上条目宽；内容区仍读两侧 padding。放在 `SafeArea` 里面会把系统带变成空白，等于把官方要我们占住的那条边又还回去。**条目宽不再是一个拍的常量**：本轮 Mac 实测合上态 `safeAreaInsets.right = 84pt`，而系统把竖排 bar 与摄像头遮挡放在**同一条右边带**里（§2 那两行）——所以 84pt 是「系统自己给这条边留的宽」的一手读数。设计取 **68pt 条目宽 + 系统 padding**，并规定：若主机报出的那条边 padding 已经 ≥68，条目就**只吃 padding 不再额外加宽**（否则外屏 466 宽会被吃掉 152pt，内容只剩 314pt）。这条规则写进 §8 第 2 项的实测：Flutter 侧 `MediaQuery.paddingOf` 到底透不透出那 84pt，决定侧栏是 68 还是 84。
- **顺序契约**（R12）：`SideControlBand` 分三段——导航（返回/关闭）、强动作（`topBarPinnedTrailing` 的等价物）、其余；发现页把 4 个目的地放在最后一段，播放器把 播放/暂停 放在第一段。
- **溢出方向 bottom→top，且优先级先组后项**（R13/R15）：`SideControlBand` 接受一个 `List<BandItem>`，每项带 `group`、`priority`、`hasBadge`；装不下时按「组 → 组内」的顺序从**底部**开始收；带徽章的条目在同组内排到最后被收（对应 HIG 点名的 badge 例外）。
- **每个条目必须有图标也有标题**（R14）：竖排只画图标，横排优先图标，溢出菜单图标+标题。据此审一遍现有条目：`NavigationDestination` 四条（`library_page.dart:3151-3172`）本就 icon+label 齐备，可直接复用；传输条里 `dropOrder` 的 `volume-slider` 是纯自定义 view——按 R14 它进不了侧栏，所以侧栏形态下它降级成一个静音图标 + 长按调节，而不是硬塞。
- **不手摆间距，用分组**（R16）：清掉传输条里条目之间的硬编码间隔，改为组间由 band 统一给。
- **跨姿势相对位置稳定**（R29）：侧栏与底部条共用同一份 `List<BandItem>` 声明，只是排布方向不同。**不做**「切到侧栏时重排条目」的逻辑。
- **接上 `dropOrder`**（§4.3）：`playback_transport.dart:22` 那份名单成为侧栏与窄横条唯一的丢弃来源；一期先把它接到真实测量（按 `BandItem` 的固有宽度自底向上裁），并把「播放、选集、倍速、全屏永不丢弃」写成断言而不是注释。
- **不做覆盖开关**（R18）。
- **双栏时控件跟着它影响的走**（R17）：发现页列表栏的「刷新」「筛选」留在列表栏头部，不进侧栏；只有整页级动作进侧栏。
- 二期（不在一期）：内屏竖屏双栏时详情栏的竖排条（R10）。一期该处保持横排并记为已知偏差。

### 5.4 预留区让位

| 预留区 | 出现在 | 本设计怎么让 |
|---|---|---|
| 折叠带（division） | 内屏半开 | **把分栏边界主动吸附到带的边缘**（R23 的 Notes 先例）：双栏不再等宽，`leading = division.left`，`trailing = 屏宽 - division.right`，中带本身只画分隔底色，任何可点控件不落进去。 |
| 外屏摄像头（occlusion） | 外屏，常开（R21） | 侧栏第一段（导航/强动作）与遮挡带同侧，靠 `band` 顶开；内容区的页头标题与右上角徽章按 `occlusions` 下移。一期先把它当作「这条边的 padding 比别的大」处理，不新增原生读取——若 §8 现读发现 `MediaQuery.paddingOf` 不含它，再补桥。 |
| 内屏摄像头（occlusion，仅工作时） | 内屏，只在采集时 | **不适用**：本应用不采集影像（§5.9）。 |

约束：让位计算只能发生在页面级 `LayoutBuilder`，不许写进 sliver 内部（R27 的「不要把 arrangement view 放进滚动容器」）。`EpisodePager` 这类网格的父级负责给宽，网格只负责**在给定宽里推列数、并在有折时把奇数减成偶数**——后半句今天没人做（列数是 `episode_pager.dart:255-259` 那条 floor 的副产品，奇偶随宽度漂移，见 §5.7）。前半句在这轮有了一个必须写死的推论：**双栏一旦成立，「给定宽」就是那一栏的宽，不是屏宽**，所以主栏的列数会小于 §5.7 那张表里整屏的读数（本轮现取：书立 2 列 vs 整屏 4 列、内屏横 3 列 vs 6 列，见 §5.7 末尾的栏宽表）。

**带的轴向决定分栏的轴向。** 折叠带始终垂直于铰链，所以竖持时它是竖的（分左右）、横持时它是横的（分上下）；R25 说的「宽于高时横向分栏、高于宽时纵向分栏」在这种设备上不足以定出落点——951×669 的内屏横持按 R25 该横向分栏，可那条带恰恰横着切过两栏的中间。规则定为：**带 active 时，分栏沿带的法向分开**（竖带→左右、横带→上下），带的两侧各放一栏；不带 active 时回到 R25 的按长短边分。**滚动内容不承诺让位**：横带经过某一行是物理事实，能做的只有 §5.7 的偶数列（让中带落在列间空档而不是卡片上）与 §5.4 的页面级分栏吸附；这条局限同时是 R27 禁止把 arrangement 塞进滚动容器的理由。

`division == null` 但 `fold != none`（全开或读不到）时，**不做任何中缝预留**——此时内屏是一整块连续面板，等分双栏是正解；让位只在读到带的时候发生。这条与 R22 相配，也是 §5.1「fold 与 posture 必须分开」的用意。

### 5.5 两种 arrangement 到本应用页面的映射

| 官方原语 | 触发条件 | 我们对应的页面 | 一期落地 |
|---|---|---|---|
| split（R25）：宽于高时横向分栏，否则纵向 | 发现/分类双栏、详情页头+分集、我的页 | `library_page.dart` 外壳的 `Row`、`detail_page.dart` 主从 | 外壳与详情在 `regularWidth` 下走双栏；栏间边界按 §5.4 让位；`AutoTabsRouter` 的 PageView 只在**单栏**时保留横滑，双栏时横滑让给「换栏」而不是「翻页」，避免一个手势同时决定两件事 |
| overlay（R26）：全开时主视图叠在副视图上，半开时主视图落到折叠带**近侧**（下/后） | 播放页（画面叠在信息/控件上） | `player_page.dart` + `playback/compact_controls.dart` | 半开横持（笔记本）→ 画面占**下半**（观众那一侧），选集/推荐/控件占上半；竖持书立 → 画面占折叠带**右（近）半**，信息占左半。不新增页面，只把现有 `Stack` 的两个孩子按带的位置重排（R24：只移动必要的东西） |

### 5.6 逐界面设计

- **发现 / 分类 / 榜单 / 我的（外壳）**：外屏 = 侧栏 + 单栏内容（compact）；内屏竖 = 底部条 + 双栏（列表栏 + 详情栏，R2/R17）；内屏横 = 侧栏 + 双栏；半开竖 = 双栏边界吸到带（§5.4）。榜单页保持「一个榜一页」，侧栏里榜单目的徽章按 R15 晚于同组其他项收起。
- **详情页**：分集网格的列数是 `EpisodePager` 从约束宽推的（§5.7），本设计只改两件事——`rows`/`cellExtent` 不再读屏宽，以及有折时把推出来的奇数列减 1。按 §5.7 那张表现算：`regularWidth` 全开竖屏 4 列、横屏 6 列、半开竖带 4 列（中带落在列间空档）；外屏仍是 3 列——**外屏没有折叠带，奇数列在那儿不违规**，别把偶数规则错误地套到 cover 上。题材词入口（既有 §详情页 题材行）在双栏时属于列表栏控件，留在列表栏头部（R17）；它展开的那只悬停面板要按 §5.12 改（现在硬上限 380pt、从屏幕右边 12pt 起画，半开时横跨中缝）。
- **播放页**：见 §5.5 overlay 行 + R19（画面可满宽，只让开灵动岛与状态栏）。传输条在外屏与内屏横屏换成侧栏条目（§5.3），`mobilePortrait/mobileLandscape/desktopWide/desktopNarrow` 四值扩到「四值 × 是否侧栏」，但**由 `LayoutEnvironment` 提供而不是页面再算一次**（`player_page.dart:1811-1819` 是今天唯一的重算点：`:1811` 先算 `landscape = size.width >= size.height`，`:1812-1819` 按 `platformPlayback.mobile` 与 `size.width >= 720` 选四值，改成从 env 读）。全屏切换（`:1586-1587` 的 `SystemChrome.setEnabledSystemUIMode(immersiveSticky)`）在内屏半开时**不要**同时清掉系统带：折叠带位置由主机给，immersive 之后 padding 读数变化会让让位算错。
- **下载选择 / 清晰度 / 缓存面板 / 投屏设备列表**：`dialogHost` 由 `width>=720 && height>=400` 改为读 `regularWidth`（§5.2）；`download_selection.dart:25` 那个 `width: 720` 的对话框宽度改为「min(内容需要, 所在屏去掉折叠带后的可用宽)」，否则内屏半开时对话框会压到中缝上。外屏上的弹层头部按钮改为侧向（R11）。
- **设置页**：`850` 归入 `wideSidebar`；内屏双栏时设置成为一个栏 + 详情栏（锚点列在左栏，内容在右栏），外屏保持今天的单列（`controller.message` 那条渲染路径 `settings_page.dart:335` 不受影响）。
- **本地缓存页**：`:321` 的边距读 `pageMargin`；「长按/右键整体动作」面板（§PC 卡片右键）按 §5.2 的 `dialogHost` 决定对话框还是抽屉，折叠带上不居中。

### 5.7 网格偶数列

R23 的原文是「优先偶数列，好让内容干净地分开」，适用条件是**这台设备有折**，不是「屏幕宽」。

**先纠正第一轮的一句话**：本仓的分集网格从来没有「选 3 或 4 列」这件事。`EpisodePager` 只接 `rows`（可见行数）与 `cellExtent`（目标单元宽），列数是它自己在 `playback/episode_pager.dart:255-259` 里推的：

```
列数 = floor((constraints.maxWidth + spacing) / (cellExtent + spacing))   // spacing 默认 10（:41）
```

所以 R5 的违例**不在网格里**（它读的正是所在约束宽），而在调用方 `detail_page.dart:339-342`：那里按整块屏宽选 `rows` 与 `cellExtent`。而列数的奇偶从头到尾没人管，它只是那条 floor 的副产品。「列数由约束宽推」在本仓是既有做法不是新发明——TV 的网格同样如此，只是用了 `ceil`（`packages/tv/lib/src/grid.dart:156-160`）。

本轮把这条 floor 逐档现算了一遍。详情页今天（以及一期）是**整屏路由**（`library_page.dart:1430` push，原 `:1402`），所以约束宽 = 屏宽 − 侧栏 − `detail_page.dart:332` 的左右各 24；竖带时页面级分栏不作用于滚动内容（§5.4），仍按整屏宽算：

| 档 | 今天 | 设计后 |
|---|---|---|
| 外屏 466（compact；设计后侧栏 84） | `floor(428/110)` = 3 列 | `floor(344/110)` = **3 列**（这块屏没有折，R23 不管它） |
| 内屏竖 669（全开） | `floor(631/110)` = **5 列**（有折却是奇数） | `floor(631/130)` = 4 列 ✓ |
| 内屏横 951 | `floor(913/130)` = **7 列** | `floor(845/130)` = 6 列 ✓ |
| 半开·书立 669（竖带） | 同 669 → **5 列**，中带 314.5–354.5 正切在第 3 列的卡片上 | 4 列，中带落在第 2、3 列之间的空档 ✓ |
| 半开·笔记本 951（横带） | **7 列**；横带切在滚动的行上，这条 §5.4 已认 | 6 列 ✓ |
| 未知主机 390 | `floor(352/110)` = 3 列 | 逐字保持 3 列，不强转 |

于是落地是**两条**，不是一条：

1. `rows` 与 `cellExtent` 改读 `LayoutEnvironment`（`compact → 3 / 100`，`regular → 4 / 120`），页面不再算屏宽——这一条治 R5。
2. 有折（`fold != none`）时把**推出来的列数**减到偶数、下限 2，写在 `EpisodePager` 内部那条 `crossAxisCount` 上——因为奇偶只有在推完之后才知道，把它写在调用方等于猜。这一条治 R23。

`unknown` 主机（含 Android 折叠屏一期之前的状态）保持今天，不做偶数强转——避免把 iOS 专属标定当成通用律。TV 的网格（`packages/tv/lib/src/grid.dart:156-160`）不受影响。

**外壳一旦分栏，同一格公式喂的就是栏宽，不是屏宽**（本轮现取的读数，原型里已画出来）。上表算的是「整块屏只有一栏」，而 §5.4 的双栏把网格关进了左/上那一栏：

| 档 | 主栏宽×高（pt） | 栏内可用（减左右各 24） | 推出来 |
|---|---|---|---|
| 半开·书立（竖带左侧） | 315×882 | 267 | `floor(277/130)` = **2 列** |
| 内屏竖·全开（等分一半） | 335×882 | 287 | **2 列** |
| 内屏横·全开（等分一半，侧栏 68） | 442×669 | 394 | `floor(404/130)` = **3 列** |
| 半开·笔记本（横带上侧） | 883×315 | 835 | **6 列**（那一栏只有 315pt 高，列数按宽推、能摆下的行数是另一件事） |

所以实现时不许把上表那个 4 / 6 列抄进双栏的调用方——那是单栏时的读数。原型里详情页与双栏主栏两处共用同一个 `masterPane()` 式子（宽按带的轴向取，高再扣掉横排底部条 69pt），就是为了让这两个数不可能各说一套。

### 5.8 iOS 宿主与桥接

一期需要宿主做的事按最小化列。本节在第二轮按 §3 的一手 API 面重写过——**桥接层不再需要「等上游」，也不该再猜 API 名**：

- `SceneDelegate.swift`（现在是空的 `FlutterSceneDelegate` 子类）加一段，读四类一手来源并在变化时经 `hongguo/duo` 通道广播：
  1. **换屏 / 尺寸级**：`traitCollection.horizontalSizeClass`、`verticalSizeClass`（本轮实测合上态 = compact / regular）；换屏事件用 `windowScene(_:didUpdateEffectiveGeometry:)`（iOS 26+，头文件注释原文「Always called when a `UIWindowScene` moves between screens」），**不要**再用已弃用的 `windowScene(_:didUpdateCoordinateSpace:interfaceOrientation:traitCollection:)`。
  2. **姿势**：`UIHingeInteraction(updateHandler:)` 挂在根 view 上，读 `update.hinge?.status`（`closed` / `partiallyOpen` / `fullyOpen` / `unknown`）；`hinge == nil` 即「该层级不提供铰链」= §5.1 的 `fold == unknown` 一手判据。**`angle` 一期不读**（R32：系统明说更新频率与精度是 system policy，只要三档就别用连续角）。
  3. **预留区**：`view.__reservedRegions(of: .division(), options: .includeInactive)` 与 `.occlusion(...)`，把 `frame`、`margins`、`isActive`、`kind` 原样过通道；`fold` 读 inactive 项的**非零 frame**、`posture` 读 `isActive`，正是 §5.1「fold 与 posture 必须分开」的实现手段。
  4. **侧边带**：`safeAreaInsets` 每条边（本轮实测合上态 `r = 84pt`），这就是 §5.1 `band` 字段与 §5.3「侧栏长进系统那条边」的一手宽度来源，不需要自己定常量。
- **桥接层三个已实测的坑**（都要写进实现，不是注释）：① `windowScene(_:didUpdateEffectiveGeometry:)` 在 scene 创建时也会回调且 `previousEffectiveGeometry` 为 nil——Swift 按头文件的 nonnull 桥接会在进函数体前 `EXC_BAD_ACCESS`（崩溃帧 `swift_getObjectType`），参数必须声明为可选；② `UIScreen.main` 自 iOS 26 弃用、`UIScreen.screens` 自 iOS 16 弃用（提示改读 `view.window.windowScene.screen` 与 `UIApplication.shared.openSessions`），原生侧禁止出现这两个符号；③ 区域是**逐 view** 查询的（`UIView` 分类），所以每个页面级容器要自己取，不能假设有一条全局带。
- `Info.plist`：`UISupportedInterfaceOrientations` 的 iPhone 段不含 `PortraitUpsideDown`——对折叠机型来说这少了一个合法姿势（外屏倒持）。列为**待核**而不是直接改：R6 明确禁止用方向做布局决策，所以补上方向不该改变任何布局结果；改与不改都要在 Mac 上实测「倒持外屏」时 Dart 侧读到的 band 边是否跟着翻。`UIApplicationSupportsMultipleScenes = false` 一期不动（内屏 Split View 多任务是 §5.9 的不做项）。
- 通道形状：`getPose() -> {screen, sizeClass, bandEdge, division{frame,margins,active}, occlusions[]}` + `EventChannel poseChanged`。**语义全部定义在 §5.1，通道只是它的一个 provider**；PR #193025 落地后把 provider 换成 `MediaQuery.displayFeatures`、`LayoutEnvironment` 与所有页面代码不动——这是本设计刻意留的唯一接缝。第二轮的重判让这条接缝从「等上游才能验证」变成「上游到了只是换个 provider，不到也能先自写」，因为它两端的一手 API 名已经落在 §3 的表里。
- 构建前提：iOS 27.1 SDK / Xcode 27.x。R28 说明用 Xcode 26 及更早构建时内容不会伸到状态栏与摄像头下，safe area 读数就不是最终值；§3 的 API 又全部标 `API_AVAILABLE(ios(27.1))`——**SDK 与运行时两头都要 27.1，缺一头就读不到**。本轮已确认本机为 Xcode 27.1（build 27A9275）+ iOS 27.1 模拟器运行时（build 24A94232）。

### 5.9 明确不适用的官方条目

- 「改善影像采集处理」「为 iPhone Duo 注册采集配件」（PREP 的 AVKit/AVFoundation 两节）：本应用只播放，不采集，内屏摄像头因此永不激活（R21）。
- Live Activities 扩到灵动岛：仓库无 Live Activity。
- 内屏 Split View 多任务（R30）：需要 `UIApplicationSupportsMultipleScenes`，一期不开。§5.3 只把「侧栏贴哪一边」做成读主机 band 而不是写死常量，为的是将来不必重设计。
- 游戏满屏/信箱留边（HIG 游戏段）：不适用。
- Liquid Glass 采纳、iPhone Mirroring（TN3210）：另案。

### 5.10 手势与折叠带的关系（本轮补：此前只裁决了「东西放哪」）

§5.3–§5.7 全在管静态位置，而这个应用的核心交互是**横向手势**，一条竖着的折叠带正好横在它们的路径上。逐条裁决（行号本轮现读）：

| 手势 | 现在的实现 | 与折叠带的关系 | 裁决 |
|---|---|---|---|
| 外壳换目的地（4 tab） | `AutoTabsRouter.pageView` `library_page.dart:3132-3150`（`animatePageTransition: !desktopHost` 在 `:3139`） | 整屏宽 pager，双栏时跨住中缝 | 双栏时 pager 的 viewport 必须等于**所在栏**的约束宽；带 active 时把 `division.frame`（R33：它已含 margins）加进交换死区 |
| 类型级横滑（一级三页） | `_innerPages` `:2876-2883` | 同上 | 同上 |
| 题材级横滑（二级） | `_slotPage` `:2889-2900`，`physics: _handoverPhysics`（声明在 `:391`，用法在 `:2894`） | 接力链的下一层：外层不吃了才轮到它 | 接力阈值 `_edgePullExtent = 48.0`（`:383`，三处门 `:491/:532/:582`）**按栏算不按屏算**；48 与 40 谁大都不构成为让位，让位只由 `division.frame` 决定 |
| 行内横滑（题材 chip 行） | `_onNestedScroll` `:468`、`_onRowScroll` `:505`（挂载 `:2805`，原 `:3250`）、`viewportWidth` 一路传进 `:2790/:2889/:2911` | 行的可用宽**已经是参数**而不是屏宽 | 这条已经栏相对：只要把传进去的 `viewportWidth` 从「屏宽」换成「去掉带之后的栏宽」，整条链自动对。这正是让位必须发生在页面级 `LayoutBuilder` 的理由（R27） |
| 选集页横滑 | `episode_pager.dart:282` `PageView.builder`，`dragDevices` 含 touch/stylus/mouse/trackpad `:275-279` | 半开时面板跨带 → 一次拖「跨中带翻页」 | 面板宽今天按 `math.min(340.0, size.maxWidth * .8)`（`episode_workspace.dart:220`）改为按**所在半屏**可用宽；带落在面板内时面板整体吸到带近侧 |
| 进度条横拖 seek | `player_progress_bar.dart:61-62` `_fractionAt(x, width)`，`width` 取自身 `box.maxWidth`（`:98`），拖拽 `:131-158` | **已合规**（读自身约束） | 判据不动。唯一要求：横带（笔记本姿）下传输条随主视图一起落到带近侧（§5.5），于是它永不跨带——**进度 0.5 不等于屏幕中线** |
| 双击分区快进/快退 | `compact_controls.dart:258-262` 记 `_doubleFraction = dx / context.size.width`（分母在 `:259`），`:153-164` 按 0.35 / 0.65 分派 | 分母是**画面自身宽**，不是屏宽 → 已合规 | 判据不动；但竖带（书立姿）下 0.35/0.65 之间那条「中间＝播放/暂停」带会与折叠带重合，落在 `margins` 内的双击按中间区处理，而不是按左右区 |

这一节的结论可以压成一句，而且它是本轮最有操作价值的一句：**凡是分母取自身约束的手势（进度条、双击、`viewportWidth` 链）都不需要改判据，只需要保证传进去的那个宽是「去掉带之后的宽」；真正要改的只有三处按整块容器算的——`detail_page.dart:339`（屏宽）、`episode_workspace.dart:220`（屏宽）、`anchored_panel.dart:107`（**本轮更新**：`fe33852` 之后它已经不再读 `MediaQuery.sizeOf`，改读浮层 `LayoutBuilder` 的盒子，所以「按屏」这半条没了；但那条 overlay 在 Duo 上仍跨整块屏，所以「按整块容器」这半条留着）。** 也就是说折叠适配的手势成本几乎全部落在「谁给这些组件喂宽度」，而不是「组件内部的手势逻辑」。

**本轮把这张表做成了可复算的图**（原型第 5 节「手势的路径上有没有那条带」）：每档姿势并排画今天与设计后喂进去的宽，并把 0.35 / 0.65 两条分区线、中缝播放键、pager 的 viewport 投到那一栏坐标上逐条判跨不跨带。本轮现取的读数：外屏合上态 leading 0 / **trailing 84**（实测那条边），内容宽 466 → **382**；书立档每栏 315pt，**今天**按整屏 669 算出的 ep 分区线、中缝与 pager **三条都横跨中带**，**设计后三条都不跨**；笔记本档横带不吃宽（paneW 883 = 内容宽，只吃高）；内屏横档设计后等分 442pt；未知主机三档两栏逐字相同、画面铺满整屏（§5.2 等价律的图解）。**这些是算术，不是设备上的手势响应**——滑动接力与双击在真机上按不按这里的判定生效，仍要等一次真展开帧（§8 Mac 项）。

### 5.11 可达性与文字缩放：侧栏是这两个盲区的第一个固定尺寸件

- **语义**：全 `packages/app/lib` 只有 8 处 `Semantics` 相关调用，各 1 处，分布在 `playback/player_progress_bar.dart`、`playback/episode_pager.dart`、`playback/player_center_overlay.dart`、`playback/compact_controls.dart`、`downloads/download_selection.dart`、`features/player_page.dart`、`cast/cast_floating_window.dart`、`features/tv/tv_library_page.dart`；**`features/library_page.dart` 为 0 处**（本轮现读）。今天底部条是 Material `NavigationBar`，语义白送；换成自绘 `SideControlBand` 之后，VoiceOver 在**最需要它的外屏**上会读到一片空。→ 一期交付里 `BandItem` 必须落 `Semantics(button: true, selected: …, label: 标题, hint: 组名)`，并把「四条目的地在侧栏形态下仍可被语义遍历」写成 `side_band_test.dart` 的断言。
- **R15 的「带徽章晚收」今天没有数据源**：全仓库没有一处 Material `Badge` / `Badge.count`（本轮现读为空），所谓徽章是画出来的文字胶囊（`widgets/drama_card.dart:52-66`、`ranking/rank_card.dart:153-179`）和一枚 `Icons.fiber_new_rounded`（`features/library_page.dart:2236`，原 `:2208`）。→ `BandItem.hasBadge` 只能是**声明出来的布尔**，由页面构造条目时显式传入，不能指望从子树探测。
- **文字缩放是零处理**：`textScaler` / `textScaleFactor` / `BoldText` 在 `packages/**` 里 **0 命中**（本轮现读）。今天没有固定尺寸的交互件，这笔欠账不疼；§5.3 的 68pt 条目宽是**第一个**。→ 规则：条目宽随缩放增长时**换形态不换字号**（超过约 1.3× 时标题从隐藏转为图标下方两行），触控目标在任意缩放下不小于 44×44pt。
  **本轮把「再涨就整条退回横排」这条判掉了**：原型第 6 节的滑块 1.00–1.70 × 四档姿势扫过一遍（夹具 `scaleSweep`），缩放吃的是**条目高**——48pt → 48 + 2×15×1.7 ≈ **99pt**，而条目宽只从 68pt 涨到 **71pt**，离「吃掉外屏 466pt 的 40%（= 186pt）」还差 115pt，所以宽度型回退在 Duo 上**不可达**。真正发生的是一样的高度型后果：外屏那条边共 678pt，chrome（系统带 30 + 6 条组标题 72 + 溢出标记 42）先吃掉 144pt，条目可用 534pt；1.00× 时核心四项占 192pt、**九条全摆得下、溢出 0 条**，1.35× 核心涨到 354pt、只剩 180pt，**摆得下的掉到 5 条、溢出 4 条**，1.70× 核心 396pt 仍是 5 条 / 溢出 4 条。同一条边在内屏竖屏（951pt）1.70× 还能留 7 条——**同一个缩放在两档姿势上给出的可见条目数差两条**，这就是 §5.11 必须让 `SideControlBand` 自己按约束高算、而不是写死「显示前 N 条」的原因。→ 缩放的退路是 §5.12 那只溢出菜单变长（R13/R16），不是形态换回横排；「什么时候宁可退回横排」仍然是**设计判断**，要等 §8 第 9 项的大字号实拍才有输入。这条进 §8 的 Mac 验收（开系统大字号实拍）。
- **可借的现成设施**：`packages/tv/lib/src/environment.dart:21-25` 的 `InheritedWidget + of(context) ?? fallback` 形状（§5.1 已声明照它）；键盘/焦点在主工程里也有同类件（`playback/compact_controls.dart:65-76` 的 `HardwareKeyboard` handler、`features/library_page.dart:1867` 的 `filterChipFocus.requestFocus()`）。一期不把焦点遍历扩到 Duo，但**别把它写成只有桌面族能走**。

### 5.12 溢出之后东西去哪儿：一期用现成的三面，不新造

R13 只规定丢弃顺序，不规定被收起的条目落在哪一面。仓库里已有三面：

| 面 | 位置 | 锚点 | 适不适合侧栏 |
|---|---|---|---|
| `PopupMenuButton` | `playback/playback_transport.dart:212/:243/:284`、`ranking/board_tabs.dart:137-143` | 触发条目自身 | **适合**：条目就在侧栏里，位置天然正确；已带图标+标题，满足 R14「溢出菜单用得上标题」 |
| `showAnchoredPanel` / `showAnchoredPeek` | `widgets/anchored_panel.dart:14`（`right: alignRight ? 12 : null` `:52`；`maxWidth: width ?? 380` `:55`；`flip = below < 200 && above > below` `:110`，`size` 取 `:107` 的 `space.biggest`，来自 `:105` 的 `LayoutBuilder`；两者都先过 `overlayLocalAnchor` `:182-185`） | **整块 overlay** 右 12pt | 要改才能用：它读的是浮层全域（Duo 上仍跨整块屏，违反 R5 的后半），双栏/半开时会把面板甩到另一栏上。**本轮更新（`fe33852`）**：锚点已换算进 overlay 坐标、可用高宽已改读浮层盒子，PC 帧那半边修好了；**按所在栏定位这一半仍未修**；两条支路的宽度上限不一样，别混：面板走 `maxWidth: width ?? 380`（`:55`），悬停走声明式默认 `double width = 300`（`:99`）再被 `maxLeft = size.width - width - 12`（`:111`）钳住，**两个调用方 `library_page.dart:1776-1792`（题材词筛选面板）与 `:1876`（悬停预览）都不传 `width`**，于是半开 669 竖带时面板从右 12pt 起画会占住 x≈277–657，**正横跨 314.5–354.5 那条带**（悬停那一只是 300 宽，同样落在带右侧那条栏外）；`below < 200` 这条翻转线在同一姿势下也没人校过 |
| `showModalBottomSheet` | `widgets/sort_menu.dart:183` | 底部 | 外屏上正是 R11「条在侧边」的场景，用它就得连头部一起改，超出 P1 范围 |

裁决：**复用 `PopupMenuButton` 作为溢出落面**，一期不新造面板；`showAnchoredPanel` / `showAnchoredPeek` 的 overlay 全域锚点与那两条宽度上限（380 / 300）登记为独立缺陷（它同时就是 §4.1 那条 R5 违例的后半——`fe33852` 已把「读窗口高度」改成「读浮层盒子」，但浮层在 Duo 上仍跨整块屏），不在本设计里顺手改，但 §5.6 详情页那一行要指向它，免得半开时有人以为筛选面板已经让位了。溢出条目进菜单后**保持同一顺序**，这样被收起的条目在屏幕上的相对次序不变（R29）。

**本轮原型第 4/6 节把这只落面画出来了**（上一版只算了「谁被收」没说「收到哪」）：三条带宿主（外壳侧栏、溢出滑杆实验台、播放页那条）共用同一个 `···` 标记与同一份 `computeDrop()`，点它展开的就是那只 `PopupMenuButton` 形状的面板，里面同时装着**被收掉的条目**与**按 R14 根本不进竖排的条目**（纯文字、自定义 view），且顺序与声明序一致。夹具本轮现取：九档姿势各一只菜单宿主（`pmenu 9`），每只 5 项，没有一项甩出宿主边界（`menuPastHost` 0）。**上一版在这里写的「面板 552px 宽」已删**：`.pmenu` 在实验台里是 `position:static` 的块，宽度跟着那一栏的可用宽（也就是浏览器窗口）走——本轮同一段代码在 560px 视口下量到 487px，上一轮在更宽的窗口下量到 552px，**这个数根本不是设计量，写进文档只会变成下一轮的假漂移**。夹具因此把 `window.innerWidth` 一起打进读数（`menuHosts[].vw`），今后这条宽度只能连着视口宽一起读。仍然没演示的是它在 iOS 上的**真实弹出位置与动画**——那是 P1 的实现验收，不是原型能给的证据。

另一条值得照抄的先例：`ranking/board_tabs.dart:7-11` 的注释已经写明「两族输入用两条不同的溢出规则」，并把它做成声明式参数 `overflowAfter`（`:24/:40`）；`features/library_page.dart:2448-2450` 的 `_themeChips` 则用 `_desktopRowMax = 8`（`:47`）+ `desktopHost` 决定截断。§5.3 的 `BandItem` 沿用同一个形状（一个可选 `overflowAfter`），但**键换成实测高度而不是宿主族**——按 `desktopHost` 判在 Duo 上会给出反向答案：外屏属移动端族，却恰恰是最需要截断的那一面。

### 5.13 挂点与测试挂载：`LayoutEnvironment` 放在哪一层

- **生产挂点**：`navigation/app_navigation.dart:209` 的 `MaterialApp.router`，其 `builder:` 在 `:221`，链上依次是 `CallbackShortcuts`（`:223`）→ `MacWindowFrame`（`:235`）→ `CastFloatingLayer`（`:243`）。`LayoutEnvironment` 插在 **`:221` 那个 builder 的最外层**——在 `MaterialApp.router` 之内才拿得到 `MediaQuery`，在 `CallbackShortcuts` 之外免得被桌面键盘层挡住重建。
- **与 `TvEnvironment` 的关系**：`main.dart:79` 已经在 `builder:` 里挂了 `TvEnvironment`。**两者不合并**：一个说「这是哪种 flavor」，一个说「这台设备现在是什么姿势」；合并会让 TV 构建产物多背一条 iOS 通道。§5.1 借的是它的**形状**，不是它的位置。
- **测试挂载有两种模式且没有公共辅助**（本轮现读：`test/adaptive_ui_test.dart:45` 的 `mount` 只是那个文件里的局部函数，`desktop_fakes.dart`、`catalog_sort_test.dart`、`my_page_test.dart`、`player_controls_test.dart` 各自再拼一遍）。→ 新增 `packages/app/test/support/pose_mount.dart`，导出 `withPose({required DuoPose pose, required Size size, Widget child})` 与 `mountWithPose(tester, pose, size)`；§8 的四个新套件全部挂在它上面。**一期不动既有测试的挂载方式**——它们走 `unknown` 支路，正是 §5.2「未知主机逐字不变」的回归网。

### 5.14 连带面：这套改动会碰到谁

- **TV flavor**：`packages/tv` 直接复用主工程页面，主工程里有一串按 flavor 分叉的字面量（`features/settings_page.dart:444/:572/:727/:731/:746/:807`，其中 `:746` 是 `width: tv ? 300 : 170`；`features/local_cache_page.dart`、`features/my_page.dart`、`features/downloads_page.dart`、`downloads/download_selection.dart` 同样被 TV 引用）。`LayoutEnvironment` 在 TV 上恒为 `unknown`，所以 §5.2 的未知支路等价律是 TV 不回归的**唯一**保证——把它写成 `layout_environment_test.dart` 的一个用例（TV flavor 挂载 + 1920×1080 → 档位与今天逐字相同）。
- **Android 折叠机**：`packages/app/android/app/src/main/AndroidManifest.xml:23` 的 `configChanges` 已含 `screenSize|smallestScreenSize|screenLayout|fontScale`，即折叠时 Activity 不重建、只重排。本设计**不给 Android 折叠机任何新行为**（`fold == unknown`），它们继续按 720。这不是遗漏，是 §5.7「别把 iOS 专属标定当通用律」的同一件事。
- **一份未实现的旧设计**：`docs/design/android-tv-adaptation.md:119` 推荐的 `os / formFactor / input` 三轴 profile，在 `packages/**` 里 grep `DisplayProfile|formFactor` **0 命中**（本轮现读）——那套抽象从未落地。本设计的 `LayoutEnvironment` 因此是仓库里**第一个真实存在的环境注入层**：它一旦成形，那份旧设计里「接入 DisplayProfile」的待办就有了挂靠点；反过来说，它的形状必须一次定对，**别写成 iOS 专用**。

## 6. 原型

[prototypes/iphone-duo.html](prototypes/iphone-duo.html) 是单文件、无网络依赖、双击即开的交互原型，沿用本仓库原型house style（顶部 `.meta` 分段控制 + `#readout` 读出窗 + `#legend` + `#kbd` + `.stage` 设备框）。本轮把它从「演示四件事」扩成**八节**，每节都把自己那部分的算术直接印在页面上——也就是说**读得出数的地方都是式子跑出来的，不是画师摆的**。键盘 `1–9` 选姿势、`r` 循环两套判据、`a/i` 强制带的两个矛盾读数。

1. **发现页外壳：同一块内屏竖屏，两套判据并排**（§5.1/§5.2）。左「现状（裸 720）」给出底部标签条 + 单栏 + 推出 5 列（奇，中带切卡）+ 底部抽屉；右「设计后（尺寸级）」给出双栏 + 居中对话框，读出窗里那一格「设计后 columns=4」是**整块屏只有一栏时**的推导，而画面上双栏的主栏按栏宽另推 2 列（§5.7 末尾那张栏宽表）——两个数并排写、不互相覆盖。这一格仍是 §0 第 2 条的可视化证据。
2. **分集网格与弹层**（§5.7/§5.12）：偶数列那条 floor 按「整屏喂屏宽、双栏喂栏宽」走同一条式子；弹层那一格演示「尺寸级 → 居中对话框」对「裸 720 → 底部抽屉」。
3. **播放页 overlay arrangement**（§5.5/R26/R19）：横带（笔记本姿）下画面推到近侧半屏、传输条随主视图一起落近侧，因此那条进度条**永不跨带**——这一格同时是 §5.10「进度 0.5 不等于屏幕中线」的图解。
4. **侧栏装不下的时候**（§5.3/R12/R13/R14/R15）：条目按「整组 → 组内、自底向上」丢弃，带徽章项晚收，纯文字/纯自定义 view 条目按 R14 **根本不进竖排**（直接落溢出菜单），`dropOrder` 名单来自 `playback_transport.dart:22`；侧栏可用高度是可调滑杆（90–620pt）。**本轮补的是 chrome 预算**：系统带 30 + 6 条组标题 72 + 溢出标记 42 = 144pt 同时进预算和进画法，于是「算出来摆得下几条」和「框里画了几格」永远是同一个数（夹具 `bandLie` 专门抓这两个数不一致，本轮读数 0）。
5. **手势的路径上有没有那条带**（§5.10；本轮新增）。每档姿势并排画「今天喂进去的宽」与「设计后喂进去的宽」，并把进度条 0.35/0.65 分区线、双击中间区、pager 的 viewport 三条线**投影到那一栏的坐标**上，逐条判它落不落在带上。本轮现读的几条：外屏合上态 leading 0 / trailing 84（实测那条边），内容宽 466 → **382**；书立档双栏每栏 315pt，**今天**按整屏 669 算出的分区线与 pager 全部横跨中带，**设计后**三条都不跨；笔记本档横带不吃宽（paneW 883 = 内容宽），横带只吃高；内屏横档设计后等分 442pt。未知主机三档两栏逐字相同，且画面铺满整屏——这就是 §5.2 那条等价律的图解。
6. **侧栏在系统大字号与 VoiceOver 下**（§5.11；本轮新增）。缩放滑块 1.00–1.70 演「换形态不换字号」：1.3× 以上标题从隐藏转为图标下方两行，条目高 48 → 99pt 同时进预算；旁边列出 `BandItem` 必须自带的 `Semantics(button/selected/label/hint)` 逐条清单与本轮现读的语义欠账。**本轮在这里判掉了 §5.11 原来那句「再涨就整条退回横排」**——见 §5.11 那条更正。
7. **五条字面量线在 Duo 上谁会被触发**（§4.1/§5.2；本轮新增）。`720 <`、`720 >=`、`400 >=`、`850 <`、`1100 >=`、`280 <` 逐条打出「本档今天读到多少 pt → 会不会过」与「设计后换成什么」，并按当前档现算最窄栏。本轮在这里的收获：**`280` 这条线在 Duo 九档上永不触发**（最小值 314.5pt，见 §4.1 与 §5.2 的更正）；`400` 那条**整删**，因为今天它读整块屏高恒过，而一旦有人「顺手改成读栏高」，笔记本姿那一半只有 (669 − 40)/2 = 314.5pt 高，就会把对话框打回抽屉。
8. **仍然没有演示的七件事**逐条写在原型第 8 节：内屏摄像头遮挡（本应用不采集）、内屏 Split View（`UIApplicationSupportsMultipleScenes=false`）、详情栏竖排条（R10，§7 P3）、**内屏与半开帧**（本轮 404 条采样全是合上态）、焦点遍历（一期不动，没画焦点环）、**手势的真实命中**（第 5 节演的是算术，滑动接力与双击在设备上是否按这里的判定生效要等真展开帧）、**VoiceOver 实读**（第 6 节给的是字段清单与缩放形态，朗读文本要设备开辅助功能实拍）。这七条明确写「没演示」，避免读成「已经覆盖全部官方条目」或「设备上都验过了」。

带让位（§5.4 + §5.5）不是单独一节，而是第 1–3 节共用的一张图：半开姿势画一条 40pt 的中带，双栏边界吸附到带边（带的轴向决定分栏轴向：竖带分左右、横带分上下），overlay 姿势把画面推到近侧半屏；读出不活动（全开）时带为 `null`、栏宽回到等分——把 R22 的 active/inactive 差别演成可切换状态（键盘 `a`/`i`/`u`）。「折叠带读数」那一组还能强制两个矛盾读数（全开但带仍 active / 折起但带未 active），用来演示 §5.1 的滞后容忍。另外：**「现状」那一栏照样把带画出来**，因为它是物理事实，布局不认它也在那里——这正是那一栏要暴露的东西。带上的标签写的是 `frame`，因为 R33 说 `frame` 已含 `margins`；实现读的也是 `frame`，不许写死 40。每个姿势的 `#readout` 打出 `screen / sizeClass / division / safeArea / occlusion / bars / panes / grid(列数·栏内宽·单元宽·行数) / 分栏后主栏(栏宽·栏高·列数) / dialogHost`，并逐格标这一格是**实测**还是**推断**；字段名与 §5.1 的 `DuoPose` 一一对应。

设备框比例按 §2 的工作数值（外 466×678、内 669×951）等比缩放；折叠带按第三方实测的 40pt 同比例画。**框上的标注本轮已改完口径**：外屏那一栏换成一手实测（`SCREENS.cover.src` 写明 404 帧、`safeArea` 行打出 `(0,0,34,84)`、遮挡层按实测两块 37×37@(400,29) 与 84×170@(382,0) 画，旧的 96×28pt 示意角已删）；内屏与 40pt 带仍标「待展开帧」。**本轮另改的两处口径**：① 侧栏那一格从左边挪到**右边**（trailing），因为实测那条边在右（§5.3 同条），夹具加了 `bandEdge` 断言防止它再漂回去；② 详情页的示意格**不再画底部条**——详情页是整屏路由（`library_page.dart:1430` push），本轮现读 `detail_page.dart` 没有 `bottomNavigationBar`/`NavigationBar`/`TabBar`，旧版照抄外壳那一格画了条 `.tabbar` 还把它的 69pt 扣进预算，现在扣的那格换成详情页自己的顶栏 42pt。侧栏宽在合上态按实测 84pt 画、其余档按 68pt 设计值，两边都由 `bandWidth()` 一处给出，配 §5.3 那条「padding 已 ≥68 就不再额外加宽」和 §9 那句「读到 Dart 侧 `paddingOf` 之前不许实现侧栏宽度」。**示意格里画几张卡片也不是写死的**：列数走 §5.7 那条 floor（整屏一栏时喂屏宽、双栏时喂栏宽，同一处 `masterPane()`），行数按那一栏剩下的可用高推（扣顶栏 42pt、信息块 89pt 与卡片自身的 26pt 标题区），所以「框里摆得下」是算出来的，不是靠 `overflow:hidden` 兜住的。

## 7. 落地阶段

| 阶段 | 内容 | 是否需要折叠感知 | 是否需要 Mac |
|---|---|---|---|
| P0 | `LayoutEnvironment`/`DuoPose` 骨架 + `duo_breakpoints.dart` + `test/support/pose_mount.dart`；`unknown` 支路逐字等价于今天；把 §4.1 现读的 **13 行比较式判据**改完，另加 **3 处守门正则抓不到的非比较式**（本轮现读：`download_selection.dart:25` 的 `width: 720`、`episode_workspace.dart:220` 的 `math.min(340.0, size.maxWidth * .8)`、`anchored_panel.dart:104` 的 `below < 200`——它们不在那 13 行里，别把两个数加成一个）；保住现有测试读数；守门正则上线（期望命中 0） | 否（全部 unknown） | 否 |
| P1 | `SideControlBand` + 传输条条目声明合并 + `dropOrder` 接上真实测量；外屏与内屏横屏的竖排条；**§5.11 的语义与缩放两条硬要求**（`BandItem` 自带 `Semantics`、`hasBadge` 为声明式布尔、缩放换形态不换字号）；**§5.12 的溢出落面接 `PopupMenuButton`** | 否（只需尺寸级/band 边） | 验收需 |
| P2 | 双栏吸附折叠带 + 偶数列（**双栏之后喂网格的约束宽换成主栏宽，见 §5.7 末尾那张栏宽表**）+ overlay 播放页（立姿分屏）+ **§5.10 的宽度喂法改造**（`viewportWidth` 链、`episode_workspace.dart:220`、`anchored_panel.dart:101`）；`hongguo/duo` 自写通道 | **是**（读带；但**不再被上游 PR 阻塞**——§5.8 的四个 API 名已坐实，自写 provider 即可） | 是（40pt 与 margins 要实测帧） |
| P3 | 详情栏竖排条（R10）、内屏多任务（R30）、`PortraitUpsideDown` 决策、焦点遍历扩到 Duo | 是 | 是 |

P0/P1 不碰原生、不依赖 #193025，可在本机把测试跑绿并交付；P2 起任何「已经适配折叠」的说法都必须有 Mac 读数支撑。**本轮把 P2 的依赖从「等上游」改成「等一次成功的展开采样 + 一段自写桥」**：前者是工程量，后者是取证缺口（§8），两者都不再是别人的合并决定。另有一条排序建议来自 §5.14：`LayoutEnvironment` 是仓库第一个真实存在的环境注入层，P0 的形状评审要拉上那份未落地的 `android-tv-adaptation.md` 一起看，别做成 iOS 专用。

## 8. 验证计划

**本轮（Mac）已经实际跑过的取证，与它的边界**：`tool/duo_probe/` 是一个手工打包的 UIKit 探针（`swiftc` 编 `main.swift` → 造 `.app` → ad-hoc 签名 → `simctl install/launch`），跑在 iPhone Duo / iOS 27.1 模拟器上，250ms 一帧写进沙盒 `Documents/samples.jsonl`，脚本经 `get_app_container` 取回落盘到 `tool/duo_probe/evidence/*.jsonl`。已落盘的三帧文件与读数：`duo-20261101T123726Z.jsonl`（**404 条采样 / 100.28s**——该文件 `wc -l` 是 405，多的那一行是开头的 `# header`，本轮按 `DUOPROBE ` 前缀逐条重数过）、`…T123315Z`（30 条）、`…T122109Z`（45 条），三份合起来 **479 条**（就是开头那句「三帧共 479 个样本」的来源；附录用的是同一组数，那里按行写的 404/30/45 与这里的条数一致），全部是**合上态**：`hinge.status = closed` 471 条、另 3 条是连接期的 `no-update`，`divisionActive` 与 `divisionAll` 在全部 474 条带该字段的采样里都是空数组。所以本轮坐实的是外屏那一半（§2 的 scale / 466×678 / H=compact V=regular / 右 84pt / 两块遮挡 / hinge=closed 回调），**内屏与半开一条都没有**。

这条负结果本身就是验收信息，三处原因都记下来免得下轮重踩：

1. **模拟器是 headless 起的**（`simctl boot`，`Simulator.app` 宿主进程不在，只有 `DeviceHub.app` 在跑），折叠姿势没有任何程序化入口：`simctl` 无 fold/hinge 子命令，Device Hub 的菜单被辅助功能权限挡住（AppleScript 报 `-1719`）。也就是说「让用户手动展开」必须先把 Device Hub 窗口带到前台，否则 404 帧会像本轮一样全部停在 `closed`。
2. **采样在 100s 就停了，而窗口是 240s**：探针的 Timer 在 100.28s 后不再产生帧，且 `~/Library/Logs/DiagnosticReports/` 里没有对应时间的崩溃（最近三份 `duoprobe-*.ips` 都早于本轮启动时间）——即**应用被挂起**而不是崩掉。下一版探针必须补 `sceneWillResignActive/didEnterBackground/willEnterForeground/didDisconnect` 四个标记帧，否则「没有读数」会被误读成「没有变化」。
3. **本轮的屏幕实拍没有拿到**：`screencapture -x` 在这个 shell 里只拍出壁纸（本机已知现象），所以**本轮无帧可附**，§2 那几条结论的证据只有 JSONL 数值帧，不是像素截图。按仓库既有规矩，像素级验收仍算未做。

**本机可跑（第一轮在 Windows NTFS 克隆 `hg-verify-dl`，本轮在 Mac，两边都能跑）：**

- 原型自身的结构校验（**本轮再跑，口径又比上一轮宽，上一轮的读数作废**）：夹具把 4 种折叠带读数 × 9 档姿势（六个 Duo 姿势 + 三个未知主机档）里真实存在的组合全展开，逐框量框内每一个非零尺寸后代。本轮现取的读数：**24 组组合 / 192 个设备框 / 8816 个盒，越出设备框 0 个**，卡片内被自身 `overflow:hidden` 裁掉的标题条 0 个，海报 3:4 比例失真 0 个，溢出菜单宿主 9 只（每档一只、5 项、宽度随窗口，本轮 560px 视口下 487px，见 §5.12 那条删掉绝对像素的说明），三条带宿主（外壳侧栏 / 实验台 / 播放页那条）「算出来放得下但画出来顶出屏」0 个，`undefined`/`NaN`/`[object Object]` 全文扫描 0 命中，明细数组 `det` 为空。跑法：把 [prototypes/iphone-duo.check.js](prototypes/iphone-duo.check.js) 整段函数体贴进浏览器控制台（或用 `mcp__browser-use__evaluate_script` 以 `<script src>` 注入，让页面跑的就是入库那一份），它返回上面这些计数与每档读数。
  本轮夹具**新增的四类检查/口径**，都是上一轮量不到的：① `bandEdge` —— 断言 `bars==='side'` 那几格里 `:scope > .band` 的右边与屏框右边对齐（本轮把侧栏从左边改到右边，这条防它漂回去；三档实测姿势 `gapRight` 全 0）；② `scaleSweep` —— 缩放滑块 1.00–1.70 × 四档姿势共 60 步，量侧栏假条不能吃超屏宽（最大 44px = 71pt，对 466pt 屏的裕量 −245px）与标题是否顶穿条目盒；③ `benchSweep` —— 侧栏高度滑杆 90–620pt 共 54 步，只在预算说放得下（`!coreOverrun`）时要求画出来也放得下（90–330pt 那一段是**故意**让「连核心四项都放不下」露出来的，对应 §8 Mac 验收第 6 项）；④ **本轮再补一条口径**：`menuHosts` 每项现在同时打 `w` 与 `window.innerWidth`（`vw`），因为那只溢出面板是 `position:static` 的块、宽度跟着窗口走——本轮读数 `w=487 / vw=560`，九档姿势同一个数，说明它量的是页面列宽而不是任何 Duo 设计量，今后**只准连着 `vw` 一起引用**（§5.12 那条 552px 就是这么废掉的）。
  **本轮被自己的夹具骗过一次，记下来**：`scaleSweep` 原来用 `tx.scrollWidth > tx.clientWidth` 判「标题被裁」，而 `<span>`/`<i>` 这类 inline 元素在 Chrome 里 `scrollWidth` 与 `clientWidth` **恒为 0**，于是那条检查永远绿——实际画面上标题被挤成一字一行、竖着顶出条目盒（因为缩放实验台那格只写了 `.fake-band`，没带 `.band`，条目就不是列 flex，图标盒子与标题排版全丢了）。现在改成量**每个条目最后一个子元素的底边 vs 条目盒底边**（`itemOver`），并且实验台与溢出滑杆那两格都挂上 `.band` 类，与设备框共用同一套 CSS。这条改动做过反向验证：同一份夹具下，带 `.band` 时 `itemOver=0`，把类名去掉立刻报 1 条顶穿。**教训写进规矩：夹具里凡是拿 `scrollWidth`/`clientWidth` 判 inline 元素的断言，都算没有断言。**
  上一轮改掉的三处，全是「靠裁剪兜住」而不是「按可用高排布」，更早那轮的窄口径量不到：① 播放器画面占位块在横屏/笔记本框里按 9:16 从宽推出 692px 高、比 415px 的框还长，只被 `.scr` 裁掉 → 加 `max-height:100%`（外屏窄，那条「画面可满宽」的 9:16 示意不受影响）；② 外屏详情页的信息块被第三行卡片顶出屏 22px → 演示行数的预算里加上 `.blk` 实高（41px + 上下 margin 14px ≈ 89pt）；**这一条本轮又改了一次**：那一版把外壳的 `.tabbar` 69pt 也一起扣了，而详情页是整屏路由、本轮现读 `detail_page.dart` 没有 `bottomNavigationBar`/`NavigationBar`/`TabBar`，于是「画了一条不存在的底部条 + 多扣 69pt」两处一起错 → 现在扣的是详情页自己的顶栏 42pt，底部条不画（§6 末同条）；③ 双栏主栏写死 `cards(2, 6)` / `cards(3, 6)`，容器有确定高时 CSS Grid 把 auto 行拉平分配，海报被卡片自己裁成半张、第二条标题整条不见 → 换成 `masterPane()` 按栏宽走 §5.7 那条 floor、按栏高推行数，画图与读出窗共用这一个式子。
  姿势矩阵本轮读数（今天 → 设计后，全部现取）：**cover 3 → 3 列**（栏内 418 → 334pt，单元 100pt，奇数列合法因为这块屏没折）、**内屏竖 / 书立 5 → 4 列**（栏内 621pt 不变，单元 100 → 120pt）、**内屏横 / 笔记本 7 → 6 列**（903 → 835pt）、**非 Duo 手机 3 → 3 列逐字**（342pt，一期不强转）。双栏后主栏另算：书立 315×882pt → 2 列、内屏竖 335×882pt → 2 列、内屏横 442×669pt → 3 列、笔记本 883×315pt → 6 列（§5.7 末尾那张表）。几何件本轮也现取核对过：外屏侧边带 52px = 84pt（实测系统值）**且画在 x=237、右边与屏框对齐**（`bandEdge` 三档 side 姿势 `gapRight` 全 0，本轮从左边改到右边的那次修正由这条钉住）、内屏侧栏 42px = 68pt（§5.3 设计值）、书立中缝 25×547px @x=195（竖带分左右）、笔记本 548×25px @y=195（横带分上下）、遮挡两块 52.1×105.4px 与 22.9px 圆点（= 84×170pt 与 37×37pt）。带顶那格系统标签本轮用 Range 的行盒数验过不换行：外屏「状态栏段」36px 落在 52px 的带里、内屏「灵动岛」27px 落在 42px 的带里，都 1 个行盒（内屏那格原来写「灵动岛 / 状态栏」，四个字带圆点会折行，已缩短）。
  **这仍是 DOM 度量 + 浏览器整页渲染，不是对着模拟器的像素验收**：本轮 in-app 浏览器拿到了可见表面，两张渲染帧已入库到 `docs/evidence/iphone-duo-prototype-2026-11-02/`：`duo-scale-170.png`（128047 字节，改 CSS 前，正是那张看出「标题被挤成一字一行」）与 `duo-scale-170-fixed.png`（125567 字节，改后，缩放 1.70× 外屏那一格：图标盒 + 两行标题 + 徽章 + 底部 `···`，旁边印着「本档不成立」那条示意横排）；上一轮记的 `NATIVE_BROWSER_VIEWPORT_UNAVAILABLE` 本轮没有复现。**但这两帧量的是原型自己的排版，不是模拟器里的应用**：配色、字距这类只能靠眼睛发现的没有与模拟器同框比对过，模拟器侧本轮仍无帧（本节第 3 项），设备像素级验收仍算未做。
  **第四轮（同一天，改完引用与页脚措辞后重跑）补一句**：夹具照常跑通（`24/192/8816`、五个越界类计数全 0、`det` 空、`menuHosts[0]` = `{items:5, w:487, vw:560}`），但**这一轮取帧又撞上 `NATIVE_BROWSER_VIEWPORT_UNAVAILABLE`（`visibilityState=hidden`）→ 本轮无新帧**，像素记录仍是上面那两张。也就是说这条错误是**间歇性**的，不是上一轮偶发：取帧前得先把应用内浏览器切到可见，否则只能拿 DOM 度量，而 DOM 度量证明不了配色与字距。
- `dart format --output=none --set-exit-if-changed packages tool`、`dart analyze --fatal-infos packages tool`；`packages/app` 与 `packages/tv` 全量 `flutter test`（用 `.fvm` 钉的 3.47.4，且 `dart test` 必须在包目录内跑）。
- 新增套件：`layout_environment_test.dart`（`unknown` 支路对 390/600/740/800/1280 逐字复现今天档位——把「一期不改未知主机」写成断言；再加 §5.14 那条 TV flavor + 1920×1080 用例）、`side_band_test.dart`（§5.3 三段顺序 + 自底向上溢出 + 徽章晚收 + 无图标条目拒绝进侧栏 + §5.11 的语义遍历）、`fold_collapse_test.dart`（`division` 给定/为 `null` 时双栏边界与列数，并把 §5.7 末尾那张栏宽表钉成断言：书立 315×882 → 2 列、等分 335×882 → 2 列、内屏横 442×669 → 3 列、笔记本 883×315 → 6 列。前三档必须与整屏那个 4/4/6 列不同，否则就是把屏宽抄进了双栏的调用方；笔记本那档两者恰好都是 6，不作为判据）、`transport_drop_test.dart`（`dropOrder` 真被消费，且四个永不丢弃项在任意窄度下仍在）。全部挂在 §5.13 的 `test/support/pose_mount.dart` 上。
- 一条**按比较式**的守门测试（本轮已实跑校准）：`packages/app/lib` 内不得再出现把布局档位钉在字面量上的表达式，三条正则 `maxWidth\s*[<>]=?\s*[1-9][0-9]{2,}`、`\.width\s*[<>]=?\s*[1-9][0-9]{2,}`、`\.height\s*[<>]=?\s*[1-9][0-9]{2,}`；**当前命中恰为 §4.1 的 13 行 / 16 个字面量、零误报**，迁移完成后期望命中数为 0（豁免 `layout/duo_breakpoints.dart`）。第一轮写的「grep 掉 720/850」既漏 `1100` 又会被 `'720p'` 与 `q.width > 0` 误报，作废。

**属于 Mac 验收（一律不得在提交说明里写成已验证）：**

1. ~~Xcode 27.x 现读外/内屏逻辑点与 `devicePixelRatio`~~ —— **本轮已做一半**：倍率 3 与外屏 466×678 有一手帧；**内屏 669×951 仍只有「设备类型定义 ÷ 倍率」与第三方模拟器读数两条间接证据**，需要展开帧。
2. `MediaQuery.paddingOf` 每条边在四个姿势下的读数，验证 §3 引用的「非对称安全区已正确上报」这句第三方断言 —— **原生侧本轮已读到 84pt**，剩下的问题是**它经 Flutter 引擎出来还剩多少**（这是 Dart 侧验收，不是原生侧）。
3. `horizontalSizeClass` 归属：外屏 compact **本轮实测已坐实**（H=compact / V=regular）；内屏 regular 待展开帧，据此定 §5.2 的 600 过渡标定值是否直接换掉。
4. 折叠带实测宽度与不活动时的报法（PR 正文称 40pt 且 inactive 仍留框），以及 §2 的轴向推断（竖持=竖带）—— 本轮合上态读到 `division` 为空数组，符合预期但不构成证据。**这一条是内屏三件事里唯一带设计数字的（40pt 决定让位宽），优先级最高。**
5. posture 与 region 的滞后窗口（放平 2–15ms、折起约 1s）在同一台模拟器上的真实时序，验证 §5.1 的容忍策略 —— 需要一次**成功的**展开/合上循环（250ms 帧序能直接量出滞后）。
6. 外屏倒持（缺 `PortraitUpsideDown`）与传输条四个永不丢弃项在侧栏极限窄度下的实拍帧。
7. `packages/app/integration_test` 在 iOS 27.x 模拟器上重跑；本设计新增的 `Size` 档位（466×678、669×951、951×669）进 `adaptive_ui_test.dart` 的循环。
8. **本轮新增**：`UIViewReservedRegion.margins`（R33）在 Duo 上的实际值——外屏两块遮挡的 margins 实测全 0，但 division 的 margins 未读；若它非零，§5.10 的手势死区与 §5.4 的让位宽就要按 `frame`（外圈）而不是内缩后的本体算——反过来，若它是 0，两个矩形重合，按哪个都一样。
9. **本轮新增**：系统大字号（Accessibility 显示缩放）下 §5.3 侧栏条目的形态切换与 44pt 目标（§5.11 第三条），需实拍。
10. **本轮新增**：`interactivelyResizing`（R34）在换屏过程中是否真的会置位——本轮所有帧都是 `false`，因为没发生换屏。
11. **本轮新增（`fe33852` 带出来的）**：两个悬停/筛选面板在 Duo 上按**所在栏**定位。`overlayLocalAnchor`（`anchored_panel.dart:182-185`）已经把「窗口坐标 → 浮层坐标」这一步做对了，剩下的一跳是「浮层全域 → 所在栏」：要求是把 `DuoPose` 的那条栏矩形（§5.1）喂给两条支路的可用盒子，替掉它们现在读的整块 overlay（悬停在 `:107` `space.biggest`，面板在 `:58` `space.maxHeight - anchored.bottom - 24`），并且**两个调用方各自显式传 `width`**（今天 `:1776` 与 `:1876` 都不传，于是面板吃 380、悬停吃默认 300）。验收姿势就用半开书立（669 竖带、栏宽 314.5pt）：面板与悬停都必须整只落在自己那一栏里，`below < 200` 那条翻转线（`:110`）在同一姿势下第一次有了被校的意义。

**下一次取证的固定动作**（写死，避免再采一轮空帧）：① 把 Device Hub 里这台 iPhone Duo 的窗口点到前台并确认探针的屏上限时绿字在动；② `DUO_SAMPLE_SECONDS=300 tool/duo_probe/build_and_run.sh` 后台起；③ 依次 **展开→停 20s→半开→停 20s→合上→停 10s→展开后转横屏→停 20s**；④ 采完立刻读摘要里的「切换时刻」表，若仍只有 `scene-connected` 一行，说明手势没落到系统，不要改设计去迁就一次失败的采样。

## 9. 风险与未定

- **669pt 这条地基只坐实了一半。** 本轮把「像素÷3」这个换算律本身证了（外屏定义 1398×2034 ÷ 实测 scale 3 = 实测 466×678，分毫不差），所以内屏 2007×2853 ÷ 3 = 669×951 从「折算猜测」升成「同一律的推论 + 第三方模拟器实测互证」；但**展开帧仍然没有**，而 §5.2 的 600 过渡标定值、§5.7 那张栏宽表（连带本轮由它推出的两条结论：`280` 那条线在 Duo 上永不触发、`400` 那条一旦改读栏高就会在笔记本姿打回抽屉）都吃这个数。地基未完全坐实之前，P0 可以合、P1 的分派表可以合，但**不要**对外说内屏已适配。
- **上游不再是闸门，但语义仍会变。** #193025 未合、引擎还要换 Xcode——这两条现在只影响「将来能不能改用 `MediaQuery.displayFeatures`」，不影响本设计能不能落地（§5.8 自写通道）。真正的残留风险是**语义**：Flutter 团队已表示不会用 `DisplayFeatureState` 表达 active/inactive，而 §5.1 把 `fold`/`posture` 分开正是为此。§5.1 的接缝（换 provider 不动页面）是对这条的唯一对冲。
- **40pt 这条带从头到尾没有一手实测。** 它是第三方 PR 正文的模拟器读数，而 §5.4 的让位、§5.5 的 overlay 分屏、§5.10 的手势死区全都按它算。**设计不能改，但任何实现都不许把 40 写成常量**——必须读 `division.frame`（它已含 margins，见 R33）；本轮实测外屏遮挡的 margins 全 0，说明这个字段真有可能是 0，也可能 division 不是。
- **§5.10 的手势裁决是推理，不是测量。** 「进度条与双击已合规」有源码行号撑着（分母取 `box.maxWidth` / `context.size.width`），但「竖带下 0.35/0.65 分区线与带重合时应判中间区」是设计判断，没有任何用户研究或实测支持；同理「接力链的 48pt 阈值按栏算」也没量过。P2 做这条时要留一个可关的开关在 `LayoutEnvironment` 里，别把判断写死进手势层。
- **可达性欠账比布局欠账更大，而且它没有回归网。** 全 `packages/app/lib` 8 处 `Semantics`、`library_page.dart` 0 处、`Badge` 0 处、`textScaler` 全仓 0 处（本轮现读）。自绘侧栏一旦上线，VoiceOver 用户在外屏上得到的将是**比今天更差**的体验——今天至少 `NavigationBar` 是 Material 给的。所以 §5.11 那条语义要求不是 P1 的附加项，是 P1 的验收线。
- **`foldable` 1.0.5 是一个月龄、单一维护者的新包。** 用它可以把 P2 提前，代价是引入一个 iOS-only 平台依赖，且其数据模型（hinge 角/姿势）超出 `DisplayFeature`。倾向自写 3 方法通道（§5.8 的四个 API 名已坐实，自写的理由比第一轮更硬），但**未定**，取决于 §8 第 4、5 项现读时它是否已把坑踩平。
- **`SafeArea` 与侧栏争边**（§5.3 第一条）会改动外壳的树形，`adaptive_ui_test.dart`、`download_ui_test.dart`、`horizontal_filters_test.dart` 都在这条路径上。分期做、每步保住未知主机的读数，是唯一能让这件事不出连环回归的办法。**本轮新增一个具体冲突**：实测右边带 84pt 与设计的 68pt 条目宽不等，若 Flutter 侧也透出 84，则侧栏总宽可能到 152pt——外屏 466 宽只剩 314pt 给内容。§5.3 那条「padding 已 ≥68 就不再额外加宽」是为此写的，但它依赖 §8 第 2 项的读数，**在那之前不要实现侧栏宽度**。
- **`dropOrder` 从未被消费意味着它的顺序没人验证过**——那份名单写的是意图不是事实。P1 接上真实测量时如果顺序不合理，得改名单，不能为了测试绿而硬测。
- **PiP 浮窗硬编码 `CGRect(x:8,y:64,width:120,height:214)`**（`ios/Runner/AppDelegate.swift:63`，本轮现读）与任何一条边都不相干；在 Duo 上它是「落在侧栏带上的一块独立窗口」，本设计不处理，登记为已知缺陷。
- **不做姿势专属页面**（R24）不是「不做优化」的托辞：本设计里唯一被允许随姿势重排的是播放器 overlay 与双栏边界，其余一律「按可用空间放大」。如果有人提出「半开时给一个专门的立姿界面」，那是与 R24 正面冲突的，要单独立项讨论。
- **取证工具本身还不可靠。** 探针本轮暴露三个缺口（§8 详述）：无程序化折叠入口（只能人手动）、应用会在无人操作时被挂起而**不产生任何标记帧**、这个 shell 的 `screencapture -x` 只拍出壁纸所以**本轮无像素证据**。在补上生命周期标记帧之前，「采不到」与「没变化」在这份数据里长得一模一样——这是本文件所有 Mac 结论目前最需要防备的一条。

## 附：来源

- Apple《Designing for iPhone Duo》（HIG），<https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo>，变更记录 2026-09-09 New page。本轮存证 `hg-verify-dl/hig-duo.md`（24,153 B）。
- Apple《Preparing your app for iPhone Duo》（Technology Overviews），<https://developer.apple.com/documentation/TechnologyOverviews/preparing-your-app-for-iphone-duo>，2026-09-09。存证 `hg-verify-dl/prep-duo.md`（17,705 B）。
- Apple《Layout》（HIG），存证 `hg-verify-dl/hig-layout.md`（27,416 B）。
- App Store Connect 截图规格（外 1398×2034 / 内 2007×2853），本轮直接 curl `developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/` 现读；存证 `hg-verify-dl/shots.html`。
- flutter/flutter#192515（open，proposal，P2）与 flutter/flutter#193025（open，未合入），本轮存证 `duo192515.json`、`duo192515c.json`、`pr193025.json`；#189554 被 #192515 正文引用为「更大范围的双栏/分屏支持提案」，本轮未读其正文。
- pub.dev `foldable` 1.0.5，存证 `foldable.json`。
- Apple 视频（未看，仅登记为后续材料）：tech-talks 111461–111466、WWDC26 session 278。

**本轮（Mac）新增的一手来源**：

- iOS 27.1 模拟器 SDK 头文件（Xcode 27.1，build 27A9275；SDK 路径 `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator27.1.sdk`）：`UIKit/Headers/UIHinge.h`（`status` 四档、`angle` 在 `:66-68`）、`UIHingeInteraction.h`、`UIViewReservedRegion.h`（`frame`/`margins`/`isActive`/`kind` 与 `IncludeInactive`，全部 `API_AVAILABLE(ios(27.1))`、`NS_REFINED_FOR_SWIFT`）、`UIWindowScene.h`（`displayLink` 换屏自动重定向、`didUpdateEffectiveGeometry`）、`UIScreen.h`（`mainScreen` iOS 26 弃用、`screens` iOS 16 弃用及其替代提示原文）。§1 的 R32/R33/R34 与 §3 的「原生 API 面」表逐条出自这些文件。
- 模拟器设备类型定义：`/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone Duo.simdevicetype/Contents/Resources/capabilities.plist` —— `displays[0]` 1398×2034 @scale 3、hdpi/vdpi 460、`nativeOrientation 0`；`displays[1]` 2007×2853 @scale 3、`nativeOrientation/nativeRotation 270`；另有 `ScreenDimensionsCapability.main-screen-scale = 3`。同目录 `profile.plist` 给 `modelIdentifier = iPhone19,4`、`minRuntimeVersion = 27.1`。这是 §2 那两行「倍率一手」与「内屏原生方向是横的」的来源。
- 探针原始读数：`tool/duo_probe/evidence/duo-20261101T122109Z.jsonl`（45 帧）、`…T123315Z.jsonl`（30 帧）、`…T123726Z.jsonl`（404 帧 / 100.28s，全部合上态）。崩溃存证：`~/Library/Logs/DiagnosticReports/duoprobe-2026-11-01-{202859,203141,203158}.ips`（对应 §5.8 那个 `previousEffectiveGeometry` 为 nil 的坑，修复后本轮再无新崩溃）。
- 本轮的像素级实拍：**没有**。`screencapture -x` 在本 shell 只拍出壁纸（§8 第 3 条），所以 §2 标「一手实测」的各行其证据是 JSONL 数值帧，不是截图。
