# TV 详情页选集焦点修复 — findings

被测：`flutter_hongguo` 工作树（HEAD 099f6d5 + 本轮 4 处修复），debug TV flavor（`com.example.hongguo_app.tv`），运行在 `emulator-5554`（1920x1080）。
驱动：`tool/tv_focus_probe.py` — 用 `adb shell input keyevent` 注入真实 Android D-pad（19/20/21/22/23/4），每步 `uiautomator dump` + `exec-out screencap`。模拟器允许事件注入，未使用任何桌面合成点击。
证据：本目录 `emulator/*-focus.log`（每步一行：焦点节点的文案 + 全局矩形 + 语义树中 `focused="true"` 的节点数）与同名前缀的原始截图/XML，未入库的完整序列在 `build/verification/tv/focus-fix/`。
基准：v0.3.2 发布包（tag v0.3.2 / commit 099f6d5）的缺陷记录见本目录 `v0.3.2-baseline-findings.md`。

焦点判读口径：Flutter Android 的 a11y 桥**不输出被视口裁掉的语义节点**，页面容器本身恒为 `focused="true"`，所以日志里 `(2 focused)` = 有一个带文案的焦点节点，`(1 focused)` / `NO LABELLED FOCUS` = 遥控器焦点在语义树里不可见（用户看到的就是"页面全灭"）。

## 结论速览

| 项 | v0.3.2 | 本轮 | 证据（`emulator/`） |
| --- | --- | --- | --- |
| D1 选集格遥控器可达 | 不通过 | **通过** | `06-D1-fixed`、`10-tail-handoff` |
| D2 翻页焦点交接 | 不通过（焦点彻底丢失） | **通过** | `11-to-tail`、`12-D2-arrow` |
| N1 焦点进入折叠下方时是否仍在屏上 | 未测 → 缺陷 | **通过** | `04-D1-down`（缺陷）→ `08-down-reveal`（修复） |
| N2 焦点向上回滚时是否仍在屏上 | 未测 → 缺陷 | **通过** | `07-up-and-right`（缺陷）→ `09-up-reveal`（修复） |

N1/N2 是 D1 修好后在真机上才暴露的两个独立缺陷，只在真机出现（widget 夹具里视口不裁节点，测不出来），故单列。

## 修复

按「优先使用 hongguo_tv，不满足时修正 hongguo_tv」的要求，焦点逻辑全部落在 `packages/tv`（hongguo_tv）内，不在业务组件逐个绕过；`packages/app` 侧只有选集分页器的交接落点配合。

### 1. D1 — `TvNavigation.focusInDirection`：按几何搜索方向目标

- 根因：Flutter 的方向遍历策略（`DirectionalFocusTraversalPolicyMixin`）只在**与源节点同一个竖直 `Scrollable`** 的候选里挑下一个（按 `Scrollable.maybeOf(..., axis: vertical)` 过滤）。详情页是 `SingleChildScrollView` 里嵌 `PageView` + `GridView`，选集格属于嵌套视口，于是 Down 从「开始观看」永远跨过整个选集块，落到页面自己那个视口里的推荐卡 —— v0.3.2 的 D1。
- 改动：[packages/tv/lib/src/environment.dart:49](file:///Users/lee/Desktop/flutter_hongguo/packages/tv/lib/src/environment.dart#L49) 新增静态 `focusInDirection(FocusNode?, TraversalDirection)`，在 `nearestScope.traversalDescendants` 里按全局矩形搜索该方向的节点，沿用 Flutter 自己的取舍（优先落在源带宽内的，再取主轴位移最小的；出带时才二次按交叉轴排序）；在 `onKeyEvent` 里先走几何搜索，返回 false 才回落框架默认（[environment.dart:160](file:///Users/lee/Desktop/flutter_hongguo/packages/tv/lib/src/environment.dart#L160)）。请求焦点后不同步校验 `hasFocus` —— 焦点在微任务里落地，返回 false 会让框架在同一帧重挑一个错节点。
- 负对照：`packages/app/test/episode_pager_tv_page_test.dart` 用例 1-3，未修复代码上失败于 `Expected: '第 1 集' / Actual: '推荐A'`。
- 真机：`06-D1-fixed-focus.log` — Down 依次 `第 1 集`→`5`→`9`→`13`→推荐卡，每步都是带文案的焦点节点；`10-tail-handoff-focus.log` — 从「开始观看」Right 走完操作行（下载剧集 → ♡ 收藏）后 Right 直接进选集第 3、4 格。截图 `fixed-d1-down-enters-pager.png`。

### 2. D2 — 失能的 `TvFocusable` 保留焦点，只是不再参与遍历

- 根因：[packages/tv/lib/src/focusable.dart](file:///Users/lee/Desktop/flutter_hongguo/packages/tv/lib/src/focusable.dart) 原实现用 `canRequestFocus: widget.onActivate == null` 表达「无操作 = inert」。焦点正停在该节点上时把它翻成不可聚焦，`Focus` 会 `unfocus(disposition: previouslyFocusedChild)`，主焦点掉到 `_ModalScopeState<dynamic> Focus Scope` —— 一个没有任何可访问文案的焦点，用户看到的就是页面全灭，且后续按键无法恢复（v0.3.2 的 `tree-62`–`65` 连续四棵树无焦点）。触发路径正是：在第 1 页激活「上一页」，翻页后「上一页」变 inert，而它手里正拿着焦点。
- 改动：[focusable.dart:78](file:///Users/lee/Desktop/flutter_hongguo/packages/tv/lib/src/focusable.dart#L78) 改为 `skipTraversal: widget.onActivate == null`。inert = 不能激活、遥控器不路过，不等于不可聚焦；已经站在上面的焦点得以保留。
- 负对照：`packages/tv/test/inert_focus_test.dart` 用例 1（聚焦 → 重建为 `onActivate: null` → 断言焦点仍在该节点），未修复时失败于 `Actual: '_ModalScopeState<dynamic> Focus Scope'`（reason `D2: the page lost its focus entirely`）；用例 2 保证 inert 项仍会被方向遍历跳过。
- 定位过程：先在 v0.3.2 基线工作树里用 widget 夹具探测分页器自身的交接路径（`_turnTo` 边界页、箭头激活），结论是这些路径**不会**丢焦点，所以缺陷不在 `episode_pager` 而在 hongguo_tv 的 inert 语义 —— 修复因此落在模块里。
- 真机：`11-to-tail-focus.log` — 从推荐区 Up 回到选集尾行并横向走完 `14→15→16→17→18` 再 `17→16→15→14`（跨页边界），全程有落点；`12-D2-arrow-focus.log` 是 v0.3.2 致害序列原样重放：`第 16 集` → Down → `下一页` → select → Left → `上一页` → select → **`第 1 集` 带文案聚焦**。截图 `fixed-d2-prev-arrow-handoff-lands-cell1.png`。

### 3. N1 — 可见性展开要覆盖全部祖先滚动器

- 根因：`focusable.dart` 原来用 `Scrollable.maybeOf(context)?.position.ensureVisible(...)`。`ScrollPosition.ensureVisible` 内部 `RenderAbstractViewport.maybeOf` 取的是**最近**视口 —— 嵌套 `GridView` 自己的那个，而它是 `NeverScrollableScrollPhysics` 滚不动，外层页面从没被展开，焦点节点被视口裁掉，于是从 a11y 树里消失。
- 改动：[focusable.dart:95](file:///Users/lee/Desktop/flutter_hongguo/packages/tv/lib/src/focusable.dart#L95) 改用 `Scrollable.ensureVisible(context, ...)`，它遍历所有嵌套滚动器。
- 负对照：`packages/tv/test/nested_reveal_test.dart` 用例 1，未修复时格子底边 `Actual: 1480.0`（超出 1080 视口）。
- 真机：缺陷读数 `04-D1-down-focus.log` 第 03-06 步 `NO LABELLED FOCUS (1 focused)`（截图 `defect-n1-focus-below-fold-unlabelled.png`：页面上无任何高亮）；修复后 `08-down-reveal-focus.log` 同序列每步都是 `第 N 集` 且完整在屏（`[72,453][501,739]`，截图 `fixed-n1-down-reveals-cell9.png`）。

### 4. N2 — 展开策略要居中，`keepVisibleAtEnd` 不会往回转

- 根因：`keepVisibleAtEnd` 只保证末端可见，**从不减小 offset**，位于折叠线上方的格子永远展不开 —— 从选集最后一行 Up 回上一行时焦点又消失。
- 改动：同 `focusable.dart:95`，显式策略 + `alignment: 0.5`，两个方向都把目标带到视野中部。
- 负对照：`nested_reveal_test.dart` 用例 2（Down 三步到 `cell 4` 再 Up，断言 `cell 2` 完整在屏），未修复时 `Actual: 1890.0`。
- 真机：缺陷读数 `07-up-and-right-focus.log` 第 02-07 步 `NO LABELLED FOCUS`（截图 `defect-n2-up-loses-focus-above-fold.png`：只剩推荐 rail，选集块已滚出视野，无高亮）；修复后 `09-up-reveal-focus.log` — 从推荐卡 Up 依次 `第 9 集`→`5`→`1`→`开始观看`（截图 `fixed-n2-up-reveals-cell1.png`）。

### 配套：`episode_pager` 的交接落点

[packages/app/lib/playback/episode_pager.dart:162](file:///Users/lee/Desktop/flutter_hongguo/packages/app/lib/playback/episode_pager.dart#L162)：`_turnTo(page, {focusEpisode, focusFallback})` + `_handFocus` 最多等两帧直到目标格子的 `node.context` 就绪再请求焦点，拿不到就停在同侧箭头上（`_onCellKey` 传 `focusFallback: _prevNode/_nextNode`）。类注释改为说明竖直移动由 `TvNavigation.focusInDirection` 承接。

## 门禁读数（本轮现读）

- `packages/tv`：`flutter test --no-pub` → `+36: All tests passed!`（含新增 `inert_focus_test.dart` 2 例、`nested_reveal_test.dart` 2 例）。
- `packages/app`：`flutter test --no-pub -r expanded` → `00:23 +219 ~1: All tests passed!`（1 个 skip 为既有跳过；含新增 `episode_pager_tv_page_test.dart` 4 例）。
- `dart format --output=none --set-exit-if-changed` 本轮 6 个文件：`Formatted 6 files (0 changed)`。
- `dart analyze --fatal-infos` 本轮 6 个文件：`No issues found!`。
- 以上只覆盖本轮路径；工作树同时存在另一会话的改动，全仓门禁读数不以本文件为准。

## 复现

```
# 在 packages/app 构建 TV flavor 并安装到 emulator-5554
.fvm/flutter_sdk/bin/flutter build apk --debug --flavor tv
adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-tv-debug.apk

# 详情页选集块：注入真实 D-pad 并逐步读语义树焦点
python3 tool/tv_focus_probe.py --device emulator-5554 \
  --out build/verification/tv/focus-fix --tag 12-D2-arrow \
  --steps right,right,down,select,left,select
```

负对照复现：`git checkout -- packages/tv/lib/src/focusable.dart` 后跑 `packages/tv/test/inert_focus_test.dart`、`packages/tv/test/nested_reveal_test.dart` 与 `packages/app/test/episode_pager_tv_page_test.dart`，即得上文 `Actual:` 读数；跑完 `git checkout` 恢复的文件需重新应用本轮改动（本轮改动未提交前不要照此操作，改用另一份工作树）。

## 未覆盖 / 遗留

- 未跑 Android 手机真机（焦点几何搜索只在 TV 环境启用）；iOS/桌面无 D-pad，不受影响。
- 丢焦点后的**自愈路径**（真已丢失时按任意键能否恢复）仍未测，与 v0.3.2 基线同一条未覆盖项。
- 探测件 `packages/app/test/tv_focus_diag_test.dart`、基线工作树里的 `d2_probe_test.dart` 属临时夹具，随任务 #28 清理，不入库。
