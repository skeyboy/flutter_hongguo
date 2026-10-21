# 搜索聚焦下拉：最近搜索与推荐位

搜索框获得焦点后向下弹出面板，左侧能力是本地历史、右侧能力是上游榜单。PC 与 mobile 共用同一套交互，差别只在键盘与触屏：PC 用 Tab/点击聚焦并以 ESC 收起，mobile 点击聚焦、返回手势收起。

## 交互

- 聚焦即弹。文本变化会重算历史匹配；输入非空时不再请求推荐位，因为下方结果区已经在回答这个词。
- 历史显示 `SearchHistory.shown`（3）条，最新在前；一旦输入内容，只显示包含该串的历史（不区分大小写）。
- 推荐位显示标题 + 一个标记图标：`fiber_new_rounded`（最新上架）或 `local_fire_department_rounded`（热度上榜），带 Tooltip。不显示封面与简介，行高紧凑，与历史行视觉同级但不混淆。
- 每条历史行尾部一个删除按钮，删除后面板保持打开；只有历史和推荐都空了才收起，并把光标留在输入框里。
- 点历史行 = 填入关键词并立即执行搜索；点推荐行 = 直接进详情页，不改动搜索状态、不发起搜索请求。
- 面板挂在 `Overlay` 而不是页面列里：Dart 的 `RenderBox.hitTest` 只在 `size.contains(position)` 时成立，写在列里的下拉能被画到筛选行上方却点不中。
- 面板与输入框共用一个 `TextFieldTapRegion(groupId: searchTapGroup)`。默认 `groupId` 是 `EditableText`，不同组时按下行会先触发失焦、面板被移除、点击丢失。
- 关闭路径：遮罩点击、ESC、返回手势（`PopScope.canPop = !filterOpen && !suggestionsOpen`）、选中任一行的处理函数。层级上面板优先于筛选面板。
- 面板打开时 `_nearEnd` 直接返回，避免滚动条到底触发分页与下拉打架。

## 最近搜索的存储

`packages/app/lib/search/search_history.dart` 单独成文件、单独成盘文件（`<support>/search-history.json`，`FilePreferencesBackend` 原子 tmp+rename）。放进 `PersonalLibrary` 也能跑，但那里每次编辑都会重写全部观看记录，输入一次搜索不该付这个代价。格式 `{version: 1, queries: [...]}`，去空白、去重、上限 `retained`（12）条；版本号不匹配抛 `StateError`，不静默清空用户历史。写操作串行，写失败时内存列表保留但视为未保存。非原生运行时（web、单测）走 `searchHistoryFor()` 的 `Expando` 兜底，历史只在当次会话内，不假装持久化。

## 推荐位取数

`SearchSuggester` 读取上游真实存在的两个榜单：`sort=online_time` 标「最新」、`sort=hot_score` 标「热门」，两个请求并行发出，按 id 去重后交替合并，上限 6 行，`genre` 跟随当前页面。单个榜失败返回空列表，另一个榜照常出，历史不受影响。结果只留内存、10 分钟新鲜期、同 genre 请求去重；不写 `LibraryCache`——那是 7 天磁盘快照，一条被标成「最新」的旧数据是假的。设备标识轮换后使用调用方传入的当前 client，不会从缓存里读到旧身份的结果。

## 标记语义与后端配合清单

`Drama` 只有 id/title/cover/intro/episodeCount，`/api/v1/recommend/list` 对 `short_play` 返回的 rows 不带 `published_at`、`score` 或 `rank`。因此图标只能声明「这一行来自哪个榜单」，不能声明「今天上架」或热度数值。

1. 推荐接口给 `short_play` 返回带类型的推荐位（最新/热门/榜单）与 `rank`，前端就不必用 `browse` 拼两个榜，图标语义也能升级成真实排序。
2. 需要「新」的硬语义时补 `published_at` 或 `first_online_at`；否则文案停在「最新上架」。
3. 搜索历史清零、跨端同步需要接口；本期纯本地，删除只影响本机。
4. 输入联想（term 补全）若有接口，面板可切换为词列表；本期只有本地包含匹配。

## 验收状态

已自动化：`packages/app/test/search_history_test.dart` 7 例（顺序与去重、空白与上限、输入匹配、单条删除、重新载入、写失败不假装保存、异版本拒读），`packages/app/test/search_suggestions_test.dart` 5 例（聚焦弹出后历史 3 行与标记数量、历史行搜索与删除不关面板、推荐行直接进详情且不触发搜索请求、遮罩关闭后重开命中缓存不再请求、榜单不可用时历史仍可用）。app 全量 176 例通过（1 skip）、`dart analyze --fatal-infos` 无 issue、`dart format` 干净。

未做：真机与桌面的窗口内人工验证。原生窗口禁止用合成点击驱动（点击会逃逸到其他应用），聚焦触发的下拉无法用自动化在设备上证明；本段结论只到 widget 层，不代表 Android/iOS/桌面实测通过。
