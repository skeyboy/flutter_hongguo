import 'package:flutter/material.dart';

import '../downloads/download_manager.dart';
import '../platform/runtime.dart';
import '../navigation/app_navigation.dart';
import '../catalog/local_library.dart';
import '../playback/local_playlist.dart';
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
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除已下载视频？'),
          content: Text(
            '${task.drama.title} · 第 ${task.episode.index} 集\n删除后需重新下载才能离线观看。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await _action(() => manager.remove(task.key));
  }

  Widget _task(EpisodeDownload task) => Card(
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
                Text(
                  '第 ${task.episode.index} 集 · ${task.quality == 'best' || task.quality == 'auto' ? '自动画质' : task.quality}',
                ),
                const SizedBox(height: 4),
                Text(
                  '${task.message}${task.phase == DownloadPhase.running && task.fraction != null ? " · ${(task.fraction!.clamp(0, 1) * 100).floor()}%" : ""}',
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
        actions: [
          IconButton(
            tooltip: '查看离线剧集',
            onPressed: () => pushAppPage<void>(
              context,
              AppScreen.cache,
              (_) => LocalCachePage(runtime: widget.runtime),
            ),
            icon: const Icon(Icons.video_library_outlined),
          ),
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
                  Text(error!),
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
                      padding: const EdgeInsets.all(12),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          for (var i = 0; i < 3; i++)
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
                          ),
                        ),
                      ),
                    if (working) const LinearProgressIndicator(minHeight: 2),
                    Expanded(
                      child: groups.isEmpty
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(24),
                                child: Text(
                                  '暂无下载\n去剧集详情页选择想离线观看的集数',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            )
                          : RefreshIndicator(
                              onRefresh: _load,
                              child: ListView(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
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
                                      child: Text(
                                        group.first.drama.title,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium,
                                      ),
                                    ),
                                    for (final task
                                        in group..sort(
                                          (a, b) => a.episode.index.compareTo(
                                            b.episode.index,
                                          ),
                                        ))
                                      _task(task),
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
