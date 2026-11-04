import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hongguo_tv/hongguo_tv.dart' show TvEnvironment, TvFocusable;

import '../catalog/local_group_delete.dart';
import '../catalog/local_library.dart';
import '../downloads/drama_downloads.dart';
import '../downloads/download_manager.dart';
import '../merge/merge_selection.dart';
import '../platform/runtime.dart';
import '../navigation/app_navigation.dart';
import '../widgets/tv_confirm.dart';
import 'download_episodes_page.dart';
import 'local_cache_page.dart';

class DownloadsPage extends StatefulWidget {
  final DownloadRuntime runtime;
  const DownloadsPage({super.key, required this.runtime});
  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  late final manager = widget.runtime.downloads;

  /// The disk is read alongside the queue: a drama's progress is how many files
  /// it actually owns, and a record whose file has gone is a failed download --
  /// `reconcile` says so, this list only reports what the two together agree on.
  List<LocalEpisode> files = const [];
  String _seen = '';
  bool loading = true, working = false;
  String? error;
  int filter = 0;

  @override
  void initState() {
    super.initState();
    manager.addListener(_changed);
    _load();
  }

  /// The queue emits on every progress tick; only a record changing phase means
  /// the disk should now hold something else, so that is the one that re-scans.
  void _changed() {
    if (!mounted) return;
    setState(() {});
    final seen = queueSignature(manager);
    if (seen == _seen) return;
    _seen = seen;
    unawaited(_syncFiles());
  }

  Future<void> _syncFiles() async {
    try {
      final read = await widget.runtime.localEpisodes();
      if (mounted) setState(() => files = read);
    } catch (_) {
      // A background refresh that failed leaves the last good list standing;
      // 刷新 and every deliberate action still report the read error.
    }
  }

  @override
  void dispose() {
    manager.removeListener(_changed);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await manager.reconcile();
      final onDisk = await widget.runtime.localEpisodes();
      if (mounted) {
        _seen = queueSignature(manager);
        setState(() {
          files = onDisk;
          loading = false;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '无法读取下载记录，请重试';
        });
      }
    }
  }

  Future<void> _action(Future<void> Function() callback) async {
    if (working) return;
    setState(() => working = true);
    try {
      await callback();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e is StateError ? e.message : '操作未完成，请检查网络与存储后重试'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _open(DramaDownloads group) async {
    await pushAppPage<void>(
      context,
      AppScreen.downloadEpisodes,
      (_) => DownloadEpisodesPage(
        runtime: widget.runtime,
        dramaId: group.id,
        dramaTitle: group.drama.title,
      ),
    );
    if (mounted) await _load();
  }

  /// One key for a queue a restart, a dropped network or a cancelled batch left
  /// in pieces. The per-episode 继续下载 lives on the drill-in page; this is the
  /// answer to 「我刚把后台下载打开」.
  Future<void> _resumeAll() async {
    if (working) return;
    setState(() => working = true);
    try {
      final count = manager.resumeAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(count == 0 ? '没有需要继续的下载' : '已重新排队 $count 条下载'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  /// 归类删除 for the queue: the drama's records and its cached files go together,
  /// because a viewer who is done with a series never wants one leftover episode
  /// holding the shelf open. The report comes from reading the cache back.
  Future<void> _removeDrama(DramaDownloads group) async {
    if (working) return;
    final confirmed = await showTvConfirm(
      context,
      title: '删除本剧全部下载？',
      body:
          '${group.drama.title}\n${group.tasks.length} 条下载记录与 ${group.files.length} 个本地缓存文件一并删除，删除后需重新下载才能离线观看。',
      confirmLabel: '删除全部',
    );
    if (confirmed != true || !mounted) return;
    await _action(() async {
      final result = await removeLocalDrama(
        widget.runtime,
        LocalDramaGroup(id: group.id, drama: group.drama, files: group.files),
      );
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(result.caption)));
      }
    });
  }

  /// 合成 for the whole drama, fed by the cache scan rather than the queue: the
  /// rows say what was asked for, only the files on disk say what can be merged.
  Future<void> _mergeDrama(EpisodeDownload first) async {
    if (working) return;
    final runtime = widget.runtime;
    if (runtime is! MergeRuntime) return;
    final files = await runtime.localEpisodes();
    final group = groupLocalEpisodes(files)
        .where((g) => g.id == first.drama.id)
        .firstOrNull;
    final options = mergeOptionsFromFiles(group?.files ?? const []);
    if (!mounted) return;
    if (options.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('本剧还没有可合成的已完成下载')));
      return;
    }
    await showMergeSelection(
      context,
      runtime,
      options: options,
      suggestedTitle: '${first.drama.title} 合集',
      // 组级入口来自已完成的那一组，默认全选，viewer 只需去掉不要的。
      preselect: true,
    );
  }

  bool _matches(DramaDownloads group) => switch (filter) {
    1 => group.hasInFlight,
    2 => group.hasOffline,
    _ => true,
  };

  Widget _cardBody(DramaDownloads group, {required bool tv}) => Padding(
    padding: EdgeInsets.symmetric(
      horizontal: tv ? 16 : 12,
      vertical: tv ? 14 : 10,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          group.drama.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: tv
              ? const TextStyle(fontSize: 24)
              : Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          group.caption,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: tv
              ? const TextStyle(fontSize: 18)
              : Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: group.progress, minHeight: 4),
      ],
    ),
  );

  Widget _deleteIcon(bool tv) =>
      Icon(Icons.delete_sweep_outlined, size: tv ? 20 : 24);

  Widget _tvCard(DramaDownloads group) => Card(
    elevation: 0,
    margin: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: TvFocusable(
            key: ValueKey('downloads-drama-tv-${group.id}'),
            label: '${group.drama.title} 分集进度',
            onActivate: working ? null : () => _open(group),
            child: _cardBody(group, tv: true),
          ),
        ),
        TvFocusable(
          key: ValueKey('downloads-drama-delete-tv-${group.id}'),
          label: '${group.drama.title} 删除本剧',
          onActivate: working ? null : () => _removeDrama(group),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.delete_sweep_outlined, size: 20),
                SizedBox(width: 6),
                Text('删除本剧', style: TextStyle(fontSize: 18)),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _touchCard(DramaDownloads group) => Card(
    elevation: 0,
    margin: const EdgeInsets.symmetric(vertical: 6),
    child: InkWell(
      key: ValueKey('downloads-drama-${group.id}'),
      onTap: working ? null : () => _open(group),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardBody(group, tv: false),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 4, 4),
            child: Row(
              children: [
                const Icon(Icons.chevron_right, size: 20),
                Text('分集进度', style: Theme.of(context).textTheme.bodySmall),
                const Spacer(),
                if (widget.runtime is MergeRuntime)
                  IconButton(
                    key: ValueKey('downloads-drama-merge-${group.id}'),
                    tooltip: '合成已下载的分集',
                    onPressed: working
                        ? null
                        : () => _mergeDrama(group.tasks.first),
                    icon: const Icon(Icons.video_library_outlined),
                  ),
                IconButton(
                  key: ValueKey('downloads-drama-delete-${group.id}'),
                  tooltip: '删除本剧全部下载',
                  onPressed: working ? null : () => _removeDrama(group),
                  icon: _deleteIcon(false),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    // The flag comes from `build`, because `TvEnvironment.of` registers a
    // dependency and an async callback cannot ask again after an await.
    final tv = TvEnvironment.of(context);
    final all = groupDramaDownloads(manager, files);
    final groups = all.where(_matches).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载管理'),
        // On TV the remote's Back key pops this route, exactly as it does on the
        // detail page; an arrow the ring cannot reach is decoration the viewer
        // can see but not press.
        automaticallyImplyLeading: !tv,
        actions: [
          if (tv)
            TvFocusable(
              label: '查看离线剧集',
              onActivate: () => pushAppPage<void>(
                context,
                AppScreen.cache,
                (_) => LocalCachePage(runtime: widget.runtime),
              ),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.video_library_outlined, size: 20),
                    SizedBox(width: 8),
                    Text('离线剧集', style: TextStyle(fontSize: 18)),
                  ],
                ),
              ),
            )
          else
            IconButton(
              tooltip: '查看离线剧集',
              onPressed: () => pushAppPage<void>(
                context,
                AppScreen.cache,
                (_) => LocalCachePage(runtime: widget.runtime),
              ),
              icon: const Icon(Icons.video_library_outlined),
            ),
          if (manager.resumableCount > 0)
            if (tv)
              TvFocusable(
                key: const ValueKey('downloads-resume-all-tv'),
                label: '继续全部下载',
                onActivate: working ? null : _resumeAll,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.play_circle_outline, size: 20),
                      SizedBox(width: 8),
                      Text('继续全部', style: TextStyle(fontSize: 18)),
                    ],
                  ),
                ),
              )
            else
              IconButton(
                key: const ValueKey('downloads-resume-all'),
                tooltip: '继续全部下载',
                onPressed: working ? null : _resumeAll,
                icon: const Icon(Icons.play_circle_outline),
              ),
          if (tv)
            TvFocusable(
              label: '刷新下载',
              onActivate: working ? null : _load,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.refresh, size: 20),
                    SizedBox(width: 8),
                    Text('刷新', style: TextStyle(fontSize: 18)),
                  ],
                ),
              ),
            )
          else
            IconButton(
              tooltip: '刷新下载',
              onPressed: working ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
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
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.all(tv ? 20 : 12),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          for (var i = 0; i < 3; i++)
                            if (tv)
                              // `selected` fills the chip: the ring alone only
                              // tells where the remote is, not which filter runs.
                              TvFocusable(
                                key: ValueKey('downloads-filter-tv-$i'),
                                label: ['全部', '下载中', '已完成'][i],
                                selected: filter == i,
                                onActivate: () => setState(() => filter = i),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  child: Text(
                                    ['全部', '下载中', '已完成'][i],
                                    style: const TextStyle(fontSize: 20),
                                  ),
                                ),
                              )
                            else
                              ChoiceChip(
                                label: Text(['全部', '下载中', '已完成'][i]),
                                selected: filter == i,
                                onSelected: (_) => setState(() => filter = i),
                              ),
                        ],
                      ),
                    ),
                    if (manager.warning != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          manager.warning!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: tv ? 18 : null,
                          ),
                        ),
                      ),
                    if (working) const LinearProgressIndicator(minHeight: 2),
                    Expanded(
                      child: groups.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  all.isEmpty
                                      ? '暂无下载\n去剧集详情页选择想离线观看的集数'
                                      : '这个筛选下还没有剧目\n切回「全部」看看其余的下载',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: tv ? 20 : null),
                                ),
                              ),
                            )
                          : RefreshIndicator(
                              onRefresh: _load,
                              child: ListView(
                                padding: EdgeInsets.fromLTRB(
                                  tv ? 32 : 16,
                                  0,
                                  tv ? 32 : 16,
                                  24,
                                ),
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: [
                                  for (final group in groups)
                                    tv ? _tvCard(group) : _touchCard(group),
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
}
