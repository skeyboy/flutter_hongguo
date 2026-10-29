# 侧栏切换取证（2026-10-29，macOS 真窗口）

对应设计文档 `docs/design/discover-catalog-cascade-tabs.md` §14。跑法：`tool/verify_sidebar_switch_live.sh`（内部执行 `packages/app/integration_test/sidebar_switch_live_test.dart -d macos`，全屏录影后按夹具报的 `HGWIN` 窗口矩形裁剪；macOS 没有单窗口录制能力）。

## 两份日志的来源不同，要说清

- `mac-fixed.log` —— **本轮结论押的这一跑**，被测的是当前工作树（`library_page.dart:2379` 为 `animatePageTransition: !desktopHost`）。4 次侧栏点击后各采一串 `ev=page`（共 81 个样本），`in_between=0`：第一次采样（点击后 71–220ms）就已经是 0.00 或 1.00。本目录 8 张帧条全部出自这一跑的录屏。
- `mac-before-fix-probe.log` —— **对照跑，被测的树不是可发布的那一份**：为了量出「改之前确实滑」，把 :2379 临时改回 `true` 后直接跑夹具（不录屏，所以这一跑没有帧条）。同一条采样序列里四次点击分别有 10/9/11/11 个样本停在两页之间（每段各 25/25/26/28 个样本，现读自该日志）。跑完即还原，还原后单独复跑过 `dart format --set-exit-if-changed` 与 `dart analyze --fatal-infos`。

## 帧条命名

`jump-in-*` / `jump-out-*` = 侧栏点击（发现↔分类）；`slide-*` / `slide-back-*` = 一级「类型」胶囊点击（短剧↔漫剧），留在原行为里，作用是证明同一台机器、同一段录屏、同一口径下「滑」是被量得出来的。变化帧计数：侧栏 2/1/2/2（窗口总帧 39/40/40/39），一级 8/6/5/7（40/41/40/40）。

## 口径的弱点

`select='gt(scene,0.02)'` 把在线列表的内容到达（封面陆续贴上）也算成变化，所以帧条只能当插图。不加 `ev=page` 采样器的两次预跑里，同一条 jump-in 读出过 `1 changed of 38` 也读出过 `6 changed of 25`——差别只在采样那一秒里上游回没回数据。结论一律押 `ev=page` 那串位置读数。
