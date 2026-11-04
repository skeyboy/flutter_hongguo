import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_tv/hongguo_tv.dart'
    show TvEnvironment, TvFocusable, tvBuild;

import '../merge/merge_export.dart' show showMergeExport;
import '../merge/merge_manager.dart' show MergeManager, MergePhase;
import '../merge/merge_selection.dart';
import '../merge/merged_library.dart';
import '../navigation/app_navigation.dart';
import '../platform/runtime.dart';
import '../widgets/tv_confirm.dart';
import 'player_page.dart';

/// The picker over everything this device has downloaded, opened the same way
/// from both merge pages. It is fed by the cache scan rather than a detail
/// request -- a merge is made of what is already on disk -- so a failed read or
/// an empty shelf lands as a message instead of a panel that promises nothing.
Future<void> showMergePicker(
  BuildContext context,
  AppRuntime runtime, {
  String? suggestedTitle,
  String? targetMergeId,
}) async {
  if (runtime is! MergeRuntime) return;
  final List<MergeEpisodeOption> options;
  try {
    options = mergeOptionsFromFiles(await runtime.localEpisodes());
  } catch (e) {
    _say(context, e is StateError ? e.message : '无法读取本地剧集，请稍后重试');
    return;
  }
  if (!context.mounted) return;
  if (options.isEmpty) {
    _say(context, '还没有可选的离线剧集，请先下载分集');
    return;
  }
  await showMergeSelection(
    context,
    runtime,
    options: options,
    suggestedTitle: suggestedTitle,
    targetMergeId: targetMergeId,
  );
}

void _say(BuildContext context, String text) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// The merged resources on disk, and one product's whole record: what is in it,
/// where it went when it was exported, and what can still be done to it.
class MergedPage extends StatefulWidget {
  final AppRuntime runtime;

  /// Set opens straight on that resource instead of on the library, which is how
  /// the queue's cards and a phone's list drill in.
  final String? mergeId;
  const MergedPage({super.key, required this.runtime, this.mergeId});

  @override
  State<MergedPage> createState() => _MergedPageState();
}

class _MergedPageState extends State<MergedPage> {
  MergeRuntime? merge;
  MergeManager? _queue;

  /// null until the first read answers, so the page never claims an empty library
  /// it has not looked at yet.
  List<MergedVideo>? videos;
  String? selected;
  bool busy = false;
  String? error;

  /// How many finished merges the last read saw: the queue notifies on every
  /// progress tick, and only a job reaching its end is worth a disk read.
  int settled = 0;

  @override
  void initState() {
    super.initState();
    selected = widget.mergeId;
    final runtime = widget.runtime;
    if (runtime is MergeRuntime) {
      merge = runtime;
      _queue = runtime.merges..addListener(_changed);
    }
    _load();
  }

  @override
  void dispose() {
    _queue?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final manager = _queue;
    if (manager == null) {
      setState(() {});
      return;
    }
    final done = manager.tasks
        .where((task) => !task.isExport && task.phase == MergePhase.done)
        .length;
    final grew = done != settled;
    settled = done;
    setState(() {});
    if (grew) unawaited(_load());
  }

  /// Reads the queue before the library: a product published by a process that
  /// died mid-write is already on disk, and 采纳 it is what keeps the list and
  /// the task cards from disagreeing.
  Future<void> _load() async {
    final manager = _queue, library = merge?.mergedLibrary;
    if (manager == null || library == null) {
      if (mounted) {
        setState(() {
          videos = const [];
          busy = false;
        });
      }
      return;
    }
    try {
      await manager.reconcile();
      final values = await library.list();
      if (!mounted) return;
      settled = manager.tasks
          .where((task) => !task.isExport && task.phase == MergePhase.done)
          .length;
      setState(() {
        videos = values;
        error = null;
        busy = false;
        if (selected != null &&
            !values.any((video) => video.mergeId == selected)) {
          selected = null;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '无法读取合并资源，请重试。';
        });
      }
    }
  }

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _open(MergedVideo video) async {
    await pushAppPage<void>(
      context,
      AppScreen.merged,
      (_) => MergedPage(runtime: widget.runtime, mergeId: video.mergeId),
    );
    if (mounted) await _load();
  }

  Future<void> _play(MergedVideo video) async {
    await pushAppPage<void>(
      context,
      AppScreen.player,
      (_) => PlayerPage(
        runtime: widget.runtime,
        // The product is one file with no catalog entry behind it, so the player
        // is handed a one-episode drama of its own: the merged file is the vid.
        detail: DramaDetail(Drama(id: video.mergeId, title: video.title), [
          Episode(vid: video.mergeId, index: 1),
        ]),
        cachedOnly: true,
        mergeId: video.mergeId,
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _append(MergedVideo video) async {
    if (busy) return;
    setState(() => busy = true);
    await showMergePicker(
      context,
      widget.runtime,
      suggestedTitle: video.title,
      targetMergeId: video.mergeId,
    );
    if (mounted) setState(() => busy = false);
  }

  Future<void> _export(MergedVideo video) async {
    if (busy) return;
    setState(() => busy = true);
    await showMergeExport(context, widget.runtime, video);
    if (mounted) setState(() => busy = false);
  }

  Future<void> _remove(MergedVideo video) async {
    final manager = _queue;
    if (manager == null || busy) return;
    final confirmed = await showTvConfirm(
      context,
      title: '删除合并资源？',
      body: '只删除合并后的文件与构成记录，下载的分集保留。',
      confirmLabel: '删除',
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      await manager.remove(video.mergeId);
    } catch (_) {
      _notice('删除未完成，请检查存储空间后重试。');
    }
    if (!mounted) return;
    setState(() => busy = false);
    await _load();
    if (!mounted) return;
    final gone = !(videos ?? const <MergedVideo>[]).any(
      (value) => value.mergeId == video.mergeId,
    );
    if (gone && widget.mergeId == video.mergeId) Navigator.pop(context);
  }

  /// `existsSync` is one stat call per row, but a path the system refuses has to
  /// leave the page standing: an answer it cannot get reads as still there.
  bool _alive(String path) {
    try {
      return File(path).existsSync();
    } catch (_) {
      return true;
    }
  }

  bool _sourceGone(MergedItem item) {
    final runtime = merge;
    if (runtime == null) return false;
    return !_alive(runtime.mediaPath(item.vid, item.quality));
  }

  Widget _actions(MergedVideo video, {required bool tv}) {
    Widget action(
      String key,
      String label,
      IconData icon,
      VoidCallback? onTap,
    ) => tv
        ? TvFocusable(
            key: ValueKey(key),
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
        : OutlinedButton.icon(
            key: ValueKey(key),
            onPressed: onTap,
            icon: Icon(icon),
            label: Text(label),
          );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (tv)
          action(
            'merged-play',
            '播放',
            Icons.play_arrow,
            busy ? null : () => _play(video),
          )
        else
          FilledButton.icon(
            key: const ValueKey('merged-play'),
            onPressed: busy ? null : () => _play(video),
            icon: const Icon(Icons.play_arrow),
            label: const Text('播放'),
          ),
        action(
          'merged-append',
          '追加剧集',
          Icons.playlist_add,
          busy ? null : () => _append(video),
        ),
        // 导出不落在 TV：遥控器没有文件管理器的语义，那枚面板自己会返回。
        if (!tvBuild)
          action(
            'merged-export',
            '导出',
            Icons.ios_share,
            busy ? null : () => _export(video),
          ),
        action(
          'merged-remove',
          '删除',
          Icons.delete_outline,
          busy ? null : () => _remove(video),
        ),
      ],
    );
  }

  Widget _field(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );

  Widget _detail(MergedVideo video, {required bool tv, required bool pane}) {
    final theme = Theme.of(context);
    final title = TextStyle(fontSize: tv ? 30 : null);
    final resolution = video.width > 0 && video.height > 0
        ? '${video.codec ?? '未记录'} · ${video.width}x${video.height}'
        : (video.codec ?? '未记录');
    return ListView(
      padding: EdgeInsets.all(pane ? 16 : (tv ? 28 : 20)),
      children: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        Text(
          video.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: tv ? title : theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 14),
        _actions(video, tv: tv),
        const SizedBox(height: 16),
        _field('名称', video.title),
        _field('时长', _clock(video.durationMs)),
        _field('大小', mergeBytesLabel(video.bytes)),
        _field('编码', resolution),
        _field('创建', _stamp(video.createdAt)),
        _field('更新', _stamp(video.updatedAt)),
        const SizedBox(height: 16),
        Text(
          '构成',
          style: tv
              ? const TextStyle(fontSize: 24)
              : theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        if (video.items.isEmpty)
          Text('暂无构成记录，可重新合成或追加剧集。', style: theme.textTheme.bodySmall)
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '集数 · 名称 · 起始 / 时长 / 大小 / 源',
              style: theme.textTheme.bodySmall,
            ),
          ),
          for (final item in video.items) _itemRow(item, tv: tv),
        ],
        const SizedBox(height: 16),
        Text(
          '导出记录',
          style: tv
              ? const TextStyle(fontSize: 24)
              : theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        if (video.exports.isEmpty)
          Text('尚未导出到应用外的位置。', style: theme.textTheme.bodySmall)
        else ...[
          for (final record in video.exports) _exportRow(record, tv: tv),
        ],
      ],
    );
  }

  Widget _itemRow(MergedItem item, {required bool tv}) {
    final theme = Theme.of(context);
    final gone = _sourceGone(item);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 64, child: Text('第 ${item.index} 集')),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.episodeTitle.isEmpty
                      ? item.sourceName
                      : item.episodeTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // The media-cache file this episode was read from, so a product
                // an unknown bucket contributed can still be traced afterwards.
                Text(
                  '起始 ${_clock(item.offsetMs)} · 时长 ${_clock(item.durationMs)} · '
                  '${mergeBytesLabel(item.sourceSize)} · ${item.vid} ${item.quality}'
                  '${item.dramaId.isEmpty ? ' · 来源未知' : ''}',
                  style: tv
                      ? const TextStyle(fontSize: 16)
                      : theme.textTheme.bodySmall,
                ),
                if (gone)
                  Text(
                    '源文件已清理',
                    style: TextStyle(
                      fontSize: tv ? 16 : 12,
                      color: theme.colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _exportRow(MergedExport record, {required bool tv}) {
    final theme = Theme.of(context);
    final present = _alive(record.path);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            record.path,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: tv ? 20 : null),
          ),
          Text(
            '${record.mode == 'append' ? '追加' : '新片段'} · ${_stamp(record.at)} · '
            '${mergeBytesLabel(record.bytes)} · ${present ? '文件在' : '已移动或删除'}',
            style: tv
                ? const TextStyle(fontSize: 16)
                : theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _list(
    List<MergedVideo> items, {
    required bool tv,
    required bool pane,
  }) => RefreshIndicator(
    onRefresh: _load,
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      children: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: busy ? null : _load,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        for (final video in items)
          if (tv)
            TvFocusable(
              key: ValueKey('merged-tv-${video.mergeId}'),
              label: '${video.title} 查看构成',
              onActivate: busy ? null : () => _open(video),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.movie_outlined, size: 26),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            video.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 22),
                          ),
                          Text(
                            _caption(video),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 17),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            ListTile(
              key: ValueKey('merged-${video.mergeId}'),
              selected: pane && video.mergeId == selected,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              leading: const Icon(Icons.movie_outlined),
              title: Text(
                video.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                _caption(video),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: busy
                  ? null
                  : () {
                      if (pane) {
                        setState(() => selected = video.mergeId);
                      } else {
                        unawaited(_open(video));
                      }
                    },
            ),
      ],
    ),
  );

  String _caption(MergedVideo video) =>
      '${video.items.length} 集 · ${_clock(video.durationMs)} · '
      '${mergeBytesLabel(video.bytes)}'
      '${video.codec == null ? '' : ' · ${video.codec}'} · ${_stamp(video.updatedAt)}';

  Widget _empty({required bool tv}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            error ?? '还没有合并资源\n把已下载的剧集合成一个文件，可直接播放或导出。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: tv ? 20 : null),
          ),
          const SizedBox(height: 16),
          if (tv)
            TvFocusable(
              label: '去合成',
              autofocus: true,
              onActivate: busy
                  ? null
                  : () => showMergePicker(context, widget.runtime),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('去合成', style: TextStyle(fontSize: 20)),
              ),
            )
          else
            FilledButton.icon(
              key: const ValueKey('merged-create'),
              onPressed: busy
                  ? null
                  : () => showMergePicker(context, widget.runtime),
              icon: const Icon(Icons.merge_type),
              label: const Text('去合成'),
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
    if (merge == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('合并资源')),
        body: const Center(
          child: Text('此设备暂不支持合成', textAlign: TextAlign.center),
        ),
      );
    }
    final items = videos ?? const <MergedVideo>[];
    final detail = selected == null
        ? null
        : items.where((video) => video.mergeId == selected).firstOrNull;
    // A wide window keeps the list beside the composition; a phone or a remote
    // walks into a page whose actions are its own focus targets instead.
    final pane = !tv && MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      appBar: AppBar(
        title: const Text('合并资源'),
        automaticallyImplyLeading: !tv,
        actions: [
          if (tv)
            TvFocusable(
              key: const ValueKey('merged-new-tv'),
              label: '新建合成',
              onActivate: busy
                  ? null
                  : () => showMergePicker(context, widget.runtime),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.merge_type, size: 20),
                    SizedBox(width: 8),
                    Text('新建合成', style: TextStyle(fontSize: 18)),
                  ],
                ),
              ),
            )
          else
            IconButton(
              key: const ValueKey('merged-new'),
              tooltip: '新建合成',
              onPressed: busy
                  ? null
                  : () => showMergePicker(context, widget.runtime),
              icon: const Icon(Icons.merge_type),
            ),
          if (tv)
            TvFocusable(
              label: '刷新合并资源',
              onActivate: busy ? null : _load,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text('刷新', style: TextStyle(fontSize: 18)),
              ),
            )
          else
            IconButton(
              tooltip: '刷新合并资源',
              onPressed: busy ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: videos == null && error == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
          ? _empty(tv: tv)
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1280),
                child: !pane
                    ? detail == null
                          ? _list(items, tv: tv, pane: false)
                          : _detail(detail, tv: tv, pane: false)
                    : Row(
                        children: [
                          SizedBox(
                            width: 360,
                            child: _list(items, tv: false, pane: true),
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(
                            child: detail == null
                                ? Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(24),
                                      child: Text(
                                        '选择左侧的合并资源查看构成',
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  )
                                : _detail(detail, tv: false, pane: true),
                          ),
                        ],
                      ),
              ),
            ),
    );
  }
}

/// `1:23:45` for a product that can run past an hour; the columns always show, so
/// the composition table stays aligned.
String _clock(int milliseconds) {
  final total = (milliseconds / 1000).floor();
  return '${total ~/ 3600}:${_two(total % 3600 ~/ 60)}:${_two(total % 60)}';
}

String _stamp(DateTime at) =>
    '${at.year}-${_two(at.month)}-${_two(at.day)} ${_two(at.hour)}:${_two(at.minute)}';

String _two(int value) => value.toString().padLeft(2, '0');
