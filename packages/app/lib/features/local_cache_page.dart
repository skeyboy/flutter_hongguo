import '../navigation/app_navigation.dart';

import 'package:flutter/material.dart';
import 'package:hongguo_tv/hongguo_tv.dart' show TvEnvironment, TvFocusable;

import '../catalog/local_artwork.dart';
import '../catalog/local_library.dart';
import '../platform/runtime.dart';
import '../playback/local_playlist.dart';
import '../widgets/tv_confirm.dart';
import 'cache_metadata_page.dart';
import 'library_page.dart';
import 'player_page.dart';

Future<List<LocalEpisode>> _localFiles(AppRuntime runtime) =>
    runtime is LocalMediaRuntime ? runtime.localEpisodes() : Future.value([]);

class LocalCachePage extends StatefulWidget {
  final AppRuntime runtime;
  const LocalCachePage({super.key, required this.runtime});
  @override
  State<LocalCachePage> createState() => _LocalCachePageState();
}

class _LocalCachePageState extends State<LocalCachePage> {
  List<LocalEpisode>? entries;
  String? error;
  String query = '';
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await _localFiles(widget.runtime);
      if (mounted) {
        setState(() {
          entries = values;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '无法读取本地缓存，请重试。');
    }
  }

  Future<void> _repair() async {
    await pushAppPage<bool>(
      context,
      AppScreen.cacheMetadata,
      (_) => CacheMetadataPage(
        runtime: widget.runtime,
        videos: entries!.map((e) => e.vid).toSet(),
      ),
    );
    await _load();
  }

  Future<void> _open(LocalDramaGroup group) async {
    await pushAppPage<void>(
      context,
      AppScreen.localEpisodes,
      (_) => LocalEpisodesPage(runtime: widget.runtime, initial: group),
    );
    await _load();
  }

  /// Cached-drama card for a 10-foot grid. `DramaCard`'s 15/12 px text is
  /// phone-sized and its ink highlight is the only focus cue, so the TV pane
  /// builds the same content with a ring and readable sizes.
  Widget _tvDramaCard(LocalDramaGroup group) => TvFocusable(
    key: ValueKey('local-drama-tv-${group.id}'),
    label: '${group.drama.title}，${group.badge}',
    onActivate: () => _open(group),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: DramaCover(
                    drama: group.drama,
                    imageProvider: localArtwork(group.coverPath),
                    allowNetwork: false,
                  ),
                ),
              ),
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
                    group.badge,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          group.drama.title.isEmpty ? '未命名短剧' : group.drama.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 18, height: 1.35),
        ),
        Text(
          group.unidentified
              ? '补全资料后按剧目归类'
              : '${group.episodeCount} 集 · ${localBytesLabel(group.bytes)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 15,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final tv = TvEnvironment.of(context);
    final groups = groupLocalEpisodes(entries ?? []);
    final text = query.trim().toLowerCase();
    final visible = groups
        .where(
          (g) =>
              g.drama.title.toLowerCase().contains(text) ||
              g.files.any((e) => e.vid.contains(text)),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地缓存剧集'),
        actions: [
          if (widget.runtime is LibraryCacheRuntime &&
              entries?.isNotEmpty == true)
            if (tv)
              TvFocusable(
                label: '补全剧目信息',
                onActivate: _repair,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Text('补全剧目信息', style: TextStyle(fontSize: 18)),
                ),
              )
            else
              IconButton(
                tooltip: '补全剧目信息',
                onPressed: _repair,
                icon: const Icon(Icons.manage_search),
              ),
          if (tv)
            TvFocusable(
              label: '刷新缓存列表',
              onActivate: _load,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text('刷新', style: TextStyle(fontSize: 18)),
              ),
            )
          else
            IconButton(
              tooltip: '刷新缓存列表',
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1280),
          child: error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(error!, style: TextStyle(fontSize: tv ? 22 : null)),
                      if (tv)
                        TvFocusable(
                          label: '重试',
                          autofocus: true,
                          onActivate: _load,
                          child: const Padding(
                            padding: EdgeInsets.all(14),
                            child: Text('重试', style: TextStyle(fontSize: 22)),
                          ),
                        )
                      else
                        TextButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : entries == null
              ? const Center(child: CircularProgressIndicator())
              : entries!.isEmpty
              ? const Center(
                  child: Text(
                    '还没有已完成的本地剧集\n播放时会自动缓存后续剧集。',
                    textAlign: TextAlign.center,
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final padding = constraints.maxWidth < 720 ? 16.0 : 28.0;
                    final identified = groups
                        .where((g) => !g.unidentified)
                        .length;
                    final unique = entries!.map((e) => e.vid).toSet().length;
                    final bytes = entries!.fold(0, (n, e) => n + e.bytes);
                    return RefreshIndicator(
                      onRefresh: _load,
                      child: CustomScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(
                                padding,
                                12,
                                padding,
                                20,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    '$identified 部剧 · $unique 集 · ${localBytesLabel(bytes)}',
                                    style: tv
                                        ? const TextStyle(fontSize: 24)
                                        : Theme.of(context)
                                              .textTheme
                                              .titleMedium,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '按剧目整理，可直接离线播放已缓存分集。',
                                    style: TextStyle(fontSize: tv ? 18 : null),
                                  ),
                                  const SizedBox(height: 18),
                                  TextField(
                                    onChanged: (value) =>
                                        setState(() => query = value),
                                    decoration: const InputDecoration(
                                      hintText: '搜索已缓存的剧名或视频 ID',
                                      prefixIcon: Icon(Icons.search),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (visible.isEmpty)
                            const SliverToBoxAdapter(
                              child: Padding(
                                padding: EdgeInsets.all(40),
                                child: Center(child: Text('没有匹配的缓存剧目')),
                              ),
                            ),
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(
                              padding,
                              0,
                              padding,
                              28,
                            ),
                            sliver: SliverGrid(
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 210,
                                    mainAxisSpacing: 20,
                                    crossAxisSpacing: 14,
                                    childAspectRatio: 0.55,
                                  ),
                              delegate: SliverChildBuilderDelegate((
                                context,
                                index,
                              ) {
                                final group = visible[index];
                                if (tv) return _tvDramaCard(group);
                                return DramaCard(
                                  key: ValueKey('local-drama-${group.id}'),
                                  drama: group.drama,
                                  badge: group.badge,
                                  subtitle: group.unidentified
                                      ? '补全资料后按剧目归类'
                                      : '${group.episodeCount} 集 · ${localBytesLabel(group.bytes)}',
                                  coverImage: localArtwork(group.coverPath),
                                  allowNetworkCover: false,
                                  onTap: () => _open(group),
                                );
                              }, childCount: visible.length),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class LocalEpisodesPage extends StatefulWidget {
  final AppRuntime runtime;
  final LocalDramaGroup initial;
  const LocalEpisodesPage({
    super.key,
    required this.runtime,
    required this.initial,
  });
  @override
  State<LocalEpisodesPage> createState() => _LocalEpisodesPageState();
}

class _LocalEpisodesPageState extends State<LocalEpisodesPage> {
  late LocalDramaGroup group;
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    group = widget.initial;
    _load();
  }

  Future<void> _load() async {
    try {
      final groups = groupLocalEpisodes(await _localFiles(widget.runtime));
      final updated = groups.where((g) => g.id == group.id).firstOrNull;
      if (mounted) {
        setState(() {
          group =
              updated ??
              LocalDramaGroup(
                id: group.id,
                drama: group.drama,
                files: [],
                unidentified: group.unidentified,
              );
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '缓存列表刷新失败，请重试。');
    }
  }

  Future<void> _repair() async {
    await pushAppPage<bool>(
      context,
      AppScreen.cacheMetadata,
      (_) => CacheMetadataPage(
        runtime: widget.runtime,
        videos: group.files.map((e) => e.vid).toSet(),
      ),
    );
    await _load();
  }

  Future<void> _delete(LocalEpisode entry) async {
    final confirmed = await showTvConfirm(
      context,
      title: '删除本地剧集？',
      body: entry.label,
      confirmLabel: '删除',
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      await widget.runtime.evict(entry.vid, quality: entry.quality);
      await _load();
      if (mounted &&
          group.files.any(
            (e) => e.vid == entry.vid && e.quality == entry.quality,
          )) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('该文件正在使用，暂时无法删除。')));
      }
    } catch (_) {
      if (mounted) setState(() => error = '删除失败，请重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _play(LocalEpisode entry) async {
    final queue = localPlaybackQueue(group, entry);
    await pushAppPage<void>(
      context,
      AppScreen.player,
      (_) => PlayerPage(
        runtime: widget.runtime,
        detail: queue.detail,
        initialPosition: queue.initialPosition,
        cachedOnly: true,
        cachedQuality: entry.quality,
      ),
    );
    await _load();
  }

  /// One cached file as two remote targets: play, and delete. A row-wide
  /// target would swallow the trailing action, and `_delete` needs a way in.
  Widget _tvEpisodeTile(LocalEpisode entry) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Expanded(
        child: TvFocusable(
          label: '${entry.label} 播放',
          onActivate: busy ? null : () => _play(entry),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            child: Row(
              children: [
                Icon(
                  entry.inUse ? Icons.play_arrow : Icons.play_circle_outline,
                  size: 28,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.unidentified
                            ? '视频 ${entry.vid}'
                            : '第 ${group.episodeFor(entry)?.index ?? "?"} 集',
                        style: const TextStyle(fontSize: 22),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _episodeCaption(entry),
                        style: const TextStyle(fontSize: 17),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      TvFocusable(
        label: entry.inUse ? '使用中，无法删除' : '删除缓存',
        onActivate: busy || entry.inUse ? null : () => _delete(entry),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Icon(
            entry.inUse ? Icons.lock_outline : Icons.delete_outline,
            size: 26,
          ),
        ),
      ),
    ],
  );

  String _episodeCaption(LocalEpisode entry) => [
    if (group.episodeFor(entry)?.title.isNotEmpty == true)
      group.episodeFor(entry)!.title,
    '${localQualityLabel(entry.quality)} · ${localBytesLabel(entry.bytes)}'
        '${entry.inUse ? " · 使用中" : ""}',
  ].join('\n');

  @override
  Widget build(BuildContext context) {
    final tv = TvEnvironment.of(context);
    final files = group.sortedFiles();
    return Scaffold(
      appBar: AppBar(
        title: Text(group.drama.title),
        actions: [
          if (tv)
            TvFocusable(
              label: '刷新缓存列表',
              onActivate: _load,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text('刷新', style: TextStyle(fontSize: 18)),
              ),
            )
          else
            IconButton(
              tooltip: '刷新缓存列表',
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView(
            padding: EdgeInsets.all(tv ? 32 : 20),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: tv ? 120 : 96,
                    height: tv ? 175 : 140,
                    child: DramaCover(
                      drama: group.drama,
                      imageProvider: localArtwork(group.coverPath),
                      allowNetwork: false,
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.drama.title,
                          style: tv
                              ? const TextStyle(fontSize: 30)
                              : Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '${group.badge}\n${files.length} 个文件 · ${localBytesLabel(group.bytes)}',
                          style: TextStyle(fontSize: tv ? 18 : null),
                        ),
                        if (group.unidentified &&
                            widget.runtime is LibraryCacheRuntime)
                          if (tv)
                            TvFocusable(
                              label: '补全剧目信息',
                              onActivate: _repair,
                              child: const Padding(
                                padding: EdgeInsets.all(12),
                                child: Text(
                                  '补全剧目信息',
                                  style: TextStyle(fontSize: 20),
                                ),
                              ),
                            )
                          else
                            TextButton.icon(
                              onPressed: _repair,
                              icon: const Icon(Icons.manage_search),
                              label: const Text('补全剧目信息'),
                            ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (error != null)
                if (tv)
                  TvFocusable(
                    label: '重试',
                    autofocus: true,
                    onActivate: _load,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(error!, style: const TextStyle(fontSize: 20)),
                    ),
                  )
                else
                  TextButton(onPressed: _load, child: Text(error!)),
              if (files.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    '暂无已缓存分集，可返回查看其他剧目。',
                    style: TextStyle(fontSize: tv ? 20 : null),
                  ),
                ),
              for (final entry in files)
                if (tv)
                  _tvEpisodeTile(entry)
                else ...[
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      group.unidentified
                          ? '视频 ${entry.vid}'
                          : '第 ${group.episodeFor(entry)?.index ?? "?"} 集',
                    ),
                    subtitle: Text(_episodeCaption(entry)),
                    onTap: busy ? null : () => _play(entry),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '播放本地剧集',
                          onPressed: busy ? null : () => _play(entry),
                          icon: const Icon(Icons.play_arrow),
                        ),
                        IconButton(
                          tooltip: entry.inUse ? '使用中，无法删除' : '删除缓存',
                          onPressed: busy || entry.inUse
                              ? null
                              : () => _delete(entry),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  ),
                ],
            ],
          ),
        ),
      ),
    );
  }
}
