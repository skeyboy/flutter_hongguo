import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import '../../platform/runtime.dart';
import '../../widgets/drama_cover.dart';
import 'data/tv_feed_cache.dart';
import 'tv_detail_page.dart';

/// One route owns one theme's list, pagination, requests, scroll and focus.
class TvFeedPage extends StatefulWidget {
  final AppRuntime runtime;
  final String genre, routeId;
  final String? theme;
  final ValueNotifier<String> active;
  final ValueNotifier<String>? searchQuery;
  const TvFeedPage({
    super.key,
    required this.runtime,
    required this.genre,
    required this.routeId,
    required this.active,
    this.theme,
    this.searchQuery,
  });
  @override
  State<TvFeedPage> createState() => _TvFeedPageState();
}

class _TvFeedPageState extends State<TvFeedPage> {
  final cache = TvFeedCache();
  final items = <Drama>[];
  final visited = <String>{};
  StreamSubscription<AppSettings>? settingsSubscription;
  Timer? refreshTimer;
  CatalogRequestScope _requestScope = CatalogRequestScope();
  String? cursor, error;
  bool loading = false, failedMore = false, scheduled = false;
  int revision = 0, emptyPages = 0;
  late TvFeedKey applied;
  CatalogPage? firstPage;
  bool get active => widget.active.value == widget.routeId;
  TvFeedKey get key => (
    genre: widget.genre,
    theme: widget.theme ?? '',
    query: widget.searchQuery?.value ?? '',
    sort: settingsFor(widget.runtime).catalogSort,
    pageSize: settingsFor(widget.runtime).tvPageSize,
  );

  @override
  void initState() {
    super.initState();
    applied = key;
    loading = active;
    widget.active.addListener(_activated);
    widget.searchQuery?.addListener(_configurationChanged);
    final runtime = widget.runtime;
    if (runtime is ConfigurableRuntime) {
      settingsSubscription = runtime.settingsChanges.listen(
        (_) => _configurationChanged(),
      );
    }
    _activated();
  }

  void _configurationChanged() {
    if (!mounted || applied == key) return;
    revision++;
    _requestScope.cancel();
    applied = key;
    final saved = cache.read(applied);
    setState(() {
      items
        ..clear()
        ..addAll(saved?.items ?? const <Drama>[]);
      firstPage = saved;
      cursor = saved?.nextCursor;
      loading = false;
      error = null;
      visited.clear();
      emptyPages = 0;
    });
    _activated();
  }

  void _activated() {
    refreshTimer?.cancel();
    if (!active) {
      _requestScope.cancel();
      revision++;
      setState(() => loading = false);
      return;
    }
    setState(() => loading = true);
    // A kept-alive page remains visible immediately; only its refresh is debounced.
    refreshTimer = Timer(const Duration(milliseconds: 220), () {
      if (mounted && active) unawaited(load());
    });
  }

  void scheduleMore() {
    if (scheduled ||
        !mounted ||
        !active ||
        loading ||
        cursor == null ||
        error != null ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduled = false;
      if (mounted &&
          active &&
          !loading &&
          cursor != null &&
          error == null &&
          ModalRoute.of(context)?.isCurrent != false) {
        unawaited(load(more: true));
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> load({bool more = false}) async {
    if (!mounted || (more && (loading || cursor == null))) return;
    if (!more) {
      _requestScope.cancel();
      _requestScope = CatalogRequestScope();
    }
    final requested = applied;
    final ticket = more ? revision : ++revision;
    final requestedCursor = more ? cursor : null;
    setState(() {
      loading = true;
      error = null;
      failedMore = more;
    });
    try {
      final page = await _requestScope.run(
        () => requested.query.isNotEmpty
            ? widget.runtime.catalog.search(
                requested.query,
                cursor: requestedCursor,
              )
            : widget.runtime.catalog.browse(
                genre: requested.genre,
                theme: requested.theme.isEmpty ? null : requested.theme,
                sort: requested.sort,
                cursor: requestedCursor,
                seen: more ? items.map((d) => d.id).toList() : const [],
              ),
      );
      if (!mounted || ticket != revision || requested != applied) return;
      setState(() {
        if (!more) {
          final fresh = cache.reconcile(requested, page);
          final unchanged =
              firstPage != null &&
              firstPage!.items.length == fresh.items.length &&
              List.generate(
                fresh.items.length,
                (i) => identical(firstPage!.items[i], fresh.items[i]),
              ).every((v) => v);
          if (!unchanged) {
            final oldHead =
                firstPage?.items.map((d) => d.id).toSet() ?? <String>{};
            final tail = items.where((d) => !oldHead.contains(d.id)).toList();
            final ids = fresh.items.map((d) => d.id).toSet();
            items
              ..clear()
              ..addAll(fresh.items)
              ..addAll(tail.where((d) => ids.add(d.id)));
            cursor = fresh.nextCursor;
            visited.clear();
            emptyPages = 0;
          } else if (items.length == fresh.items.length) {
            cursor = fresh.nextCursor;
          }
          firstPage = fresh;
        } else {
          final ids = items.map((d) => d.id).toSet();
          final before = items.length;
          items.addAll(
            page.items.where((d) => d.id.isNotEmpty && ids.add(d.id)),
          );
          emptyPages = items.length == before ? emptyPages + 1 : 0;
          if (requestedCursor != null) visited.add(requestedCursor);
          cursor =
              page.nextCursor == requestedCursor ||
                  visited.contains(page.nextCursor) ||
                  emptyPages >= 2
              ? null
              : page.nextCursor;
        }
        loading = false;
      });
    } catch (e) {
      if (mounted && ticket == revision) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  Future<void> open(Drama drama) async {
    final focus = FocusManager.instance.primaryFocus;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: '/tv/detail/${drama.id}'),
        builder: (_) => TvDetailPage(runtime: widget.runtime, initial: drama),
      ),
    );
    if (mounted) {
      await WidgetsBinding.instance.endOfFrame;
      if (mounted && focus?.context != null) focus!.requestFocus();
    }
  }

  @override
  void dispose() {
    revision++;
    _requestScope.cancel();
    refreshTimer?.cancel();
    widget.active.removeListener(_activated);
    widget.searchQuery?.removeListener(_configurationChanged);
    unawaited(settingsSubscription?.cancel());
    super.dispose();
  }

  Widget _placeholder() => Center(
    key: const ValueKey('tv-feed-placeholder'),
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          key: const ValueKey('tv-feed-placeholder-content'),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const SizedBox(
                width: 48,
                height: 48,
                child: CircularProgressIndicator(),
              )
            else
              Icon(
                error != null
                    ? Icons.cloud_off_outlined
                    : Icons.video_library_outlined,
                size: 56,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            const SizedBox(height: 20),
            Text(
              loading
                  ? '正在加载'
                  : error != null
                  ? '加载失败'
                  : '暂无内容',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 26),
            ),
            if (!loading && error != null) ...[
              const SizedBox(height: 12),
              const Text(
                '暂时无法获取影视内容',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18),
              ),
              const SizedBox(height: 24),
              TvFocusable(
                label: '重试',
                onActivate: () => load(more: failedMore),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.refresh),
                      SizedBox(width: 8),
                      Text('重试', style: TextStyle(fontSize: 22)),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => TickerMode(
    enabled: active,
    child: Stack(
      fit: StackFit.expand,
      children: [
        FocusTraversalGroup(
          child: TvGrid(
            maxExtent: 190,
            aspectRatio: .68,
            ids: [for (final d in items) d.id],
            label: (i) => items[i].title,
            activate: (i) => open(items[i]),
            onNearEnd: scheduleMore,
            hasMore: cursor != null && error == null,
            navigationEnabled: active,
            itemBuilder: (context, i) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: DramaCover(drama: items[i])),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: Text(
                      items[i].title,
                      key: ValueKey(items[i].title),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 20),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (items.isEmpty) Positioned.fill(child: _placeholder()),
        // Retrying/loading never reserves a footer or changes the grid viewport.
        // Keep a recoverable error reachable without displacing existing cards.
        if (items.isNotEmpty && error != null)
          Positioned(
            key: const ValueKey('tv-feed-status'),
            left: 0,
            right: 0,
            bottom: 4,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(10),
                child: TvFocusable(
                  label: '重试',
                  onActivate: () => load(more: failedMore),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('加载失败 · ', style: TextStyle(fontSize: 18)),
                        Text('重试', style: TextStyle(fontSize: 18)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
