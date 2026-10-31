import 'package:flutter/material.dart';
import 'package:hongguo_tv/hongguo_tv.dart' show TvEnvironment, TvFocusable;

import '../catalog/local_group_delete.dart';
import '../catalog/local_library.dart';
import '../downloads/download_manager.dart';
import '../platform/runtime.dart';
import '../navigation/app_navigation.dart';
import '../playback/local_playlist.dart';
import '../widgets/tv_confirm.dart';
import 'local_cache_page.dart';
import 'player_page.dart';

class DownloadsPage extends StatefulWidget {
  final DownloadRuntime runtime;
  const DownloadsPage({super.key, required this.runtime});
  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  late final manager = widget.runtime.downloads;
  bool loading = true, working = false;
  String? error;
  int filter = 0;
  @override
  void initState() {
    super.initState();
    manager.addListener(_changed);
    _load();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    manager.removeListener(_changed);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await manager.reconcile();
      if (mounted) {
        setState(() {
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

  Future<void> _watch(EpisodeDownload task) async {
    final runtime = widget.runtime;
    final files = await runtime.localEpisodes();
    final group = groupLocalEpisodes(files)
        .where((g) => g.files.any((f) => '${f.vid}_${f.quality}' == task.key))
        .firstOrNull;
    if (group == null) {
      await _load();
      throw StateError('本地文件已移除，请重新下载');
    }
    final file = group.files.firstWhere(
      (f) => '${f.vid}_${f.quality}' == task.key,
    );
    final queue = localPlaybackQueue(group, file);
    if (!mounted) return;
    await pushAppPage<void>(
      context,
      AppScreen.player,
      (_) => PlayerPage(
        runtime: runtime,
        detail: queue.detail,
        initialPosition: queue.initialPosition,
        cachedOnly: true,
        cachedQuality: task.quality,
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _remove(EpisodeDownload task) async {
    if (task.phase == DownloadPhase.ready) {
      final confirmed = await showTvConfirm(
        context,
        title: '删除已下载视频？',
        body:
            '${task.drama.title} · 第 ${task.episode.index} 集\n删除后需重新下载才能离线观看。',
        confirmLabel: '删除',
      );
      if (confirmed != true || !mounted) return;
    }
    await _action(() => manager.remove(task.key));
  }

  /// One key for a queue a restart, a dropped network or a cancelled batch left
  /// in pieces. The per-task 继续下载 stays for a single episode; this is the
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
  /// holding the shelf open.
  Future<void> _removeDrama(EpisodeDownload first, int taskCount) async {
    if (working) return;
    final confirmed = await showTvConfirm(
      context,
      title: '删除本剧全部下载？',
      body: '${first.drama.title}\n$taskCount 条下载记录与本地缓存文件一并删除，删除后需重新下载才能离线观看。',
      confirmLabel: '删除全部',
    );
    if (confirmed != true || !mounted) return;
    final files = await widget.runtime.localEpisodes();
    final group =
        groupLocalEpisodes(files)
            .where((g) => g.id == first.drama.id)
            .firstOrNull ??
        LocalDramaGroup(
          id: first.drama.id,
          drama: first.drama,
          files: const [],
        );
    await _action(() async {
      final result = await removeLocalDrama(widget.runtime, group);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(result.caption)));
      }
    });
  }

  String _episodeLine(EpisodeDownload task) =>
      '第 ${task.episode.index} 集 · ${task.quality == 'best' || task.quality == 'auto' ? '自动画质' : task.quality}';

  String _messageLine(EpisodeDownload task) =>
      '${task.message}${task.phase == DownloadPhase.running && task.fraction != null ? " · ${(task.fraction!.clamp(0, 1) * 100).floor()}%" : ""}';

  Widget _task(EpisodeDownload task, {required bool tv}) =>
      tv ? _tvTask(task) : _touchTask(task);

  bool _inFlight(DownloadPhase phase) =>
      phase == DownloadPhase.queued || phase == DownloadPhase.running;

  // One task as two remote targets, like the cache page's file row: a row-wide
  // target would swallow the destructive action at its end.
  Widget _tvTask(EpisodeDownload task) {
    final inFlight = _inFlight(task.phase);
    final ready = task.phase == DownloadPhase.ready;
    // Title plus index keeps the label unique per row, so the viewer knows
    // which episode the confirm key acts on.
    final name = '${task.drama.title} 第 ${task.episode.index} 集';
    final primaryLabel = inFlight
        ? '暂停下载'
        : ready
        ? '离线观看'
        : '继续下载';
    final primaryIcon = inFlight
        ? Icons.pause
        : ready
        ? Icons.play_arrow
        : Icons.refresh;
    final VoidCallback primaryAction = inFlight
        ? () => manager.pause(task.key)
        : ready
        ? () => _action(() => _watch(task))
        : () => manager.resume(task.key);
    final secondaryLabel = inFlight ? '取消下载' : '删除下载记录';
    final secondaryIcon = inFlight ? Icons.close : Icons.delete_outline;
    final VoidCallback secondaryAction = inFlight
        ? () => manager.cancel(task.key)
        : () => _remove(task);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TvFocusable(
              label: '$name $primaryLabel',
              onActivate: working ? null : primaryAction,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Icon(primaryIcon, size: 26),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _episodeLine(task),
                            style: const TextStyle(fontSize: 22),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _messageLine(task),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 17),
                          ),
                          if (task.phase == DownloadPhase.running)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: LinearProgressIndicator(
                                value: task.fraction?.clamp(0, 1),
                                minHeight: 2,
                              ),
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
            label: '$name $secondaryLabel',
            onActivate: working ? null : secondaryAction,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Icon(secondaryIcon, size: 26),
            ),
          ),
        ],
      ),
    );
  }

  Widget _touchTask(EpisodeDownload task) => Card(
    elevation: 0,
    margin: const EdgeInsets.symmetric(vertical: 4),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          Icon(
            task.phase == DownloadPhase.ready
                ? Icons.download_done
                : Icons.downloading_outlined,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_episodeLine(task)),
                const SizedBox(height: 4),
                Text(
                  _messageLine(task),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (task.phase == DownloadPhase.running)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: LinearProgressIndicator(
                      value: task.fraction?.clamp(0, 1),
                      minHeight: 2,
                    ),
                  ),
              ],
            ),
          ),
          if (task.phase == DownloadPhase.running ||
              task.phase == DownloadPhase.queued) ...[
            IconButton(
              tooltip: '暂停下载',
              onPressed: working ? null : () => manager.pause(task.key),
              icon: const Icon(Icons.pause),
            ),
            IconButton(
              tooltip: '取消下载',
              onPressed: working ? null : () => manager.cancel(task.key),
              icon: const Icon(Icons.close),
            ),
          ] else ...[
            IconButton(
              tooltip: task.phase == DownloadPhase.ready
                  ? '离线观看'
                  : task.phase == DownloadPhase.failed
                  ? '重试下载'
                  : '继续下载',
              onPressed: working
                  ? null
                  : task.phase == DownloadPhase.ready
                  ? () => _action(() => _watch(task))
                  : () => manager.resume(task.key),
              icon: Icon(
                task.phase == DownloadPhase.ready
                    ? Icons.play_arrow
                    : Icons.refresh,
              ),
            ),
            IconButton(
              tooltip: '删除下载记录',
              onPressed: working ? null : () => _remove(task),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    // The flag comes from `build`, because `TvEnvironment.of` registers a
    // dependency and an async callback cannot ask again after an await.
    final tv = TvEnvironment.of(context);
    final groups = <String, List<EpisodeDownload>>{};
    for (final task in manager.tasks) {
      if (filter == 1 &&
          ![
            DownloadPhase.queued,
            DownloadPhase.running,
            DownloadPhase.paused,
          ].contains(task.phase)) {
        continue;
      }
      if (filter == 2 && task.phase != DownloadPhase.ready) continue;
      (groups[task.drama.id] ??= []).add(task);
    }
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
                                  '暂无下载\n去剧集详情页选择想离线观看的集数',
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
                                  for (final group in groups.values) ...[
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        top: 16,
                                        bottom: 8,
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              group.first.drama.title,
                                              style: tv
                                                  ? const TextStyle(
                                                      fontSize: 24,
                                                    )
                                                  : Theme.of(context)
                                                        .textTheme
                                                        .titleMedium,
                                            ),
                                          ),
                                          if (tv)
                                            TvFocusable(
                                              key: ValueKey(
                                                'downloads-drama-tv-${group.first.drama.id}',
                                              ),
                                              label:
                                                  '${group.first.drama.title} 删除本剧',
                                              onActivate: working
                                                  ? null
                                                  : () => _removeDrama(
                                                      group.first,
                                                      group.length,
                                                    ),
                                              child: const Padding(
                                                padding: EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 6,
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      Icons
                                                          .delete_sweep_outlined,
                                                      size: 20,
                                                    ),
                                                    SizedBox(width: 6),
                                                    Text(
                                                      '删除本剧',
                                                      style: TextStyle(
                                                        fontSize: 18,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            )
                                          else
                                            IconButton(
                                              key: ValueKey(
                                                'downloads-drama-${group.first.drama.id}',
                                              ),
                                              tooltip: '删除本剧全部下载',
                                              onPressed: working
                                                  ? null
                                                  : () => _removeDrama(
                                                      group.first,
                                                      group.length,
                                                    ),
                                              icon: const Icon(
                                                Icons.delete_sweep_outlined,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    for (final task
                                        in group..sort(
                                          (a, b) => a.episode.index.compareTo(
                                            b.episode.index,
                                          ),
                                        ))
                                      _task(task, tv: tv),
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
}
