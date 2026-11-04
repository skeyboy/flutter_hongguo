import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hongguo_tv/hongguo_tv.dart' show TvEnvironment, TvFocusable;

import '../catalog/local_library.dart';
import '../downloads/drama_downloads.dart';
import '../downloads/download_manager.dart';
import '../navigation/app_navigation.dart';
import '../playback/local_playlist.dart';
import '../platform/runtime.dart';
import '../widgets/tv_confirm.dart';
import 'player_page.dart';

/// One drama's episodes and where each of them stands: a queue record with its
/// phase, a finished file, or a playback cache the queue never recorded. This is
/// the layer 下载管理 drills into, so a viewer who wants to know why 山海之间 says
/// 「已完成 3 / 8 集」 can see which five are missing rather than count rows.
class DownloadEpisodesPage extends StatefulWidget {
  final DownloadRuntime runtime;
  final String dramaId;
  final String dramaTitle;
  const DownloadEpisodesPage({
    super.key,
    required this.runtime,
    required this.dramaId,
    required this.dramaTitle,
  });
  @override
  State<DownloadEpisodesPage> createState() => _DownloadEpisodesPageState();
}

class _DownloadEpisodesPageState extends State<DownloadEpisodesPage> {
  late final manager = widget.runtime.downloads;
  List<LocalEpisode> files = const [];
  String _seen = '';
  bool loading = true, working = false;
  String? error;

  @override
  void initState() {
    super.initState();
    manager.addListener(_changed);
    _load();
  }

  // Same rule as the card page: a phase change means the shelf owes a new file,
  // a progress tick does not.
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
      // The rows keep the last good scan; 刷新 and the actions still report it.
    }
  }

  @override
  void dispose() {
    manager.removeListener(_changed);
    super.dispose();
  }

  /// The queue is reconciled first, so a file deleted from another page has
  /// already turned into a 失败 row by the time these rows are drawn.
  Future<void> _load() async {
    try {
      await manager.reconcile();
      final read = await widget.runtime.localEpisodes();
      if (mounted) {
        _seen = queueSignature(manager);
        setState(() {
          files = read;
          loading = false;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '无法读取下载记录，请返回重试';
        });
      }
    }
  }

  LocalDramaGroup? get _group =>
      groupLocalEpisodes(files)
          .where((g) => g.id == widget.dramaId)
          .firstOrNull;

  List<DownloadEpisodeRow> get _rows => downloadEpisodeRows(
    manager.tasks.where((task) => task.drama.id == widget.dramaId).toList(),
    _group?.files ?? const [],
    _group,
  );

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

  /// The player is given the shelf group, not the record: a ready download and
  /// an episode cached while playing are the same file to it. A record whose
  /// file went away answers with the error its own path raises rather than a
  /// silent push.
  Future<void> _watch(DownloadEpisodeRow row) async {
    final runtime = widget.runtime;
    final read = await runtime.localEpisodes();
    final group = groupLocalEpisodes(read)
        .where((g) => g.files.any((f) => '${f.vid}_${f.quality}' == row.key))
        .firstOrNull;
    if (group == null) {
      await _load();
      throw StateError('本地文件已移除，请重新下载');
    }
    final file = group.files.firstWhere(
      (f) => '${f.vid}_${f.quality}' == row.key,
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
        cachedQuality: row.quality,
      ),
    );
    if (mounted) await _load();
  }

  /// A record's delete takes its file too, and `manager.remove` reads the disk
  /// back before forgetting the record. A playback-cached episode has no record
  /// to forget, so it goes by the file alone -- both answer in the same words:
  /// what is no longer on disk.
  Future<void> _remove(DownloadEpisodeRow row) async {
    final task = row.task;
    final destructive = task == null || task.phase == DownloadPhase.ready;
    if (destructive) {
      final confirmed = await showTvConfirm(
        context,
        title: task == null ? '删除本地剧集？' : '删除已下载视频？',
        body: '${widget.dramaTitle} · 第 ${row.index} 集\n删除后需重新下载才能离线观看。',
        confirmLabel: '删除',
      );
      if (confirmed != true || !mounted) return;
    }
    if (task == null) {
      await _action(() async {
        await widget.runtime.evict(row.vid, quality: row.quality);
        await _load();
        if (mounted &&
            _rows.any(
              (r) => r.key == row.key && (r.file != null || r.task != null),
            )) {
          throw StateError('该文件正在使用，暂时无法删除');
        }
      });
      return;
    }
    await _action(() async {
      await manager.remove(task.key);
      await _load();
    });
  }

  String _episodeLine(DownloadEpisodeRow row) =>
      '第 ${row.index} 集 · ${row.quality == 'best' || row.quality == 'auto' ? '自动画质' : row.quality}';

  String _messageLine(DownloadEpisodeRow row) {
    final task = row.task;
    if (task == null) {
      return '播放时缓存 · 下载管理里没有这条记录，可直接离线观看';
    }
    final percent = task.phase == DownloadPhase.running && task.fraction != null
        ? ' · ${(task.fraction!.clamp(0, 1) * 100).floor()}%'
        : '';
    return '${task.message}$percent';
  }

  ({String label, IconData icon, VoidCallback action}) _primary(
    DownloadEpisodeRow row,
  ) {
    final task = row.task;
    if (task == null) {
      return (
        label: '离线观看',
        icon: Icons.play_arrow,
        action: () => _action(() => _watch(row)),
      );
    }
    if (task.phase == DownloadPhase.queued ||
        task.phase == DownloadPhase.running) {
      return (
        label: '暂停下载',
        icon: Icons.pause,
        action: () => manager.pause(task.key),
      );
    }
    if (task.phase == DownloadPhase.ready) {
      return (
        label: '离线观看',
        icon: Icons.play_arrow,
        action: () => _action(() => _watch(row)),
      );
    }
    // A failed record is the queue's own word for 重试; a paused or cancelled one
    // is still 继续下载.
    return (
      label: task.phase == DownloadPhase.failed ? '重试下载' : '继续下载',
      icon: Icons.refresh,
      action: () => manager.resume(task.key),
    );
  }

  ({String label, IconData icon, VoidCallback action}) _secondary(
    DownloadEpisodeRow row,
  ) {
    final task = row.task;
    if (task != null &&
        (task.phase == DownloadPhase.queued ||
            task.phase == DownloadPhase.running)) {
      return (
        label: '取消下载',
        icon: Icons.close,
        action: () => manager.cancel(task.key),
      );
    }
    return (
      label: task == null ? '删除本地文件' : '删除下载记录',
      icon: Icons.delete_outline,
      action: () => _remove(row),
    );
  }

  String _name(DownloadEpisodeRow row) =>
      '${widget.dramaTitle} 第 ${row.index} 集';

  // One episode as two remote targets: a row-wide target would swallow the
  // destructive half at its end.
  Widget _tvRow(DownloadEpisodeRow row) {
    final primary = _primary(row), secondary = _secondary(row);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TvFocusable(
              label: '${_name(row)} ${primary.label}',
              onActivate: working ? null : primary.action,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Icon(primary.icon, size: 26),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _episodeLine(row),
                            style: const TextStyle(fontSize: 22),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _messageLine(row),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 17),
                          ),
                          if (row.isRunning)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: LinearProgressIndicator(
                                value: row.task?.fraction?.clamp(0, 1),
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
            label: '${_name(row)} ${secondary.label}',
            onActivate: working ? null : secondary.action,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Icon(secondary.icon, size: 26),
            ),
          ),
        ],
      ),
    );
  }

  Widget _touchRow(DownloadEpisodeRow row) {
    final primary = _primary(row), secondary = _secondary(row);
    final task = row.task;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            Icon(
              task == null || task.phase == DownloadPhase.ready
                  ? Icons.download_done
                  : Icons.downloading_outlined,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_episodeLine(row)),
                  const SizedBox(height: 4),
                  Text(
                    _messageLine(row),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (row.isRunning)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: LinearProgressIndicator(
                        value: task?.fraction?.clamp(0, 1),
                        minHeight: 2,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: primary.label,
              onPressed: working ? null : primary.action,
              icon: Icon(primary.icon),
            ),
            IconButton(
              tooltip: secondary.label,
              onPressed: working ? null : secondary.action,
              icon: Icon(secondary.icon),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tv = TvEnvironment.of(context);
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.dramaTitle,
          style: TextStyle(fontSize: tv ? 24 : null),
        ),
        automaticallyImplyLeading: !tv,
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
          ? Center(
              child: Text(error!, style: TextStyle(fontSize: tv ? 22 : null)),
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        tv ? 32 : 16,
                        16,
                        tv ? 32 : 16,
                        4,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              rows.isEmpty
                                  ? '这部剧已经没有下载记录了'
                                  : '共 ${rows.length} 集 · ${_group?.badge ?? '本地还没有文件'}',
                              style: TextStyle(
                                fontSize: tv ? 20 : null,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (working) const LinearProgressIndicator(minHeight: 2),
                    Expanded(
                      child: rows.isEmpty
                          ? const SizedBox.shrink()
                          : RefreshIndicator(
                              onRefresh: _load,
                              child: ListView(
                                padding: EdgeInsets.fromLTRB(
                                  tv ? 32 : 16,
                                  8,
                                  tv ? 32 : 16,
                                  24,
                                ),
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: [
                                  for (final row in rows)
                                    tv ? _tvRow(row) : _touchRow(row),
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
