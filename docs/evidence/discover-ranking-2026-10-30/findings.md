# 发现页筛选与榜单（2026-10-30）

本轮把 [../design/discover-filters-and-ranking.md](../design/discover-filters-and-ranking.md) 的设计落到代码，按阶段 1→4 推进，桌面端优先；移动端只同步了「榜单成为一个目的地」，L2′/L3 的弹层形态维持现状（底部弹层留到下一轮）。规格原型：[../design/prototypes/discover-filters-ranking.html](../design/prototypes/discover-filters-ranking.html)。

## 每一层由哪个文件承担

| 层 | 代码 | 它保证的那句话 |
| --- | --- | --- |
| L0 目的地 | `packages/app/lib/features/library_page.dart`（`destination`）、`packages/app/lib/ranking/ranking_page.dart` | 榜单与「分类/我的」并列，不带 类型 也不带 题材 的请求：`rankBoard(track, board)` 的入参里没有它们 |
| L1 类型 | 同上，`_switchFeed` | 换类型是换页：`browse`/`browseFiltered` 重新起一次请求 |
| L2 主题 | 主题行 + `packages/app/lib/ranking/board_tabs.dart` | 桌面只铺头 8 枚，尾部交给 `更多 ▾`；不要求指针横滑 |
| L2′ 更多筛选 | `packages/app/lib/features/discover_filter_panel.dart` + `packages/app/lib/widgets/anchored_panel.dart` | 词表给几行就画几行；选任何一行只改请求、不收弹层、不换页 |
| L3 排序 | `packages/app/lib/widgets/sort_menu.dart` | 三档（`online_time`/`hot_score`/`hot_collect`）是上游发布的，客户端不认「推荐」 |
| 悬停预览 | `packages/app/lib/widgets/hover_peek.dart` | 停住 1.5s 才出现，划过去不算兴趣；预览自己能被指针接管（收 300ms，进入即取消） |
| 键盘 | `library_page.dart` 的 `_shortcutBindings` | `F` 抽屉、`O` 排序、`Esc` 逐层关闭并把焦点还给触发它的那枚控件 |

## 实机跑出来的一条（重要）

`flutter test` 里 `defaultTargetPlatform` 默认是 android，所以 `desktopHost` 在既有 296 个用例中始终为 false——桌面分支在本轮之前**没有任何自动化覆盖**。后果是一次真实崩溃：

- 现象：Mac 实机进入「榜单」，红屏指向 `RankSelectorRow-[<'rank-tracks'>]`。
- 原因：`board_tabs.dart` 用 `overflowAfter ?? items.length` 直接 `sublist(0, 8)`，而线上真人剧/漫剧赛道只有 2–3 条，`RangeError (end): Not in inclusive range 0..3: 8`。
- 修复：`final limit = (overflowAfter ?? items.length).clamp(0, items.length);`——溢出值是「行在哪里停」，不是「欠几枚 chip」，3 条的赛道不该出现 `更多 ▾（0）`。
- 这条只有在 `debugDefaultTargetPlatformOverride = TargetPlatform.macOS` 的用例里才会跑到，见 `packages/app/test/discover_desktop_layers_test.dart`。

同源的一行教训：镜像到 PSSD 检出时，`lib/` 的新文件必须和 `library_page.dart` 一起过去，否则 Mac 侧编译不过而 Windows 侧全绿。

## 下钻不做的事

- 「找同题材」只在 `category_schema` 的词表里找完全同名或前缀同名的主题；找不到就退回「全部主题」，并在读数里说清这个类型实际只有几个主题——不凑一个相近的词。
- 「看它所在的榜」先把 类型 映射到 赛道（`short_play→human`、`comic_series→comic_series_rank`、`ai_series→ai_playlet`），再在**上游回来的榜树**里认「热播榜」（标签含「热播」或 id 以 `hot_play` 结尾）；榜树是随第一次回答才到的，所以这个心愿挂在 `rankDrillTrack` 上、由 controller 的 notify 兑现。赛道没发布热播榜时，尊重上游 `is_selected` 的默认榜。

## 已知未改的口径分歧

排序档的界面词这里用「最高热度 / 最高收藏」，而设置页（`packages/app/lib/features/settings_page.dart:753`）写的是「收藏最多」。没顺手统一，因为 `packages/app/test/tv_settings_test.dart:23` 靠 `find.text('收藏最多').last` 定位；要统一得连这条用例一起过一遍。

## 门禁

- `flutter analyze --no-pub`（`packages/app`）→ `No issues found!`
- `flutter test --no-pub`（`packages/app` 全量）→ `03:02 +310 ~1: All tests passed!`，其中本轮新增的桌面用例 14 条：`packages/app/test/discover_desktop_layers_test.dart`（9）与 `packages/app/test/discover_desktop_spec_test.dart`（5）。
- `packages/api` → `+95 -9`。9 条失败全部落在 `media_cache_test.dart` / `prefetch_scheduler_test.dart`（Windows 侧既有，本轮没有改过这两个文件；CI 在 ubuntu-24.04 上跑 api）。
- 词表与榜字段用例（`packages/api/test/catalog_vocabulary_test.dart`）由 `dart test` 跑：`+11: All tests passed!`。
- 提交：`ea00b68` feat(api) 筛选词表与榜树、`f9b48ba` feat(discover) 鼠标族层叠与榜单目的地、`37d7ed0` test(discover) 桌面用例与 live 工装重讲。
- 移动端本轮只同步了「榜单成为目的地」这一条；L2′/L3 的底部弹层形态留给另一个 topic。

## 实机验收（Mac）

崩溃修复后进入 榜单 的结果记在这里，因为它同时是「桌面分支此前没有任何自动化覆盖」这条结论的复现材料。

（待补：Mac 实机 `榜单 / 更多筛选 / 排序 / 悬停预览 / F-O-Esc` 的逐项读数。）
