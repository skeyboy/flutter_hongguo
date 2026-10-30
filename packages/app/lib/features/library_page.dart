import '../navigation/app_navigation.dart';

import 'dart:async';
import 'dart:convert';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';

import '../platform/background/host_policy.dart';
import '../platform/runtime.dart';
import '../widgets/anchored_panel.dart';
import '../widgets/brand.dart';
import '../widgets/drama_card.dart';
import '../widgets/drama_cover.dart';
import '../widgets/hover_peek.dart';
import '../widgets/sort_menu.dart';

export '../widgets/brand.dart';
export '../widgets/drama_card.dart';
export '../widgets/drama_cover.dart';
import '../catalog/library_cache.dart';
import '../search/search_history.dart';
import '../search/search_suggestions.dart';
import '../ranking/ranking_controller.dart';
import '../ranking/ranking_page.dart';
import '../ranking/rank_entry_card.dart';
import 'detail_page.dart';
import 'discover_filter_panel.dart';
import 'library/library_page_state.dart';
import 'my_page.dart';

/// Both filter rows -- the choices above and the theme rail below -- hold this
/// height in every state (chips, spinner, retry), so the two rows of one family
/// read as one block and pinning the rail can never nudge the rows below it.
const _filterRowHeight = 52.0;

/// How many chips a filter row of the mouse family shows before 更多 ▾（n）takes
/// the rest. The prototype's own limit, and the one the widest measured row can
/// be trusted with: 主题 runs to 29 items and 设定 to 42, and a row that has to be
/// slid sideways to be read is not a row a pointer reads.
const _desktopRowMax = 8;

/// The three types, in the one place that names them: the level shared by both
/// pages and the parent name the theme rail carries.
const _genreNames = {
  'short_play': '短剧',
  'comic_series': '漫剧',
  'ai_series': 'AI 短剧',
};

/// The 赛道 that ranks one type, which is the same domain under the ranking
/// endpoint's own name -- upstream publishes it in `cell_selector`, and four
/// samples gave the same three words back each time. 演员赛道 has no type behind
/// it, so it appears nowhere here: a card of a type never points at it.
const _rankTrackByGenre = {
  'short_play': 'human',
  'comic_series': 'comic_series_rank',
  'ai_series': 'ai_playlet',
};

class LibraryPage extends StatefulWidget {
  final AppRuntime runtime;
  const LibraryPage({super.key, required this.runtime});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends LibraryPageStateBase {
  /// 发现 and 分类 are two pages of one catalog, and both of them are alive for
  /// as long as a swipe is in flight -- so everything a page owns (its search
  /// field, its focus, its scroll position, its query text) is held once per
  /// page. A `TextEditingController` and a `ScrollController` can each only be
  /// attached to one live widget, which is what forces the split.
  ///
  /// The value itself is a top-level constant: `panes` is read by the methods
  /// that still live here, while the fields that were built from it now live one
  /// level up, and a `static` is not inherited.
  static const panes = kDiscoverPanes;

  /// Which first-level page of the page the shell is asking about right now.
  /// Both pages answer with the shared 类型, which is the whole point of the
  /// cascade: 一级 means the same thing over there as it does here.
  String slotOfPane(int pane) => genre;

  ScrollController scrollAt(_ThemeFeed feed) =>
      feedScroll.putIfAbsent(feed.key, () {
        final controller = ScrollController();
        // Each list asks for its own next page, through the record that belongs
        // to it, and tells its own page whether the band above it has been
        // scrolled far enough to get out of the way.
        controller.addListener(() {
          _nearEnd(feed);
          _trackCollapse(feed);
        });
        return controller;
      });

  /// The list of one feed record, looked up through the record itself. A late
  /// response and a pending debounce only ever know the record they belong to.
  ScrollController scrollOf(_ThemeFeed feed) => scrollAt(feed);

  PageController levelAt(int pane, String slot) =>
      levelScroll[pane]!.putIfAbsent(
        slot,
        () => PageController(initialPage: level2IndexOf(pane, slot)),
      );

  /// 题材按父类型分桶：一级成为可横滑的页之后，拖拽中邻页也会铺出自己的二级栏，
  /// 而它要的是自己那个类型的题材，不是当前类型的那一份（换类型清空重转圈因此
  /// 没有了，一次上游返空也只脏它自己那一桶）。
  final themesByGenre = <String, _ThemeBucket>{};
  final autoScheduled = <_ThemeFeed>{};

  /// The bucket of the type currently on screen -- the rail the viewer is
  /// looking at, and what the live fixture reads back.
  List<CatalogFilter> get themes => themesOf(genre).values;
  bool get themesLoading => themesOf(genre).loading;
  String? get themesError => themesOf(genre).error;

  _ThemeBucket themesOf(String genre) =>
      themesByGenre.putIfAbsent(genre, _ThemeBucket.new);

  /// One entry per feed the viewer has opened, keyed by [feedKeyOf]. A theme the
  /// viewer already scrolled through keeps its rows, cursor and scroll offset
  /// here instead of being rebuilt from the disk snapshot on every visit.
  ///
  /// Both pages are alive at once, so every record carries the pane it belongs
  /// to and the key it was made under: a response that lands late has to be
  /// filed in the feed that asked for it, not in whichever page is on screen.
  final feeds = <String, _ThemeFeed>{};
  String _activeKey = '';

  /// The request one list would ask for. The key carries its own first level and
  /// its own second level, so a swipe can show what the page next to it holds
  /// while the drag is still moving, and a response that lands late is filed
  /// where it was asked for. 类型 is the shared 一级 and 题材 the shared 二级 --
  /// both pages read them the same way, see
  /// docs/design/discover-catalog-cascade-tabs.md.
  String feedKeyAtLevel(int pane, String slot, String level2) => jsonEncode({
    'destination': pane,
    'query': queryOf(pane),
    // 推荐/最新 两枚 chip 让位给 L3 之后，这一维恒为默认值。键的形状保持原样：
    // 磁盘上已有一版保活快照是按这个形状存的，动它等于把观众已经翻过的页丢掉。
    'view': 'recommend',
    'genre': slot,
    'sort': sortFor(pane, slot),
    // 题材 narrows both pages' browse; 搜索 takes neither, so it stays out of
    // those keys rather than silently narrowing a feed that would ignore it.
    'theme': _themeOfLevel2(level2),
    // L2′ the same way, and only while something is actually picked: a key that
    // changed shape every time a viewer opened the app would throw away the
    // snapshot on disk for a dimension nobody used.
    if (_orderedDims.isNotEmpty) 'dims': _orderedDims,
  });
  String feedKeyAt(int pane, String slot) =>
      feedKeyAtLevel(pane, slot, level2At(pane, slot));

  /// The second level is a theme id, empty for 全部 and null while the endpoint
  /// would ignore it.
  String? _themeOfLevel2(String level2) => level2.isEmpty ? null : level2;

  /// [dims] in upstream's own key order: picking 设定 then 背景 and picking 背景
  /// then 设定 have to be one feed record, not two that ask the same question
  /// twice. 「不限」removes its key, so what is in here is what the viewer answered.
  Map<String, List<String>> get _orderedDims => {
    for (final key in catalogDimKeys) key: ?dims[key],
  };

  /// The dimensions a feed record was asked for, read back off its own key: the
  /// request that lands late belongs to the selection that made it, not to
  /// whichever chips the row holds now. 题材 is not in here -- it is the key's own
  /// `theme` field, the level the second row is made of.
  Map<String, List<String>> _dimsOfKey(String key) {
    final raw = paramsOf(key)['dims'];
    if (raw is! Map) return const {};
    return {
      for (final entry in raw.entries)
        '${entry.key}': [for (final id in entry.value as List) '$id'],
    };
  }

  /// The one word a second-level page is filed under in every key and controller
  /// that has to be unique inside its own first-level page.
  static String level2Slug(String level2) => level2.isEmpty ? 'all' : level2;

  String feedKeyOf(int pane) => feedKeyAt(pane, slotOfPane(pane));
  String get feedKey => feedKeyOf(destination);
  _ThemeFeed get feed => feedOf(destination);

  /// How many kept-alive feeds the shell holds. The disk snapshot is bounded by
  /// `LibraryCache` (80 keys, seven days); this is the same promise for the
  /// rows in memory, which a free-text search would otherwise grow without
  /// limit -- one retained page per term typed.
  static const _feedKeep = 32;

  _ThemeFeed feedAt(int pane, String slot) =>
      feedAtLevel(pane, slot, level2At(pane, slot));

  /// The record of one second-level page of one first-level page. A swipe lays
  /// the theme next to this one out while the drag is still moving, so the
  /// record has to be reachable by name rather than only through whichever
  /// choice the shell's state currently holds.
  _ThemeFeed feedAtLevel(int pane, String slot, String level2) {
    final key = feedKeyAtLevel(pane, slot, level2);
    final kept = feeds.putIfAbsent(
      key,
      () => _ThemeFeed(key, pane, slot, level2),
    );
    if (feeds.length > _feedKeep) _evictFeeds();
    return kept;
  }

  _ThemeFeed feedOf(int pane) => feedAt(pane, slotOfPane(pane));

  /// Drops the oldest feeds no page is reading. The two pages' own first-level
  /// pages stay whatever their state, and a record with a request still running
  /// stays too -- its response has somewhere to land.
  void _evictFeeds() {
    final keep = {for (final p in panes) feedKeyOf(p), _activeKey};
    for (final entry in feeds.values.toList()) {
      if (feeds.length <= _feedKeep) return;
      if (keep.contains(entry.key)) continue;
      if (entry.loading || entry.refreshing || entry.loadingMore) continue;
      entry.revision++;
      entry.scope.cancel();
      feeds.remove(entry.key);
      // The record's own list goes with it -- but only once nothing is laid out
      // under that key, since a controller with a live client is a page the
      // viewer can still see.
      final orphan = feedScroll.remove(entry.key);
      if (orphan != null) {
        if (orphan.hasClients) {
          feedScroll[entry.key] = orphan;
        } else {
          orphan.dispose();
        }
      }
      feedFilterTimer.remove(entry.key)?.cancel();
    }
  }

  /// Which page a feed record belongs to, read back out of its own key. A timer
  /// or a late response only ever knows the record, never the current screen.
  int paneOf(String key) => (jsonDecode(key) as Map)['destination'] as int;

  /// The request itself is asked of the record's own key, not of the shell's
  /// current state: with several first- and second-level pages alive at once,
  /// the record that is fetching is not necessarily the one on screen.
  Map<String, dynamic> paramsOf(String key) =>
      Map<String, dynamic>.from(jsonDecode(key) as Map);

  String queryOf(int pane) => paneQuery[pane]!;

  /// Which second-level page of one first-level page is on it, in the one
  /// notation the level-2 controllers, chips and swipe order all share.
  /// The shared 题材 pick counts only on the page it was made under: a
  /// neighbour page dragged in mid-swipe is a different type, and a theme id
  /// from this one means nothing there.
  String level2At(int pane, String slot) => slot == genre ? theme ?? '' : '';

  /// Where that page sits in its own level's swipe order. A theme the rail has
  /// not been given yet (its type's list is still on its way) reads as 全部, so
  /// the pager never points past what the page can paint.
  int level2IndexOf(int pane, String slot) {
    final wanted = level2At(pane, slot);
    final options = level2Options(pane, slot);
    for (final (index, option) in options.indexed) {
      if (option.id == wanted) return index;
    }
    return 0;
  }

  /// The id a second-level page names, read back out of its own option.
  ({String id, String label}) level2OptionAt(int pane, String slot, int index) {
    final options = level2Options(pane, slot);
    return options[index.clamp(0, options.length - 1)];
  }

  /// The second level of one first-level page, in swipe order: 全部 first, then
  /// the children of the type that page is about.
  List<({String id, String label})> level2Options(int pane, String slot) {
    if (queryOf(pane).isNotEmpty) {
      return const [(id: '', label: '全部')];
    }
    return [
      // The parent name rides along, so what this row is a child of is on
      // screen rather than remembered.
      (id: '', label: '全部 · ${_genreNames[slot] ?? slot}'),
      if (slot == genre)
        for (final e in themesOf(slot).values) (id: e.id, label: e.name),
    ];
  }

  /// 最新 is a mode the viewer picks, so it has to move the rows: it asks the
  /// catalog for the newest online date instead of the configured sort. The
  /// other modes keep whatever sort the viewer set in 设置.
  ///
  /// On the mouse family the L3 dropdown replaces both of those words and writes
  /// [paneSort] -- the one 档 actually in force, which is what its chip has to
  /// read back. A page that has not been touched keeps 设置's value, so 排序 stays
  /// a per-page state that never reaches behind the viewer's back into 设置.
  String sortFor(int pane, String slot) {
    final picked = paneSort[pane];
    if (picked != null) return picked;
    return settingsFor(widget.runtime).catalogSort;
  }

  /// Made once from the runtime's catalog and never replaced, so the boards the
  /// viewer already scrolled through are still there when they come back.
  RankingController? _ranking;
  RankingController get ranking {
    final existing = _ranking;
    if (existing != null) return existing;
    final controller = RankingController(catalog: widget.runtime.catalog)
      ..addListener(_applyRankDrill);
    // 触控族的入口卡把榜单的行借到发现页上来（§4「发现页唯一一处允许出现榜单内容」），
    // 所以这一页也得听见榜单的动静：卡上的行是等回来的，不是第一次铺就能有的那一帧。
    // 桌面没有这张卡，也就不多这一个重画。
    if (!desktopHost) controller.addListener(_onRankingFeed);
    return _ranking = controller;
  }

  /// 榜单那边有动静了，而这一页正把入口卡铺在 发现 上。榜自己盖着的时候不用重画：
  /// 那一页自己听着同一份内容。
  void _onRankingFeed() {
    if (!mounted || rankOpen) return;
    setState(() {});
  }

  /// 入口卡要的那一份内容，第一次铺 触控族 的 发现 页时去要一次。放在铺页之后而不是
  /// 铺页当中，因为建这一页不该顺手造出一个控制器来；`open()` 自己认「回过的榜不再
  /// 问」，所以这一趟要么真的发一次请求，要么立刻回来。
  bool _rankEntryWarmed = false;
  void _warmRankEntry() {
    if (_rankEntryWarmed) return;
    _rankEntryWarmed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ranking.open());
    });
  }

  /// 榜的名字用它自己的词：上游发的 赛道 与 榜块，一个都不写死（§5「禁止再写死榜名」
  /// 同一条规矩）。还没回话时没有名字可借，那时这张卡也还没有行可排。
  String get _rankEntryTitle {
    final controller = _ranking;
    if (controller == null) return '';
    final track = controller.selectedTrack?.label;
    String? board;
    for (final value in controller.boards) {
      if (value.id == controller.board) board = value.label;
    }
    return [?track, ?board].join(' · ');
  }

  /// Once the 赛道 tree is on screen, honour the drill that asked for it. A 榜 the
  /// 赛道 never published leaves the answer's own default alone -- upstream marked
  /// one `is_selected`, and that is a truer word than a guess.
  void _applyRankDrill() {
    final wanted = rankDrillTrack;
    if (wanted == null || ranking.tracks.isEmpty) return;
    final hot = _hotBoardOf(wanted);
    // 树已经到手却没有热播榜：这个赛道不欠这个名字，上游的默认榜作数，心愿到此为止。
    rankDrillTrack = null;
    if (hot == null || ranking.board == hot) return;
    ranking.selectBoard(hot);
  }

  /// Folded once the list of the page on screen has gone past the height of the
  /// band it is scrolling under, and unfolded again only near the top -- the gap
  /// between the two is what stops a list a little longer than a screen from
  /// flickering the band open and shut on every pixel.
  static const _collapseAfter = 40.0, _collapseBefore = 8.0;

  /// A row -- or a page -- that has run out of width hands the rest of the drag
  /// one level up, which is what lets 推荐 → 最新 → 榜单 be reached from inside
  /// the chip rows, and 发现 → 分类 reached once the inner pages have run out.
  static const _edgePullExtent = 48.0;

  /// The levels a swipe can hand over clamp instead of rubber-banding. Only a
  /// clamping position reports the pull it could not apply as an
  /// `OverscrollNotification`, and that report is what every handover below
  /// counts: under the iOS bounce the same delta becomes out-of-range pixels,
  /// nothing bubbles up, and the level above never hears of the drag -- so on
  /// iPhone the edge would stop being an edge and just stretch.
  static const ScrollPhysics _handoverPhysics = PageScrollPhysics(
    parent: ClampingScrollPhysics(),
  );
  static const ScrollPhysics _rowPhysics = ClampingScrollPhysics();

  ScrollController rowAt(String key) =>
      rowScroll.putIfAbsent(key, ScrollController.new);

  GlobalKey rowContentAt(String key) =>
      rowContent.putIfAbsent(key, GlobalKey.new);

  /// Records what a row has to show and asks the frame after this one to move
  /// only that row. `Scrollable.ensureVisible` is not usable here: it walks
  /// every ancestor viewport, and these rows live inside the first-level pages,
  /// so one reveal could turn a level or the shell the drag never asked to.
  void _trackBandTarget(String rowKey, int index, [String content = '']) {
    if (index < 0) return;
    final pair = '$content|$index';
    if (bandShown[rowKey] == pair && !bandOwed.contains(rowKey)) return;
    bandShown[rowKey] = pair;
    bandOwed.add(rowKey);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _revealBandTarget(rowKey, pair, index),
    );
  }

  /// The smallest movement of this row's own offset that puts the chip back
  /// inside the row. Nothing moves when it already is: the row the viewer is
  /// reading is not re-arranged under their finger because a level settled.
  void _revealBandTarget(String rowKey, String pair, int index) {
    if (!mounted || bandShown[rowKey] != pair) return;
    if (!rowScroll.containsKey(rowKey)) return;
    final content = rowContentAt(rowKey).currentContext?.findRenderObject();
    final controller = rowScroll[rowKey]!;
    if (content is! RenderBox || !controller.hasClients) return;
    final laidOut = <RenderBox>[];
    content.visitChildren((child) {
      if (child is RenderBox) laidOut.add(child);
    });
    if (laidOut.length <= index) return;
    final chip = laidOut[index];
    final viewport = RenderAbstractViewport.maybeOf(chip);
    if (viewport == null) return;
    final position = controller.position;
    if (position.isScrollingNotifier.value) return;
    // Leading edge of the row for a chip left behind, trailing edge for one not
    // yet reached -- whichever way it needs moving is the way that costs least.
    final revealStart = viewport.getOffsetToReveal(chip, 0.0).offset;
    final revealEnd = viewport.getOffsetToReveal(chip, 1.0).offset;
    // `revealEnd > revealStart` says the chip is wider than the row it has to be
    // shown in (the two offsets differ by exactly chipWidth - viewportWidth), so
    // no offset shows it whole and the promise has one part left to keep: the
    // leading edge, which is where the name is read from. Reaching for the
    // trailing edge here would slide that off the left -- and the pinned tail of
    // the touch family's row makes an ordinary 题材 name over-wide on a narrow
    // window.
    final double? wanted;
    if (revealEnd > revealStart) {
      wanted = (revealStart - position.pixels).abs() > 0.5 ? revealStart : null;
    } else {
      wanted = revealEnd > position.pixels
          ? revealEnd
          : revealStart < position.pixels
          ? revealStart
          : null;
    }
    bandOwed.remove(rowKey);
    if (wanted == null) return;
    unawaited(
      position.animateTo(
        wanted.clamp(position.minScrollExtent, position.maxScrollExtent),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  bool _onNestedScroll(ScrollNotification notification) {
    // The page list itself is depth 0 and already pages on a swipe.
    if (notification.depth == 0) return false;
    if (notification is ScrollStartNotification ||
        notification is ScrollEndNotification) {
      edgePull = 0;
      return false;
    }
    if (notification is! OverscrollNotification) return false;
    final overscroll = notification.overscroll;
    // Only a drag: momentum has no intent behind it, and only a row lying
    // across the axis -- the list running out of rows vertically is not a
    // reason to leave the page.
    if (overscroll == 0 ||
        notification.dragDetails == null ||
        notification.metrics.axis != Axis.horizontal) {
      edgePull = 0;
      return false;
    }
    // Turning around at the edge is a new question, not a refund of the pull
    // already spent.
    if (overscroll.sign != edgePull.sign) edgePull = 0;
    edgePull += overscroll;
    if (edgePull.abs() < _edgePullExtent) return false;
    final wanted = edgePull > 0 ? destination + 1 : destination - 1;
    edgePull = 0;
    // 我的 is not in the swipe, and nothing lies before 发现.
    if (panes.contains(wanted)) _selectTab(wanted);
    return false;
  }

  /// The pinned second-level row of one page, asked about a drag that ran out of
  /// row width inside it. The row is the strip of the level the viewer is
  /// already on, so what is left of that pull belongs to the level above it --
  /// the type. What this page cannot spend (there is no type that way, or the
  /// mode takes no type at all) it hands to the shell with the count dropped, so
  /// the same pull is never spent twice.
  bool _onRowScroll(int pane, ScrollNotification notification) {
    if (notification is ScrollStartNotification ||
        notification is ScrollEndNotification) {
      bandEdgePull[pane] = 0;
      return false;
    }
    if (notification is! OverscrollNotification) return false;
    final overscroll = notification.overscroll;
    if (overscroll == 0 ||
        notification.dragDetails == null ||
        notification.metrics.axis != Axis.horizontal) {
      bandEdgePull[pane] = 0;
      return false;
    }
    var pull = bandEdgePull[pane] ?? 0;
    if (overscroll.sign != pull.sign) pull = 0;
    pull += overscroll;
    final tabs = innerTabs[pane];
    final wanted = tabs == null ? -1 : tabs.activeIndex + (pull > 0 ? 1 : -1);
    if (queryOf(pane).isNotEmpty ||
        tabs == null ||
        !slotSets[pane]!.asMap().containsKey(wanted)) {
      // Nothing lies that way inside this page. Hand the whole drag to the
      // shell from here, so what this level counted is not counted twice.
      bandEdgePull[pane] = 0;
      return false;
    }
    if (pull.abs() < _edgePullExtent) {
      bandEdgePull[pane] = pull;
      // Spent here, so it is not spent again one level up.
      return true;
    }
    bandEdgePull[pane] = 0;
    tabs.setActiveIndex(wanted);
    return true;
  }

  /// One page's own first level, asked about a drag whose innermost list has run
  /// out of pages. `depth` counts the viewports a notification bubbled through
  /// on the way here, so the listener wrapping a page's first-level pager hears
  /// that pager at 0 and the second-level pages inside it at 1 and deeper --
  /// which is what keeps one gesture to one level: the pull is spent on the
  /// narrowest question still open, and only what this level cannot spend is
  /// handed further up, where the other tab of the catalog waits.
  bool _onLevelScroll(int pane, ScrollNotification notification) {
    if (notification is ScrollStartNotification ||
        notification is ScrollEndNotification) {
      levelEdgePull[pane] = 0;
      return false;
    }
    // The first-level pager already pages on a swipe of its own; nothing here is
    // a handover from below.
    if (notification.depth == 0) return false;
    if (notification is! OverscrollNotification) return false;
    final overscroll = notification.overscroll;
    if (overscroll == 0 ||
        notification.dragDetails == null ||
        notification.metrics.axis != Axis.horizontal) {
      levelEdgePull[pane] = 0;
      return false;
    }
    var pull = levelEdgePull[pane] ?? 0;
    if (overscroll.sign != pull.sign) pull = 0;
    pull += overscroll;
    final tabs = innerTabs[pane];
    final wanted = tabs == null ? -1 : tabs.activeIndex + (pull > 0 ? 1 : -1);
    // 搜索 asks `search(query)`, which takes neither genre nor theme: three
    // identical type pages would be a false control, so the pull goes straight
    // up to the tab.
    final canPage = queryOf(pane).isEmpty;
    if (!canPage ||
        tabs == null ||
        !slotSets[pane]!.asMap().containsKey(wanted)) {
      levelEdgePull[pane] = 0;
      // Not spent here, so the level above gets the whole of it.
      return false;
    }
    if (pull.abs() < _edgePullExtent) {
      levelEdgePull[pane] = pull;
      // Counted here, so the shell cannot count the same pull a second time.
      return true;
    }
    levelEdgePull[pane] = 0;
    tabs.setActiveIndex(wanted);
    return true;
  }

  static const paneRoutes = ['CatalogDiscover', 'CatalogCategories'];

  /// The word every scoped key on a page carries. These are the page names the
  /// viewer sees -- 发现 and 分类 -- not a second word for the whole catalog.
  static String paneName(int pane) => pane == 0 ? 'discover' : 'categories';

  /// The key of the list the viewer is actually looking at: pane, 一级 and 二级 in
  /// one string. A swipe lays the neighbour out beside it, so "the results of
  /// this page" is only answerable by the two levels together -- which is what
  /// a test or a live fixture has to drag on to move a page.
  String resultsKey(int pane) {
    final slot = slotOfPane(pane);
    return 'catalog-results-${paneName(pane)}-$slot-'
        '${level2Slug(level2At(pane, slot))}';
  }

  /// The two catalog pages live behind their own router, the way the television
  /// build keeps its sidebar panes; `setActiveIndex` is the only way either page
  /// is entered, so the swipe and the navigation bar cannot drift apart.
  late final router = RootStackRouter.build(
    routes: [
      NamedRouteDef(
        name: 'CatalogShell',
        path: '/',
        initial: true,
        builder: (_, _) => _CatalogShell(this),
        children: [
          for (final pane in panes)
            NamedRouteDef(
              name: paneRoutes[pane],
              path: 'catalog-$pane',
              builder: (_, _) => _CatalogPane(state: this, pane: pane),
              children: [
                for (final slot in slotSets[pane]!)
                  NamedRouteDef(
                    name: slotRouteName(pane, slot),
                    path: slot,
                    // A first-level page the viewer swiped away from leaves the
                    // tree once the swipe settles. Nothing is lost: the rows,
                    // the cursor and where the list stood live in the feed
                    // record, and only the page on screen is on screen -- which
                    // is what keeps its search box and its chip rows the only
                    // ones of their name.
                    maintainState: false,
                    builder: (_, _) =>
                        _CatalogSlot(state: this, pane: pane, slot: slot),
                  ),
              ],
            ),
        ],
      ),
    ],
  );

  /// Stable route instances: a rebuilt shell hands the same list to the tabs
  /// router, which then knows the pages did not change.
  late final tabRoutes = [
    for (final pane in panes) NamedRoute(paneRoutes[pane]),
  ];

  /// The name one first-level page is routed under. Both pages keep their own
  /// route even where the slot is the same word, so a route never means two
  /// different lists.
  static String slotRouteName(int pane, String slot) =>
      'CatalogSlot$pane-$slot';

  /// The tabs of one page's own first level, in the order that page pages
  /// through them. Instances are stable for the same reason [tabRoutes] is.
  late final innerRoutes = <int, List<PageRouteInfo>>{
    for (final pane in panes)
      pane: [
        for (final slot in slotSets[pane]!)
          NamedRoute(slotRouteName(pane, slot)),
      ],
  };

  /// One stable listener per page -- a router keeps holding the closure it was
  /// handed, so a fresh one on every rebuild would leave the old ones attached.
  late final innerChanged = <int, VoidCallback>{
    for (final pane in panes) pane: () => _onInnerTabChanged(pane),
  };

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    viewRev.value++;
  }

  /// The scroll, focus and query of the page currently on screen. Everything
  /// that still has to speak about "this page" reads through these, and every
  /// widget that renders a page passes its own pane index instead. The list
  /// itself belongs to a first-level page, so it is read through the record.
  ScrollController get scroll => scrollOf(feed);
  String get query => queryOf(destination);
  String get sort => sortFor(destination, slotOfPane(destination));
  @override
  void initState() {
    super.initState();
    final runtime = widget.runtime;
    _activeKey = feedKey;
    feedCache = runtime is LibraryCacheRuntime
        ? runtime.libraryCache
        : LibraryCache();
    lastSort = sort;
    lastCatalog = runtime.catalog;
    if (runtime is ConfigurableRuntime) {
      sortEvents = runtime.settingsChanges.listen((value) {
        if (!mounted) return;
        final clientChanged = !identical(lastCatalog, runtime.catalog);
        if (value.catalogSort == lastSort && !clientChanged) return;
        lastCatalog = runtime.catalog;
        lastSort = value.catalogSort;
        settingsChanged = true;
        // The active page reloads; the other one reloads when it is entered.
        if (!mineOpen && !rankOpen && query.isEmpty) {
          _switchFeed();
          unawaited(_reload(feed));
        }
      });
    }
    for (final pane in panes) {
      paneFocus[pane]!.addListener(() => _onSearchFocus(pane));
      paneSearch[pane]!.addListener(() => _onSearchText(pane));
    }
    unawaited(router.replaceAll([const NamedRoute('CatalogShell')]));
    _reload(feed);
  }

  @override
  void dispose() {
    for (final entry in feeds.entries) {
      entry.value.revision++;
      entry.value.scope.cancel();
    }
    suggestionsEntry?.remove();
    suggestionsEntry = null;
    filterPanelEntry?.remove();
    filterPanelEntry = null;
    // The sheet is a route, so it outlives this page's tree on its own: the
    // setter is dropped so a repaint queued from a settling router cannot be
    // delivered to a body that no longer has a page to read.
    filterSheetSetState = null;
    peekHide?.cancel();
    peekEntry?.remove();
    peekEntry = null;
    filterChipFocus.dispose();
    sortChipFocus.dispose();
    for (final bucket in themesByGenre.values) {
      bucket.revision++;
      bucket.scope.cancel();
    }
    unawaited(sortEvents?.cancel());
    _ranking?.removeListener(_applyRankDrill);
    _ranking?.removeListener(_onRankingFeed);
    _ranking?.dispose();
    for (final timer in feedFilterTimer.values) {
      timer?.cancel();
    }
    tabs?.removeListener(_onTabChanged);
    for (final pane in panes) {
      innerTabs[pane]?.removeListener(innerChanged[pane]!);
      for (final controller in levelScroll[pane]!.values) {
        controller.dispose();
      }
    }
    for (final pane in panes) {
      paneSearch[pane]!.dispose();
      paneFocus[pane]!.dispose();
    }
    for (final controller in feedScroll.values) {
      controller.dispose();
    }
    for (final controller in rowScroll.values) {
      controller.dispose();
    }
    router.dispose();
    viewRev.dispose();
    super.dispose();
  }

  Future<CatalogPage> _page(_ThemeFeed feed, {String? next}) =>
      feed.scope.run(() => _requestPage(feed, next: next));

  Future<CatalogPage> _requestPage(_ThemeFeed feed, {String? next}) {
    // Asked of the record's own key: three first-level pages can be alive at
    // once, so the shell's current choice is not necessarily the one fetching.
    final params = paramsOf(feed.key);
    final text = params['query'] as String;
    if (text.isNotEmpty) {
      return widget.runtime.catalog.search(text, cursor: next);
    }
    final genre = params['genre'] as String;
    final sort = params['sort'] as String;
    // 题材 is the second level of both pages, so a theme picked on either one
    // narrows the rows the same way -- `browse` really does take
    // `category_dim_theme` (hongguo_api's `_selection`).
    final theme = params['theme'] as String?;
    // The second dimension of that row is only carried by a catalog that reads
    // the whole `selector_rows` panel. With nothing picked there is nothing to
    // carry, and the request stays the one this app has always made.
    final extra = _dimsOfKey(feed.key);
    final catalog = widget.runtime.catalog;
    if (extra.isEmpty || catalog is! FilteredCatalogRepository) {
      return catalog.browse(
        genre: genre,
        sort: sort,
        theme: theme,
        cursor: next,
        seen: next == null ? [] : feed.items.map((d) => d.id).toList(),
      );
    }
    return catalog.browseFiltered(
      CatalogQuery(
        genre: genre,
        sort: sort,
        dims: {
          if (theme != null) categoryThemeKey: [theme],
          ...extra,
        },
        cursor: next,
        seen: next == null ? [] : feed.items.map((d) => d.id).toList(),
      ),
    );
  }

  /// Ask for the next page of one record once it has been laid out. The set
  /// holds the record, not the page index: inside one page there are three
  /// first-level lists, and each of them can be near its own end.
  void _scheduleMore(_ThemeFeed feed) {
    if (autoScheduled.contains(feed) || !mounted) return;
    autoScheduled.add(feed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      autoScheduled.remove(feed);
      if (mounted) _nearEnd(feed);
    });
  }

  /// Only the list that is actually on screen pages itself: a record belonging
  /// to a first-level page that has been swiped away from, to a theme that is
  /// not the one being read, or to the other page of the shell, is asked to stay
  /// where it is.
  void _nearEnd(_ThemeFeed feed) {
    if (!isOnScreen(feed) ||
        suggestionsPane != null ||
        !settingsFor(widget.runtime).autoLoadMore) {
      return;
    }
    final controller = scrollOf(feed);
    if (feed.loading ||
        feed.refreshing ||
        feed.loadingMore ||
        feed.autoPaused ||
        feed.error != null ||
        feed.cursor == null ||
        !controller.hasClients) {
      return;
    }
    if (controller.position.extentAfter < 600) {
      _more(feed: feed, automatic: true);
    }
  }

  /// Whether the list this record owns is the one on screen -- a theme laid out
  /// next to it during a swipe has its own offset and must not fold the band of
  /// a page the viewer is not looking at.
  bool isOnScreen(_ThemeFeed feed) =>
      identical(feeds[feed.key], feed) &&
      feed.pane == destination &&
      feed.key == feedKeyOf(feed.pane);

  /// Driven by the on-screen list, so the fold follows the scroll instead of a
  /// tap: whatever the viewer does to the rows -- a fling, a pull-to-refresh, a
  /// swipe back to a page left deep -- is the same question answered from the
  /// same offset.
  void _trackCollapse(_ThemeFeed feed) {
    if (!isOnScreen(feed) || mineOpen || rankOpen) return;
    final controller = feedScroll[feed.key];
    if (controller == null || !controller.hasClients) return;
    final offset = controller.offset;
    final collapsed = bandCollapsed[feed.pane] ?? false;
    if (!collapsed && offset > _collapseAfter) {
      setState(() => bandCollapsed[feed.pane] = true);
    } else if (collapsed && offset < _collapseBefore) {
      setState(() => bandCollapsed[feed.pane] = false);
    }
  }

  /// Loads one feed from the first page. The record is captured rather than
  /// looked up again, so a late response can only ever land in the feed that
  /// asked for it.
  Future<void> _reload(
    _ThemeFeed feed, {
    bool refreshThemes = true,
    bool preserveContent = false,
    bool preserveScroll = false,
    bool force = false,
  }) async {
    feedFilterTimer[feed.key]?.cancel();
    feed.scope.cancel();
    feed.scope = CatalogRequestScope();
    final current = ++feed.revision;
    final key = feed.key, controller = scrollOf(feed);
    final params = paramsOf(key);
    setState(() {
      feed.loading = !preserveContent || feed.items.isEmpty;
      feed.refreshing = true;
      feed.refreshError = null;
      feed.cachedAt = null;
      feed.loadingMore = false;
      feed.autoPaused = false;
      feed.emptyPages = 0;
      feed.error = null;
      if (!preserveContent) feed.items.clear();
      feed.cursor = null;
    });
    if (!preserveScroll && controller.hasClients) controller.jumpTo(0);
    // Each type asks for its own children once. A bucket already filled, still
    // loading, or failed with a retry chip on it is left alone -- and because
    // the flight belongs to the type and not to the rail, a page left behind
    // with an older type can no longer cancel the one every 分类 is waiting on.
    if (refreshThemes && (params['query'] as String).isEmpty) {
      final bucket = themesOf(params['genre'] as String);
      if (bucket.values.isEmpty && bucket.error == null && !bucket.loading) {
        unawaited(_loadThemes(params['genre'] as String));
      }
    }
    final cached = await feedCache.readFeed(key);
    if (!mounted || current != feed.revision) return;
    if (cached != null) {
      setState(() {
        feed.items
          ..clear()
          ..addAll(cached.page.items);
        feed.cursor = cached.page.nextCursor;
        feed.firstPage = cached.page;
        feed.cachedAt = cached.updated;
        feed.loading = false;
      });
      final age = feedCache.now().difference(cached.updated);
      if (!force && !age.isNegative && age < const Duration(seconds: 30)) {
        setState(() => feed.refreshing = false);
        feed.visited = true;
        _scheduleMore(feed);
        return;
      }
    }
    try {
      final page = await _page(feed);
      if (!mounted || current != feed.revision) return;
      final seen = <String>{};
      setState(() {
        feed.items
          ..clear()
          ..addAll(page.items.where((d) => seen.add(d.id)));
        feed.cursor = page.nextCursor;
        feed.firstPage = page;
        feed.loading = false;
        feed.refreshing = false;
        feed.cachedAt = null;
      });
      feed.visited = true;
      // 这一档答上了，就不再欠它一次回滚。
      if (_askedSort(feed)) paneSortRollback.remove(feed.pane);
      await _saveSnapshot(feed, key, current);
      _scheduleMore(feed);
    } catch (e) {
      if (mounted && current == feed.revision) {
        setState(() {
          if (cached != null || feed.items.isNotEmpty) {
            feed.refreshError = cached != null
                ? '网络刷新失败，正在显示本地缓存。'
                : '网络刷新失败，仍显示上次结果。';
            feed.autoPaused = true;
          } else {
            feed.error = e;
          }
          feed.refreshing = false;
          feed.loading = false;
        });
        if (_askedSort(feed)) _rollBackSort(feed);
      }
    }
  }

  /// Whether the request this record made is the 档 the L3 control now reads
  /// back -- the one flight a failed sort owes a rollback for, and the only one
  /// that can prove the 档 answered.
  bool _askedSort(_ThemeFeed feed) =>
      paramsOf(feed.key)['sort'] == paneSort[feed.pane];

  /// The 档 the viewer picked never answered, so the chip goes back to the one
  /// that did. Nothing is asked for again: the rows of that 档 are still the ones
  /// on screen (the switch seeded them and this request added none), so the
  /// label and the list agree again on their own.
  void _rollBackSort(_ThemeFeed feed) {
    final pane = feed.pane;
    final back = paneSortRollback.remove(pane);
    if (back == null || paneSort[pane] == back) return;
    setState(() => paneSort[pane] = back);
    _switchFeed(keepAlive: true, refresh: false);
  }

  /// Refreshes a feed the viewer already has on screen: only its head is
  /// re-requested, and the rows plus the cursor that produced them stay put
  /// unless the first page itself changed.
  Future<void> _refreshKept(_ThemeFeed feed) async {
    feedFilterTimer[feed.key]?.cancel();
    final current = ++feed.revision;
    // A refresh supersedes whatever page was on its way: that response is
    // dropped by the revision check in `_more`, so the flag has to be cleared
    // here or the footer keeps spinning for a request that already stopped
    // existing and paging stays blocked.
    setState(() {
      feed.refreshing = true;
      feed.loadingMore = false;
      feed.refreshError = null;
      feed.error = null;
    });
    try {
      final page = await _page(feed);
      if (!mounted || current != feed.revision) return;
      final head = feed.firstPage;
      final unchanged =
          head != null &&
          head.items.length == page.items.length &&
          List.generate(
            page.items.length,
            (i) => head.items[i].id == page.items[i].id,
          ).every((same) => same);
      setState(() {
        if (unchanged) {
          if (feed.items.length == page.items.length) {
            feed.cursor = page.nextCursor;
          }
        } else {
          final oldHead = head?.items.map((d) => d.id).toSet() ?? <String>{};
          final tail = feed.items
              .where((d) => !oldHead.contains(d.id))
              .toList();
          final ids = page.items.map((d) => d.id).toSet();
          feed.items
            ..clear()
            ..addAll(page.items)
            ..addAll(tail.where((d) => ids.add(d.id)));
          feed.cursor = page.nextCursor;
          feed.emptyPages = 0;
        }
        feed.firstPage = page;
        feed.loading = false;
        feed.refreshing = false;
        feed.cachedAt = null;
      });
      await _saveSnapshot(feed, feed.key, current);
      _scheduleMore(feed);
    } catch (_) {
      if (mounted && current == feed.revision) {
        setState(() {
          feed.refreshError = '网络刷新失败，仍显示上次结果。';
          feed.autoPaused = true;
          feed.refreshing = false;
          feed.loading = false;
        });
      }
    }
  }

  Future<void> _saveSnapshot(_ThemeFeed feed, String key, int current) async {
    final page = CatalogPage(List.of(feed.items), nextCursor: feed.cursor);
    try {
      await feedCache.writeFeed(key, page);
    } catch (_) {
      if (mounted && current == feed.revision) {
        setState(() => feed.refreshError = '内容已更新，但本地缓存保存失败。');
      }
    }
  }

  /// The next page of one record's own feed. The record is passed in rather
  /// than looked up from the screen: a footer button belongs to the list that
  /// painted it, and appending its second page to whichever list happens to be
  /// visible is exactly what the per-record feed layer exists to prevent.
  Future<void> _more({required _ThemeFeed feed, bool automatic = false}) async {
    if (feed.cursor == null ||
        feed.loadingMore ||
        feed.loading ||
        feed.refreshing ||
        (automatic && feed.autoPaused)) {
      return;
    }
    final current = feed.revision, requested = feed.cursor!, key = feed.key;
    setState(() {
      feed.loadingMore = true;
      feed.autoPaused = false;
      feed.error = null;
    });
    try {
      final page = await _page(feed, next: requested);
      if (!mounted || current != feed.revision) return;
      final seen = feed.items.map((d) => d.id).toSet(), fresh = <Drama>[];
      for (final drama in page.items) {
        if (seen.add(drama.id)) fresh.add(drama);
      }
      setState(() {
        feed.items.addAll(fresh);
        feed.loadingMore = false;
        feed.emptyPages = fresh.isEmpty ? feed.emptyPages + 1 : 0;
        if (page.nextCursor == requested) {
          feed.autoPaused = true;
          feed.error = '分页暂未推进，请稍后重试或刷新。';
        } else {
          feed.cursor = page.nextCursor;
        }
        if (feed.emptyPages >= 3 && feed.cursor != null) {
          feed.autoPaused = true;
          feed.error = '暂时没有更多新内容，可手动重试。';
        }
      });
      await _saveSnapshot(feed, key, current);
      _scheduleMore(feed);
    } catch (e) {
      if (mounted && current == feed.revision) {
        setState(() {
          feed.error = e;
          feed.loadingMore = false;
          feed.autoPaused = true;
        });
      }
    }
  }

  /// How long a switch waits before it touches the network. Rapid taps along the
  /// theme rail therefore cost one request for the theme finally stayed on.
  static const _switchWait = Duration(milliseconds: 220);

  /// Leaving a feed stops its requests but keeps its rows; entering one paints
  /// what it already holds before anything is fetched, which is what makes a
  /// theme the viewer already opened come back exactly as it was left.
  void _switchFeed({
    bool keepAlive = false,
    bool seed = false,
    bool refresh = true,
  }) {
    final key = feedKey;
    _ThemeFeed? outgoing;
    if (key != _activeKey) {
      outgoing = feeds[_activeKey];
      if (outgoing != null) {
        // Where the page being left had got to is read from the record's own
        // controller: during a swipe the destination has already moved, so the
        // page going out is not the one the active list belongs to.
        final leaving = scrollOf(outgoing);
        if (leaving.hasClients) outgoing.scroll = leaving.offset;
        outgoing.revision++;
        outgoing.scope.cancel();
        outgoing.scope = CatalogRequestScope();
        outgoing.loading = false;
        outgoing.loadingMore = false;
        outgoing.refreshing = false;
        // A page left before any of its rows landed is still empty and still
        // off screen; only the level it belongs to can ask for it again.
        outgoing.left = !outgoing.visited;
      }
      _activeKey = key;
      // 换的是眼前这份列表，那预览卡说的就不是它了。
      _closePeek();
    }
    final incoming = feed;
    feedFilterTimer[incoming.key]?.cancel();
    if (!keepAlive) {
      // A filter change keeps the previous rows on screen while the new query
      // is in flight; a theme switch never shows another theme's rows.
      if (seed &&
          !incoming.visited &&
          outgoing != null &&
          outgoing.items.isNotEmpty) {
        final seedFrom = outgoing;
        setState(() {
          incoming.items.addAll(seedFrom.items);
          incoming.loading = false;
          incoming.autoPaused = true;
        });
      }
      if (scroll.hasClients) scroll.jumpTo(0);
      return;
    }
    if (incoming.visited) {
      _restoreScroll(incoming, incoming.scroll);
      // Coming back from 我的 only restores the view; the rows and their cursor
      // are already the ones the viewer left.
      if (!refresh) return;
      feedFilterTimer[incoming.key] = Timer(_switchWait, () {
        // "Still the feed this page would ask for" is asked of the record's
        // own first-level page: the viewer may have swiped on while this was
        // waiting, and the page being left still gets the refresh it was
        // entered for.
        if (mounted && feedKeyAt(incoming.pane, incoming.slot) == key) {
          unawaited(_refreshKept(incoming));
        }
      });
      return;
    }
    setState(() {
      incoming.loading = true;
      // Entered again, so the request it was left without is owed to it now.
      incoming.left = false;
    });
    if (scroll.hasClients) scroll.jumpTo(0);
    final bucket = themesOf(incoming.slot);
    if (bucket.values.isEmpty && bucket.error == null && !bucket.loading) {
      // A rail that has not been given its parent's children is filled by the
      // page that shows it -- on either tab, since 题材 is the shared 二级. A load
      // already in flight is left alone: starting a second one for the same type
      // cancels the first and then joins its cancellation, which the viewer
      // would read as 题材加载失败. A failed load is left alone for the same
      // reason: the retry chip is the way back, not a silent re-request.
      unawaited(_loadThemes(incoming.slot));
    }
    feedFilterTimer[incoming.key] = Timer(_switchWait, () {
      if (mounted && feedKeyAt(incoming.pane, incoming.slot) == key) {
        unawaited(_reload(incoming, refreshThemes: false));
      }
    });
  }

  /// Put a kept-alive feed back at the offset it was left at. A jump is clamped
  /// by what is laid out at the moment it is asked for, and while the feed being
  /// left is still on screen that can be far shorter than the offset being
  /// restored -- so the same jump is repeated once the incoming rows have been
  /// laid out, which is what makes a theme come back where it was left.
  void _restoreScroll(_ThemeFeed target, double offset) {
    final controller = scrollOf(target);
    void jump() {
      if (!controller.hasClients) return;
      controller.jumpTo(offset.clamp(0, controller.position.maxScrollExtent));
    }

    jump();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) jump();
    });
  }

  void _onSearchFocus(int pane) {
    if (paneFocus[pane]!.hasFocus) {
      _openSuggestions(pane);
    } else if (suggestionsPane == pane) {
      _closeSuggestions();
    }
  }

  void _onSearchText(int pane) {
    if (suggestionsPane == pane) _openSuggestions(pane);
  }

  void _openSuggestions(int pane) {
    final store = searchHistoryFor(widget.runtime);
    final text = paneSearch[pane]!.text;
    setState(() {
      suggestionsPane = pane;
      historyRows = store.matching(text);
      suggestionAnchor = _anchoredSearchRect(pane);
    });
    unawaited(_loadHistory(store, pane));
    if (suggestionAnchor == null) {
      _closeSuggestions();
      return;
    }
    _showSuggestions();
    // Recommendations only answer a blank field; a typed term already has the
    // results grid below it.
    if (text.isNotEmpty || suggestionsLoading) return;
    if (suggestionsGenre == genre && suggestionRows.isNotEmpty) return;
    unawaited(_loadSuggestions());
  }

  /// A fresh session holds nothing in memory yet, so the panel has to read what
  /// the last one left on disk. A damaged history file only costs the history
  /// rows, never the focus event.
  Future<void> _loadHistory(SearchHistory store, int pane) async {
    try {
      await store.load();
    } on Object catch (_) {
      return;
    }
    if (!mounted) return;
    final hits = store.matching(paneSearch[pane]!.text);
    if (hits.isEmpty) return;
    if (suggestionsPane != pane) {
      if (paneFocus[pane]!.hasFocus) _openSuggestions(pane);
      return;
    }
    setState(() => historyRows = hits);
    suggestionsEntry?.markNeedsBuild();
  }

  /// The panel lives in the overlay because a box only receives taps inside its
  /// own size, and the dropdown has to reach above the filter row.
  void _showSuggestions() {
    final entry = suggestionsEntry;
    if (entry == null) {
      suggestionsEntry = OverlayEntry(builder: _suggestionOverlay);
      Overlay.of(context).insert(suggestionsEntry!);
    } else {
      entry.markNeedsBuild();
    }
  }

  Rect? _anchoredSearchRect(int pane) {
    final field = paneField[pane]!.currentContext?.findRenderObject();
    final overlay = Overlay.of(context).context.findRenderObject();
    if (field is! RenderBox || overlay is! RenderBox) return null;
    final origin = overlay.globalToLocal(field.localToGlobal(Offset.zero));
    return Rect.fromLTWH(
      origin.dx,
      origin.dy + field.size.height + 4,
      field.size.width,
      0,
    );
  }

  Future<void> _loadSuggestions() async {
    final ticket = ++suggestionsRevision;
    suggestionsLoading = true;
    final rows = await suggester.load(widget.runtime.catalog, genre: genre);
    suggestionsLoading = false;
    if (!mounted || ticket != suggestionsRevision) return;
    setState(() {
      suggestionRows = rows;
      suggestionsGenre = genre;
    });
    if (rows.isEmpty && historyRows.isEmpty) {
      // Nothing to offer: leave the caret in the field instead of painting an
      // empty card over the feed.
      setState(() => suggestionsPane = null);
      suggestionsEntry?.remove();
      suggestionsEntry = null;
      return;
    }
    suggestionsEntry?.markNeedsBuild();
  }

  void _closeSuggestions() {
    suggestionsRevision++;
    suggestionsEntry?.remove();
    suggestionsEntry = null;
    final pane = suggestionsPane;
    if (pane == null) return;
    if (mounted) setState(() => suggestionsPane = null);
    if (paneFocus[pane]!.hasFocus) paneFocus[pane]!.unfocus();
  }

  /// Escape and the back gesture dismiss the search suggestions; the filters
  /// are part of the page now, so there is no layer under them to close.
  /// 每一处自己盖上去的层：搜索联想、L2′ 抽屉、L3 下拉。`Esc`、系统返回和换目的地
  /// 都走这一条——规格要的是「Esc 关弹层并把焦点还给触发它的那枚控件」，而还开着的
  /// 抽屉就是一次还没还的焦点。
  void _closeOverlays() {
    if (suggestionsPane != null) _closeSuggestions();
    _closePeek();
    _closeFilterPanel();
    _closeSortMenu();
  }

  /// 排序下拉是唯一一枚 hover 就会开的层，所以「关它」有一半的时候后面没有人。焦点
  /// 只在那一层真的开着时才需要归还——还错的焦点比不还更难读。
  void _closeSortMenu() {
    final menu = sortMenuKey.currentState;
    if (menu == null || !menu.isOpen) return;
    menu.close();
    sortChipFocus.requestFocus();
  }

  /// A single-key shortcut must not eat a letter the viewer is typing.
  VoidCallback _hotkey(VoidCallback action) => () {
    if (paneFocus.values.any((node) => node.hasFocus)) return;
    action();
  };

  void _pickHistory(String value) {
    final pane = suggestionsPane ?? destination;
    paneSearch[pane]!.text = value;
    _search(pane);
  }

  Future<void> _removeHistory(String value) async {
    final store = searchHistoryFor(widget.runtime);
    await store.remove(value);
    if (!mounted) return;
    final pane = suggestionsPane ?? destination;
    setState(() => historyRows = store.matching(paneSearch[pane]!.text));
    if (historyRows.isEmpty && suggestionRows.isEmpty) {
      setState(() => suggestionsPane = null);
      suggestionsEntry?.remove();
      suggestionsEntry = null;
      return;
    }
    suggestionsEntry?.markNeedsBuild();
  }

  void _openSuggestion(Suggestion row) {
    _closeSuggestions();
    pushAppPage<void>(
      context,
      AppScreen.detail,
      (_) => DetailPage(runtime: widget.runtime, initial: row.drama),
    );
  }

  /// A search belongs to the page it was typed on: 发现 and 分类 keep their own
  /// term, so swiping back does not hand a title over to the other filter tree.
  void _search(int pane) {
    _closeSuggestions();
    final text = paneSearch[pane]!.text.trim();
    setState(() => paneQuery[pane] = text);
    if (text.isNotEmpty) {
      unawaited(searchHistoryFor(widget.runtime).record(text));
    }
    if (pane == destination) {
      _switchFeed();
      _reload(feed, refreshThemes: false);
    } else {
      unawaited(_reload(feedOf(pane), refreshThemes: false));
    }
  }

  /// The pages are switched through the tabs router, never by writing
  /// [destination]: that would let a swipe and a tap disagree about what is on
  /// screen, and [destination] is only ever refreshed from the router itself.
  /// 榜单 and 我的 are not router pages, so a tap on either is a layer over
  /// whichever catalog page the router is on -- and a tap back on 发现 or 分类 is
  /// that layer coming off.
  void _selectTab(int index) {
    if (index == 2) {
      _openRanking();
      return;
    }
    if (index == 3) {
      _openMine();
      return;
    }
    final wasOverlay = mineOpen || rankOpen;
    if (wasOverlay) {
      setState(() {
        mineOpen = false;
        rankOpen = false;
      });
    }
    if (index == destination) {
      if (wasOverlay) {
        // Back from an overlay: the rows and the cursor are the ones that were
        // left, unless the viewer changed something in there that moves the
        // feed.
        _switchFeed(keepAlive: true, refresh: settingsChanged);
        settingsChanged = false;
        _scheduleMore(feed);
      }
      return;
    }
    tabs?.setActiveIndex(index);
  }

  void _openMine() {
    if (mineOpen) return;
    _closeOverlays();
    final active = scrollOf(feed);
    if (active.hasClients) feed.scroll = active.offset;
    setState(() {
      mineOpen = true;
      rankOpen = false;
    });
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// 榜单 reads a different endpoint and a different shape of answer from the
  /// catalog pages, so it gets its own controller -- and the page it hands to
  /// the layer asks that controller for whatever it was left on, instead of
  /// starting over.
  void _openRanking() {
    if (rankOpen) return;
    _closeOverlays();
    final active = scrollOf(feed);
    if (active.hasClients) feed.scroll = active.offset;
    setState(() {
      rankOpen = true;
      mineOpen = false;
    });
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// Called by the tabs router -- a settled swipe, or a tap that went through
  /// [_selectTab]. The feed layer keeps every page's rows, so entering a page
  /// shows what it already holds instead of starting a request.
  void _onTabChanged() {
    final next = tabs?.activeIndex;
    if (next == null || next == destination) return;
    swipeHintSeen = true;
    setState(() => destination = next);
    // Both levels of this page may have moved while it was away -- 类型 and
    // 题材 are shared values, and a handover answers the page that was on
    // screen -- so the entered page is brought onto them before anything is
    // asked of it. Without this the router sits on the slot the viewer left
    // it on and lays out a first-level page the level no longer names.
    _syncInnerIndex(next);
    _syncLevelIndex(next, slotOfPane(next));
    _switchFeed(keepAlive: true);
    _scheduleMore(feed);
  }

  /// The panel one type published. A runtime that answers the whole
  /// `selector_rows` panel is asked for it; one that only ever served the 题材
  /// row is wrapped as that one row, so the second row reads the same either way
  /// and the drawer simply has nothing else to offer.
  Future<List<CatalogDim>> _vocabulary(String genre) {
    final catalog = widget.runtime.catalog;
    if (catalog is FilteredCatalogRepository) return catalog.filterRows(genre);
    return catalog
        .themes(genre)
        .then(
          (values) => [
            CatalogDim(
              key: categoryThemeKey,
              label: catalogDimRowNames[categoryThemeKey] ?? '主题',
              items: values,
            ),
          ],
        );
  }

  List<CatalogFilter> _themesOf(List<CatalogDim> rows) {
    for (final row in rows) {
      if (row.key == categoryThemeKey) return row.items;
    }
    return const [];
  }

  /// One flight per parent type. A second call for the type already loading
  /// would cancel the first and then join its cancellation, which the viewer
  /// reads as 题材加载失败 -- and both pages enter through here now, so the guard
  /// belongs to that type's own bucket. A late answer writes the bucket it was
  /// asked for, never whichever type is on screen, so a type the viewer swiped
  /// past keeps what it learned instead of losing it to the next one.
  ///
  /// One answer fills two layers: the 题材 of the second row and every other
  /// dimension of L2′ are the same `selector_rows` request.
  Future<void> _loadThemes(String requestedGenre) async {
    final bucket = themesOf(requestedGenre);
    if (bucket.loading && bucket.requested == requestedGenre) return;
    bucket.requested = requestedGenre;
    bucket.scope.cancel();
    final scope = bucket.scope = CatalogRequestScope();
    final ticket = ++bucket.revision;
    setState(() {
      bucket.loading = true;
      bucket.error = null;
    });
    try {
      final rows = await scope.run(() => _vocabulary(requestedGenre));
      if (mounted && ticket == bucket.revision) {
        setState(() {
          bucket
            ..rows = rows
            ..values = _themesOf(rows)
            ..asked = true
            ..loading = false;
        });
      }
    } catch (failure) {
      // The UI only ever says 题材加载失败, but the live evidence run has to
      // tell a cancelled flight from an upstream that answered nothing.
      debugPrint('catalog.themes($requestedGenre) failed: $failure');
      if (mounted && ticket == bucket.revision) {
        setState(() {
          bucket.loading = false;
          bucket.error = '题材加载失败';
        });
      }
    }
    // The drawer is an entry of the overlay, not of this page's tree: it is
    // rebuilt when it is told to, and what it shows is this type's panel.
    _repaintFilterPanel();
  }

  /// The drawer is an entry of the overlay, not of this page's tree, so it is
  /// rebuilt when it is told to -- and everything it shows (this type's panel,
  /// what is picked in it) is read again at that moment. The touch family's
  /// same layer is a route, so the same telling goes to its `setState`.
  void _repaintFilterPanel() {
    final sheet = filterSheetSetState;
    if (sheet != null) {
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && identical(filterSheetSetState, sheet)) sheet(() {});
        });
        return;
      }
      sheet(() {});
    }
    final entry = filterPanelEntry;
    if (entry == null) return;
    // Asked for inside a frame it has to wait for that frame: `markNeedsBuild`
    // on an entry whose overlay is mid-build is an assert, and a type turned by
    // a settling router is reached from exactly there.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (identical(filterPanelEntry, entry)) entry.markNeedsBuild();
      });
      return;
    }
    entry.markNeedsBuild();
  }

  /// A choice made on one page changes that page's feed. [pane] comes from the
  /// row that painted the chip: both pages are alive, so a keyboard activation
  /// on the one that is not on screen must not be filed against whichever page
  /// happens to be visible. 类型 is the shared 一级 and 题材 the shared 二级, so
  /// either page's row moves the same two values.
  void _selectFilter(String group, String value, int pane) {
    if (group == 'genre') {
      // 类型 is one of this page's own first-level pages on either tab, not a
      // narrowing of the list already on it: the chip changes the page.
      _gotoSlot(pane, value);
      return;
    }
    if (group == 'sort') {
      // L3, the mouse family's one and only answer to 「看哪一路流」: one of the
      // three sorts upstream publishes, written for this page alone.
      final previous = sortFor(pane, slotOfPane(pane));
      _reQuery(() => paneSort[pane] = value, pane, rollbackTo: previous);
      return;
    }
    final before = feedKeyOf(pane);
    setState(() => _writeLevel2(value));
    if (before == feedKeyOf(pane)) return;
    // A tap along the row moves the same page a swipe would have turned to, so
    // the pager is put on it -- otherwise the two would disagree about which
    // second-level page is the one on screen.
    _syncLevelIndex(pane, slotOfPane(pane));
    if (pane != destination) {
      // The visible page keeps its rows, its cursor and the shell's active
      // feed; this one only re-arms its own record.
      _rearmFeed(feedOf(pane));
      return;
    }
    // Each theme is its own feed: switching to one the viewer already opened
    // restores it, switching to a new one loads it, and neither rebuilds the
    // rows of the one being left.
    _switchFeed(keepAlive: true);
  }

  /// Put a feed whose key just changed into its waiting shape: the rows cached
  /// for the new key come back as soon as the disk has them, and one debounced
  /// reload asks for the rest. Rapid taps along a row therefore cost one request
  /// for the choice finally stayed on.
  void _rearmFeed(_ThemeFeed target, {bool preserveScroll = false}) {
    final key = target.key, current = target.revision;
    setState(() {
      target.refreshing = true;
      target.loadingMore = false;
      target.autoPaused = true;
      target.cursor = null;
      target.error = null;
      target.refreshError = null;
    });
    unawaited(
      feedCache.readFeed(key).then((cached) {
        if (mounted && current == target.revision && cached != null) {
          setState(() {
            target.items
              ..clear()
              ..addAll(cached.page.items);
            target.cursor = cached.page.nextCursor;
            target.firstPage = cached.page;
            target.cachedAt = cached.updated;
            target.loading = false;
          });
        }
      }),
    );
    feedFilterTimer[target.key] = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        _reload(
          target,
          refreshThemes: false,
          preserveContent: true,
          preserveScroll: preserveScroll,
        );
      }
    });
  }

  /// A parameter that narrows the same page rather than turning it -- L3 排序, or
  /// one line of L2′. The rows are replaced in place: the seed keeps what is on
  /// screen while the new answer is on its way, the debounced reload is the one
  /// request for the last choice made (a 档 picked while a page was still loading
  /// queues behind it rather than running next to it), and the offset the viewer
  /// had read to stays where it was -- which is the only way 「排序 ≠ 换页」is
  /// something you can see rather than something the design doc claims.
  void _reQuery(void Function() write, int pane, {String? rollbackTo}) {
    final leaving = scroll.hasClients ? scroll.offset : feed.scroll;
    final before = feedKeyOf(pane);
    if (rollbackTo != null) paneSortRollback[pane] = rollbackTo;
    setState(write);
    if (before == feedKeyOf(pane)) return;
    if (pane != destination) {
      // The other page's row re-arms its own record; the visible list is not
      // this page's to move.
      _rearmFeed(feedOf(pane));
      return;
    }
    _switchFeed(seed: true);
    _restoreScroll(feed, leaving);
    _rearmFeed(feed, preserveScroll: true);
  }

  /// L2′ 的一维选中：立刻发请求，弹层留在原地。多维抽屉一次只点一个是常态，
  /// 收起由观众的 `完成`/`Esc`/点遮罩决定，不是由「选中了」决定。
  void _pickDim(String dimKey, String? itemId, int pane) {
    _reQuery(() {
      if (itemId == null) {
        dims.remove(dimKey);
      } else {
        // 实测每一维都是单选（主题行、`selection_type` 3 的赛道行都是），所以一维
        // 只留一项；真要并集得等上游把它做成多选。
        dims[dimKey] = [itemId];
      }
    }, pane);
    _repaintFilterPanel();
  }

  /// 第二行尾部的 `≡`。桌面点开的是锚在这枚 chip 下沿的浮层；触控族点开的是一条
  /// 底部弹层——390 宽的屏上，锚在行尾的浮层没有地方开，而行本身只有 52 高。
  /// 两族是同一层的两种形状，不是两个功能：读同一份 `rows`、写同一个 `dims`。
  void _toggleFilterPanel() {
    if (_filterLayerOpen) {
      _closeFilterPanel();
      return;
    }
    final bucket = themesOf(genre);
    if (bucket.rows.isEmpty && !bucket.loading && bucket.error == null) {
      unawaited(_loadThemes(genre));
    }
    if (!desktopHost) {
      _openFilterSheet();
      return;
    }
    final chip = filterChipKey.currentContext;
    final anchor = chip == null ? null : globalRectOf(chip);
    if (anchor == null) return;
    filterPanelEntry = showAnchoredPanel(
      context: context,
      anchor: anchor,
      id: 'filter-panel',
      panel: (context, close) => DiscoverFilterPanel(
        genre: genre,
        genreLabel: _genreNames[genre] ?? genre,
        rows: themesOf(genre).rows,
        selected: dims,
        loading: themesOf(genre).loading,
        error: themesOf(genre).error,
        onPick: (dimKey, itemId) => _pickDim(dimKey, itemId, destination),
        onRetry: () => unawaited(_loadThemes(genre)),
        onDone: close,
      ),
      onDismiss: _filterPanelClosed,
    );
  }

  /// The touch family's L2′: the same panel, in a sheet that stays where it was
  /// opened. The route holds no state of its own -- it re-reads the page on every
  /// rebuild the page asks for, so 选完留在原地 is one mechanism rather than two.
  void _openFilterSheet() {
    StateSetter? bound;
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (sheetContext) => ConstrainedBox(
          // 原型给这块层的上限是屏高的 76%：再高就盖住了它要改的那张列表，而
          // 「选一个看一眼」正是触控族这一层的用法。
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.76,
          ),
          child: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setSheetState) {
                bound = setSheetState;
                filterSheetSetState = setSheetState;
                final bucket = themesOf(genre);
                return DiscoverFilterPanel(
                  genre: genre,
                  genreLabel: _genreNames[genre] ?? genre,
                  rows: bucket.rows,
                  selected: dims,
                  loading: bucket.loading,
                  error: bucket.error,
                  dismissLabel: '收起',
                  onPick: (dimKey, itemId) =>
                      _pickDim(dimKey, itemId, destination),
                  onRetry: () => unawaited(_loadThemes(genre)),
                  onDone: () => Navigator.of(sheetContext).pop(),
                );
              },
            ),
          ),
        ),
      ).whenComplete(() {
        // Only the sheet this call opened may clear the page: a second one opened
        // over the first must not have the first's exit wipe out the live setter.
        if (!mounted || !identical(filterSheetSetState, bound)) return;
        _filterPanelClosed();
      }),
    );
  }

  /// The one layer the tail `≡` has open, whichever family it is wearing.
  bool get _filterLayerOpen =>
      filterPanelEntry != null || filterSheetSetState != null;

  void _closeFilterPanel() {
    final entry = filterPanelEntry;
    if (entry != null) {
      entry.remove();
      _filterPanelClosed();
      return;
    }
    if (filterSheetSetState != null && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  /// 抽屉走了——不管是「完成」、点遮罩还是 `Esc`——页面就不该再握着它，并把焦点还给
  /// 那枚 chip。留着它，下一次 `F` 会去「关」一个已经不存在的层。
  void _filterPanelClosed() {
    filterPanelEntry = null;
    filterSheetSetState = null;
    // The sheet's own route took the focus and gives it back by being popped; a
    // keyboard focus request from here would only fight that dismissal.
    if (desktopHost) filterChipFocus.requestFocus();
  }

  int get _dimCount => dims.values.where((ids) => ids.isNotEmpty).length;

  /// §6.1.6 的卡面下钻。开在页面上而不是控件里，因为「鼠标移进预览卡就不收起」这条
  /// 只有握着浮层的页面能同时听见卡与预览两头的进出。
  void _showPeek(Drama drama, Rect anchor) {
    _closePeek();
    peekEntry = showAnchoredPeek(
      context: context,
      anchor: anchor,
      card: (context) => _peekCard(context, drama),
      onPointerEnter: () => peekHide?.cancel(),
      onPointerExit: _schedulePeekClose,
    );
  }

  /// 300ms，可 cancel——Netflix 那类界面被骂的点就是预览收不掉。
  void _schedulePeekClose() {
    peekHide?.cancel();
    peekHide = Timer(const Duration(milliseconds: 300), _closePeek);
  }

  void _closePeek() {
    peekHide?.cancel();
    peekHide = null;
    peekEntry?.remove();
    peekEntry = null;
  }

  Widget _peekCard(BuildContext context, Drama drama) {
    final label = drama.tagNames.firstOrNull ?? '';
    final title = drama.title.isEmpty ? '未命名短剧' : drama.title;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 预览用的就是那张封面，不做占位色：观众认的是画面，不是色块。
              SizedBox(
                width: 72,
                height: 96,
                child: DramaCover(
                  key: ValueKey('peek-cover-${drama.id}'),
                  drama: drama,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      key: ValueKey('peek-title-${drama.id}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                      ),
                    ),
                    if (drama.episodeCount > 0 || label.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          [
                            if (label.isNotEmpty) label,
                            if (drama.episodeCount > 0)
                              '${drama.episodeCount} 集',
                          ].join(' · '),
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (drama.intro.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                drama.intro,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                TextButton(
                  key: const ValueKey('peek-drill-theme'),
                  onPressed: () => _drillTheme(drama),
                  child: const Text('找同题材 ›'),
                ),
                TextButton(
                  key: const ValueKey('peek-drill-rank'),
                  onPressed: () => _drillRank(),
                  child: const Text('看它所在的榜 ›'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 这部剧的题材词是不是这个类型主题行里的一个。上游的词是按类型发布的，所以命中
  /// 只许用「同名」或「剧面的词以它开头」这两种读法，不许就近找一个相近的。
  CatalogFilter? _themeFor(String label) {
    if (label.isEmpty) return null;
    for (final option in themes) {
      if (label == option.name || label.startsWith(option.name)) return option;
    }
    return null;
  }

  /// `找同题材 ›`：把这部剧的题材写进 L2，其余层一个字都不动。未命中时不硬凑——
  /// 主题退回「全部」，并把为什么写出来（实测漫剧榜上的「恋爱」就不在漫剧的 8 个
  /// 主题里）。
  void _drillTheme(Drama drama) {
    _closePeek();
    final label = drama.tagNames.firstOrNull ?? '';
    final hit = _themeFor(label);
    if (hit != null) {
      _selectFilter('theme', hit.id, destination);
      _explain('带着「${hit.name}」回到主题行；排序与滚动位置都不动。');
      return;
    }
    // 没命中和词表这次没回是两句话：前者的原因是这部剧的词不在表里，后者的原因是
    // 这张表这次根本没来，而后者还要顺手再要一次。
    _selectFilter('theme', '', destination);
    if (themes.isEmpty) {
      unawaited(_loadThemes(genre));
      _explain('这个类型的主题词表这次没回（selector_rows 缺行）→ 只退回全部主题，已再要一次。');
      return;
    }
    _explain(
      label.isEmpty
          ? '这部剧没有可读出的题材词（category_schema 没回）→ 只退回全部主题。'
          : '「$label」不在${_genreNames[genre] ?? genre}的主题词表里'
                '（本类型只有 ${themes.length} 个主题）→ 只退回全部主题，不硬凑一个相近的词。',
    );
  }

  /// `看它所在的榜 ›`：赛道 id 就是类型域的另一种写法（`human` 是真人剧、
  /// `ai_playlet` 是 AI 短剧），所以这里换的是一个名字，不是一个新问题。榜块由上游
  /// 发布，回过的树里认得出热播榜就用它，认不出就交给上游的默认榜——不猜一个 id。
  void _drillRank() {
    _closePeek();
    final track = _rankTrackByGenre[genre];
    if (track == null) {
      _explain('这个类型没有对应的赛道。');
      return;
    }
    _openRanking();
    ranking.selectTrack(track);
    final hot = _hotBoardOf(track);
    if (hot == null) {
      // 榜树只随第一次回答到达：心愿得活到那次 notify，而不是现在猜一个 id。
      rankDrillTrack = track;
      return;
    }
    rankDrillTrack = null;
    if (ranking.board != hot) ranking.selectBoard(hot);
  }

  String? _hotBoardOf(String track) {
    for (final value in ranking.tracks) {
      if (value.id != track) continue;
      for (final board in value.boards) {
        if (board.label.contains('热播') || board.id.endsWith('hot_play')) {
          return board.id;
        }
      }
      return null;
    }
    return null;
  }

  /// 下钻之后要说一句为什么，因为观众点的是「找同题材」，屏幕上却可能什么都没选上。
  void _explain(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: const ValueKey('discover-drill-readout'),
        content: Text(message),
      ),
    );
  }

  void _diagnostics() {
    final checks = runCoreDiagnostics();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('离线检查'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in checks.entries)
              ListTile(
                dense: true,
                leading: Icon(
                  e.value ? Icons.check_circle_outline : Icons.error_outline,
                  color: e.value ? Colors.green : Colors.red,
                ),
                title: Text(e.key),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  /// One search field per page. A [TextEditingController] can only be attached
  /// to one live widget, and both pages are live for as long as a swipe is in
  /// flight -- so the field is part of the page, and so is what it is looking
  /// for.
  Widget _searchBox(int pane) => RepaintBoundary(
    key: paneField[pane],
    child: TextField(
      key: ValueKey('search-field-${paneName(pane)}'),
      controller: paneSearch[pane],
      focusNode: paneFocus[pane],
      groupId: paneTapGroup[pane]!,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _search(pane),
      decoration: InputDecoration(
        hintText: '搜索剧名…',
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: IconButton(
          tooltip: '搜索',
          onPressed: () => _search(pane),
          icon: const Icon(Icons.arrow_forward_rounded),
        ),
      ),
    ),
  );

  Widget _suggestionOverlay(BuildContext context) {
    final anchor = suggestionAnchor;
    if (anchor == null) return const SizedBox.shrink();
    final viewport = MediaQuery.sizeOf(context);
    return SizedBox.expand(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              key: const ValueKey('search-suggestions-dismiss'),
              behavior: HitTestBehavior.opaque,
              onTap: _closeSuggestions,
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
          Positioned(
            left: anchor.left,
            top: anchor.top,
            width: anchor.width,
            child: _suggestionPanel(
              suggestionsPane ?? destination,
              (viewport.height - anchor.top - 24)
                  .clamp(120.0, 320.0)
                  .toDouble(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _suggestionPanel(int pane, double maxHeight) {
    final latest = suggestionRows.any(
      (row) => row.mark == SuggestionMark.latest,
    );
    return TextFieldTapRegion(
      groupId: paneTapGroup[pane]!,
      child: Material(
        key: const ValueKey('search-suggestions'),
        elevation: 6,
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.hardEdge,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (historyRows.isNotEmpty) ...[
                  _suggestionLabel('最近搜索'),
                  for (final value in historyRows)
                    ListTile(
                      key: ValueKey('search-history-$value'),
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: const Icon(Icons.history_rounded, size: 18),
                      title: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        key: ValueKey('search-history-remove-$value'),
                        tooltip: '删除',
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () => _removeHistory(value),
                      ),
                      onTap: () => _pickHistory(value),
                    ),
                ],
                if (suggestionRows.isNotEmpty) ...[
                  _suggestionLabel(latest ? '最新与热门' : '热门推荐'),
                  for (final row in suggestionRows)
                    ListTile(
                      key: ValueKey('search-suggest-${row.drama.id}'),
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      title: Text(
                        row.drama.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Tooltip(
                        message: row.mark == SuggestionMark.latest
                            ? '最新上架'
                            : '热度上榜',
                        child: Icon(
                          key: ValueKey('search-suggest-mark-${row.drama.id}'),
                          row.mark == SuggestionMark.latest
                              ? Icons.fiber_new_rounded
                              : Icons.local_fire_department_rounded,
                          size: 18,
                        ),
                      ),
                      onTap: () => _openSuggestion(row),
                    ),
                ] else if (suggestionsLoading)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _suggestionLabel(String value) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      value,
      style: Theme.of(context).textTheme.labelSmall
          ?.copyWith(color: Theme.of(context).colorScheme.outline),
    ),
  );

  /// The grid's own heading. The brand row and the 我的 shortcut are gone from
  /// the top of this page on purpose: the bottom bar, the navigation rail and
  /// the wide sidebar already carry them, so every pixel above the rows
  /// belongs to the content instead.
  ///
  /// It names the first-level page it sits above, not whichever page the shell
  /// is on: mid-swipe two of them are laid out at once, and each list has to
  /// say what it itself is holding.
  Widget _sectionTitleAt(int pane, String slot, String level2) {
    final text = queryOf(pane);
    if (text.isNotEmpty) {
      return Text(
        '“$text”',
        style: Theme.of(context).textTheme.titleLarge
            ?.copyWith(fontWeight: FontWeight.w600),
      );
    }
    final style = Theme.of(context).textTheme.titleLarge
        ?.copyWith(fontWeight: FontWeight.w600);
    // What this page holds, in the order its levels are reached: which stream,
    // which type, which theme inside it. Both pages answer in the same sentence
    // because both ask the same two questions.
    //
    // 「最新上架」 is the one heading the L3 档 can write on its own: 热度/收藏 are
    // both "the flow the app chose for you", so they share the default words
    // rather than invent a heading per 档 that no viewer asked for.
    final lead = pane != 0
        ? '符合筛选的故事'
        : sortFor(pane, slot) == 'online_time'
        ? '最新上架'
        : '为你发现';
    final themeName = level2Options(pane, slot)
        .where((option) => option.id == level2 && option.id.isNotEmpty)
        .map((option) => option.label)
        .firstOrNull;
    return Text(
      [lead, _genreNames[slot] ?? slot, ?themeName].join(' · '),
      style: style,
    );
  }

  void _clearSearch(int pane) {
    paneSearch[pane]!.clear();
    setState(() => paneQuery[pane] = '');
    if (pane == destination) {
      _switchFeed();
      _reload(feed);
    } else {
      unawaited(_reload(feedOf(pane)));
    }
  }

  /// The two levels of one page, in the same chip language as the theme rail:
  /// every option of a group is applied by one tap, the current value is the
  /// highlighted chip, and the row itself keeps the highlighted chip inside its
  /// own width -- a type arrived at by a swipe is as readable as one tapped.
  /// This row does not fold away with the search box: it is the only way to
  /// change the mode or the type without scrolling all the way back up.
  ///
  /// 发现 leads with 频道 (推荐 / 最新) and its second row is 类型; 分类 leads with
  /// 类型 and puts 题材, its real child, in the pinned rail under this row. 榜单 is
  /// neither of these rows -- it is a destination of its own, so no mode of a
  /// catalog page has to stop offering the level that page is built on.
  Widget _choiceRow(int pane, bool compact) {
    List<({Widget chip, bool chosen})> group(
      String name,
      String selected,
      Map<String, String> values, {
      String? keyPrefix,
    }) => [
      for (final e in values.entries)
        (
          chip: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              key: ValueKey('filter-${keyPrefix ?? name}-${e.key}'),
              label: Text(
                e.value,
                style: TextStyle(
                  fontWeight: selected == e.key
                      ? FontWeight.w700
                      : FontWeight.w400,
                ),
              ),
              selected: selected == e.key,
              onSelected: (_) {
                if (selected != e.key) _selectFilter(name, e.key, pane);
              },
              materialTapTargetSize: MaterialTapTargetSize.padded,
            ),
          ),
          chosen: selected == e.key,
        ),
    ];
    final text = queryOf(pane);
    // A search query replaces the level rather than sitting under it: the row
    // answers the one question the page is actually in -- what to leave behind.
    // 推荐/最新 is gone from this row on both families: it was the touch
    // family's two words for one request parameter, and 「推荐」 is not a sort
    // upstream publishes at all. L3 -- 行尾那一枚 -- owns 排序 now.
    final groups = <List<({Widget chip, bool chosen})>>[
      if (text.isNotEmpty)
        [
          (
            chip: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                key: ValueKey('clear-search-${paneName(pane)}'),
                avatar: const Icon(Icons.close, size: 18),
                label: const Text('清除搜索'),
                onPressed: () => _clearSearch(pane),
              ),
            ),
            chosen: false,
          ),
        ]
      // 类型 is the 一级 of both pages, so it sits on this row on either tab.
      else
        group(
          'genre',
          genre,
          _genreNames,
          keyPrefix: 'genre-${paneName(pane)}',
        ),
    ];
    // The row is laid out with a seam between the two dimensions it holds, so
    // the chip the level names is not simply the one the group lists first.
    final children = <Widget>[];
    var target = -1;
    for (final (index, chips) in groups.indexed) {
      if (index > 0) {
        // 频道 answers "which stream", 类型/榜单 answers "which kind of
        // story"; the seam keeps the two from reading as one choice.
        children.add(
          Container(
            width: 1,
            height: 24,
            margin: const EdgeInsets.only(right: 12),
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        );
      }
      for (final item in chips) {
        if (item.chosen) target = children.length;
        children.add(item.chip);
      }
    }
    final rowKey = 'choices-$pane';
    _trackBandTarget(rowKey, target);
    final choices = rowAt(rowKey);
    return SizedBox(
      height: _filterRowHeight,
      child: Scrollbar(
        controller: choices,
        child: SingleChildScrollView(
          key: ValueKey('filter-choices-${paneName(pane)}'),
          controller: choices,
          scrollDirection: Axis.horizontal,
          physics: _rowPhysics,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 24,
            vertical: 4,
          ),
          child: Row(key: rowContentAt(rowKey), children: children),
        ),
      ),
    );
  }

  /// The chips of one type's 题材, in the order the vocabulary published them.
  ///
  /// On the mouse family the row stops at [_desktopRowMax] and puts the rest
  /// behind 更多 ▾（n）: dragging a list sideways with a pointer is the thing this
  /// build already refuses for paging, so a row that has to be dragged to be read
  /// is a row that cannot be read. A choice that fell in the tail is still named
  /// by the list's own title (`_sectionTitleAt`) -- the row does not pretend to
  /// show what it has no room for.
  List<Widget> _themeChips(int pane, String slot, String selected) {
    final options = level2Options(pane, slot);
    final limit = desktopHost ? _desktopRowMax : options.length;
    final head = options.take(limit).toList();
    final tail = options.length <= limit
        ? const <({String id, String label})>[]
        : options.skip(limit).toList();
    return [
      // Whatever this row is a child of is on screen rather than remembered:
      // 全部 carries the type it belongs to.
      for (final option in head)
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            key: ValueKey('theme-rail-${option.id}'),
            // 触控族的这条 rail 会横滑：选中的勾是 Material 3 淡入淡出的，它会改变
            // 这枚 chip 的宽度、把后面的每一枚在一次性 reveal 之后再挪几个点。选中的
            // 底色和加粗已经说了同一句话，所以这里把勾去掉——留在行尾的是稳定的偏移，
            // 「点一下就被完整显示」那条承诺才有地方成立。
            showCheckmark: !desktopHost ? false : null,
            label: Text(
              option.label,
              style: TextStyle(
                fontWeight: option.id == selected
                    ? FontWeight.w700
                    : FontWeight.w400,
              ),
            ),
            selected: option.id == selected,
            onSelected: (_) {
              if (option.id == selected) return;
              _selectFilter('theme', option.id, pane);
            },
            materialTapTargetSize: MaterialTapTargetSize.padded,
          ),
        ),
      if (tail.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: PopupMenuButton<String>(
            key: const ValueKey('theme-rail-more'),
            tooltip: '更多题材',
            onSelected: (id) => _selectFilter('theme', id, pane),
            itemBuilder: (context) => [
              for (final option in tail)
                PopupMenuItem(
                  key: ValueKey('theme-rail-menu-${option.id}'),
                  value: option.id,
                  child: Text(option.label),
                ),
            ],
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text('更多 ▾', style: TextStyle(fontSize: 13)),
            ),
          ),
        ),
    ];
  }

  /// L2′ and L3, where each family keeps them: the fixed tail of the second row,
  /// so they never slide away with the content they narrow (§6.1.2③).
  ///
  /// [rowWidth] is the width this row has been given: the touch family pins the
  /// two controls *beside* a strip that has to keep sliding, so they are capped
  /// at half of it -- a `排序 · 最新上架 ▾` that eats the 题材 rail on a split-screen
  /// window would be a row with nothing left to narrow.
  List<Widget> _narrowControls(int pane, double rowWidth) {
    final catalog = widget.runtime.catalog;
    if (!desktopHost) {
      // 触控族的两枚在两个目录页都出现：原型把 `≡` 和 `排序` 钉在 `发现`/`分类`
      // 第二行的行尾，词表缺行那一态也不收——缺的是主题行，不是改请求的能力。这一族
      // 不铺 `SortMenu`：`MenuAnchor` 在 52 高的行尾没有地方开，它的 hover 计时在这
      // 里也没有对应的手；`SortSheet` 是同一份 `catalogSortKeys` 的另一种形状。
      final selected = sortFor(pane, slotOfPane(pane));
      return [
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: rowWidth * .5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 和桌面同一个判断：只答 题材 一行的运行时没有别的维度可给，点开来的
              // 抽屉是一间只装着「重试」的房间。
              if (catalog is FilteredCatalogRepository)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    // 键按页分：甩动中两页一起铺，同一个键撞两次 `find.byKey` 就会
                    // 一次捞出两枚。所以唯一会开着抽屉的那一页（发现）拿桌面也用的那个
                    // 短名，分类那一页后缀自己的页名——和 `filter-choices-*` 同一套
                    // 命名。锚点句柄 `filterChipKey` 只桌面需要（浮层要问位置），触控族
                    // 的弹层不锚在 chip 上。
                    key: ValueKey(
                      pane == 0
                          ? 'filter-narrow'
                          : 'filter-narrow-${paneName(pane)}',
                    ),
                    onPressed: _toggleFilterPanel,
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      // 原型：`≡${nPicked ? ' ${nPicked}' : ''}`。数字是已经选下的维数；
                      // 一枚都不选时行尾只留符号本身，390 宽的屏上它和主题行分同一行。
                      _dimCount == 0 ? '≡' : '≡ $_dimCount',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: ActionChip(
                    // The one key both families' 排序 answers to, so a test -- and
                    // the 「换排序不换页」promise it is checked by -- asks either
                    // shape. 分类那一枚按页改名：两页同时铺时短名只能用一次。
                    key: ValueKey(
                      pane == 0 ? 'sort-menu' : 'sort-menu-${paneName(pane)}',
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => unawaited(
                      SortSheet.show(
                        context,
                        selected: selected,
                        onPick: (value) => _selectFilter('sort', value, pane),
                      ),
                    ),
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            '排序 · ${catalogSortLabels[selected] ?? selected}',
                            // 行窄到装不下全名时省略号收掉的是档位名，不是这一枚：
                            // 弹层里三档的原文仍然写全，读回来也在 chip 的语义里。
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        const Icon(Icons.arrow_drop_down, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ];
    }
    if (pane != 0) return const [];
    return [
      // A runtime that only ever answers the 题材 row has no dimension to offer;
      // the drawer would be a room with a retry that cannot work in it.
      if (catalog is FilteredCatalogRepository)
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: OutlinedButton(
            key: filterChipKey,
            focusNode: filterChipFocus,
            onPressed: _toggleFilterPanel,
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              side: BorderSide(
                color: filterPanelEntry != null
                    ? Theme.of(context).colorScheme.outline
                    : Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Text(
              _dimCount == 0 ? '≡ 更多筛选' : '≡ 更多筛选 · $_dimCount',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(right: 12),
        child: SortMenu(
          key: sortMenuKey,
          focusNode: sortChipFocus,
          selected: sortFor(pane, slotOfPane(pane)),
          onPick: (value) => _selectFilter('sort', value, pane),
        ),
      ),
    ];
  }

  /// 词表缺行: the type answered with no 主题 row. Upstream sends the panel per
  /// request and four samples lost one to all three types, so this is the normal
  /// branch rather than an error -- the list still carries 类型 + 排序, and what
  /// the row owes is the way back, not an empty page.
  Widget _vocabularyMissing(bool compact, String slot) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 24),
      child: desktopHost
          ? Row(
              children: [
                Flexible(
                  child: Text(
                    // The upstream name of the thing that is missing, so the
                    // sentence can be checked against the request log.
                    '上游这次没回该类型的 selector_rows —— 列表仍按类型+排序出内容',
                    key: const ValueKey('theme-rail-missing'),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  key: const ValueKey('theme-rail-retry'),
                  onPressed: () => unawaited(_loadThemes(slot)),
                  child: const Text('现在重试'),
                ),
              ],
            )
          // The touch family gets the same sentence as one pressable chip: a
          // dead label it cannot act on is the thing this state must not be.
          : ActionChip(
              key: const ValueKey('theme-rail-retry'),
              label: const Text(
                '主题词表这次没回 · 重试',
                style: TextStyle(fontSize: 13),
              ),
              onPressed: () => unawaited(_loadThemes(slot)),
            ),
    ),
  );

  /// The second level of the page on screen, pinned above its lists: the 题材 of
  /// the type being browsed.
  /// It does not fold away with the top, because it is also the strip that names
  /// whichever page a sideways swipe landed on -- and because each chip opens a
  /// feed of its own, its loading and retry states keep a fixed height instead of
  /// pushing the grid around.
  Widget _level2Row(int pane, bool compact) {
    final slot = slotOfPane(pane);
    final selected = level2At(pane, slot);
    final bucket = themesOf(slot);
    // 搜索 eats both levels, so this row can offer nothing that still means
    // something; the way back out of the search is the chip above it.
    if (queryOf(pane).isNotEmpty) return const SizedBox.shrink();
    final themesPending = bucket.loading;
    final themesFailed = bucket.error != null && bucket.values.isEmpty;
    // A type that was asked and came back with no 主题 row is 缺行, not an empty
    // rail: the row says so where its chips would have been.
    final themesMissing =
        bucket.asked && bucket.values.isEmpty && !themesFailed;
    Widget body;
    if (themesPending) {
      body = const Center(
        key: ValueKey('theme-rail-loading'),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else if (themesFailed) {
      body = Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 24),
          child: TextButton(
            key: const ValueKey('theme-rail-retry'),
            onPressed: () => unawaited(_loadThemes(slot)),
            child: Text('${bucket.error} · 重试题材'),
          ),
        ),
      );
    } else if (themesMissing) {
      body = _vocabularyMissing(compact, slot);
    } else if (desktopHost) {
      // No controller of its own: the row is not something the level machinery
      // has to reveal a chip inside, because what does not fit went to 更多 ▾
      // rather than to the end of a slide. A window too narrow for even the head
      // of them can still wheel along it -- and a wheel has no `dragDetails`, so
      // it never becomes the sideways drag that turns a level.
      body = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
        child: SingleChildScrollView(
          key: const ValueKey('theme-rail'),
          scrollDirection: Axis.horizontal,
          child: Row(children: _themeChips(pane, slot, selected)),
        ),
      );
    } else {
      final rail = rowAt('rail-$pane');
      // The row is marked with the content it holds rather than only its index:
      // entering another type refills it with the children of that type, and index
      // 0 of the new content is a different question from index 0 of the chips the
      // row is still offset by.
      _trackBandTarget('rail-$pane', level2IndexOf(pane, slot), slot);
      body = Scrollbar(
        controller: rail,
        child: SingleChildScrollView(
          key: const ValueKey('theme-rail'),
          controller: rail,
          scrollDirection: Axis.horizontal,
          physics: _rowPhysics,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 24,
            vertical: 4,
          ),
          child: Row(
            key: rowContentAt('rail-$pane'),
            children: _themeChips(pane, slot, selected),
          ),
        ),
      );
    }
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SizedBox(
        height: _filterRowHeight,
        // The row's own width is what the pinned tail is measured against: the
        // touch family's two controls share this row with a strip that has to
        // keep sliding, so they may take at most half of it (see
        // `_narrowControls`). A LayoutBuilder rather than a constant because the
        // half is a split-screen window's half, not a phone's.
        child: LayoutBuilder(
          builder: (context, box) {
            final trailing = _narrowControls(pane, box.maxWidth);
            return trailing.isEmpty
                ? body
                : Row(
                    children: [
                      Expanded(child: body),
                      ...trailing,
                    ],
                  );
          },
        ),
      ),
    );
  }

  /// One catalog page: the band it keeps on screen, then the first-level pages
  /// it slides sideways through. Both of these are built while a swipe is in
  /// flight, so nothing here may read the shell's "currently on screen"
  /// getters; every one of them is asked of [pane].
  Widget _pane(int pane, bool compact, double viewportWidth) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      // Only what the viewer answers once folds: where to search, and the
      // sentence about the swipe. Both filter rows stay pinned, because the
      // rows are how the band is read while the rows it selects are being
      // scrolled -- a type that went away with the header could only be
      // changed again by scrolling all the way back to the top.
      _paneTop(pane, compact, viewportWidth),
      // The first level: which stream, which type. It is outside the handover
      // listener below on purpose -- a pull that runs out of this row's width
      // is not a request to turn the level it belongs to, and the type is
      // already turned by the strip under it and by the pages themselves.
      _choiceRow(pane, compact),
      NotificationListener<ScrollNotification>(
        onNotification: (notification) => _onRowScroll(pane, notification),
        child: _level2Row(pane, compact),
      ),
      // Every drag of a list inside this page reaches the handover below as a
      // notification that has already been answered by the level it came from --
      // or refused by it -- so the listener sits between the two levels.
      Expanded(
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) => _onLevelScroll(pane, notification),
          child: _innerPages(pane),
        ),
      ),
    ],
  );

  /// The part of the band that the list is allowed to scroll out of the way:
  /// the search box and the swipe hint. Folded, it is offstage rather than
  /// gone: the search field keeps its text, its focus node and the key the
  /// viewer's history overlay is anchored to, and comes back at the top of the
  /// same tap-free scroll up.
  Widget _paneTop(int pane, bool compact, double viewportWidth) {
    final padding = compact ? 16.0 : 28.0;
    return Visibility(
      key: ValueKey('pane-top-${paneName(pane)}'),
      visible: !(bandCollapsed[pane] ?? false),
      maintainState: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(padding, compact ? 8 : 14, padding, 0),
            child: Row(
              children: [
                if (compact)
                  Expanded(child: _searchBox(pane))
                else
                  SizedBox(
                    width: (viewportWidth * .42).clamp(240.0, 440.0),
                    child: _searchBox(pane),
                  ),
                IconButton(
                  tooltip: '离线检查',
                  onPressed: _diagnostics,
                  icon: const Icon(Icons.verified_outlined),
                ),
              ],
            ),
          ),
          if (compact && !swipeHintSeen)
            Padding(
              padding: EdgeInsets.fromLTRB(padding, 0, padding, 8),
              child: Text(
                // Three levels are reachable from one gesture, so the sentence
                // names them in the order they are met: this page's own second
                // level first, then its type, then the other tab.
                '左右滑动切换题材，滑到尽头切换类型，再滑切换 发现 · 分类',
                key: const ValueKey('swipe-hint'),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The page's own first level, as the tabs router of its route: the three
  /// types, on either tab -- 一级 is shared, so both pages page through the same
  /// three pages.
  Widget _innerPages(int pane) => AutoTabsRouter.pageView(
    routes: innerRoutes[pane]!,
    animatePageTransition: true,
    builder: (context, child, _) {
      _attachInnerTabs(pane, AutoTabsRouter.of(context));
      return child;
    },
  );

  /// One first-level page of one catalog page: the second-level pages it slides
  /// sideways through, which are the 题材 of this type. The controller is held
  /// per (page, type) because a swipe between types lays two of these out at
  /// once and a `PageController` attaches to one live `PageView`.
  Widget _slotPage(int pane, String slot, bool compact, double viewportWidth) {
    final options = level2Options(pane, slot);
    return PageView.builder(
      key: ValueKey('level2-${paneName(pane)}-$slot'),
      controller: levelAt(pane, slot),
      physics: _handoverPhysics,
      itemCount: options.length,
      // The settle is what writes the level, not the drag: a swipe that stops
      // halfway back is the viewer changing their mind.
      onPageChanged: (index) => _onLevel2PageChanged(pane, slot, index),
      itemBuilder: (context, index) =>
          _level2Page(pane, slot, options[index].id, compact, viewportWidth),
    );
  }

  /// One second-level page: its own rows, its own scroll position, its own
  /// pull-to-refresh.
  Widget _level2Page(
    int pane,
    String slot,
    String level2,
    bool compact,
    double viewportWidth,
  ) {
    final padding = compact ? 16.0 : 28.0;
    final f = feedAtLevel(pane, slot, level2);
    // Each list asks for its own next page as it gets laid out, so a swipe
    // that lays two of them out feeds both records rather than only the one
    // the shell says is on screen.
    _scheduleMore(f);
    // And a list that has never been asked for anything -- the theme next door,
    // spread on screen mid-drag -- asks for its first page now.
    _enterLevel2(f);
    // 入口卡借的那一份榜单内容，从这一页第一次铺出来时就开始要（§4）。
    if (pane == 0 && !desktopHost) _warmRankEntry();
    return RefreshIndicator(
      onRefresh: () => _reload(f, refreshThemes: false, force: true),
      key: ValueKey(
        'catalog-results-${paneName(pane)}-$slot-${level2Slug(level2)}',
      ),
      child: CustomScrollView(
        controller: scrollOf(f),
        // Qualified by both levels: a second-level page that has not been
        // visited yet must not inherit where the page next to it was scrolled
        // to, since the scrollable it replaces is filed under the same pane.
        key: PageStorageKey(
          'catalog-feed-${paneName(pane)}-$slot-${level2Slug(level2)}',
        ),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(padding, 12, padding, 10),
              child: _sectionTitleAt(pane, slot, level2),
            ),
          ),
          // §4 的第二入口：榜单升成目的地之后入口深了一层，触控族用这张卡补回来。它借的
          // 只是内容——`rankBoard` 不吃 genre/theme，所以点它只换目的地，不写这两页的层。
          // 没有行可排（这运行时没有榜）的时候它自己不占位；搜索吃了两层，它也跟着不在。
          if (pane == 0 && !desktopHost && queryOf(pane).isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: padding),
                child: RankEntryCard(
                  title: _rankEntryTitle,
                  entries: _ranking?.entries ?? const [],
                  onOpen: _openRanking,
                ),
              ),
            ),
          if (f.refreshing || f.cachedAt != null || f.refreshError != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: padding,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    if (f.refreshing)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        f.refreshError ??
                            (f.cachedAt != null
                                ? (f.refreshing ? '已显示本地缓存，正在刷新…' : '已显示本地缓存')
                                : '正在更新内容…'),
                      ),
                    ),
                    if (!f.refreshing)
                      TextButton(
                        onPressed: () => _reload(
                          f,
                          refreshThemes: false,
                          preserveContent: true,
                          force: true,
                        ),
                        child: Text(f.refreshError == null ? '刷新' : '重试刷新'),
                      ),
                  ],
                ),
              ),
            ),
          if (f.loading)
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: padding),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 210,
                  mainAxisSpacing: 20,
                  crossAxisSpacing: 14,
                  childAspectRatio: 0.55,
                ),
                delegate: SliverChildBuilderDelegate(
                  (_, _) => Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  childCount: 10,
                ),
              ),
            ),
          if (!f.loading && f.items.isNotEmpty)
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: padding),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 210,
                  mainAxisSpacing: 20,
                  crossAxisSpacing: 14,
                  childAspectRatio: 0.55,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final drama = f.items[index];
                  // 鼠标族的第二眼：指针停住 1.5s 才出预览卡，出去 300ms 收，
                  // 移进预览卡就收回那句话。触控族不套这层——点卡本来就是进详情。
                  return HoverPeek(
                    enabled: desktopHost && pane == destination,
                    onShow: (anchor) => _showPeek(drama, anchor),
                    onLeave: _schedulePeekClose,
                    child: DramaCard(
                      drama: drama,
                      onTap: () => pushAppPage<void>(
                        context,
                        AppScreen.detail,
                        (_) =>
                            DetailPage(runtime: widget.runtime, initial: drama),
                      ),
                    ),
                  );
                }, childCount: f.items.length),
              ),
            ),
          if (!f.loading && f.items.isEmpty && f.error == null)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: Column(
                  children: [
                    Icon(Icons.search_off_rounded, size: 42),
                    SizedBox(height: 14),
                    Text('暂时没有找到内容'),
                    SizedBox(height: 8),
                    Text('试试其他剧名、题材，或稍后刷新。'),
                  ],
                ),
              ),
            ),
          if (f.error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 32),
                    const SizedBox(height: 12),
                    Text('${f.error}', textAlign: TextAlign.center),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: f.items.isEmpty
                          ? () => _reload(f, refreshThemes: false, force: true)
                          : () => _more(feed: f),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          if (!f.loading && f.cursor != null && f.error == null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: f.loadingMore
                      ? const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 12),
                            Text('正在加载更多…'),
                          ],
                        )
                      : TextButton(
                          onPressed: () => _more(feed: f),
                          child: const Text('加载更多'),
                        ),
                ),
              ),
            ),
          if (!f.loading && f.cursor == null && f.items.isNotEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('已加载全部内容')),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  /// The frame the two pages share: the navigation, and the swipeable stack.
  /// 榜单 and 我的 are layered over the stack instead of replacing it, because
  /// unmounting the pages would throw away the rows and the scroll positions the
  /// whole feed layer exists to keep.
  Widget _shell(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      this.compact = size.maxWidth < 720;
      final wide = size.maxWidth >= 1100;
      final compact = this.compact;
      final pages = AutoTabsRouter.pageView(
        routes: tabRoutes,
        // A click on the sidebar has already decided where the viewer wants to
        // go, so the 300ms slide only delays the answer; the touch hosts keep
        // it, because the same pager settles a drag a finger ends mid-page.
        // `false` is the package's jump path -- the `Duration.zero` it is
        // documented as equivalent to asserts inside `DrivenScrollActivity`.
        animatePageTransition: !desktopHost,
        builder: (context, child, _) {
          _attachTabs(AutoTabsRouter.of(context));
          return PopScope(
            canPop: suggestionsPane == null && !_filterLayerOpen,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _closeOverlays();
            },
            child: child,
          );
        },
      );
      const destinations = [
        NavigationDestination(
          icon: Icon(Icons.explore_outlined),
          selectedIcon: Icon(Icons.explore),
          label: '发现',
        ),
        NavigationDestination(
          icon: Icon(Icons.grid_view_outlined),
          selectedIcon: Icon(Icons.grid_view_rounded),
          label: '分类',
        ),
        NavigationDestination(
          icon: Icon(Icons.leaderboard_outlined),
          selectedIcon: Icon(Icons.leaderboard),
          label: '榜单',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: '我的',
        ),
      ];
      final selected = rankOpen
          ? 2
          : mineOpen
          ? 3
          : destination;
      return CallbackShortcuts(
        bindings: _shortcutBindings,
        child: Scaffold(
          bottomNavigationBar: compact
              ? NavigationBar(
                  key: const ValueKey('catalog-tabs'),
                  selectedIndex: selected,
                  onDestinationSelected: _selectTab,
                  destinations: destinations,
                )
              : null,
          body: SafeArea(
            child: Row(
              children: [
                if (!compact) ...[
                  if (wide)
                    SizedBox(
                      width: 200,
                      child: Material(
                        color: Theme.of(context).colorScheme.surface,
                        child: Column(
                          children: [
                            const Padding(
                              padding: EdgeInsets.all(24),
                              child: Brand(),
                            ),
                            const SizedBox(height: 16),
                            for (
                              var index = 0;
                              index < destinations.length;
                              index++
                            )
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 4,
                                ),
                                child: ListTile(
                                  key: ValueKey('catalog-tab-$index'),
                                  leading: destinations[index].icon,
                                  title: Text(destinations[index].label),
                                  selected: selected == index,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  selectedTileColor: Theme.of(context)
                                      .colorScheme
                                      .primaryContainer,
                                  onTap: () => _selectTab(index),
                                ),
                              ),
                            const Spacer(),
                            Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                '每一集，都值得期待。',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    NavigationRail(
                      selectedIndex: selected,
                      labelType: NavigationRailLabelType.selected,
                      onDestinationSelected: _selectTab,
                      destinations: [
                        for (final item in destinations)
                          NavigationRailDestination(
                            icon: item.icon,
                            selectedIcon: item.selectedIcon,
                            label: Text(item.label),
                          ),
                      ],
                    ),
                  VerticalDivider(
                    width: 1,
                    color: Theme.of(context).dividerColor,
                  ),
                ],
                Expanded(
                  // StackFit.expand, because the pages under 我的 are laid out but
                  // not painted -- and an offstage child contributes no size, so a
                  // loose Stack would collapse to nothing and take 我的 with it.
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Offstage(
                        offstage: mineOpen || rankOpen,
                        // Whatever the chip rows and the inner pages cannot spend
                        // -- no page that way inside this one -- is spent here,
                        // where the other page of the catalog waits.
                        child: NotificationListener<ScrollNotification>(
                          onNotification: _onNestedScroll,
                          child: pages,
                        ),
                      ),
                      if (rankOpen)
                        Positioned.fill(
                          child: RankingPage(
                            key: const ValueKey('rank-page'),
                            runtime: widget.runtime,
                            controller: ranking,
                          ),
                        ),
                      if (mineOpen)
                        Positioned.fill(
                          child: MyPage(
                            key: const ValueKey('my-page'),
                            runtime: widget.runtime,
                            onSettingsChanged: () {
                              settingsChanged = true;
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  /// 这一页的键盘。绑在整个界面上而不是绑在滑动的页面上：焦点可以在目的地栏，可以
  /// 在两行筛选，也可以在卡面——快捷键要在这种地方都答话。
  ///
  /// 播放页的 `F` 是全画面，在另一个路由的子树里，不会和这里相遇；搜索框拿到焦点时
  /// 两枚单键都让路（`_hotkey`），因为那里的一个字母不该是一次开关。
  Map<ShortcutActivator, VoidCallback> get _shortcutBindings => {
    const SingleActivator(LogicalKeyboardKey.escape): _closeOverlays,
    if (desktopHost) ...{
      const SingleActivator(LogicalKeyboardKey.keyF): _hotkey(
        _toggleFilterPanel,
      ),
      const SingleActivator(LogicalKeyboardKey.keyO): _hotkey(
        () => sortMenuKey.currentState?.toggle(),
      ),
    },
  };

  /// The tabs router is only reachable from inside its own builder, and it is
  /// the single thing allowed to change pages -- a swipe settles into it, and a
  /// tap on the navigation asks it.
  void _attachTabs(TabsRouter value) {
    if (identical(tabs, value)) return;
    tabs?.removeListener(_onTabChanged);
    tabs = value;
    value.addListener(_onTabChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onTabChanged();
    });
  }

  /// The same, for one page's own first level. A page that has never been on
  /// screen starts its router at its first slot, so whatever that page's level
  /// actually holds has to be filed into the router before the viewer sees it.
  void _attachInnerTabs(int pane, TabsRouter value) {
    if (identical(innerTabs[pane], value)) return;
    innerTabs[pane]?.removeListener(innerChanged[pane]!);
    innerTabs[pane] = value;
    value.addListener(innerChanged[pane]!);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncInnerIndex(pane);
    });
  }

  /// Put that page's router on the slot its own level says. A page reaches this
  /// from the other side of the catalog too -- 类型 is shared, so a pick over
  /// there names a page here -- and the router is the only thing allowed to say
  /// which page is on screen.
  void _syncInnerIndex(int pane) {
    final tabs = innerTabs[pane];
    if (tabs == null) return;
    final wanted = slotSets[pane]!.indexOf(slotOfPane(pane));
    if (wanted == -1 || wanted == tabs.activeIndex) return;
    tabs.setActiveIndex(wanted);
  }

  /// The router settled somewhere else -- a swipe inside the page, or a tap on
  /// one of its own chips -- so the level of that page is what changes.
  void _onInnerTabChanged(int pane) {
    final tabs = innerTabs[pane];
    if (tabs == null) return;
    final slot = slotSets[pane]![tabs.activeIndex];
    if (slot == slotOfPane(pane)) return;
    _applySlot(pane, slot);
  }

  /// A tap on one of a page's own first-level chips is a page change, not a
  /// filter change. The level moves and the router is filed to match, which is
  /// the only way a chip and a swipe can end on the same page: the router never
  /// hears a second answer for the choice already made, because the level it
  /// would report is the one just written.
  void _gotoSlot(int pane, String slot) {
    if (slot == genre) return;
    _applySlot(pane, slot);
    // 一级 is shared, so both pages follow the value the way their own chip would
    // have moved them -- whichever one the viewer lands on is already on it.
    _syncInnerIndex(0);
    _syncInnerIndex(1);
  }

  /// What a page's own level moving costs: the shared value is written, and the
  /// record it names is either shown -- when that page is the one on screen --
  /// or re-armed for the next time it is.
  void _applySlot(int pane, String slot) {
    setState(() => _writeSlot(slot));
    // The theme belonged to the type that just went away, so this page's own
    // second-level pager has to be put back on 全部 -- the page the level now
    // names, not the one the viewer left behind.
    _syncLevelIndex(pane, slot);
    if (pane != destination) {
      _rearmFeed(feedOf(pane));
      return;
    }
    // Entering one of this page's own first-level pages shows what it already
    // holds and asks for nothing: unlike a trip to 我的, nothing about this
    // record's request changed while it was away, so the rows and the offset
    // it was left at are the answer. A slot never opened yet takes the load
    // path below the visited check, which is cache-first.
    _switchFeed(keepAlive: true, refresh: false);
  }

  /// What the shared 一级 actually is, written once the page is agreed. 题材 is a
  /// child of the type, so leaving one drops the theme picked inside it rather
  /// than carrying an id that belongs to a different parent over to the next
  /// page; the children of the type being entered are asked for only when
  /// nobody has fetched them yet -- a type already walked keeps its own rail.
  void _writeSlot(String slot) {
    genre = slot;
    theme = null;
    // L2′ 和 题材 同一个父亲：换了类型，那些 `cate_*` 就不再指这一页的东西了，
    // 所以跟着归零——规格要的是同一条语义，不是第二套重置规则。
    dims.clear();
    // A drawer left open over a type that just changed shows the new type's
    // panel with nothing picked -- the same reset the row it hangs under went
    // through.
    _repaintFilterPanel();
    final bucket = themesOf(slot);
    if (bucket.values.isEmpty && !bucket.loading && bucket.error == null) {
      unawaited(_loadThemes(slot));
    }
  }

  /// Where a page's second level actually is, written once its own pager settles
  /// or one of its chips is tapped. 题材 is the only second level a catalog page
  /// has; the empty id is 全部, which means that type unfiltered.
  void _writeLevel2(String id) => theme = id.isEmpty ? null : id;

  /// The second-level pager of the page on screen settled somewhere new. A chip
  /// tap goes through [_selectFilter] and never reaches here; this is the swipe,
  /// and like a swipe between first-level pages it is a look at what the new
  /// page already holds rather than a reason to ask the upstream again.
  void _onLevel2PageChanged(int pane, String slot, int index) {
    if (pane != destination || slot != slotOfPane(pane)) return;
    final options = level2Options(pane, slot);
    if (!options.asMap().containsKey(index)) return;
    final id = options[index].id;
    if (id == level2At(pane, slot)) return;
    setState(() => _writeLevel2(id));
    _switchFeed(keepAlive: true, refresh: false);
    _scheduleMore(feed);
  }

  /// Put a page's second-level pager on the option its own level names. A pick
  /// from the chip row, and a type change that drops the theme with the type it
  /// belonged to, both move the list without a swipe -- so the pager has to be
  /// told, or it would sit on the page the viewer left.
  void _syncLevelIndex(int pane, String slot) {
    // Deferred to the frame that lays the new shape out: entering a type swaps
    // its children in for the last one's, and a jump asked for before that would
    // be clamped by the page count of the list being left.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || slot != slotOfPane(pane)) return;
      final controller = levelScroll[pane]![slot];
      if (controller == null || !controller.hasClients) return;
      final wanted = level2IndexOf(pane, slot);
      if ((controller.page ?? controller.initialScrollOffset).roundToDouble() ==
          wanted.toDouble()) {
        return;
      }
      controller.jumpToPage(wanted);
    });
  }

  /// Ask for the rows of a second-level page as it is laid out, when nothing has
  /// ever been asked of it: a swipe spreads the theme next door on screen while
  /// the drag is still moving, and a page never entered has no rows to show for
  /// it. The same debounce a tap waits out, so a long flick along the level costs
  /// the request for the page it lands on rather than one for each it passed.
  void _enterLevel2(_ThemeFeed target) {
    if (_level2Asked(target) ||
        (feedFilterTimer[target.key]?.isActive ?? false)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _level2Asked(target)) return;
      setState(() => target.loading = true);
      feedFilterTimer[target.key] = Timer(_switchWait, () {
        if (mounted &&
            identical(feeds[target.key], target) &&
            !target.visited) {
          unawaited(_reload(target, refreshThemes: false));
        }
      });
    });
  }

  static bool _level2Asked(_ThemeFeed target) =>
      target.visited ||
      target.left ||
      target.loading ||
      target.refreshing ||
      target.error != null ||
      target.items.isNotEmpty;

  @override
  Widget build(BuildContext context) =>
      Router(routerDelegate: router.delegate());
}

/// The routed frame. `Router` re-renders its routed tree only when its own
/// delegate reports a change, so the shell watches the revision every `setState`
/// bumps instead of relying on a rebuild arriving from above.
class _CatalogShell extends StatelessWidget {
  final _LibraryPageState state;
  const _CatalogShell(this.state);
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: state.viewRev,
    builder: (context, _, _) => state._shell(context),
  );
}

/// One routed catalog page, kept alive so the other one stays visible in the
/// middle of a swipe and its rows survive the trip. Its own first level is the
/// tabs router inside it, so the band above that router is laid out once for
/// whichever page of it is on screen.
class _CatalogPane extends StatelessWidget {
  final _LibraryPageState state;
  final int pane;
  const _CatalogPane({required this.state, required this.pane});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: state.viewRev,
    builder: (context, _, _) => LayoutBuilder(
      builder: (context, constraints) => state._pane(
        pane,
        // The same rule the shell laid itself out by, from the same measure: a
        // page must not read as a phone while the navigation still is a rail.
        state.compact,
        constraints.maxWidth,
      ),
    ),
  );
}

/// One first-level page of one catalog page -- 推荐, or 漫剧. It is routed, so a
/// swipe inside the page lands on it the same way a chip tap does, and its rows
/// come from the feed record filed under that same slot.
class _CatalogSlot extends StatelessWidget {
  final _LibraryPageState state;
  final int pane;
  final String slot;
  const _CatalogSlot({
    required this.state,
    required this.pane,
    required this.slot,
  });
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: state.viewRev,
    builder: (context, _, _) => LayoutBuilder(
      builder: (context, constraints) =>
          state._slotPage(pane, slot, state.compact, constraints.maxWidth),
    ),
  );
}

/// Everything one feed of the catalog owns: its rows, where its pagination got
/// to, and the requests still in flight for it. One of these exists per feed the
/// viewer has opened, so a theme they come back to is the same list they left
/// rather than a fresh request that starts at the top.
class _ThemeFeed {
  final String key;
  final int pane;

  /// Which first-level page of that pane asked for these rows: 类型, the level
  /// both pages share. The list and its scroll position belong to this page and
  /// to the second-level page inside it, not to the pane.
  final String slot;

  /// Which second-level page inside that first-level page these rows are: a
  /// 题材, or 全部 for that type unfiltered. It is the level the viewer swipes
  /// through innermost, so each of them keeps its own rows.
  final String level2;
  _ThemeFeed(this.key, this.pane, this.slot, this.level2);
  final items = <Drama>[];
  CatalogRequestScope scope = CatalogRequestScope();
  CatalogPage? firstPage;
  String? cursor;
  Object? error;
  String? refreshError;
  DateTime? cachedAt;
  int revision = 0, emptyPages = 0;
  double scroll = 0;
  bool loading = true,
      loadingMore = false,
      refreshing = false,
      autoPaused = false,
      visited = false;

  /// Left with its first page still in flight, so its request was cancelled and
  /// nothing landed. It is not asked again until the viewer returns to the page
  /// it belongs to -- otherwise the level it was just swiped away from would
  /// spend a second request on the very call that was cancelled.
  bool left = false;
}

/// The children of one type, and the request that fills them. One of these per
/// 类型: a swipe lays the neighbour page out too, and it has to show its own
/// rail instead of the current type's -- or lose it to a re-load the moment the
/// viewer comes back.
class _ThemeBucket {
  List<CatalogFilter> values = const [];

  /// The whole panel the type answered with, 主题 included: upstream's
  /// `selector_rows` is one request, and the second row and L2′ are two readings
  /// of it. Empty for a runtime that only publishes the 题材 row.
  List<CatalogDim> rows = const [];

  /// A request came back and said something. An empty row list from a type that
  /// has one is 缺行 -- the state that draws 「现在重试」-- which is a different
  /// thing from a type nobody has asked about yet.
  bool asked = false;

  CatalogRequestScope scope = CatalogRequestScope();
  int revision = 0;
  String? requested;
  bool loading = false;
  String? error;
}
