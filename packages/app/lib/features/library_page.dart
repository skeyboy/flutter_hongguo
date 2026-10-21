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
import '../search/search_suggestions.dart';
import 'detail_page.dart';
import 'my_page.dart';

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
  String get sort => settingsFor(widget.runtime).catalogSort;
  String? theme, cursor;
  StreamSubscription<AppSettings>? sortEvents;
  late String lastSort;
  List<Drama> items = [];
  List<CatalogFilter> themes = [];
  bool loading = true,
      loadingMore = false,
      autoPaused = false,
      autoScheduled = false,
      settingsChanged = false;
  Object? error;
  bool filterOpen = false, themesLoading = false;
  String focusedFilter = 'genre';
  String? themesError;
  Timer? filterTimer;
  int themesRevision = 0;
  String? refreshError;
  DateTime? cachedAt;
  bool refreshing = false;
  late final LibraryCache feedCache;
  String get feedKey => jsonEncode({
    'destination': destination,
    'query': query,
    'view': view,
    'genre': genre,
    'sort': sort,
    'theme': theme,
    'board': board,
  });
  int revision = 0, emptyPages = 0, destination = 0;
  bool get ranking => query.isEmpty && destination == 0 && view == 'rank';
  bool get mobile => MediaQuery.sizeOf(context).width < 720;
  @override
  void initState() {
    super.initState();
    final runtime = widget.runtime;
    feedCache = runtime is LibraryCacheRuntime
        ? runtime.libraryCache
        : LibraryCache();
    lastSort = sort;
    if (runtime is ConfigurableRuntime) {
      sortEvents = runtime.settingsChanges.listen((value) {
        if (!mounted || value.catalogSort == lastSort) return;
        lastSort = value.catalogSort;
        settingsChanged = true;
        if (destination != 2 && query.isEmpty && !ranking) unawaited(_reload());
      });
    }
    scroll.addListener(_nearEnd);
    searchFocus.addListener(_onSearchFocus);
    search.addListener(_onSearchText);
    _reload();
  }

  @override
  void dispose() {
    revision++;
    suggestionsEntry?.remove();
    suggestionsEntry = null;
    unawaited(sortEvents?.cancel());
    filterTimer?.cancel();
    scroll.dispose();
    search.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  Future<CatalogPage> _page({String? next}) {
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
      seen: next == null ? [] : items.map((d) => d.id).toList(),
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
    if (filterOpen ||
        suggestionsOpen ||
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

  Future<void> _reload({
    bool refreshThemes = true,
    bool preserveContent = false,
  }) async {
    filterTimer?.cancel();
    final current = ++revision;
    final key = feedKey;
    setState(() {
      loading = !preserveContent || items.isEmpty;
      refreshing = true;
      refreshError = null;
      cachedAt = null;
      loadingMore = false;
      autoPaused = false;
      emptyPages = 0;
      error = null;
      if (!preserveContent) items = [];
      cursor = null;
    });
    if (scroll.hasClients) scroll.jumpTo(0);
    if (refreshThemes && query.isEmpty && !ranking) {
      unawaited(_loadThemes(genre));
    }
    final cached = await feedCache.readFeed(key);
    if (!mounted || current != revision) return;
    if (cached != null) {
      setState(() {
        items = cached.page.items;
        cursor = cached.page.nextCursor;
        cachedAt = cached.updated;
        loading = false;
      });
    }
    try {
      final page = await _page();
      if (!mounted || current != revision) return;
      final seen = <String>{};
      setState(() {
        items = page.items.where((d) => seen.add(d.id)).toList();
        cursor = page.nextCursor;
        loading = false;
        refreshing = false;
        cachedAt = null;
      });
      await _saveSnapshot(key, current);
      _scheduleMore();
    } catch (e) {
      if (mounted && current == revision) {
        setState(() {
          if (cached != null || items.isNotEmpty) {
            refreshError = cached != null
                ? '网络刷新失败，正在显示本地缓存。'
                : '网络刷新失败，仍显示上次结果。';
            autoPaused = true;
          } else {
            error = e;
          }
          refreshing = false;
          loading = false;
        });
      }
    }
  }

  Future<void> _saveSnapshot(String key, int current) async {
    final page = CatalogPage(List.of(items), nextCursor: cursor);
    try {
      await feedCache.writeFeed(key, page);
    } catch (_) {
      if (mounted && current == revision) {
        setState(() => refreshError = '内容已更新，但本地缓存保存失败。');
      }
    }
  }

  Future<void> _more({bool automatic = false}) async {
    if (cursor == null ||
        loadingMore ||
        loading ||
        refreshing ||
        (automatic && autoPaused)) {
      return;
    }
    final current = revision, requested = cursor!, key = feedKey;
    setState(() {
      loadingMore = true;
      autoPaused = false;
      error = null;
    });
    try {
      final page = await _page(next: requested);
      if (!mounted || current != revision) return;
      final seen = items.map((d) => d.id).toSet(), fresh = <Drama>[];
      for (final drama in page.items) {
        if (seen.add(drama.id)) fresh.add(drama);
      }
      setState(() {
        items = [...items, ...fresh];
        loadingMore = false;
        emptyPages = fresh.isEmpty ? emptyPages + 1 : 0;
        if (page.nextCursor == requested) {
          autoPaused = true;
          error = '分页暂未推进，请稍后重试或刷新。';
        } else {
          cursor = page.nextCursor;
        }
        if (emptyPages >= 3 && cursor != null) {
          autoPaused = true;
          error = '暂时没有更多新内容，可手动重试。';
        }
      });
      await _saveSnapshot(key, current);
      _scheduleMore();
    } catch (e) {
      if (mounted && current == revision) {
        setState(() {
          error = e;
          loadingMore = false;
          autoPaused = true;
        });
      }
    }
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
    setState(() {
      suggestionsOpen = true;
      historyRows = searchHistoryFor(widget.runtime).matching(search.text);
      suggestionAnchor = _anchoredSearchRect();
    });
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

  /// Escape and the back gesture close the nearest layer only.
  void _closeOverlays() {
    if (suggestionsOpen) {
      _closeSuggestions();
      return;
    }
    _closeFilters();
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
    filterOpen = false;
    _closeSuggestions();
    query = search.text.trim();
    theme = null;
    destination = 0;
    if (query.isNotEmpty) {
      unawaited(searchHistoryFor(widget.runtime).record(query));
    }
    _reload(refreshThemes: false);
  }

  int _lastFeedDestination = 0;

  void _navigate(int value) {
    if (value == destination) return;
    final previous = destination;
    setState(() {
      destination = value;
      filterOpen = false;
    });
    if (value == 2) return;
    if (previous == 2 && !settingsChanged && value == _lastFeedDestination) {
      _scheduleMore();
      return;
    }
    settingsChanged = false;
    _lastFeedDestination = value;
    query = '';
    search.clear();
    theme = null;
    _reload();
  }

  Future<void> _loadThemes(String requestedGenre) async {
    final ticket = ++themesRevision;
    setState(() {
      themesLoading = true;
      themesError = null;
    });
    try {
      final values = await widget.runtime.catalog.themes(requestedGenre);
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

  void _toggleFilters(String group) {
    setState(() {
      filterOpen = !filterOpen || focusedFilter != group;
      focusedFilter = group;
    });
    if (!filterOpen) _scheduleMore();
  }

  void _closeFilters() {
    if (!filterOpen) return;
    setState(() => filterOpen = false);
    _scheduleMore();
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
            themesLoading = false;
          } else if (themes.isEmpty) {
            unawaited(_loadThemes(genre));
          }
      }
    });
    if (before == feedKey) return;
    final key = feedKey, current = ++revision;
    filterTimer?.cancel();
    setState(() {
      refreshing = true;
      loadingMore = false;
      autoPaused = true;
      cursor = null;
      error = null;
      refreshError = null;
    });
    unawaited(
      feedCache.readFeed(key).then((cached) {
        if (mounted && current == revision && cached != null) {
          setState(() {
            items = cached.page.items;
            cachedAt = cached.updated;
            loading = false;
          });
        }
      }),
    );
    filterTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) _reload(refreshThemes: false, preserveContent: true);
    });
    if (scroll.hasClients) scroll.jumpTo(0);
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

  Widget _header(bool compact) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (compact) ...[
        Row(
          children: [
            const Brand(),
            const Spacer(),
            IconButton(
              tooltip: '离线检查',
              onPressed: _diagnostics,
              icon: const Icon(Icons.verified_outlined),
            ),
            IconButton(
              tooltip: '我的',
              onPressed: () => _navigate(2),
              icon: const Icon(Icons.person_outline),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _searchBox(),
        const SizedBox(height: 18),
      ],
      Text(
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
      ),
    ],
  );

  Widget _stickyFilters(bool compact) {
    Widget trigger(String group, String label) => TextButton.icon(
      key: ValueKey('sticky-$group'),
      onPressed: () => _toggleFilters(group),
      iconAlignment: IconAlignment.end,
      icon: Icon(
        filterOpen && focusedFilter == group
            ? Icons.expand_less
            : Icons.expand_more,
        size: 18,
      ),
      label: Text(label),
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    );
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      elevation: 1,
      child: SizedBox(
        height: 64,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 24),
          child: Row(
            children: [
              if (query.isNotEmpty) ...[
                const Text('搜索结果'),
                TextButton(
                  onPressed: () {
                    query = '';
                    search.clear();
                    _reload();
                  },
                  child: const Text('清除搜索'),
                ),
              ] else ...[
                if (destination == 0)
                  trigger(
                    'view',
                    {'recommend': '推荐', 'latest': '最新', 'rank': '榜单'}[view]!,
                  ),
                if (ranking)
                  trigger(
                    'board',
                    {'recommend': '推荐榜', 'hot': '热播榜', 'new': '新剧榜'}[board]!,
                  )
                else ...[
                  trigger(
                    'genre',
                    {
                      'short_play': '短剧',
                      'comic_series': '漫剧',
                      'ai_series': 'AI 短剧',
                    }[genre]!,
                  ),
                  trigger(
                    'theme',
                    theme == null
                        ? '全部题材'
                        : themes
                                  .where((e) => e.id == theme)
                                  .firstOrNull
                                  ?.name ??
                              '已选题材',
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterPanel(bool compact, double maxHeight) {
    Widget group(
      String name,
      String label,
      String selected,
      Map<String, String> values,
    ) {
      final chips = [
        for (final e in values.entries)
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 6),
            child: ChoiceChip(
              key: ValueKey('filter-$name-${e.key}'),
              label: Text(e.value),
              selected: selected == e.key,
              onSelected: (_) {
                if (selected != e.key) _selectFilter(name, e.key);
              },
              materialTapTargetSize: MaterialTapTargetSize.padded,
            ),
          ),
      ];
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 48,
              child: Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(
                  label,
                  style: TextStyle(
                    fontWeight: focusedFilter == name
                        ? FontWeight.w700
                        : FontWeight.w400,
                    color: focusedFilter == name
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                ),
              ),
            ),
            Expanded(
              child: compact
                  ? Scrollbar(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: chips),
                      ),
                    )
                  : Wrap(children: chips),
            ),
          ],
        ),
      );
    }

    return Material(
      key: const ValueKey('horizontal-filter-panel'),
      color: Theme.of(context).colorScheme.surface,
      shape: Border(
        bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  compact ? 16 : 28,
                  8,
                  compact ? 16 : 28,
                  0,
                ),
                child: Column(
                  children: [
                    if (destination == 0)
                      group('view', '频道', view, {
                        'recommend': '推荐',
                        'latest': '最新',
                        if (widget.runtime.catalog is RankCatalogRepository)
                          'rank': '榜单',
                      }),
                    if (ranking) ...[
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('当前为漫剧榜单'),
                      ),
                      group('board', '榜单', board, const {
                        'recommend': '推荐榜',
                        'hot': '热播榜',
                        'new': '新剧榜',
                      }),
                    ] else ...[
                      group('genre', '类型', genre, const {
                        'short_play': '短剧',
                        'comic_series': '漫剧',
                        'ai_series': 'AI 短剧',
                      }),
                      if (themesLoading)
                        const LinearProgressIndicator()
                      else if (themesError != null)
                        TextButton(
                          onPressed: () => _loadThemes(genre),
                          child: Text('$themesError，重试'),
                        )
                      else
                        group('theme', '题材', theme ?? '', {
                          '': '全部',
                          for (final e in themes) e.id: e.name,
                        }),
                    ],
                  ],
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _closeFilters,
                icon: const Icon(Icons.expand_less),
                label: const Text('收起筛选'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _feed(bool compact, double viewportWidth, double viewportHeight) {
    final padding = compact ? 16.0 : 28.0;
    final list = RefreshIndicator(
      onRefresh: () => _reload(refreshThemes: false),
      key: const ValueKey('catalog-results'),
      child: CustomScrollView(
        controller: scroll,
        key: const PageStorageKey('catalog-feed'),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(padding, 16, padding, 18),
              child: _header(false),
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
                            (cachedAt != null ? '已显示本地缓存，正在刷新…' : '正在更新内容…'),
                      ),
                    ),
                    if (!refreshing)
                      TextButton(
                        onPressed: () => _reload(
                          refreshThemes: false,
                          preserveContent: true,
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
                          ? () => _reload(refreshThemes: false)
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
          canPop: !filterOpen && !suggestionsOpen,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _closeOverlays();
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  padding,
                  compact ? 8 : 16,
                  padding,
                  8,
                ),
                child: compact && viewportHeight < 400
                    ? Row(
                        children: [
                          Expanded(child: _searchBox()),
                          IconButton(
                            tooltip: '我的',
                            onPressed: () => _navigate(2),
                            icon: const Icon(Icons.person_outline),
                          ),
                        ],
                      )
                    : compact
                    ? Column(
                        children: [
                          Row(
                            children: [
                              const Brand(),
                              const Spacer(),
                              IconButton(
                                tooltip: '离线检查',
                                onPressed: _diagnostics,
                                icon: const Icon(Icons.verified_outlined),
                              ),
                              IconButton(
                                tooltip: '我的',
                                onPressed: () => _navigate(2),
                                icon: const Icon(Icons.person_outline),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          _searchBox(),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(
                            child: Text(
                              destination == 1 ? '分类浏览' : '发现好故事',
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: (viewportWidth * .42).clamp(240, 440),
                            child: _searchBox(),
                          ),
                          IconButton(
                            tooltip: '离线检查',
                            onPressed: _diagnostics,
                            icon: const Icon(Icons.verified_outlined),
                          ),
                          IconButton(
                            tooltip: '我的',
                            onPressed: () => _navigate(2),
                            icon: const Icon(Icons.person_outline),
                          ),
                        ],
                      ),
              ),
              _stickyFilters(compact),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, area) => Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned.fill(child: list),
                      if (filterOpen) ...[
                        Positioned.fill(
                          child: GestureDetector(
                            key: const ValueKey('filter-dismiss-area'),
                            behavior: HitTestBehavior.opaque,
                            onTap: _closeFilters,
                            child: ColoredBox(
                              color: Colors.black.withValues(alpha: .12),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: _filterPanel(
                            compact,
                            area.maxHeight.clamp(48, 320).toDouble(),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
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
                  _feed(compact, constraints.maxWidth, constraints.maxHeight),
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
