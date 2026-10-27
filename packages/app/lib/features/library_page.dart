import '../navigation/app_navigation.dart';

import 'dart:async';
import 'dart:convert';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';

import '../platform/runtime.dart';
import '../widgets/drama_cover.dart';

export '../widgets/drama_cover.dart';
import '../localization/application_name.dart';
import '../catalog/library_cache.dart';
import '../search/search_history.dart';
import '../search/search_suggestions.dart';
import 'detail_page.dart';
import 'my_page.dart';

/// Both filter rows -- the choices above and the theme rail below -- hold this
/// height in every state (chips, spinner, retry), so the two rows of one family
/// read as one block and pinning the rail can never nudge the rows below it.
const _filterRowHeight = 52.0;

/// The three types, in the one place that names them: the level shared by both
/// pages and the parent name the theme rail carries.
const _genreNames = {
  'short_play': '短剧',
  'comic_series': '漫剧',
  'ai_series': 'AI 短剧',
};

/// The three boards of 榜单. Upstream all three are 漫剧 boards
/// (`hongguo_api`'s `_rank` sends `selected_items: comic_series_rank` with a
/// `comic_series_*` sub-board), and `rank(board)` takes no genre parameter --
/// so the board says which genre it ranks in the title, which is the honest
/// version of the old write that moved the shared first level behind the
/// viewer's back.
const _boardGenre = 'comic_series';
const _boardNames = {'recommend': '推荐榜', 'hot': '热播榜', 'new': '新剧榜'};

class LibraryPage extends StatefulWidget {
  final AppRuntime runtime;
  const LibraryPage({super.key, required this.runtime});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  /// 发现 and 分类 are two pages of one catalog, and both of them are alive for
  /// as long as a swipe is in flight -- so everything a page owns (its search
  /// field, its focus, its scroll position, its query text) is held once per
  /// page. A `TextEditingController` and a `ScrollController` can each only be
  /// attached to one live widget, which is what forces the split.
  static const panes = [0, 1];
  final paneScroll = <int, ScrollController>{
    for (final p in panes) p: ScrollController(),
  };
  final paneSearch = <int, TextEditingController>{
    for (final p in panes) p: TextEditingController(),
  };
  final paneFocus = <int, FocusNode>{for (final p in panes) p: FocusNode()};
  final paneField = <int, GlobalKey>{for (final p in panes) p: GlobalKey()};
  final paneTapGroup = <int, Object>{for (final p in panes) p: Object()};
  final paneQuery = <int, String>{for (final p in panes) p: ''};

  final suggester = SearchSuggester();
  OverlayEntry? suggestionsEntry;
  List<String> historyRows = const [];
  List<Suggestion> suggestionRows = const [];
  int? suggestionsPane;
  bool suggestionsLoading = false;
  int suggestionsRevision = 0;
  String? suggestionsGenre;
  Rect? suggestionAnchor;

  /// 一级，跨两页共享：在分类挑了「漫剧」再甩回发现，发现仍然在漫剧上。
  String genre = 'short_play';

  /// 发现的二级（频道）与它自己的子选择。分类永远不读 `view`，所以离开发现
  /// 不再需要把它复位——它属于发现这一页。
  String view = 'recommend', board = 'recommend';

  /// 分类的二级：题材是类型的孩子，只有分类这一页有它。
  String? theme;
  StreamSubscription<AppSettings>? sortEvents;
  late String lastSort;
  late CatalogRepository lastCatalog;
  List<CatalogFilter> themes = [];
  bool autoScheduled = false, settingsChanged = false;
  bool themesLoading = false;
  String? themesError;
  Timer? filterTimer;
  CatalogRequestScope _themesScope = CatalogRequestScope();
  int themesRevision = 0;
  late final LibraryCache feedCache;

  /// One entry per feed the viewer has opened, keyed by [feedKeyOf]. A theme the
  /// viewer already scrolled through keeps its rows, cursor and scroll offset
  /// here instead of being rebuilt from the disk snapshot on every visit.
  ///
  /// Both pages are alive at once, so every record carries the pane it belongs
  /// to and the key it was made under: a response that lands late has to be
  /// filed in the feed that asked for it, not in whichever page is on screen.
  final feeds = <String, _ThemeFeed>{};
  String _activeKey = '';

  /// The request a page would ask for right now. Both pages compute their own
  /// key, so a swipe can show what the other page holds while the drag is
  /// still moving. 频道 and 榜单 only exist on 发现, 题材 only on 分类, and 类型 is
  /// the one dimension both pages read -- see docs/design/discover-catalog-cascade-tabs.md.
  String feedKeyOf(int pane) => jsonEncode({
    'destination': pane,
    'query': queryOf(pane),
    'view': pane == 0 ? view : 'recommend',
    'genre': genre,
    'sort': sortFor(pane),
    'theme': pane == 1 ? theme : null,
    'board': pane == 0 ? board : 'recommend',
  });
  String get feedKey => feedKeyOf(destination);
  _ThemeFeed get feed => feedOf(destination);
  _ThemeFeed feedOf(int pane) => feeds.putIfAbsent(
    feedKeyOf(pane),
    () => _ThemeFeed(feedKeyOf(pane), pane),
  );

  /// Which page a feed record belongs to, read back out of its own key. A timer
  /// or a late response only ever knows the record, never the current screen.
  int paneOf(String key) => (jsonDecode(key) as Map)['destination'] as int;

  String queryOf(int pane) => paneQuery[pane]!;

  /// 榜单 asks `rank(board)`, which has no genre parameter at all -- so while
  /// that channel is selected the second row of 发现 shows the three boards
  /// instead of the types, rather than a control that changes nothing.
  bool isRanking(int pane) =>
      pane == 0 && queryOf(pane).isEmpty && view == 'rank';

  /// 最新 is a channel the viewer picks, so it has to move the rows: it asks
  /// the catalog for the newest online date instead of the configured sort.
  /// The other channels keep whatever sort the viewer set in 设置.
  String sortFor(int pane) => pane == 0 && view == 'latest'
      ? 'online_time'
      : settingsFor(widget.runtime).catalogSort;

  /// Which page is on screen. It mirrors the nested tab router, so a swipe and
  /// a tap on the navigation bar end up in the same place.
  int destination = 0;

  /// 我的 is a destination, not a page in the swipe: flinging past 分类 into
  /// your personal library by accident costs more than it gives.
  bool mineOpen = false;

  /// The one gesture the phone has and the desktop does not: shown until the
  /// viewer has actually moved between the two pages.
  bool swipeHintSeen = false;

  /// How wide the shell laid itself out as, read by the routed pages: one
  /// measure decides phone or desktop for the whole screen, navigation and
  /// content together.
  bool compact = true;

  static const paneRoutes = ['CatalogDiscover', 'CatalogCategories'];

  /// The word every scoped key on a page carries. These are the page names the
  /// viewer sees -- 发现 and 分类 -- not a second word for the whole catalog.
  static String paneName(int pane) => pane == 0 ? 'discover' : 'categories';

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

  /// Captured from the tabs builder, which is the only place that has it.
  TabsRouter? tabs;

  /// A rebuild of `LibraryPage` stops at the nested `Router`, which only
  /// re-renders its routed subtree when its own delegate notifies -- so every
  /// `setState` bumps this as well, and the routed shell and panes watch it.
  final viewRev = ValueNotifier<int>(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    viewRev.value++;
  }

  /// The scroll, focus and query of the page currently on screen. Everything
  /// that still has to speak about "this page" reads through these, and every
  /// widget that renders a page passes its own pane index instead.
  ScrollController get scroll => paneScroll[destination]!;
  String get query => queryOf(destination);
  bool get ranking => isRanking(destination);
  String get sort => sortFor(destination);
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
        if (!mineOpen && query.isEmpty && !ranking) {
          _switchFeed();
          unawaited(_reload(feed));
        }
      });
    }
    for (final pane in panes) {
      paneScroll[pane]!.addListener(() => _nearEnd(pane));
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
    _themesScope.cancel();
    unawaited(sortEvents?.cancel());
    filterTimer?.cancel();
    tabs?.removeListener(_onTabChanged);
    for (final pane in panes) {
      paneScroll[pane]!.dispose();
      paneSearch[pane]!.dispose();
      paneFocus[pane]!.dispose();
    }
    router.dispose();
    viewRev.dispose();
    super.dispose();
  }

  Future<CatalogPage> _page(_ThemeFeed feed, {String? next}) =>
      feed.scope.run(() => _requestPage(feed, next: next));

  Future<CatalogPage> _requestPage(_ThemeFeed feed, {String? next}) {
    final pane = feed.pane;
    final text = queryOf(pane);
    if (text.isNotEmpty) {
      return widget.runtime.catalog.search(text, cursor: next);
    }
    final catalog = widget.runtime.catalog;
    if (isRanking(pane) && catalog is RankCatalogRepository) {
      return catalog.rank(board: board, cursor: next);
    }
    return catalog.browse(
      genre: genre,
      sort: sortFor(pane),
      // 题材 is 分类's second level; 发现 asks the same repository without it so
      // a theme picked over there never silently narrows the recommendation
      // stream the viewer is swiping back to.
      theme: pane == 1 ? theme : null,
      cursor: next,
      seen: next == null ? [] : feed.items.map((d) => d.id).toList(),
    );
  }

  void _scheduleMore(int pane) {
    if (autoScheduled || !mounted) return;
    autoScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      autoScheduled = false;
      if (mounted) _nearEnd(pane);
    });
  }

  void _nearEnd(int pane) {
    if (pane != destination ||
        mineOpen ||
        suggestionsPane != null ||
        !settingsFor(widget.runtime).autoLoadMore) {
      return;
    }
    final feed = feedOf(pane), controller = paneScroll[pane]!;
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
      _more(automatic: true);
    }
  }

  /// Loads one feed from the first page. The record is captured rather than
  /// looked up again, so a late response can only ever land in the feed that
  /// asked for it.
  Future<void> _reload(
    _ThemeFeed feed, {
    bool refreshThemes = true,
    bool preserveContent = false,
    bool force = false,
  }) async {
    filterTimer?.cancel();
    feed.scope.cancel();
    feed.scope = CatalogRequestScope();
    final current = ++feed.revision;
    final pane = feed.pane, key = feed.key, controller = paneScroll[pane]!;
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
    if (controller.hasClients) controller.jumpTo(0);
    if (refreshThemes && queryOf(pane).isEmpty && !isRanking(pane)) {
      unawaited(_loadThemes(genre));
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
        _scheduleMore(pane);
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
      await _saveSnapshot(feed, key, current);
      _scheduleMore(pane);
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
      }
    }
  }

  /// Refreshes a feed the viewer already has on screen: only its head is
  /// re-requested, and the rows plus the cursor that produced them stay put
  /// unless the first page itself changed.
  Future<void> _refreshKept(_ThemeFeed feed) async {
    filterTimer?.cancel();
    final current = ++feed.revision;
    setState(() {
      feed.refreshing = true;
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
      _scheduleMore(feed.pane);
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

  Future<void> _more({bool automatic = false}) async {
    final feed = this.feed;
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
      _scheduleMore(feed.pane);
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
        // pane: during a swipe the destination has already moved, so the
        // active controller belongs to the page coming in, not the one going.
        final leaving = paneScroll[outgoing.pane]!;
        if (leaving.hasClients) outgoing.scroll = leaving.offset;
        outgoing.revision++;
        outgoing.scope.cancel();
        outgoing.scope = CatalogRequestScope();
        outgoing.loading = false;
        outgoing.loadingMore = false;
        outgoing.refreshing = false;
      }
      _activeKey = key;
    }
    filterTimer?.cancel();
    final incoming = feed;
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
      _restoreScroll(incoming.pane, incoming.scroll);
      // Coming back from 我的 only restores the view; the rows and their cursor
      // are already the ones the viewer left.
      if (!refresh) return;
      filterTimer = Timer(_switchWait, () {
        if (mounted && feedKey == key) unawaited(_refreshKept(incoming));
      });
      return;
    }
    setState(() => incoming.loading = true);
    if (scroll.hasClients) scroll.jumpTo(0);
    if (incoming.pane == 1 &&
        themes.isEmpty &&
        themesError == null &&
        !themesLoading) {
      // A rail that has not been given its parent's children is filled by the
      // page that shows it: 题材 belongs to 分类, 类型 is shared. A load already
      // in flight is left alone -- `themes` is one shared flight, so starting a
      // second one here cancels the first and then joins its cancellation,
      // which the viewer would read as 题材加载失败. A failed load is left alone
      // for the same reason: the retry chip is the way back, not a silent
      // re-request.
      unawaited(_loadThemes(genre));
    }
    filterTimer = Timer(_switchWait, () {
      if (mounted && feedKey == key) {
        unawaited(_reload(incoming, refreshThemes: false));
      }
    });
  }

  /// Put a kept-alive feed back at the offset it was left at. A jump is clamped
  /// by what is laid out at the moment it is asked for, and while the feed being
  /// left is still on screen that can be far shorter than the offset being
  /// restored -- so the same jump is repeated once the incoming rows have been
  /// laid out, which is what makes a theme come back where it was left.
  void _restoreScroll(int pane, double offset) {
    final controller = paneScroll[pane]!;
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
  void _closeOverlays() {
    if (suggestionsPane != null) _closeSuggestions();
  }

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
  void _selectTab(int index) {
    if (index == 2) {
      _openMine();
      return;
    }
    final wasMine = mineOpen;
    if (wasMine) setState(() => mineOpen = false);
    if (index == destination) {
      if (wasMine) {
        // Back from 我的: the rows and the cursor are the ones that were left,
        // unless the viewer changed something in there that moves the feed.
        _switchFeed(keepAlive: true, refresh: settingsChanged);
        settingsChanged = false;
        _scheduleMore(destination);
      }
      return;
    }
    tabs?.setActiveIndex(index);
  }

  void _openMine() {
    if (mineOpen) return;
    _closeSuggestions();
    final active = paneScroll[destination]!;
    if (active.hasClients) feed.scroll = active.offset;
    setState(() => mineOpen = true);
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
    _switchFeed(keepAlive: true);
    _scheduleMore(next);
  }

  Future<void> _loadThemes(String requestedGenre) async {
    _themesScope.cancel();
    final scope = _themesScope = CatalogRequestScope();
    final ticket = ++themesRevision;
    setState(() {
      themesLoading = true;
      themesError = null;
    });
    try {
      final values = await scope.run(
        () => widget.runtime.catalog.themes(requestedGenre),
      );
      if (mounted && genre == requestedGenre && ticket == themesRevision) {
        setState(() {
          themes = values;
          themesLoading = false;
        });
      }
    } catch (failure) {
      // The UI only ever says 题材加载失败, but the live evidence run has to
      // tell a cancelled flight from an upstream that answered nothing.
      debugPrint('catalog.themes($requestedGenre) failed: $failure');
      if (mounted && genre == requestedGenre && ticket == themesRevision) {
        setState(() {
          themesLoading = false;
          themesError = '题材加载失败';
        });
      }
    }
  }

  void _selectFilter(String group, String value) {
    final before = feedKey;
    setState(() {
      switch (group) {
        case 'genre':
          genre = value;
          theme = null;
          themes = [];
          unawaited(_loadThemes(value));
        case 'theme':
          theme = value.isEmpty ? null : value;
        case 'board':
          board = value;
        case 'view':
          // 频道 is 发现's own second level: `rank(board)` takes no genre and
          // no theme, so choosing a board reaches into neither the shared first
          // level nor 分类's rail. It used to write 漫剧 and drop the rail, which
          // made a channel read like a filter and stole the type the viewer
          // picked over there.
          view = value;
      }
    });
    if (before == feedKey) return;
    if (group == 'theme') {
      // A theme is its own feed now: switching to one the viewer already opened
      // restores it, switching to a new one loads it, and neither rebuilds the
      // rows of the theme being left.
      _switchFeed(keepAlive: true);
      return;
    }
    _switchFeed(seed: true);
    final key = feedKey, target = feed, current = target.revision;
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
    filterTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        _reload(target, refreshThemes: false, preserveContent: true);
      }
    });
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
  Widget _sectionTitle(int pane) {
    final text = queryOf(pane);
    return Text(
      text.isNotEmpty
          ? '“$text”'
          : isRanking(pane)
          ? '${_genreNames[_boardGenre]} · ${_boardNames[board] ?? '榜单'}'
          : pane == 1
          ? '符合筛选的故事'
          : view == 'latest'
          ? '最新上架'
          : '为你发现',
      style: Theme.of(context).textTheme.titleLarge
          ?.copyWith(fontWeight: FontWeight.w600),
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
  /// every option of a group is on screen at once, one tap applies it, and the
  /// current value is the highlighted chip.
  ///
  /// 发现 leads with 频道 (推荐 / 最新 / 榜单) and its second row is 类型 -- or the
  /// three boards when 榜单 is selected, because `rank` has no genre parameter at
  /// all and a type row that changes nothing would be a false control. 分类 leads
  /// with 类型 and puts 题材, its real child, in the pinned rail under this row.
  Widget _choiceRow(int pane, bool compact) {
    List<Widget> group(
      String name,
      String selected,
      Map<String, String> values, {
      String? keyPrefix,
    }) => [
      for (final e in values.entries)
        Padding(
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
              if (selected != e.key) _selectFilter(name, e.key);
            },
            materialTapTargetSize: MaterialTapTargetSize.padded,
          ),
        ),
    ];
    final text = queryOf(pane);
    final groups = <List<Widget>>[
      if (text.isNotEmpty)
        [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ActionChip(
              key: ValueKey('clear-search-${paneName(pane)}'),
              avatar: const Icon(Icons.close, size: 18),
              label: const Text('清除搜索'),
              onPressed: () => _clearSearch(pane),
            ),
          ),
        ]
      else if (pane == 0)
        group('view', view, {
          'recommend': '推荐',
          'latest': '最新',
          // A runtime whose catalog has no rank endpoint never offers 榜单 --
          // a chip that silently reloads the same feed is worse than none.
          if (widget.runtime.catalog is RankCatalogRepository) 'rank': '榜单',
        }),
      if (text.isEmpty)
        // Both pages offer 类型, so the chip keys carry the page: a shared first
        // level means one value, never two widgets with one name.
        isRanking(pane)
            ? group('board', board, _boardNames)
            : group(
                'genre',
                genre,
                _genreNames,
                keyPrefix: 'genre-${paneName(pane)}',
              ),
    ];
    return SizedBox(
      height: _filterRowHeight,
      child: Scrollbar(
        child: SingleChildScrollView(
          key: ValueKey('filter-choices-${paneName(pane)}'),
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 24,
            vertical: 4,
          ),
          child: Row(
            children: [
              for (final (index, chips) in groups.indexed) ...[
                if (index > 0)
                  // 频道 answers "which stream", 类型/榜单 answers "which kind of
                  // story"; the seam keeps the two from reading as one choice.
                  Container(
                    width: 1,
                    height: 24,
                    margin: const EdgeInsets.only(right: 12),
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ...chips,
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The themes of the current genre, laid out in one row that pins to the top
  /// of the list as everything above it scrolls away, the way the television
  /// build keeps them reachable. Tapping one opens that theme's own feed rather
  /// than filtering the rows in place, so loading and retry both keep their
  /// fixed height and never push the grid around.
  Widget _themeRail(int pane, bool compact) {
    // 题材 is 分类's second level alone. It is the same child of the same type on
    // both pages, so showing it twice is the duplication the filter panel used
    // to carry -- and 发现 is one swipe away.
    if (pane == 0 || queryOf(pane).isNotEmpty || isRanking(pane)) {
      return const SizedBox.shrink();
    }
    final selected = theme ?? '';
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SizedBox(
        height: _filterRowHeight,
        child: themesLoading
            ? const Center(
                key: ValueKey('theme-rail-loading'),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : themesError != null
            ? Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 24),
                  child: TextButton(
                    key: const ValueKey('theme-rail-retry'),
                    onPressed: () => unawaited(_loadThemes(genre)),
                    child: Text('$themesError · 重试题材'),
                  ),
                ),
              )
            : Scrollbar(
                child: SingleChildScrollView(
                  key: const ValueKey('theme-rail'),
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 12 : 24,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      for (final (id, name) in [
                        // The parent name rides along, so what this row is a
                        // child of is on screen rather than remembered.
                        ('', '全部 · ${_genreNames[genre] ?? genre}'),
                        for (final e in themes) (e.id, e.name),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            key: ValueKey('theme-rail-$id'),
                            label: Text(
                              name,
                              style: TextStyle(
                                fontWeight: id == selected
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                              ),
                            ),
                            selected: id == selected,
                            onSelected: (_) {
                              if (id != selected) _selectFilter('theme', id);
                            },
                            materialTapTargetSize: MaterialTapTargetSize.padded,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  /// One catalog page: its own search, its own two levels of narrowing, its own
  /// scroll position -- and, for 分类, the pinned 题材 rail. Both of these are
  /// built while a swipe is in flight, so nothing here may read the shell's
  /// "currently on screen" getters; every one of them is asked of [pane].
  Widget _pane(int pane, bool compact, double viewportWidth) {
    final padding = compact ? 16.0 : 28.0;
    final f = feedOf(pane);
    final controller = paneScroll[pane]!;
    return RefreshIndicator(
      onRefresh: () => _reload(f, refreshThemes: false, force: true),
      key: ValueKey('catalog-results-${paneName(pane)}'),
      child: CustomScrollView(
        controller: controller,
        key: PageStorageKey('catalog-feed-${paneName(pane)}'),
        slivers: [
          // Search is the page's own header now, and it scrolls: on a phone the
          // brand band and the row of icon buttons gave up 150 logical pixels to
          // nothing, and on the desktop the sidebar already repeats the title
          // and the 我的 shortcut.
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                padding,
                compact ? 8 : 14,
                padding,
                0,
              ),
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
          ),
          // The choices sit flush with the rail under them -- both rows start
          // at the same inset, so they read as one family of narrowing.
          SliverToBoxAdapter(child: _choiceRow(pane, compact)),
          if (pane == 1)
            SliverPersistentHeader(
              // The rail is the one thing that never leaves. It rides up to the
              // top as the search box and the choice row scroll out and stops
              // there, so a theme stays one tap away from anywhere in the rows.
              pinned: true,
              delegate: _ThemeRailHeader(
                height: queryOf(pane).isEmpty ? _filterRowHeight : 0,
                child: _themeRail(pane, compact),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(padding, 12, padding, 10),
              child: _sectionTitle(pane),
            ),
          ),
          if (compact && !swipeHintSeen)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(padding, 0, padding, 8),
                child: Text(
                  '左右滑动切换 发现 · 分类',
                  key: const ValueKey('swipe-hint'),
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
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
                delegate: SliverChildBuilderDelegate(
                  (context, index) => DramaCard(
                    drama: f.items[index],
                    onTap: () => pushAppPage<void>(
                      context,
                      AppScreen.detail,
                      (_) => DetailPage(
                        runtime: widget.runtime,
                        initial: f.items[index],
                      ),
                    ),
                  ),
                  childCount: f.items.length,
                ),
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
                          : _more,
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
                      : TextButton(onPressed: _more, child: const Text('加载更多')),
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
  /// 我的 is layered over the stack instead of replacing it, because unmounting
  /// the pages would throw away the rows and the scroll positions the whole
  /// feed layer exists to keep.
  Widget _shell(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      this.compact = size.maxWidth < 720;
      final wide = size.maxWidth >= 1100;
      final compact = this.compact;
      _scheduleMore(destination);
      final pages = AutoTabsRouter.pageView(
        routes: tabRoutes,
        animatePageTransition: true,
        builder: (context, child, _) {
          _attachTabs(AutoTabsRouter.of(context));
          return CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _closeOverlays,
            },
            child: PopScope(
              canPop: suggestionsPane == null,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) _closeOverlays();
              },
              child: child,
            ),
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
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: '我的',
        ),
      ];
      final selected = mineOpen ? 2 : destination;
      return Scaffold(
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
                    Offstage(offstage: mineOpen, child: pages),
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
      );
    },
  );

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
/// middle of a swipe and its rows survive the trip.
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

/// Everything one feed of the catalog owns: its rows, where its pagination got
/// to, and the requests still in flight for it. One of these exists per feed the
/// viewer has opened, so a theme they come back to is the same list they left
/// rather than a fresh request that starts at the top.
class _ThemeFeed {
  final String key;
  final int pane;
  _ThemeFeed(this.key, this.pane);
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
}

/// The pinned slot the theme rail rides in: the search box and the trigger row
/// scroll out above it and it stops at the top of the viewport, so changing
/// theme stays possible from anywhere in a long list.
class _ThemeRailHeader extends SliverPersistentHeaderDelegate {
  const _ThemeRailHeader({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => child;

  @override
  bool shouldRebuild(_ThemeRailHeader oldDelegate) =>
      oldDelegate.height != height || oldDelegate.child != child;
}

class Brand extends StatelessWidget {
  const Brand({super.key});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(
          Icons.play_arrow_rounded,
          color: Theme.of(context).colorScheme.onPrimary,
          size: 25,
        ),
      ),
      const SizedBox(width: 10),
      Flexible(
        child: Text(
          ApplicationName.of(context),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
        ),
      ),
    ],
  );
}

class DramaCard extends StatelessWidget {
  final Drama drama;
  final VoidCallback onTap;
  final String? badge, subtitle;
  final ImageProvider? coverImage;
  final bool allowNetworkCover;
  const DramaCard({
    super.key,
    required this.drama,
    required this.onTap,
    this.badge,
    this.subtitle,
    this.coverImage,
    this.allowNetworkCover = true,
  });
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: DramaCover(
                  drama: drama,
                  imageProvider: coverImage,
                  allowNetwork: allowNetworkCover,
                ),
              ),
              if (badge != null || drama.episodeCount > 0)
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      badge ?? '${drama.episodeCount} 集',
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          drama.title.isEmpty ? '未命名短剧' : drama.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle ?? (drama.intro.isEmpty ? '点开看看这个故事' : drama.intro),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}
