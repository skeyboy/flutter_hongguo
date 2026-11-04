import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';

import '../features/merge_tasks_page.dart';
import '../navigation/app_navigation.dart';
import '../playback/local_playlist.dart';
import '../platform/runtime.dart';
import 'merge_manager.dart' as merge;

/// One episode the panel can offer, already resolved to a file on disk.
class MergeEpisodeOption {
  final String vid, quality, dramaId, label;
  final int index, bytes;

  /// The published media-cache file exists. A merge reads the bytes the media
  /// lane left, so an episode the viewer cleaned up is not a choice to make --
  /// the row stays visible and says why it cannot be picked.
  final bool available;
  const MergeEpisodeOption({
    required this.vid,
    required this.quality,
    required this.dramaId,
    required this.label,
    required this.index,
    required this.bytes,
    this.available = true,
  });
}

/// Size text shared by the merge panels: kilobytes below a megabyte.
String mergeBytesLabel(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

/// What a merge can be made of, read from the files the runtime already holds.
///
/// Every entry point asks the same question -- which episodes of this drama are
/// on disk -- and the offline shelf answers it without a network detail: the
/// label and the episode number come from the cached metadata the file itself
/// carries, so an unknown bucket offers a row that says 视频 `vid` instead of
/// going blank.
List<MergeEpisodeOption> mergeOptionsFromFiles(
  Iterable<LocalEpisode> files, {
  Iterable<String> skipVids = const [],
}) {
  final skipped = skipVids.toSet();
  final byVideo = <String, LocalEpisode>{};
  for (final file in files) {
    if (skipped.contains(file.vid)) continue;
    final known = byVideo[file.vid];
    // One entry per episode, at the quality the player would have picked: a
    // merge cannot take two versions of the same scene.
    if (known == null || file.bytes > known.bytes) byVideo[file.vid] = file;
  }
  final options = <MergeEpisodeOption>[];
  byVideo.forEach((vid, file) {
    final episode = file.detail?.episodes
        .where((e) => e.vid == vid)
        .firstOrNull;
    options.add(
      MergeEpisodeOption(
        vid: vid,
        quality: file.quality,
        dramaId: file.detail?.drama.id ?? '',
        label: file.label,
        index: episode?.index ?? options.length + 1,
        bytes: file.bytes,
      ),
    );
  });
  return options..sort((a, b) {
    final drama = a.dramaId.compareTo(b.dramaId);
    return drama != 0 ? drama : a.index.compareTo(b.index);
  });
}

/// The same list for a detail page that knows its episode numbers: everything
/// the drama has goes in, and what is not on disk arrives marked unavailable so
/// the panel can say why that row cannot be picked.
Future<List<MergeEpisodeOption>> mergeOptionsFor(
  AppRuntime runtime,
  DramaDetail detail, {
  Iterable<String> skipVids = const [],
}) async {
  if (runtime is! MergeRuntime) return const [];
  final files = await runtime.localEpisodes();
  final skipped = skipVids.toSet();
  final options = <MergeEpisodeOption>[];
  for (final episode in detail.episodes) {
    if (skipped.contains(episode.vid)) continue;
    final quality = localQualityFor(episode.vid, files, 'best');
    final file = files
        .where((f) => f.vid == episode.vid && f.quality == quality)
        .firstOrNull;
    options.add(
      MergeEpisodeOption(
        vid: episode.vid,
        quality: quality ?? 'best',
        dramaId: detail.drama.id,
        label: '第 ${episode.index} 集',
        index: episode.index,
        bytes: file?.bytes ?? 0,
        available: file != null,
      ),
    );
  }
  return options;
}

Future<void> showMergeSelection(
  BuildContext context,
  AppRuntime runtime, {
  required List<MergeEpisodeOption> options,
  String? suggestedTitle,
  String? targetMergeId,
}) async {
  if (runtime is! MergeRuntime) return;
  final size = MediaQuery.sizeOf(context);
  final bool? accepted;
  if (size.width >= 720 && size.height >= 400) {
    accepted = await showDialog<bool>(
      context: context,
      builder: (_) => Dialog(
        child: SizedBox(
          width: 720,
          height: math.min(680, size.height * .82),
          child: MergeSelection(
            runtime: runtime,
            options: options,
            suggestedTitle: suggestedTitle,
            targetMergeId: targetMergeId,
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
          child: MergeSelection(
            runtime: runtime,
            options: options,
            suggestedTitle: suggestedTitle,
            targetMergeId: targetMergeId,
          ),
        ),
      ),
    );
  }
  if (accepted == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('已加入合成队列，可在“我的 → 合成任务”查看'),
        persist: false,
        showCloseIcon: true,
        action: SnackBarAction(
          label: '查看',
          onPressed: () => pushAppPage<void>(
            context,
            AppScreen.mergeTasks,
            (_) => MergeTasksPage(runtime: runtime),
          ),
        ),
      ),
    );
  }
}

/// The merge picker: which downloaded episodes go into one product, and under
/// what name.
///
/// It follows the download shelf's panel rather than inventing a second idiom,
/// because the input is the same -- files already on disk -- and only the
/// promise differs: a merge writes one new file and needs the room for it.
class MergeSelection extends StatefulWidget {
  final MergeRuntime runtime;
  final List<MergeEpisodeOption> options;
  final String? suggestedTitle;

  /// Set means 追加剧集: the chosen episodes grow this existing product instead
  /// of becoming a new one, and the name belongs to that product already.
  final String? targetMergeId;
  const MergeSelection({
    super.key,
    required this.runtime,
    required this.options,
    this.suggestedTitle,
    this.targetMergeId,
  });
  @override
  State<MergeSelection> createState() => _MergeSelectionState();
}

class _MergeSelectionState extends State<MergeSelection> {
  late final manager = widget.runtime.merges;
  late final name = TextEditingController(text: widget.suggestedTitle ?? '');
  final selected = <int>{};
  bool loading = true, busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    // The queue owns the truth about what is on disk, and a source can be
    // cleaned up while this panel is open; listening keeps the rows honest.
    manager.addListener(_changed);
    _load();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    manager.removeListener(_changed);
    name.dispose();
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
          error = '合成记录读取失败，请重试';
        });
      }
    }
  }

  List<int> get _selectable => [
    for (var i = 0; i < widget.options.length; i++)
      if (widget.options[i].available) i,
  ];

  bool get _allSelected =>
      _selectable.isNotEmpty && selected.length == _selectable.length;

  bool get _appending => widget.targetMergeId != null;

  String get _actionLabel => _appending ? '追加' : '合成';

  bool get _canSubmit =>
      !busy &&
      !loading &&
      selected.isNotEmpty &&
      (_appending || selected.length >= 2);

  /// The queue keeps the order it is handed, so the panel hands it in episode
  /// order however the viewer clicked.
  List<merge.MergeSelection> _queue() {
    final picked = [for (final i in selected) widget.options[i]]
      ..sort((a, b) => a.index.compareTo(b.index));
    return [
      for (final option in picked)
        merge.MergeSelection(
          vid: option.vid,
          quality: option.quality,
          index: option.index,
          title: option.label,
          dramaId: option.dramaId,
        ),
    ];
  }

  /// Untitled merges are named by the range they hold, which is what the viewer
  /// recognises later in a list of products.
  String get _titleFor {
    final typed = name.text.trim();
    if (typed.isNotEmpty) return typed;
    final items = _queue();
    if (items.isEmpty) return '合并资源';
    final first = items.first.index, last = items.last.index;
    return first == last ? '第 $first 集' : '第 $first-$last 集';
  }

  String get _precheck {
    final bytes = selected.isEmpty ? 0 : manager.expectedBytes(_queue());
    final truth = manager.television
        ? 'TV 仅在前台合成'
        : manager.mobile
        ? '退到后台会暂停，回前台继续'
        : '离开此页面仍会继续，退出 App 后需重新继续';
    final needs = !_appending && selected.length < 2 ? ' · 需至少两集' : '';
    return '预计写入 ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB · $truth$needs';
  }

  Future<void> _submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await manager.enqueue(
        items: _queue(),
        title: _titleFor,
        targetMergeId: widget.targetMergeId,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e is StateError ? e.message : '未能加入合成，请检查存储空间后重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 20, right: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _appending ? '追加剧集' : '新建合成',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: '关闭合成选集',
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
            TextButton(
              onPressed: busy || loading || _selectable.isEmpty
                  ? null
                  : () => setState(() {
                      if (_allSelected) {
                        selected.clear();
                      } else {
                        selected
                          ..clear()
                          ..addAll(_selectable);
                      }
                    }),
              child: Text(_allSelected ? '清空' : '全选'),
            ),
            Text('${selected.length} 集'),
          ],
        ),
      ),
      if (!_appending)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: TextField(
            key: const ValueKey('merge-title'),
            controller: name,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: '合并资源名称',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Text(_precheck, style: Theme.of(context).textTheme.bodySmall),
      ),
      Expanded(
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                itemCount: widget.options.length,
                itemBuilder: (context, i) {
                  final option = widget.options[i];
                  final enabled = option.available && !busy;
                  return CheckboxListTile(
                    key: ValueKey('merge-episode-$i'),
                    value: selected.contains(i),
                    controlAffinity: ListTileControlAffinity.trailing,
                    enabled: enabled,
                    title: Text(option.label),
                    subtitle: Text(
                      option.available
                          ? mergeBytesLabel(option.bytes)
                          : '${mergeBytesLabel(option.bytes)} · 离线文件已不存在',
                    ),
                    onChanged: enabled
                        ? (_) => setState(() {
                            if (!selected.add(i)) selected.remove(i);
                          })
                        : null,
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
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
              if (!busy) TextButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('confirm-merge'),
            onPressed: _canSubmit ? _submit : null,
            icon: const Icon(Icons.merge_type),
            label: Text(busy ? '正在加入…' : '$_actionLabel ${selected.length} 集'),
          ),
        ),
      ),
    ],
  );
}
