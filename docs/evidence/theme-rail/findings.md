# 两页同构的三级链路 — iPhone 实机帧索引

被测：`flutter_hongguo` 工作树（HEAD `e90e9d6` + 本轮 §12 的未提交改动），debug 移动端包，运行在 iOS 模拟器 `yxy-iPhone17Pro`（UDID `8CAD9D3D-DA70-4811-81A2-0E18EFEA6A8E`）。
驱动：`HONGGUO_RAIL_DEVICE=yxy-iPhone17Pro tool/verify_theme_rail_live.sh` → `packages/app/integration_test/theme_rail_live_test.dart`，用 `dragFrom` 打真实拖拽手势（不是合成点击），每到一个状态打印一行 `HGRAIL ... ev=shot=<名字>`，取帧器读到哪行就用 `xcrun simctl io <UDID> screenshot` 抓哪一张（模拟器是无沙箱外卷权限的进程，先暂存 `${TMPDIR}` 再拷进本目录）。
本轮通过的一跑：2026-10-28 07:43:11 → 07:44:23（CST），72s，`All tests passed`，16 帧同一次运行；原始 marker 日志在本目录 [ios-live-2026-10-28.log](ios-live-2026-10-28.log)，`build/verification/theme-rail/run.log` 只是它的运行时副本。上一轮（v0.3.6 那批）的日志仍留在 [ios-live-2026-10-27.log](ios-live-2026-10-27.log)。

验收口径：一次手势最多换一层。最内层（题材）必须滑到没有可滑的，才把这一拉交给类型；类型也没有了，才交给 shell 的 发现↔分类。交接不能跳级，也不能在还有余量时提前跳。上下滑时顶段折叠、二级条留在顶上。

## 结论速览（本轮四个读数）

| 读数（日志行） | 证明的事 | 帧 |
| --- | --- | --- |
| `level2-first-pull from=short_play/ to=short_play/cate_165` | 最内层自己应答：题材换了一页，`genre` 与 `destination` 全程没动（夹具 :311-336 两脚都断言这两条） | [ios-level2-first-pull.png](ios-level2-first-pull.png) |
| `genre-handover from=short_play/cate_1240 to=comic_series/` | 条尽头的那一拉交给类型：一级换页、二级跟着归零（`_writeSlot` 的 `theme = null`），而 shell 仍答 1 | [ios-genre-handover.png](ios-genre-handover.png) |
| `handover to=0 theme-pulls=0 genre-pulls=0 first-answer=shell` | 分类 已在自己第一页且二级在 全部，第一拉直接上交回 发现 | [ios-tab-swipe-to-discover.png](ios-tab-swipe-to-discover.png) |
| `shot=tab-swipe-to-categories from=ai_series/` | 发现 在自己最后一个类型上把这一拉交给 shell，落点仍是 viewer 自己选的那一级 | [ios-tab-swipe-to-categories.png](ios-tab-swipe-to-categories.png) |

`theme-pulls=0` 与上面那条 `level2-first-pull` 是同一规则的两面：有余量时上层一句都听不到，余量耗尽后第一拉就被交接。

## 帧索引（按 marker 顺序）

| 帧 | marker | 画面里的状态 |
| --- | --- | --- |
| [ios-rail.png](ios-rail.png) | `enter-categories destination=1 genre=short_play themes=29` → `shot=rail` | 进入 分类：一级 ✓短剧，二级条首枚「全部 · 短剧」+ 悬疑/宫斗/脑洞/青春，live themes 回了 29 条 |
| [ios-genre-comic.png](ios-genre-comic.png) | `shot=genre-comic genre=comic_series level2=` | 点 漫剧 之后二级归零（**与下一帧字节相同**，见「本轮两处不完美」） |
| [ios-level2-first-pull.png](ios-level2-first-pull.png) | `shot=level2-first-pull ...` | 一拉之内二级从 全部 翻到 宫斗，一级仍 ✓短剧、底部仍 分类；左边上一页「全部 · 短剧」那屏还在收尾，新页此刻是骨架 |
| [ios-genre-handover.png](ios-genre-handover.png) | `shot=genre-handover ...` | 条尽头再一拉：一级换成 漫剧、二级整行换成上游当时没回的题材（重试胶囊） |
| [ios-tab-swipe-to-discover.png](ios-tab-swipe-to-discover.png) | `handover to=0 ... first-answer=shell` → `shot=tab-swipe-to-discover` | 落回 发现：模式行 ✓推荐 + 一级 ✓短剧 + 二级「全部 · 短剧」，标题「为你发现 · 短剧」 |
| [ios-mode-latest.png](ios-mode-latest.png) | `shot=mode-latest view=latest` | 点 最新 胶囊（本轮它是模式，不是页）：标题换成「最新上架 · 短剧」，取数换成 `online_time` |
| [ios-rank.png](ios-rank.png) | `shot=rank level2=board:recommend genre-row=0` | 榜单态：类型整行退场（`genre-row=0` 就是这条断言的读数），二级条换成 推荐榜/热播榜/新剧榜，标题「漫剧 · 推荐榜」 |
| [ios-rank-board.png](ios-rank-board.png) | `shot=rank-board from=board:recommend to=board:hot` | 榜单档就是这一层的可滑页：一拉换到 热播榜，标题跟着换成「漫剧 · 热播榜」 |
| [ios-band-collapsed.png](ios-band-collapsed.png) | `shot=band-collapsed collapsed=true rail-top=62 offset=1580` | 上下滑折叠：搜索框、模式行、类型行都不在屏上，只有二级条吸在顶上（top=62），列表在下面滚 |
| [ios-band-expanded.png](ios-band-expanded.png) | `shot=band-expanded collapsed=false offset=0` | 滚回顶部顶段自己回来：搜索框 + 模式行与类型行同处一行（中间那道竖缝是分界）+ 二级条 + 标题 |
| [ios-tab-swipe-to-categories.png](ios-tab-swipe-to-categories.png) | `end-of-levels genre=ai_series chips=0` + `rail-pilled pane=0 ... error=题材加载失败` → `shot=tab-swipe-to-categories` | 发现 停在最后一个类型、二级条当时是空的（上游返空），于是第一拉就归 shell：底部选中 分类、一级仍是 AI 短剧 |
| [ios-theme-two.png](ios-theme-two.png) | `shot=theme-two level2=cate_262` | 点第三条题材：换一套行，顶段此时已经折叠——**选中那枚「脑洞」被左边缘切掉半枚**，即「已知未修」那条 |
| [ios-theme-two-scrolled.png](ios-theme-two-scrolled.png) | `shot=theme-two-scrolled offset=400` | 该题材的列表在自己里面下滚到 400（`_offsetOf` 读的是这条记录自己的 `ScrollController`） |
| [ios-theme-three.png](ios-theme-three.png) | `shot=theme-three level2=cate_297` | 换到第四条题材：另一套行、另一个偏移 |
| [ios-theme-two-restored.png](ios-theme-two-restored.png) | `shot=theme-two-restored offset=400 was=400` | 回切第三条题材仍是 400 那一屏：每条题材各留一套行、一个游标、一个纵向偏移 |

## 本轮两处不完美（如实记）

- `ios-genre-comic.png` 与 `ios-genre-handover.png` **MD5 相同**（`52c2af73…`）：这两处 marker 相隔 11s，但画面都是「一级=漫剧 + 二级条当时是重试胶囊 + 漫剧的行」，所以前一张没有独立信息。交接这件事的硬证据是日志里 `atEnd.genre != beforeEnd.genre` 与 `destination` 未变那两条断言，帧只负责说明「落到的那一页长什么样」。
- 两条腿的上游 `themes` 整段返空（`catalog.themes(comic_series) failed: 内容接口未返回数据，请稍后重试`、`ai_series` 同一条），于是那两处二级条显示的是「题材加载失败 · 重试题材」而不是胶囊。这是这个端点的已知偶发（见 project memory：先重跑再定性），本轮已重跑过两跑，这一跑是四个跑里唯一走完全程的；产品侧行为（失败只留一个重试入口、不脏别的桶）正是要看的形状。
- **已知未修**：吸顶的二级条可以停在「选中那枚胶囊在可见区外」（`ios-theme-two.png` 实例）。不自动补揭示的理由见 `docs/design/discover-catalog-cascade-tabs.md` §12 第 11 条。

## 与 macOS 帧的关系

本目录**无前缀**的 `discover.png`、`rail.png`、`rank.png`、`genre-comic.png`、`theme-*.png` 是更早那轮（提交 `60db477`）的 macOS 全屏录制裁剪帧，画面结构还是 band 之前那一版；`sheet-before.png` 是更早的基线。`ios-discover.png`、`ios-inner-latest.png`、`ios-inner-categories-last.png`、`ios-tab-swipe-back-to-discover.png` 是 v0.3.6 那一轮（两级、band 全程固定）的帧，本轮没有同名 marker，所以它们保持原样作为上一版的对照。本轮 macOS 那一路仍只录到桌面壁纸，所以当前结构的实机证据只有本批 `ios-*`。macOS 单窗口录制在本机不可用这条见 `docs/evidence/` 说明与 `docs/design/discover-catalog-cascade-tabs.md` §11 第 10 条。
