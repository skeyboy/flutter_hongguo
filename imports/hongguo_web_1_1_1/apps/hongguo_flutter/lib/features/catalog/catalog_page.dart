import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hongguo_core/hongguo_core.dart';
import '../../adapters/backend.dart';
import '../detail/detail_page.dart';
import '../library/library_store.dart';

class CatalogPage extends StatefulWidget {
  final Backend backend;
  final LibraryStore library;
  const CatalogPage({super.key, required this.backend, required this.library});
  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  final search = TextEditingController();
  final rows = <Series>[];
  int section = 0, offset = 0, _generation = 0;
  bool loading = false, hasMore = false;
  String? error;
  String query = '';
  @override
  void initState() {
    super.initState();
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    _generation++;
    search.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (section >= 3) return;
    final generation = ++_generation;
    if (reset) {
      offset = 0;
      rows.clear();
    }
    setState(() {
      loading = true;
      error = null;
    });
    final known = rows.map((s) => s.id).toSet();
    try {
      final page = query.isNotEmpty
          ? await widget.backend.catalog.search(query, offset: offset)
          : await widget.backend.catalog.browse(
              genre: ['short_play', 'comic_series', 'ai_series'][section],
              offset: offset,
              seen: known,
            );
      if (!mounted || generation != _generation) return;
      setState(() {
        for (final item in page.items) {
          if (item.id.isNotEmpty && known.add(item.id)) rows.add(item);
        }
        hasMore = page.hasMore && page.nextOffset > offset;
        offset = page.nextOffset;
        loading = false;
      });
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          loading = false;
          error = e.toString();
        });
      }
    }
  }

  void _section(int value) {
    _generation++;
    setState(() {
      section = value;
      query = '';
      search.clear();
      loading = false;
      error = null;
    });
    if (value < 3) unawaited(_load(reset: true));
  }

  void _open(Series series) => unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(
          backend: widget.backend,
          series: series,
          library: widget.library,
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('红果'),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Center(
            child: Text(
              widget.backend.label,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ),
      ],
    ),
    body: Column(
      children: [
        if (section < 3)
          Padding(
            padding: const EdgeInsets.all(16),
            child: SearchBar(
              controller: search,
              hintText: '搜索短剧',
              leading: const Icon(Icons.search),
              onSubmitted: (value) {
                query = value.trim();
                unawaited(_load(reset: true));
              },
              trailing: [
                IconButton(
                  tooltip: '搜索',
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: () {
                    query = search.text.trim();
                    unawaited(_load(reset: true));
                  },
                ),
              ],
            ),
          ),
        Expanded(
          child: AnimatedBuilder(
            animation: widget.library,
            builder: (context, _) {
              final items = section == 3
                  ? widget.library.favorites.values.toList()
                  : section == 4
                  ? widget.library.history.values
                        .toList()
                        .reversed
                        .map((r) => r.series)
                        .toList()
                  : rows;
              return CustomScrollView(
                slivers: [
                  if (error != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            Text(error!),
                            TextButton(
                              onPressed: () => _load(reset: true),
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (items.isEmpty && !loading && error == null)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: Text('暂无内容')),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.all(16),
                    sliver: SliverGrid(
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final series = items[index];
                        return Card(
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => _open(series),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: series.cover.isEmpty
                                      ? const ColoredBox(
                                          color: Color(0xff30242a),
                                          child: Icon(Icons.movie, size: 42),
                                        )
                                      : Image.network(
                                          series.cover,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, _, _) =>
                                              const Icon(Icons.movie, size: 42),
                                        ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    10,
                                    10,
                                    10,
                                    4,
                                  ),
                                  child: Text(
                                    series.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    10,
                                    0,
                                    10,
                                    10,
                                  ),
                                  child: Text(
                                    '${series.episodeCount} 集',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelSmall,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }, childCount: items.length),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 210,
                            childAspectRatio: 0.62,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                    ),
                  ),
                  if (loading)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                  if (!loading && hasMore && section < 3)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Center(
                          child: FilledButton.tonal(
                            onPressed: () => _load(),
                            child: const Text('加载更多'),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: section,
      onDestinationSelected: _section,
      destinations: const [
        NavigationDestination(icon: Icon(Icons.home_outlined), label: '短剧'),
        NavigationDestination(
          icon: Icon(Icons.auto_stories_outlined),
          label: '漫剧',
        ),
        NavigationDestination(
          icon: Icon(Icons.auto_awesome_outlined),
          label: 'AI短剧',
        ),
        NavigationDestination(icon: Icon(Icons.favorite_outline), label: '收藏'),
        NavigationDestination(icon: Icon(Icons.history), label: '历史'),
      ],
    ),
  );
}
