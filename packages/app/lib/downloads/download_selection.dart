import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import '../catalog/local_library.dart';
import '../features/downloads_page.dart';
import '../navigation/app_navigation.dart';
import '../platform/runtime.dart';
import 'download_manager.dart';
import 'latest_episode_check.dart';

Future<void> showDownloadSelection(
  BuildContext context,
  AppRuntime runtime,
  DramaDetail detail, {
  Set<String> cachedVids = const {},
  String? initialQuality,
}) async {
  if (runtime is! DownloadRuntime) return;
  final size = MediaQuery.sizeOf(context);
  final bool? accepted;
  if (size.width >= 720 && size.height >= 400) {
    accepted = await showDialog<bool>(
      context: context,
      builder: (_) => Dialog(
        child: SizedBox(
          width: 720,
          height: math.min(680, size.height * .82),
          child: DownloadSelection(
            runtime: runtime,
            detail: detail,
            cachedVids: cachedVids,
            initialQuality: initialQuality,
          ),
        ),
      ),
    );
  } else {
    accepted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      builder: (_) => SafeArea(
        top: false,
        child: SizedBox(
          height: size.height * (size.height < 400 ? .95 : .78),
          child: DownloadSelection(
            runtime: runtime,
            detail: detail,
            cachedVids: cachedVids,
            initialQuality: initialQuality,
          ),
        ),
      ),
    );
  }
  if (accepted == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('已加入下载，可在“我的 → 下载管理”查看'),
        persist: false,
        showCloseIcon: true,
        action: SnackBarAction(
          label: '查看',
          onPressed: () => pushAppPage<void>(
            context,
            AppScreen.downloads,
            (_) => DownloadsPage(runtime: runtime),
          ),
        ),
      ),
    );
  }
}

/// The shelf's route into the picker the detail page already uses: read what a
/// cached drama has online now, and let the viewer choose among the episodes
/// that arrived since. 检查最新剧集 only reports that gap; this is the way in.
/// Everything already on disk comes pre-marked, and a drama
/// with nothing new answers in place instead of opening an empty window.
///
/// Returns the line for the page's own notice, or null once the picker spoke
/// for itself.
Future<String?> showCachedDramaDownloadSelection(
  BuildContext context,
  AppRuntime runtime,
  LocalDramaGroup group,
) async {
  final online = await scanOnlineEpisodes(runtime, group);
  if (!online.hasNew) {
    return '已是最新：在线 ${online.detail.episodes.length} 集，本地都有缓存或在下载中';
  }
  await showDownloadSelection(
    context,
    runtime,
    online.detail,
    cachedVids: {for (final f in group.files) f.vid},
    initialQuality: online.quality,
  );
  return null;
}

class DownloadSelection extends StatefulWidget {
  final DownloadRuntime runtime;
  final DramaDetail detail;

  /// Videos already on disk that the queue has no record of. An episode cached
  /// while playing never entered 下载管理, so without this the picker reached
  /// from a cached drama would offer to fetch the same file a second time.
  final Set<String> cachedVids;

  /// The shelf opens this panel on a drama it already partly holds, so the new
  /// episodes start at the quality the rest of the series was cached at rather
  /// than the app-wide default -- a top-up should not silently switch track.
  final String? initialQuality;
  const DownloadSelection({
    super.key,
    required this.runtime,
    required this.detail,
    this.cachedVids = const {},
    this.initialQuality,
  });
  @override
  State<DownloadSelection> createState() => _DownloadSelectionState();
}

class _DownloadSelectionState extends State<DownloadSelection> {
  late final manager = widget.runtime.downloads;
  late String quality =
      widget.initialQuality ?? settingsFor(widget.runtime).defaultQuality;
  final selected = <int>{};
  bool loading = true, busy = false;
  String? error;
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
          error = '下载记录读取失败，请重试';
        });
      }
    }
  }

  bool available(int i) {
    final episode = widget.detail.episodes[i];
    if (widget.cachedVids.contains(episode.vid)) return false;
    return ![
      DownloadPhase.ready,
      DownloadPhase.running,
      DownloadPhase.queued,
    ].contains(manager.taskFor(episode.vid, quality)?.phase);
  }

  /// Why a cell cannot be picked. A file the shelf already holds says 已下载 even
  /// when the queue never heard of it; an episode still held by a paused or
  /// failed task says 已加入; a cell disabled only by the in-flight submit stays
  /// silent, the way it did before this view knew about cached files.
  String? _blockedAs(int i) {
    final episode = widget.detail.episodes[i];
    if (widget.cachedVids.contains(episode.vid)) return '已下载';
    final task = manager.taskFor(episode.vid, quality);
    if (task == null) return null;
    return task.phase == DownloadPhase.ready ? '已下载' : '已加入';
  }

  Future<void> _submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await manager.enqueue(
        widget.detail,
        selected.where(available).toList(),
        quality,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e is StateError ? e.message : '未能加入下载，请检查存储和配置后重试';
        });
      }
    }
  }

  /// The TV cell carries the same facts as the touch button but no button of
  /// its own: TvGrid owns the focus ring and the OK activation.
  Widget _tvCell(int i) {
    final episode = widget.detail.episodes[i];
    final enabled = available(i) && !busy;
    final blocked = enabled ? null : _blockedAs(i);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: ValueKey('download-episode-$i'),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: selected.contains(i) ? scheme.primaryContainer : null,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('第 ${episode.index} 集'),
          if (blocked != null)
            Text(blocked, style: const TextStyle(fontSize: 12)),
          if (selected.contains(i)) const Icon(Icons.check, size: 16),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) => Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 20, right: 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '下载剧集',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '关闭下载选集',
                onPressed: busy ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              DropdownButton<String>(
                key: const ValueKey('download-quality'),
                value: quality,
                items: [
                  for (final q in {'best', '720p', '1080p', quality})
                    DropdownMenuItem(
                      value: q,
                      child: Text(q == 'best' || q == 'auto' ? '自动画质' : q),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (q) => setState(() {
                        quality = q!;
                        selected.removeWhere((i) => !available(i));
                      }),
              ),
              const Spacer(),
              TextButton(
                onPressed: busy || loading
                    ? null
                    : () => setState(() {
                        final all = List.generate(
                          widget.detail.episodes.length,
                          (i) => i,
                        ).where(available).toSet();
                        if (selected.length == all.length) {
                          selected.clear();
                        } else {
                          selected
                            ..clear()
                            ..addAll(all);
                        }
                      }),
                child: Text(
                  selected.isNotEmpty &&
                          selected.length ==
                              List.generate(
                                widget.detail.episodes.length,
                                (i) => i,
                              ).where(available).length
                      ? '清空'
                      : '全选',
                ),
              ),
              Text('${selected.length} 集'),
            ],
          ),
        ),
        if (size.maxHeight > 400)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              '${manager.television
                  ? "TV 仅在前台下载"
                  : manager.mobile
                  ? settingsFor(widget.runtime).backgroundDownloads
                        ? "已开启后台下载，系统可能延迟调度"
                        : "未开启后台下载，退后台暂停，回前台继续"
                  : "离开此页面仍会继续，退出 App 后需重新继续"} · 同时下载 ${settingsFor(widget.runtime).downloadConcurrent} 集',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : tvBuild
              ? TvGrid(
                  // A lazy GridView never builds the rows the remote has not
                  // reached, so focus dies at the viewport edge; TvGrid
                  // materialises cells by id and keeps the ring whole.
                  maxExtent: 190,
                  aspectRatio: 1.25,
                  ids: [
                    for (var i = 0; i < widget.detail.episodes.length; i++)
                      'e$i',
                  ],
                  label: (i) => '第 ${widget.detail.episodes[i].index} 集',
                  activate: (i) {
                    if (!available(i) || busy) return;
                    setState(() {
                      if (!selected.add(i)) selected.remove(i);
                    });
                  },
                  itemBuilder: (context, i) => _tvCell(i),
                )
              : GridView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 110,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.25,
                  ),
                  itemCount: widget.detail.episodes.length,
                  itemBuilder: (context, i) {
                    final episode = widget.detail.episodes[i];
                    final enabled = available(i) && !busy;
                    final blocked = enabled ? null : _blockedAs(i);
                    return Semantics(
                      selected: selected.contains(i),
                      child: OutlinedButton(
                        key: ValueKey('download-episode-$i'),
                        style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.zero,
                          backgroundColor: selected.contains(i)
                              ? Theme.of(context).colorScheme.primaryContainer
                              : null,
                        ),
                        onPressed: enabled
                            ? () => setState(() {
                                if (!selected.add(i)) selected.remove(i);
                              })
                            : null,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('第 ${episode.index} 集'),
                            if (blocked != null)
                              Text(
                                blocked,
                                style: const TextStyle(fontSize: 10),
                              ),
                            if (selected.contains(i))
                              const Icon(Icons.check, size: 14),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                if (manager.tasks.isEmpty && !busy)
                  TextButton(onPressed: _load, child: const Text('重试')),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('confirm-download'),
              onPressed: busy || loading || selected.isEmpty ? null : _submit,
              icon: const Icon(Icons.download_outlined),
              label: Text(busy ? '正在加入…' : '下载 ${selected.length} 集'),
            ),
          ),
        ),
      ],
    ),
  );
}
