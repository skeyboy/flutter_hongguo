import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import '../../localization/application_name.dart';
import '../../platform/runtime.dart';
import '../local_cache_page.dart';
import '../my_page.dart';
import 'tv_feed_page.dart';

/// A local router keeps the TV catalog isolated from the host's mobile routes.
class TvLibraryPage extends StatefulWidget {
  final AppRuntime runtime;
  const TvLibraryPage({super.key, required this.runtime});
  @override
  State<TvLibraryPage> createState() => _TvLibraryPageState();
}

class _TvLibraryPageState extends State<TvLibraryPage> {
  late final router = RootStackRouter.build(
    routes: [
      NamedRouteDef(
        name: 'TvCatalogShell',
        path: '/',
        initial: true,
        builder: (_, _) => const _TvSidebarShell(),
        children: [
          for (var i = 0; i < 3; i++)
            NamedRouteDef(
              name: _sidebarRoutes[i],
              path: 'catalog-$i',
              builder: (_, data) => _TvSidebarPane(
                index: i,
                args: data.argsAs<_SidebarArgs>(),
                child: _TvGenrePage(
                  runtime: widget.runtime,
                  index: i,
                  activeSection: data.argsAs<_SidebarArgs>().active,
                ),
              ),
              children: [
                NamedRouteDef(
                  name: 'TvThemeFeed',
                  path: 'feed/:id',
                  usesPathAsKey: true,
                  builder: (_, data) {
                    final args = data.argsAs<_FeedArgs>();
                    return TvFeedPage(
                      key: args.pageKey,
                      runtime: widget.runtime,
                      genre: args.genre,
                      theme: args.theme,
                      routeId: args.id,
                      active: args.active,
                      searchQuery: args.searchQuery,
                    );
                  },
                ),
              ],
            ),
          NamedRouteDef(
            name: _sidebarRoutes[3],
            path: 'local-cache',
            builder: (_, data) => _TvSidebarPane(
              index: 3,
              args: data.argsAs<_SidebarArgs>(),
              child: LocalCachePage(runtime: widget.runtime),
            ),
          ),
          NamedRouteDef(
            name: _sidebarRoutes[4],
            path: 'my',
            builder: (_, data) => _TvSidebarPane(
              index: 4,
              args: data.argsAs<_SidebarArgs>(),
              child: MyPage(runtime: widget.runtime),
            ),
          ),
        ],
      ),
    ],
  );
  @override
  void initState() {
    super.initState();
    unawaited(router.replaceAll([const NamedRoute('TvCatalogShell')]));
  }

  @override
  void dispose() {
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Router(routerDelegate: router.delegate());
}

const _sidebarRoutes = [
  'TvShortCatalog',
  'TvComicCatalog',
  'TvAiCatalog',
  'TvLocalCache',
  'TvMy',
];

class _SidebarArgs {
  final ValueNotifier<int> active;
  final FocusScopeNode focus;
  final VoidCallback exitLeft;
  const _SidebarArgs(this.active, this.focus, this.exitLeft);
}

class _TvSidebarPane extends StatelessWidget {
  final int index;
  final _SidebarArgs args;
  final Widget child;
  const _TvSidebarPane({
    required this.index,
    required this.args,
    required this.child,
  });
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: args.active,
    builder: (_, selected, child) => TickerMode(
      enabled: selected == index,
      child: TvPaneBoundary(
        exitLeft: args.exitLeft,
        child: FocusScope(node: args.focus, child: child!),
      ),
    ),
    child: child,
  );
}

class _TvSidebarShell extends StatefulWidget {
  const _TvSidebarShell();
  @override
  State<_TvSidebarShell> createState() => _TvSidebarShellState();
}

class _TvSidebarShellState extends State<_TvSidebarShell> {
  static const labels = ['短剧', '漫剧', 'AI 短剧', '本地缓存', '我的'];
  final selected = ValueNotifier(0);
  final nav = List.generate(5, (i) => FocusNode(debugLabel: 'nav-$i'));
  final panes = List.generate(
    5,
    (i) => FocusScopeNode(
      debugLabel: 'tv-pane-$i',
      directionalTraversalEdgeBehavior: TraversalEdgeBehavior.stop,
    ),
  );
  final remembered = <int, FocusNode>{};
  late final routes = [
    for (var i = 0; i < 5; i++)
      NamedRoute<_SidebarArgs>(
        _sidebarRoutes[i],
        args: _SidebarArgs(selected, panes[i], _exitLeft),
      ),
  ];
  TabsRouter? tabs;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_rememberFocus);
  }

  void _rememberFocus() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null &&
        focus != panes[selected.value] &&
        focus.ancestors.contains(panes[selected.value])) {
      remembered[selected.value] = focus;
    }
  }

  void _change(int index) {
    if (selected.value == index) return;
    setState(() {
      selected.value = index;
      tabs?.setActiveIndex(index);
    });
  }

  void _exitLeft() {
    _rememberFocus();
    nav[selected.value].requestFocus();
  }

  void _enterRight() {
    final index = selected.value, previous = remembered[selected.value];
    if (previous?.context != null && previous!.canRequestFocus) {
      previous.requestFocus();
    } else {
      // A removed/off-screen card must not reset a genre to its first theme.
      // Prefer the selected control before falling back to ordinary traversal.
      for (final candidate in panes[index].descendants) {
        final control = candidate.context
            ?.findAncestorWidgetOfExactType<TvFocusable>();
        if (candidate.canRequestFocus && control?.selected == true) {
          candidate.requestFocus();
          return;
        }
      }
      panes[index].requestFocus();
      if (panes[index].focusedChild == null) panes[index].nextFocus();
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_rememberFocus);
    for (final node in nav) {
      node.dispose();
    }
    for (final node in panes) {
      node.dispose();
    }
    selected.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AutoTabsRouter(
    routes: routes,
    duration: Duration.zero,
    transitionBuilder: (_, child, _) => child,
    builder: (context, child) {
      tabs = AutoTabsRouter.of(context);
      return Scaffold(
        body: SafeArea(
          child: TvNavigation(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 28, 28, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 170,
                    child: FocusTraversalGroup(
                      child: ListView(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              '${ApplicationName.of(context)} TV',
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          for (var i = 0; i < labels.length; i++)
                            Focus(
                              canRequestFocus: false,
                              onKeyEvent: (_, event) {
                                if (event is KeyUpEvent) {
                                  return KeyEventResult.ignored;
                                }
                                final key = event.logicalKey;
                                if (key == LogicalKeyboardKey.arrowRight) {
                                  _enterRight();
                                  return KeyEventResult.handled;
                                }
                                if (key == LogicalKeyboardKey.arrowUp ||
                                    key == LogicalKeyboardKey.arrowDown) {
                                  final next =
                                      i +
                                      (key == LogicalKeyboardKey.arrowUp
                                          ? -1
                                          : 1);
                                  if (next >= 0 && next < nav.length) {
                                    nav[next].requestFocus();
                                  }
                                  return KeyEventResult.handled;
                                }
                                if (key == LogicalKeyboardKey.arrowLeft) {
                                  return KeyEventResult.handled;
                                }
                                return KeyEventResult.ignored;
                              },
                              child: TvFocusable(
                                label: labels[i],
                                focusNode: nav[i],
                                autofocus: i == 0,
                                selected: selected.value == i,
                                onActivate: () => _change(i),
                                onFocusChange: (focused) {
                                  if (focused) _change(i);
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(
                                    labels[i],
                                    style: const TextStyle(fontSize: 21),
                                  ),
                                ),
                              ),
                            ),
                          const Text(
                            '上下切换栏目\n向右进入 · 向左返回',
                            style: TextStyle(fontSize: 16),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(child: child),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _FeedArgs {
  final String genre, id;
  final String? theme;
  final ValueNotifier<String> active;
  final ValueNotifier<String>? searchQuery;
  final GlobalKey pageKey = GlobalKey();
  _FeedArgs(this.genre, this.id, this.active, {this.theme, this.searchQuery});
}

class _TvGenrePage extends StatefulWidget {
  final AppRuntime runtime;
  final int index;
  final ValueNotifier<int> activeSection;
  const _TvGenrePage({
    required this.runtime,
    required this.index,
    required this.activeSection,
  });
  @override
  State<_TvGenrePage> createState() => _TvGenrePageState();
}

class _TvGenrePageState extends State<_TvGenrePage> {
  static const genres = ['short_play', 'comic_series', 'ai_series'];
  static const labels = ['短剧', '漫剧', 'AI 短剧', '本地缓存', '我的'];
  final nodes = <String, FocusNode>{};
  final themes = <String, List<CatalogFilter>>{};
  final selectedThemes = <String, String>{};
  final queries = {for (final genre in genres) genre: ValueNotifier('')};
  final active = ValueNotifier('short_play:');
  final search = TextEditingController();
  List<PageRouteInfo>? routes;
  bool themesLoading = false;
  String? themesError;
  final routeIds = <String>[];
  final mountedRoutes = <String>{};
  TabsRouter? tabs;
  int get section => widget.index;
  late String lastRouteId;
  String get genre => genres[section.clamp(0, 2)];
  String get selected => selectedThemes[genre] ?? '';
  FocusNode node(String id) =>
      nodes.putIfAbsent(id, () => FocusNode(debugLabel: id));

  @override
  void initState() {
    super.initState();
    lastRouteId = '$genre:';
    active.value = lastRouteId;
    widget.activeSection.addListener(_sidebarChanged);
    _registerRoutes(const []);
    unawaited(_initialize());
  }

  void _registerRoutes(List<CatalogFilter> values) {
    // Append only: existing route indexes, list state and search stay stable.
    final registered = [...?routes];
    for (final theme in ['', '__search__', ...values.map((v) => v.id)]) {
      final id = '$genre:$theme';
      if (routeIds.contains(id)) continue;
      routeIds.add(id);
      registered.add(
        NamedRoute<_FeedArgs>(
          'TvThemeFeed',
          params: {'id': id},
          args: _FeedArgs(
            genre,
            id,
            active,
            theme: theme.isEmpty || theme == '__search__' ? null : theme,
            searchQuery: theme == '__search__' ? queries[genre] : null,
          ),
        ),
      );
    }
    routes = registered;
  }

  Future<void> _initialize() async {
    if (themesLoading) return;
    setState(() {
      themesLoading = true;
      themesError = null;
    });
    try {
      final values = await widget.runtime.catalog.themes(genre);
      if (!mounted) return;
      final ids = <String>{};
      final valid = values
          .where((v) => v.id.isNotEmpty && v.name.isNotEmpty && ids.add(v.id))
          .toList();
      setState(() {
        themes[genre] = valid;
        _registerRoutes(valid);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final index = routeIds.indexOf(lastRouteId);
        if (index >= 0 && tabs?.activeIndex != index) {
          tabs?.setActiveIndex(index);
        }
      });
    } catch (_) {
      if (mounted) setState(() => themesError = '题材加载失败');
    } finally {
      if (mounted) setState(() => themesLoading = false);
    }
  }

  void _activate(String id) {
    lastRouteId = id;
    active.value = widget.activeSection.value == section ? id : '';
    final index = routeIds.indexOf(id);
    if (index >= 0) tabs?.setActiveIndex(index);
  }

  void _selectTheme(String id) {
    if (selected == id && active.value == '$genre:$id') return;
    setState(() {
      selectedThemes[genre] = id;
    });
    _activate('$genre:$id');
  }

  void _sidebarChanged() {
    active.value = widget.activeSection.value == section ? lastRouteId : '';
  }

  Future<void> _searchDialog() async {
    final requestedGenre = genre;
    search.text = queries[requestedGenre]!.value;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('搜索${labels[section]}'),
        content: TextField(
          autofocus: true,
          controller: search,
          textInputAction: TextInputAction.search,
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, search.text),
            child: const Text('搜索'),
          ),
        ],
      ),
    );
    if (!mounted || result == null) return;
    final value = result.trim();
    if (value.isEmpty) {
      _selectTheme('');
      return;
    }
    queries[requestedGenre]!.value = value;
    setState(() {});
    _activate('$requestedGenre:__search__');
  }

  Widget action(
    String label,
    VoidCallback callback, {
    FocusNode? focusNode,
    bool autofocus = false,
    bool selected = false,
  }) => TvFocusable(
    label: label,
    onActivate: callback,
    focusNode: focusNode,
    autofocus: autofocus,
    selected: selected,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Text(label, style: const TextStyle(fontSize: 21)),
    ),
  );

  Widget header() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Material(
        color: Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Row(
            children: [
              Expanded(
                child: TvChoiceRail(
                  key: ValueKey('themes-$section'),
                  choices: [
                    const TvChoice('', '全部'),
                    for (final v in themes[genre] ?? <CatalogFilter>[])
                      TvChoice(v.id, v.name),
                  ],
                  selected: active.value.endsWith(':__search__')
                      ? '__search__'
                      : selected,
                  onSelected: _selectTheme,
                  trailingFocusNode: node('tv-search'),
                  lastChoiceFocusNode: node('tv-last-theme-$section'),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 120,
                child: Focus(
                  canRequestFocus: false,
                  onKeyEvent: (_, event) {
                    if (event is KeyUpEvent ||
                        event.logicalKey != LogicalKeyboardKey.arrowLeft) {
                      return KeyEventResult.ignored;
                    }
                    node('tv-last-theme-$section').requestFocus();
                    return KeyEventResult.handled;
                  },
                  child: action(
                    '搜索',
                    _searchDialog,
                    selected: active.value.endsWith(':__search__'),
                    focusNode: node('tv-search'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      // Fixed height also prevents entering/leaving search from moving the grid.
      SizedBox(
        height: 28,
        child: active.value.endsWith(':__search__')
            ? Text(
                '搜索：${queries[genre]!.value}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : themesLoading
            ? const Text('题材加载中', style: TextStyle(fontSize: 16))
            : themesError != null
            ? TvFocusable(
                label: '重试题材',
                onActivate: () => unawaited(_initialize()),
                child: const Text(
                  '题材加载失败 · 重试题材',
                  style: TextStyle(fontSize: 16),
                ),
              )
            : const SizedBox.shrink(),
      ),
    ],
  );

  @override
  void dispose() {
    widget.activeSection.removeListener(_sidebarChanged);
    active.dispose();
    search.dispose();
    for (final q in queries.values) {
      q.dispose();
    }
    for (final n in nodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (routes == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return AutoTabsRouter.builder(
      routes: routes!,
      onNavigate: (router) {
        // auto_route replaceAll defaults to the first same-name route. Restore
        // the logical selection before building, not one frame afterwards.
        final index = routeIds.indexOf(lastRouteId);
        if (index >= 0 && router.activeIndex != index) {
          router.setActiveIndex(index, notify: false);
        }
      },
      builder: (context, children, router) {
        tabs = router;
        mountedRoutes.add(routeIds[router.activeIndex]);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header(),
            Expanded(
              child: IndexedStack(
                index: router.activeIndex,
                children: [
                  for (var i = 0; i < children.length; i++)
                    ExcludeFocus(
                      excluding: i != router.activeIndex,
                      child: ExcludeSemantics(
                        excluding: i != router.activeIndex,
                        child: mountedRoutes.contains(routeIds[i])
                            ? children[i]
                            : const SizedBox.shrink(),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
