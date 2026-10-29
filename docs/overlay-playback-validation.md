# 0.2.5：筛选浮层与播放空间

实现位于主 workspace `packages/app`。本轮最终方案是所有尺寸默认把空间交给视频，选集只作为覆盖浮层出现。宽桌面不再默认显示或预留侧栏。

[设计与平台交互规则](design/overlay-playback.md)。设计参考 QuickTime 的屏上控件显示方式、Plex 的可收起导航；浮层尺寸、5 秒和本项目的快捷键均为本项目实现值。

## 发现 / 分类

筛选工具栏下方的内容区使用 Stack：底层是原列表，上层依次是外部点击遮罩和横向选项面板。面板不参加列表的 Column 高度分配，展开/关闭不推移影视卡片、不改变列表视口高度或滚动位置。

关闭遮罩只消费本次点击，不同时打开视频。原有缓存优先、250ms 合并刷新及有效筛选限制继续保留。改变筛选条件时仍会按原规则从新结果顶部显示，这与仅展开面板不会改变位置是不同的操作。

## PC / 平板 / 横屏播放

视频占满 AppBar 以下的播放区，选集默认关闭。顶部始终提供“显示或隐藏选集”入口，可用 I 键切换；Esc、关闭图标和外部点击均可收起。

右侧抽屉宽度不超过 340px 或窗口宽度的 80%，内部完整滚动，短窗口不再把选集挤到剩余区域。按“保持选集展开”只停止闲置自动关闭，仍然覆盖视频；显隐不会缩放或重建视频区域。

临时抽屉在播放中闲置 5 秒收起。鼠标悬停、触控按住/滚动、键盘操作、暂停、加载、错误或无障碍导航会抑制自动隐藏。选中分集时收起临时面板，保持展开模式除外。显隐只修改本次页面的交互状态，不改变全局播放配置。

## 手机竖屏

保留底部选集面板和显式关闭按钮，选中分集后自动关闭；浏览分集时不采用超时强制关闭，避免选到一半消失。

底部的上一集/选集/下一集、本地连播及缓存状态改为视频上的浮层，不再预留底部高度。支持手动隐藏，播放中闲置 5 秒自动隐藏；触碰画面重新显示，顶部入口仍可打开选集。手指按住或操作时不计时隐藏，暂停、加载和无障碍导航时保留已显示控件。

> 本节是 0.2.5 的记录。控制条后来按 [播放控制条重构](design/player-controls-redesign.md) 重做：那一枚 `expand_more`「隐藏播放操作」已下线（收起改 by 点画面/鼠标静置），上一集/下一集之外补了 ±10s、进度条缓冲层与 hover 时间、桌面连续音量，清晰度进了宽面/横屏的控制条右簇；浮层不预留高度、视频矩形不变这两条仍然成立。

缺集/音频提示同时在视频顶部显示，不会因为选集或底部操作隐藏而丢失。

## 生命周期和播放

- 视频矩形始终保持完整，抽屉关闭只解除遮挡，不触发 `prepare` 或重新下载。
- 横竖屏和窗口尺寸变化保留同一 Player handle；切换布局本身不改清晰度、播放位置或连播偏好。
- 本地连播、缺集停止、现有 3～5 集预缓存和引用释放继续沿用既有逻辑。
- 不新增付费 GitHub Actions 运行；main 推送仍不自动打包。

## 源码

| 行为 | 位置 |
|---|---|
| 筛选 Stack 与遮罩 | [library_page.dart](../packages/app/lib/features/library_page.dart) |
| 选集浮层、保持展开、闲置/输入保护 | [episode_workspace.dart](../packages/app/lib/playback/episode_workspace.dart) |
| 手机操作浮层、触碰唤起与隐藏 | [compact_controls.dart](../packages/app/lib/playback/compact_controls.dart) |
| 播放状态、分集切换和屏幕适配 | [player_page.dart](../packages/app/lib/features/player_page.dart) |
| 视口/卡片/滚动位置不变测试 | [horizontal_filters_test.dart](../packages/app/test/horizontal_filters_test.dart) |
| PC/平板交互与输入测试 | [episode_workspace_test.dart](../packages/app/test/episode_workspace_test.dart) |
| 手机显隐、手指操作及闲置测试 | [compact_controls_test.dart](../packages/app/test/compact_controls_test.dart) |

## 验证范围

本轮 App 单元/页面测试覆盖 390×600、600×340、800×600、1280×900 等尺寸；对比展开前后的列表矩形、卡片矩形、滚动偏移和视频矩形，并测试自动隐藏/保持展开/暂停/加载/鼠标/键盘/触控/无障碍例外。

Mac 原生验证在临时离线合成素材上比较显隐与尺寸变化前后的 Player handle，并回归本地连播、缺集和 5 集预缓存。未把这些结果外推为其他平台真机验收。

日志、最终计数与截图见 [本轮证据](evidence/overlay-playback)。

## 最终结果与截图

63 项 App 单元/页面测试、5 项 Mac 原生集成通过，静态分析和格式检查通过。截图为当前 Mac 的离线合成验证素材，不是线上影视画面。

- [PC 完整播放区](assets/overlay-playback/hongguo-player-pc-picture-ui.png) · [PC 选集覆盖](assets/overlay-playback/hongguo-player-pc-overlay-ui.png)
- [中等窗口选集](assets/overlay-playback/hongguo-player-medium-overlay-ui.png)
- [手机操作浮层](assets/overlay-playback/hongguo-player-mobile-controls-ui.png) · [手机隐藏操作后](assets/overlay-playback/hongguo-player-mobile-picture-ui.png)
- [手机底部选集](assets/overlay-playback/hongguo-player-mobile-episodes-ui.png)
- [筛选覆盖面板](assets/overlay-playback/hongguo-horizontal-filters-mobile-ui.png)

版本已更新为 0.2.5+7。本轮只提交 UI 与相关测试/文档，未触发额外收费打包或覆盖已有 Release。
