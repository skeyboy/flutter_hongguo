import 'dart:async';

import '../navigation/app_navigation.dart';

import 'package:flutter/material.dart';
import 'package:hongguo_tv/hongguo_tv.dart'
    show TvEnvironment, TvFocusable, tvBuild;

import '../catalog/local_artwork.dart';
import '../catalog/local_group_delete.dart';
import '../catalog/local_library.dart';
import '../downloads/download_selection.dart';
import '../downloads/latest_episode_check.dart';
import '../merge/merge_selection.dart';
import '../platform/background/host_policy.dart';
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

  /// One press at a time: a check writes the merged episode count back into the
  /// shelf and a delete empties it, so a second sheet on the same drama would
  /// read a group the first one already changed.
  bool busy = false;
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

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// The card's two whole-shelf actions, opened by whichever second gesture the
  /// family has: 长按 for a finger, 右键 for a pointer. Both land in the same panel
  /// with the same rows, so neither family gets its own copy of 删除 semantics.
  ///
  /// A remote has neither gesture, and its cards already walk into a page whose
  /// actions are focus targets -- so this panel is only ever the touch/pointer
  /// branch, and the TV card stays as it was.
  ///
  /// The shape follows the rule this app already uses for 下载选集 and the 投屏
  /// device list: a window with room hosts a centered dialog, a phone hosts the
  /// bottom sheet. Only the container changes -- keys, labels and the
  /// confirm-first delete are the same widget either way.
  Future<void> _groupActions(LocalDramaGroup group) async {
    if (busy) return;
    final canUpdate = widget.runtime is DownloadRuntime && !group.unidentified;
    final actions = _GroupActions(
      group: group,
      canUpdate: canUpdate,
      canMerge: _canMerge,
    );
    final size = MediaQuery.sizeOf(context);
    final picked = size.width >= 720 && size.height >= 400
        ? await showDialog<String>(
            context: context,
            builder: (_) => Dialog(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: actions,
              ),
            ),
          )
        : await showModalBottomSheet<String>(
            context: context,
            showDragHandle: true,
            builder: (_) => SafeArea(top: false, child: actions),
          );
    if (!mounted || picked == null) return;
    if (picked == 'check') {
      await _check(group);
    } else if (picked == 'download') {
      await _pickDownload(group);
    } else if (picked == 'merge') {
      await _merge(group);
    } else {
      await _remove(group);
    }
  }

  /// 合成 works on the files this shelf already holds, so it is offered wherever
  /// a drama has episodes to offer -- and never on a remote, which has no way to
  /// name where the product should go.
  bool get _canMerge => widget.runtime is MergeRuntime && !tvBuild;

  /// The panel reads the cache scan rather than the network: the whole point of
  /// a merge is that it is made of what is already on this device.
  Future<void> _merge(LocalDramaGroup group) async {
    if (busy) return;
    final runtime = widget.runtime;
    if (runtime is! MergeRuntime) return;
    final options = mergeOptionsFromFiles(group.files);
    if (options.isEmpty) {
      _notice('本剧没有可用于合成的缓存');
      return;
    }
    setState(() => busy = true);
    try {
      await showMergeSelection(
        context,
        runtime,
        options: options,
        suggestedTitle:
            '${group.drama.title.isEmpty ? '合并资源' : group.drama.title} 合集',
        // The shelf is a set the viewer already finished downloading, so the
        // episodes on disk start picked and only the exceptions are removed.
        preselect: true,
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// A read, not a write: the shelf asks the catalog how long the series is now
  /// and reports the gap. Nothing enters 下载中 here -- that is 选择下载新集's job,
  /// so a viewer who only wanted to know whether the show grew gets an answer
  /// rather than a queue full of episodes they never named.
  Future<void> _check(LocalDramaGroup group) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result = await checkLatestEpisodes(widget.runtime, group);
      await _load();
      _notice(result.caption);
    } on StateError catch (e) {
      _notice(e.message);
    } catch (_) {
      await _load();
      _notice('在线检查最新剧集失败，本地缓存仍可播放，请稍后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// The card's third gesture target: the same online read as 检查最新剧集, but
  /// the answer goes to 详情 用的那枚选集面板, so a shelf can top up the episodes
  /// it wants instead of taking the whole gap at the cached quality.
  Future<void> _pickDownload(LocalDramaGroup group) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final notice = await showCachedDramaDownloadSelection(
        context,
        widget.runtime,
        group,
      );
      await _load();
      if (notice != null) _notice(notice);
    } on StateError catch (e) {
      _notice(e.message);
    } catch (_) {
      await _load();
      _notice('在线获取最新剧集失败，本地缓存仍可播放，请稍后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// The whole drama at once, and still behind the same confirmation the shelf
  /// page uses: a long press that deleted on contact would take an offline show
  /// away from the viewer who only meant to open it.
  Future<void> _remove(LocalDramaGroup group) async {
    if (busy) return;
    final confirmed = await showTvConfirm(
      context,
      title: '删除本剧全部缓存？',
      body:
          '${group.drama.title}\n${group.files.length} 个文件 · ${localBytesLabel(group.bytes)}\n删除后需重新下载才能离线观看。',
      confirmLabel: '删除全部',
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      final result = await removeLocalDrama(widget.runtime, group);
      await _load();
      _notice(result.caption);
    } on StateError catch (e) {
      _notice(e.message);
    } catch (_) {
      await _load();
      _notice('删除未完成，请检查存储空间后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
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
                                    // 长按 is a finger's second gesture, 右键 a pointer's; telling a
                                    // desktop hand to hold a card down would describe a gesture
                                    // nobody there uses.
                                    tv
                                        ? '按剧目整理，可直接离线播放已缓存分集。'
                                        : '按剧目整理，可直接离线播放已缓存分集；${desktopHost ? '右键' : '长按'}一部剧可检查最新剧集、挑几集下载或整体删除缓存。',
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
                                  onLongPress: busy
                                      ? null
                                      : () => unawaited(_groupActions(group)),
                                  onSecondaryTap: busy
                                      ? null
                                      : () => unawaited(_groupActions(group)),
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

/// The whole-shelf actions of one cached drama, in whichever container the
/// window can host: the rows, keys and labels are the same, so the delete still
/// goes through exactly one confirmation path however it was reached.
class _GroupActions extends StatelessWidget {
  final LocalDramaGroup group;
  final bool canUpdate;
  final bool canMerge;
  const _GroupActions({
    required this.group,
    required this.canUpdate,
    required this.canMerge,
  });

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ListTile(
        title: Text(group.drama.title.isEmpty ? '未命名短剧' : group.drama.title),
        subtitle: Text(
          '${group.files.length} 个文件 · ${localBytesLabel(group.bytes)}',
        ),
      ),
      const Divider(height: 1),
      if (canUpdate)
        ListTile(
          key: const ValueKey('local-sheet-check'),
          leading: const Icon(Icons.sync),
          title: const Text('检查最新剧集'),
          subtitle: const Text('只比对在线集数，不会自动排队下载'),
          onTap: () => Navigator.pop(context, 'check'),
        ),
      if (canUpdate)
        ListTile(
          key: const ValueKey('local-sheet-download'),
          leading: const Icon(Icons.download_outlined),
          title: const Text('选择下载新集'),
          subtitle: const Text('联网比对后自己挑要下哪几集'),
          onTap: () => Navigator.pop(context, 'download'),
        ),
      if (canMerge && group.files.isNotEmpty)
        ListTile(
          key: const ValueKey('local-sheet-merge'),
          leading: const Icon(Icons.video_library_outlined),
          title: const Text('合成成本地资源'),
          subtitle: const Text('把已缓存的分集拼成一个可导出文件'),
          onTap: () => Navigator.pop(context, 'merge'),
        ),
      ListTile(
        key: const ValueKey('local-sheet-remove'),
        leading: const Icon(Icons.delete_sweep_outlined),
        title: const Text('删除本剧缓存'),
        onTap: () => Navigator.pop(context, 'remove'),
      ),
    ],
  );
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

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Asks the catalog what this drama has online now and reports the gap. The
  /// queue is untouched either way -- a viewer who checks first and wants three
  /// of the five new episodes picks them in 选择下载新集, and a failed check still
  /// leaves the shelf playable.
  Future<void> _check() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result = await checkLatestEpisodes(widget.runtime, group);
      await _load();
      _notice(result.caption);
    } on StateError catch (e) {
      _notice(e.message);
    } catch (_) {
      await _load();
      _notice('在线检查最新剧集失败，本地缓存仍可播放，请稍后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// The third way to use that read: hand the episodes the shelf is missing to
  /// 详情页那枚选集面板, so the viewer names the ones to fetch -- with what is
  /// already on disk shown as 已下载 rather than offered again.
  Future<void> _pickDownload() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final notice = await showCachedDramaDownloadSelection(
        context,
        widget.runtime,
        group,
      );
      await _load();
      if (notice != null) _notice(notice);
    } on StateError catch (e) {
      _notice(e.message);
    } catch (_) {
      await _load();
      _notice('在线获取最新剧集失败，本地缓存仍可播放，请稍后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _removeGroup() async {
    if (busy) return;
    final confirmed = await showTvConfirm(
      context,
      title: '删除本剧全部缓存？',
      body:
          '${group.drama.title}\n${group.files.length} 个文件 · ${localBytesLabel(group.bytes)}\n删除后需重新下载才能离线观看。',
      confirmLabel: '删除全部',
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      final result = await removeLocalDrama(widget.runtime, group);
      await _load();
      _notice(result.caption);
    } on StateError catch (e) {
      _notice(e.message);
    } catch (_) {
      await _load();
      _notice('删除未完成，请检查存储空间后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// 合成 from the drama page offers exactly what this shelf holds: the panel is
  /// fed by the cache scan, so an offline drama is mergeable with no network.
  Future<void> _merge() async {
    if (busy) return;
    final runtime = widget.runtime;
    if (runtime is! MergeRuntime) return;
    final options = mergeOptionsFromFiles(group.files);
    if (options.isEmpty) {
      _notice('本剧没有可用于合成的缓存');
      return;
    }
    setState(() => busy = true);
    try {
      await showMergeSelection(
        context,
        runtime,
        options: options,
        suggestedTitle:
            '${group.drama.title.isEmpty ? '合并资源' : group.drama.title} 合集',
        // The shelf is a set the viewer already finished downloading, so the
        // episodes on disk start picked and only the exceptions are removed.
        preselect: true,
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// The drama-level actions as one row per family: a remote needs each to be
  /// its own focus target, and a touch screen needs labels it can read.
  Widget _groupActions({required bool tv}) {
    final canUpdate = widget.runtime is DownloadRuntime && !group.unidentified;
    final canMerge =
        !tvBuild && widget.runtime is MergeRuntime && group.files.isNotEmpty;
    Widget action({
      required String id,
      required String label,
      required VoidCallback? onTap,
      required IconData icon,
    }) => tv
        ? TvFocusable(
            key: ValueKey('local-$id-tv'),
            label: label,
            onActivate: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 24),
                  const SizedBox(width: 10),
                  Text(label, style: const TextStyle(fontSize: 20)),
                ],
              ),
            ),
          )
        : TextButton.icon(
            key: ValueKey('local-$id'),
            onPressed: onTap,
            icon: Icon(icon),
            label: Text(label),
          );
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        if (canUpdate)
          action(
            id: 'check',
            label: '检查最新剧集',
            onTap: busy ? null : _check,
            icon: Icons.sync,
          ),
        if (canUpdate)
          action(
            id: 'download',
            label: '选择下载新集',
            onTap: busy ? null : _pickDownload,
            icon: Icons.download_outlined,
          ),
        if (canMerge)
          action(
            id: 'merge',
            label: '合成成本地资源',
            onTap: busy ? null : _merge,
            icon: Icons.video_library_outlined,
          ),
        if (group.files.isNotEmpty)
          action(
            id: 'remove-group',
            label: '删除本剧缓存',
            onTap: busy ? null : _removeGroup,
            icon: Icons.delete_sweep_outlined,
          ),
      ],
    );
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
                        const SizedBox(height: 12),
                        _groupActions(tv: tv),
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
