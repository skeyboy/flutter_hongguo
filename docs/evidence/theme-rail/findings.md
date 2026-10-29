# 两页同构的三级链路 — iPhone 实机帧索引

被测：`flutter_hongguo` 工作树（HEAD `bc6ab09` + 本轮 §13 的未提交改动），debug 移动端包，运行在 iOS 模拟器 `yxy-iPhone17Pro`（UDID `8CAD9D3D-DA70-4811-81A2-0E18EFEA6A8E`）。
驱动：`HONGGUO_RAIL_DEVICE=yxy-iPhone17Pro tool/verify_theme_rail_live.sh` → `packages/app/integration_test/theme_rail_live_test.dart`，用 `dragFrom` 打真实拖拽手势（不是合成点击），每到一个状态打印一行 `HGRAIL ... ev=shot=<名字>`，取帧器读到哪行就用 `xcrun simctl io <UDID> screenshot` 抓哪一张（模拟器是无沙箱外卷权限的进程，先暂存 `${TMPDIR}` 再拷进本目录）。

**2026-10-29 这一天跑了三遍，本目录的帧不是同一遍的**（所以下面「帧」列的 marker 一律指 passed 那份日志，除 `ios-rail.png`）：

| 日志 | 结果 | 用途 |
| --- | --- | --- |
| [ios-live-2026-10-29-failed.log](ios-live-2026-10-29-failed.log) | 13 个 `shot=` 之后 `Some tests failed`（`theme-two` 那一步上游 `themes` 返空，夹具当时还不肯放过这种形状） | 只留作「夹具为什么长现在这样」的记录 |
| [ios-live-2026-10-29-rail-frame.log](ios-live-2026-10-29-rail-frame.log) | `01:13 +1: All tests passed!`，16 帧，开机 `themes` 回了 29 条 | **只有 `ios-rail.png` 取自这一遍** |
| [ios-live-2026-10-29-passed.log](ios-live-2026-10-29-passed.log) | `01:26 +1: All tests passed!`，16 帧，本轮所有结论押的这一遍 | 本目录其余 `ios-*` 帧、以及下面全部读数 |

passed 这一遍开机那一步 `themes` 又整段返空（`rows-timeout where=rail pane=1 loading=false error=内容接口未返回数据，请稍后重试`，日志 :11），所以那一帧拍到的是重试胶囊而不是 29 条胶囊——按 project memory 的口径（上游偶发返空先重跑再定性），`ios-rail.png` 用 rail-frame 那一遍的（`enter-categories destination=1 genre=short_play theme=null themes=29`），其余帧全用 passed 这一遍。`build/verification/theme-rail/run.log` 是 passed 这一遍的运行时副本。上一轮（§12，v0.3.7 那批）的日志仍留在 [ios-live-2026-10-28.log](ios-live-2026-10-28.log)。

验收口径：一次手势最多换一层。最内层（题材）必须滑到没有可滑的，才把这一拉交给类型；类型也没有了，才交给 shell 的 发现↔分类。交接不能跳级，也不能在还有余量时提前跳。上下滑时顶段折叠，但**两级筛选行都留在屏上**（本轮改的就是这条），而且每条横行自己把选中那枚揭示进可见区。

## 结论速览（本轮四个读数）

| 读数（日志行） | 证明的事 | 帧 |
| --- | --- | --- |
| `band-collapsed collapsed=true rail-top=114 choices-top=62 offset=1580` | 列表滚到 1580 之后，顶段（搜索框/离线检查/滑动提示）已经离开，一级行仍在 y=62、二级条仍在 y=114：两级筛选都摸得着（旧版这里只剩二级条） | [ios-band-collapsed.png](ios-band-collapsed.png) |
| `filters-answered-folded genre=comic_series was=short_play collapsed=true offset=0 chip-in-row=true` | **还保持着折叠**就把类型换掉了，一级行自己滚到 ✓漫剧；不需要先滚回顶部找筛选 | [ios-filters-answered-folded.png](ios-filters-answered-folded.png) |
| `genre-handover from=short_play/cate_1240 to=comic_series/ chip-in-strip=true chip=0..124 strip=0..402 px=12` | 条尽头那一拉交给类型之后，新内容的选中那枚（全部 · 漫剧）被揭示回条内。同一个 marker 在上一轮是 `false`，本轮第 4 条那个记账修法之后翻成 `true` | [ios-genre-handover.png](ios-genre-handover.png) |
| `handover to=0 theme-pulls=0 genre-pulls=0 first-answer=shell` | 分类 已在自己第一页且二级在 全部，第一拉直接上交回 发现（三级交接本身没被本轮改动碰坏） | [ios-tab-swipe-to-discover.png](ios-tab-swipe-to-discover.png) |

## 帧索引（按 passed 日志的 marker 顺序）

| 帧 | marker | 画面里的状态 |
| --- | --- | --- |
| [ios-rail.png](ios-rail.png) | rail-frame 那遍：`enter-categories destination=1 genre=short_play themes=29` → `shot=rail` | 进入 分类：一级 ✓短剧，二级条首枚「全部 · 短剧」+ 悬疑/宫斗/脑洞/青春，live themes 回了 29 条 |
| [ios-genre-comic.png](ios-genre-comic.png) | `shot=genre-comic genre=comic_series level2=` | 点 漫剧 之后：一级 ✓漫剧、二级条整行换成漫剧的题材且从「✓全部 · 漫剧」起（列表还在骨架）——本轮目视复核过 |
| [ios-level2-first-pull.png](ios-level2-first-pull.png) | `shot=level2-first-pull from=short_play/ to=short_play/cate_165 chip-in-strip=true chip=124..207 strip=0..402 px=0` | 一拉之内二级自己换了一页（一级与 shell 都没动），选中那枚整枚在条内 |
| [ios-genre-handover.png](ios-genre-handover.png) | `shot=genre-handover ... chip-in-strip=true ...` | 条尽头再一拉：一级换成 漫剧、二级归零并留在条内；标题「符合筛选的故事 · 漫剧」——本轮目视复核过 |
| [ios-tab-swipe-to-discover.png](ios-tab-swipe-to-discover.png) | `handover to=0 ... first-answer=shell` → `shot=tab-swipe-to-discover` | 落回 发现：模式行 ✓推荐 + 一级 ✓短剧 + 二级「全部 · 短剧」，标题「为你发现 · 短剧」 |
| [ios-mode-latest.png](ios-mode-latest.png) | `shot=mode-latest view=latest` | 点 最新 胶囊（本轮它是模式，不是页）：标题换成「最新上架 · 短剧」，取数换成 `online_time` |
| [ios-rank.png](ios-rank.png) | `shot=rank level2=board:recommend genre-row=0` | 榜单态：类型整行退场（`genre-row=0` 就是这条断言的读数），二级条换成 推荐榜/热播榜/新剧榜 |
| [ios-rank-board.png](ios-rank-board.png) | `shot=rank-board from=board:recommend to=board:hot` | 榜单档就是这一层的可滑页：一拉换到 热播榜 |
| [ios-band-collapsed.png](ios-band-collapsed.png) | `shot=band-collapsed collapsed=true rail-top=114 choices-top=62 offset=1580` | 折叠态：搜索框不在了，两条筛选行都还在顶上（模式/类型一行 + 题材一行），网格在下面滚——本轮目视复核过 |
| [ios-filters-answered-folded.png](ios-filters-answered-folded.png) | `shot=filters-answered-folded genre=comic_series was=short_play collapsed=true offset=0 chip-in-row=true` | 折叠态下换完筛选的那一屏：一级行自己滚到 ✓漫剧（`推荐` 三枚滑出左缘）、二级条「✓全部 · 漫剧」起、标题「为你发现 · 漫剧」——本轮目视复核过 |
| [ios-band-expanded.png](ios-band-expanded.png) | `shot=band-expanded collapsed=false offset=0` | 滚回顶部顶段自己回来：搜索框 + 一级行 + 二级条同屏（这一形状在本目录每张展开态帧里都看得见） |
| [ios-tab-swipe-to-categories.png](ios-tab-swipe-to-categories.png) | `end-of-levels genre=ai_series chips=9` + `shot=tab-swipe-to-categories from=ai_series/cate_1182` | 发现 停在最后一个类型、二级已经滑到它自己最后一条题材（这一遍上游回了 9 条，上一轮那遍是返空），于是第一拉归 shell：底部选中 分类 |
| [ios-theme-two.png](ios-theme-two.png) | `shot=theme-two level2=cate_262 chip-in-strip=false chip=-20..63 strip=0..402 px=285` | 点第三条题材（脑洞）：换一套行、标题「符合筛选的故事 · 短剧 · 脑洞」；**选中那枚被左缘切掉 20 px**，即「本轮没解释清楚的那一条」——本轮目视复核过 |
| [ios-theme-two-before-2026-10-28.png](ios-theme-two-before-2026-10-28.png) | 上一轮同名 marker：`shot=theme-two level2=cate_262` | §12 第 11 条「已知未修」那一条的原始实例（同一种切半枚，但那时二级条是吸顶的、顶段把一级行也带走了）。这枚是本轮重录时从上一轮树上**原样另存**的，不是新拍的（md5 `4cb9110c…`） |
| [ios-theme-two-scrolled.png](ios-theme-two-scrolled.png) | `shot=theme-two-scrolled offset=400` | 该题材的列表在自己里面下滚到 400 |
| [ios-theme-three.png](ios-theme-three.png) | `shot=theme-three level2=cate_297` | 换到第四条题材：另一套行、另一个偏移 |
| [ios-theme-two-restored.png](ios-theme-two-restored.png) | `shot=theme-two-restored offset=400 was=400` | 回切第三条题材仍是 400 那一屏：每条题材各留一套行、一个游标、一个纵向偏移 |

## 本轮三处如实记下

- **`theme-two` 那个读数没有修好**：`chip-in-strip=false chip=-20..63 px=285`。同一形状在 widget 测试里复现不出来（`test/catalog_tabs_test.dart:529` 那条 `a rail chip tapped from the edge of the strip is shown whole` 通过），所以本轮只把机制猜了两条（夹具自己那次 `ensureVisible` 还在飞 / 这一遍该桶上游返空过），写在 `docs/design/discover-catalog-cascade-tabs.md` §13 第 7 条，不当作已修。
- **折叠态下顶段不会自己回来**：`filters-answered-folded` 那行读数是 `collapsed=true offset=0`——列表已经在顶部，顶段（搜索框）还收着，因为翻 `bandCollapsed` 的只有 feed 的滚动 listener。本轮有意没动，理由见 §13 第 8 条。
- **帧的来源混了两遍**（见开头那张表）：`ios-rail.png` 与其余 15 张不是同一次运行，passed 那遍的 `rail` 拍到的是重试胶囊。上一轮记的「`ios-genre-comic.png` 与 `ios-genre-handover.png` 字节相同」这一轮不再成立：现读 md5 `7f3fdac6…` 与 `08fe2a0f…`，两张是不同的一屏（前者 07:54 骨架 + 漫剧题材条，后者 07:55 交接落点）。

## 与 macOS 帧的关系

本目录**无前缀**的 `discover.png`、`rail.png`、`rank.png`、`genre-comic.png`、`theme-*.png` 是更早那轮（提交 `60db477`）的 macOS 全屏录制裁剪帧，画面结构还是 band 之前那一版；`sheet-before.png` 是更早的基线。`ios-discover.png`、`ios-inner-latest.png`、`ios-inner-categories-last.png`、`ios-tab-swipe-back-to-discover.png` 是 v0.3.6 那一轮（两级、band 全程固定）的帧，本轮没有同名 marker，所以它们保持原样作为上一版的对照。本轮 macOS 那一路仍只录到桌面壁纸，所以当前结构的实机证据只有本批 `ios-*`（现读 21 张 `ios-*.png`）。macOS 单窗口录制在本机不可用这条见 `docs/evidence/` 说明与 `docs/design/discover-catalog-cascade-tabs.md` §11 第 10 条。
