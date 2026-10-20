import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';

import '../features/downloads_page.dart';
import '../navigation/app_navigation.dart';
import '../platform/runtime.dart';
import 'download_manager.dart';

Future<void> showDownloadSelection(
  BuildContext context,
  AppRuntime runtime,
  DramaDetail detail,
) async {
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
          child: DownloadSelection(runtime: runtime, detail: detail),
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
          child: DownloadSelection(runtime: runtime, detail: detail),
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

class DownloadSelection extends StatefulWidget {
  final DownloadRuntime runtime;
  final DramaDetail detail;
  const DownloadSelection({
    super.key,
    required this.runtime,
    required this.detail,
  });
  @override
  State<DownloadSelection> createState() => _DownloadSelectionState();
}

class _DownloadSelectionState extends State<DownloadSelection> {
  late final manager = widget.runtime.downloads;
  late String quality = settingsFor(widget.runtime).defaultQuality;
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

  bool available(int i) => ![
    DownloadPhase.ready,
    DownloadPhase.running,
    DownloadPhase.queued,
  ].contains(manager.taskFor(widget.detail.episodes[i].vid, quality)?.phase);
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
                  : "离开此页面仍会继续，退出 App 后需重新继续"} · 最多保留 ${settingsFor(widget.runtime).maxCacheFiles} 集',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
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
                    final task = manager.taskFor(episode.vid, quality);
                    final enabled = available(i) && !busy;
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
                            if (!enabled && task != null)
                              Text(
                                task.phase == DownloadPhase.ready
                                    ? '已下载'
                                    : '已加入',
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
