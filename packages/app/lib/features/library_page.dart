import '../navigation/app_navigation.dart';

import 'dart:async';
import 'dart:convert';

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

class LibraryPage extends StatefulWidget {
  final AppRuntime runtime;
  const LibraryPage({super.key, required this.runtime});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final search = TextEditingController();
  final searchFocus = FocusNode();
  final searchField = GlobalKey();
  final searchTapGroup = Object();
  final suggester = SearchSuggester();
  OverlayEntry? suggestionsEntry;
  List<String> historyRows = const [];
  List<Suggestion> suggestionRows = const [];
  bool suggestionsOpen = false, suggestionsLoading = false;
  int suggestionsRevision = 0;
  String? suggestionsGenre;
  Rect? suggestionAnchor;
  final scroll = ScrollController();
  String genre = 'short_play',
      query = '',
      view = 'recommend',
      board = 'recommend';

  /// 最新 is a channel the viewer picks, so it has to move the rows: it asks
  /// the catalog for the newest online date instead of the configured sort.
  /// The other channels keep whatever sort the viewer set in 设置.
  String get sort => view == 'latest'
      ? 'online_time'
      : settingsFor(widget.runtime).catalogSort;
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

  /// One entry per feed the viewer has opened, keyed by [feedKey]. A theme the
  /// viewer already scrolled through keeps its rows, cursor and scroll offset
  /// here instead of being rebuilt from the disk snapshot on every visit.
  final feeds = <String, _ThemeFeed>{};
  String _activeKey = '';
  String get feedKey => jsonEncode({
    'destination': destination,
    'query': query,
    'view': view,
    'genre': genre,
    'sort': sort,
    'theme': theme,
    'board': board,
  });
  _ThemeFeed get feed => feeds.putIfAbsent(feedKey, () => _ThemeFeed());
  List<Drama> get items => feed.items;
  String? get cursor => feed.cursor;
  Object? get error => feed.error;
  String? get refreshError => feed.refreshError;
  DateTime? get cachedAt => feed.cachedAt;
  bool get loading => feed.loading;
  bool get loadingMore => feed.loadingMore;
  bool get refreshing => feed.refreshing;
  bool get autoPaused => feed.autoPaused;
  int destination = 0;
  bool get ranking => query.isEmpty && destination == 0 && view == 'rank';
  bool get mobile => MediaQuery.sizeOf(context).width < 720;
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
        if (destination != 2 && query.isEmpty && !ranking) {
          _switchFeed();
          unawaited(_reload(feed));
        }
      });
    }
    scroll.addListener(_nearEnd);
    searchFocus.addListener(_onSearchFocus);
    search.addListener(_onSearchText);
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
    scroll.dispose();
    search.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  Future<CatalogPage> _page(_ThemeFeed feed, {String? next}) =>
      feed.scope.run(() => _requestPage(feed, next: next));

  Future<CatalogPage> _requestPage(_ThemeFeed feed, {String? next}) {
    if (query.isNotEmpty) {
      return widget.runtime.catalog.search(query, cursor: next);
    }
    final catalog = widget.runtime.catalog;
    if (ranking && catalog is RankCatalogRepository) {
      return catalog.rank(board: board, cursor: next);
    }
    return catalog.browse(
      genre: genre,
      sort: sort,
      theme: theme,
      cursor: next,
      seen: next == null ? [] : feed.items.map((d) => d.id).toList(),
    );
  }

  void _scheduleMore() {
    if (autoScheduled || !mounted) return;
    autoScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      autoScheduled = false;
      if (mounted) _nearEnd();
    });
  }

  void _nearEnd() {
    if (suggestionsOpen ||
        destination == 2 ||
        !settingsFor(widget.runtime).autoLoadMore ||
        loading ||
        refreshing ||
        loadingMore ||
        autoPaused ||
        error != null ||
        cursor == null ||
        !scroll.hasClients) {
      return;
    }
    if (scroll.position.extentAfter < 600) _more(automatic: true);
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
    final key = feedKey;
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
    if (scroll.hasClients) scroll.jumpTo(0);
    if (refreshThemes && query.isEmpty && !ranking) {
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
        _scheduleMore();
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
      _scheduleMore();
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
      await _saveSnapshot(feed, feedKey, current);
      _scheduleMore();
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
    final current = feed.revision, requested = feed.cursor!, key = feedKey;
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
      _scheduleMore();
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
        if (scroll.hasClients) outgoing.scroll = scroll.offset;
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
      _restoreScroll(incoming.scroll);
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
  void _restoreScroll(double offset) {
    void jump() {
      if (!scroll.hasClients) return;
      scroll.jumpTo(offset.clamp(0, scroll.position.maxScrollExtent));
    }

    jump();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) jump();
    });
  }

  void _onSearchFocus() {
    if (searchFocus.hasFocus) {
      _openSuggestions();
    } else if (suggestionsOpen) {
      _closeSuggestions();
    }
  }

  void _onSearchText() {
    if (suggestionsOpen) _openSuggestions();
  }

  void _openSuggestions() {
    final store = searchHistoryFor(widget.runtime);
    setState(() {
      suggestionsOpen = true;
      historyRows = store.matching(search.text);
      suggestionAnchor = _anchoredSearchRect();
    });
    unawaited(_loadHistory(store));
    if (suggestionAnchor == null) {
      _closeSuggestions();
      return;
    }
    _showSuggestions();
    // Recommendations only answer a blank field; a typed term already has the
    // results grid below it.
    if (search.text.isNotEmpty || suggestionsLoading) return;
    if (suggestionsGenre == genre && suggestionRows.isNotEmpty) return;
    unawaited(_loadSuggestions());
  }

  /// A fresh session holds nothing in memory yet, so the panel has to read what
  /// the last one left on disk. A damaged history file only costs the history
  /// rows, never the focus event.
  Future<void> _loadHistory(SearchHistory store) async {
    try {
      await store.load();
    } on Object catch (_) {
      return;
    }
    if (!mounted) return;
    final hits = store.matching(search.text);
    if (hits.isEmpty) return;
    if (!suggestionsOpen) {
      if (searchFocus.hasFocus) _openSuggestions();
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

  Rect? _anchoredSearchRect() {
    final field = searchField.currentContext?.findRenderObject();
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
      setState(() => suggestionsOpen = false);
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
    if (suggestionsOpen && mounted) setState(() => suggestionsOpen = false);
    if (searchFocus.hasFocus) searchFocus.unfocus();
  }

  /// Escape and the back gesture dismiss the search suggestions; the filters
  /// are part of the page now, so there is no layer under them to close.
  void _closeOverlays() {
    if (suggestionsOpen) _closeSuggestions();
  }

  void _pickHistory(String value) {
    search.text = value;
    _search();
  }

  Future<void> _removeHistory(String value) async {
    final store = searchHistoryFor(widget.runtime);
    await store.remove(value);
    if (!mounted) return;
    setState(() => historyRows = store.matching(search.text));
    if (historyRows.isEmpty && suggestionRows.isEmpty) {
      setState(() => suggestionsOpen = false);
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

  void _search() {
    _closeSuggestions();
    query = search.text.trim();
    theme = null;
    destination = 0;
    if (query.isNotEmpty) {
      unawaited(searchHistoryFor(widget.runtime).record(query));
    }
    _switchFeed();
    _reload(feed, refreshThemes: false);
  }

  int _lastFeedDestination = 0;

  void _navigate(int value) {
    if (value == destination) return;
    final previous = destination;
    setState(() {
      destination = value;
      // 频道 belongs to 发现 alone: carrying 最新 or 榜单 into 分类 would silently
      // change what that list asks for.
      if (value != 0) view = 'recommend';
    });
    if (value == 2) {
      _switchFeed();
      _themesScope.cancel();
      themesRevision++;
      settingsChanged = true;
      return;
    }
    if (previous == 2 && !settingsChanged && value == _lastFeedDestination) {
      _switchFeed(keepAlive: true, refresh: false);
      _scheduleMore();
      return;
    }
    settingsChanged = false;
    _lastFeedDestination = value;
    query = '';
    search.clear();
    theme = null;
    _switchFeed();
    _reload(feed);
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
    } catch (_) {
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
          view = value;
          if (value == 'rank') {
            genre = 'comic_series';
            theme = null;
            themes = [];
            themesRevision++;
            _themesScope.cancel();
            themesLoading = false;
          } else if (themes.isEmpty) {
            unawaited(_loadThemes(genre));
          }
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

  Widget _searchBox() => TextField(
    key: searchField,
    controller: search,
    focusNode: searchFocus,
    groupId: searchTapGroup,
    textInputAction: TextInputAction.search,
    onSubmitted: (_) => _search(),
    decoration: InputDecoration(
      hintText: '搜索剧名…',
      prefixIcon: const Icon(Icons.search_rounded),
      suffixIcon: IconButton(
        tooltip: '搜索',
        onPressed: _search,
        icon: const Icon(Icons.arrow_forward_rounded),
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
              (viewport.height - anchor.top - 24)
                  .clamp(120.0, 320.0)
                  .toDouble(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _suggestionPanel(double maxHeight) {
    final latest = suggestionRows.any(
      (row) => row.mark == SuggestionMark.latest,
    );
    return TextFieldTapRegion(
      groupId: searchTapGroup,
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
  Widget _sectionTitle() => Text(
    query.isNotEmpty
        ? '“$query”'
        : ranking
        ? '漫剧榜单'
        : destination == 1
        ? '符合筛选的故事'
        : view == 'latest'
        ? '最新上架'
        : '为你发现',
    style: Theme.of(context).textTheme.titleLarge
        ?.copyWith(fontWeight: FontWeight.w600),
  );

  void _clearSearch() {
    query = '';
    search.clear();
    _switchFeed();
    _reload(feed);
  }

  /// The channel, type and board choices, in the same chip language as the
  /// theme rail under them: every option of a group is on screen at once, one
  /// tap applies it, and the current value is the highlighted chip. Each of
  /// these dimensions has three mutually exclusive values -- few enough to show
  /// at once, which is why none of them belongs behind a trigger that opens a
  /// sheet of every group at once.
  Widget _choiceRow(bool compact) {
    List<Widget> group(
      String name,
      String selected,
      Map<String, String> values,
    ) => [
      for (final e in values.entries)
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            key: ValueKey('filter-$name-${e.key}'),
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
    final groups = <List<Widget>>[
      if (query.isNotEmpty)
        [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ActionChip(
              key: const ValueKey('clear-search'),
              avatar: const Icon(Icons.close, size: 18),
              label: const Text('清除搜索'),
              onPressed: _clearSearch,
            ),
          ),
        ]
      else if (destination == 0)
        group('view', view, {
          'recommend': '推荐',
          'latest': '最新',
          // A runtime whose catalog has no rank endpoint never offers 榜单 --
          // a chip that silently reloads the same feed is worse than none.
          if (widget.runtime.catalog is RankCatalogRepository) 'rank': '榜单',
        }),
      if (query.isEmpty)
        ranking
            ? group('board', board, const {
                'recommend': '推荐榜',
                'hot': '热播榜',
                'new': '新剧榜',
              })
            : group('genre', genre, const {
                'short_play': '短剧',
                'comic_series': '漫剧',
                'ai_series': 'AI 短剧',
              }),
    ];
    return SizedBox(
      height: _filterRowHeight,
      child: Scrollbar(
        child: SingleChildScrollView(
          key: const ValueKey('filter-choices'),
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
  Widget _themeRail(bool compact) {
    if (query.isNotEmpty || ranking) return const SizedBox.shrink();
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
                        const ('', '全部'),
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

  Widget _feed(bool compact, double viewportWidth) {
    final padding = compact ? 16.0 : 28.0;
    final list = RefreshIndicator(
      onRefresh: () => _reload(feed, refreshThemes: false, force: true),
      key: const ValueKey('catalog-results'),
      child: CustomScrollView(
        controller: scroll,
        key: const PageStorageKey('catalog-feed'),
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
                    Expanded(child: _searchBox())
                  else
                    SizedBox(
                      width: (viewportWidth * .42).clamp(240.0, 440.0),
                      child: _searchBox(),
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
          SliverToBoxAdapter(child: _choiceRow(compact)),
          SliverPersistentHeader(
            // The rail is the one thing that never leaves. It rides up to the
            // top as the search box and the choice row scroll out and stops
            // there, so a theme stays one tap away from anywhere in the rows.
            pinned: true,
            delegate: _ThemeRailHeader(
              height: query.isEmpty && !ranking ? _filterRowHeight : 0,
              child: _themeRail(compact),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(padding, 12, padding, 10),
              child: _sectionTitle(),
            ),
          ),
          if (refreshing || cachedAt != null || refreshError != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: padding,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    if (refreshing)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        refreshError ??
                            (cachedAt != null
                                ? (refreshing ? '已显示本地缓存，正在刷新…' : '已显示本地缓存')
                                : '正在更新内容…'),
                      ),
                    ),
                    if (!refreshing)
                      TextButton(
                        onPressed: () => _reload(
                          feed,
                          refreshThemes: false,
                          preserveContent: true,
                          force: true,
                        ),
                        child: Text(refreshError == null ? '刷新' : '重试刷新'),
                      ),
                  ],
                ),
              ),
            ),
          if (loading)
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
          if (!loading && items.isNotEmpty)
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
                    drama: items[index],
                    onTap: () => pushAppPage<void>(
                      context,
                      AppScreen.detail,
                      (_) => DetailPage(
                        runtime: widget.runtime,
                        initial: items[index],
                      ),
                    ),
                  ),
                  childCount: items.length,
                ),
              ),
            ),
          if (!loading && items.isEmpty && error == null)
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
          if (error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 32),
                    const SizedBox(height: 12),
                    Text('$error', textAlign: TextAlign.center),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: items.isEmpty
                          ? () =>
                                _reload(feed, refreshThemes: false, force: true)
                          : () => _more(),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          if (!loading && cursor != null && error == null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: loadingMore
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
                          onPressed: () => _more(),
                          child: const Text('加载更多'),
                        ),
                ),
              ),
            ),
          if (!loading && cursor == null && items.isNotEmpty)
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
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _closeOverlays,
      },
      child: Focus(
        autofocus: true,
        child: PopScope(
          canPop: !suggestionsOpen,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _closeOverlays();
          },
          child: list,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final compact = size.maxWidth < 720, wide = size.maxWidth >= 1100;
      _scheduleMore();
      final body = destination == 2
          ? MyPage(
              key: const ValueKey('my-page'),
              runtime: widget.runtime,
              onSettingsChanged: () {
                settingsChanged = true;
              },
            )
          : LayoutBuilder(
              builder: (context, constraints) =>
                  _feed(compact, constraints.maxWidth),
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
      return Scaffold(
        bottomNavigationBar: compact
            ? NavigationBar(
                selectedIndex: destination,
                onDestinationSelected: _navigate,
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
                                leading: destinations[index].icon,
                                title: Text(destinations[index].label),
                                selected: destination == index,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                selectedTileColor: Theme.of(context)
                                    .colorScheme
                                    .primaryContainer,
                                onTap: () => _navigate(index),
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
                    selectedIndex: destination,
                    labelType: NavigationRailLabelType.selected,
                    onDestinationSelected: _navigate,
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
              Expanded(child: body),
            ],
          ),
        ),
      );
    },
  );
}

/// Everything one feed of the catalog owns: its rows, where its pagination got
/// to, and the requests still in flight for it. One of these exists per feed the
/// viewer has opened, so a theme they come back to is the same list they left
/// rather than a fresh request that starts at the top.
class _ThemeFeed {
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
