import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';

import '../features/merge_tasks_page.dart';
import '../navigation/app_navigation.dart';
import '../playback/local_playlist.dart';
import '../platform/runtime.dart';
import 'merge_manager.dart' as merge;
import 'merge_transcode.dart'
    show TranscodeSource, planTranscode, transcodeRejectOf, transcodeSourceOf;
import 'merge_worker.dart' show MergePrecheckReport, MergeProbeEntry;
import 'merged_library.dart';

/// One episode the panel can offer, already resolved to a file on disk.
class MergeEpisodeOption {
  final String vid, quality, dramaId, label;
  final int index, bytes;

  /// The published media-cache file exists. A merge reads the bytes the media
  /// lane left, so an episode the viewer cleaned up is not a choice to make --
  /// the tile stays visible and says why it cannot be picked.
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

  /// How a product's manifest records the same episode: an append that would
  /// write it twice is refused by the queue, so the tile shows 已含 instead.
  String get key => '${vid}_$quality';
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
/// carries, so an unknown bucket offers a tile that says 视频 `vid` instead of
/// going blank.
List<MergeEpisodeOption> mergeOptionsFromFiles(Iterable<LocalEpisode> files) {
  final byVideo = <String, LocalEpisode>{};
  for (final file in files) {
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
/// the panel can say why that tile cannot be picked.
Future<List<MergeEpisodeOption>> mergeOptionsFor(
  AppRuntime runtime,
  DramaDetail detail,
) async {
  if (runtime is! MergeRuntime) return const [];
  final files = await runtime.localEpisodes();
  final options = <MergeEpisodeOption>[];
  for (final episode in detail.episodes) {
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
  bool preselect = false,
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
            preselect: preselect,
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
            preselect: preselect,
          ),
        ),
      ),
    );
  }
  if (accepted == true && context.mounted) {
    // A job that is standing still because the player has the disk reads as a
    // merge that will not start, so the queue's reason is said with the job.
    final hold = runtime.merges.holdReason;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          hold == null ? '已加入合成队列，可在“我的 → 合成任务”查看' : '已加入合成队列 · $hold',
        ),
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
/// Two steps -- 选择 then 预检 -- because the kernel's verdict on these files is
/// worth more before the queue is told than after. A merge that cannot be made
/// losslessly used to surface only as a failed task card, which is exactly how
/// 「选好了却合不成」 was reported.
class MergeSelection extends StatefulWidget {
  final MergeRuntime runtime;
  final List<MergeEpisodeOption> options;
  final String? suggestedTitle;

  /// Set means the panel opens in 追加到已有: the chosen episodes grow this
  /// existing product, and the name belongs to that product already.
  final String? targetMergeId;

  /// The group entries -- 下载管理 and the local shelf -- come from a set the
  /// viewer already finished downloading, so those episodes start picked and
  /// the viewer only removes what they don't want.
  final bool preselect;
  const MergeSelection({
    super.key,
    required this.runtime,
    required this.options,
    this.suggestedTitle,
    this.targetMergeId,
    this.preselect = false,
  });
  @override
  State<MergeSelection> createState() => _MergeSelectionState();
}

enum _MergeStep { select, precheck }

/// What one mode would make of a 预检 answer: the 片 a confirm queues, and the
/// reason the whole selection is not a single product.
///
/// 无损 hands back the buckets the writer itself accepted. 兼容 re-asks those
/// very same tables with the encoder's rule, which is wider -- files whose
/// `stsd` differs only in profile or level are one product once something
/// decodes them and writes them again -- and narrower in one respect: a source
/// an encoder cannot open is no use to it either. Both readings come from the
/// precheck's single table read, so the two lanes cannot disagree about what is
/// on disk, only about what can be made of it.
class _MergeReading {
  /// The episodes of every 片, in the order the selection holds them.
  final List<List<MergeProbeEntry>> parts;

  /// The lane's own sentence on why these files are not one product; null means
  /// 可以合成一片 is a promise the merge keeps.
  final String? reject;

  /// What the products are expected to weigh. Only 兼容 has a number of its own:
  /// the rates promised to the encoder over the promised length, because a
  /// re-encode writes a different file rather than the sum of the sources.
  final int? productBytes;
  const _MergeReading({required this.parts, this.reject, this.productBytes});
}

class _MergeSelectionState extends State<MergeSelection> {
  late final manager = widget.runtime.merges;
  late final name = TextEditingController(text: widget.suggestedTitle ?? '');
  final selected = <int>{};

  _MergeStep step = _MergeStep.select;
  bool loading = true, busy = false, probing = false;
  String? error;

  /// The products 追加到已有 can grow, read once together with the queue.
  List<MergedVideo> targets = const [];

  /// null is 新建合并资源. The target decides which tiles are 已含 and which
  /// files the precheck compares against.
  String? appendTarget;
  Set<String> included = const {};

  /// The last 预检 answer; null until it arrives.
  MergePrecheckReport? report;

  /// `lossless` copies every source byte, `compatible` re-encodes them into one
  /// H.264 file. The default is the lane that cannot lose quality, and 兼容 is
  /// only reachable when a machine has answered with an encoder.
  String mode = 'lossless';

  bool get _compatible => mode == 'compatible' && !_appending;

  @override
  void initState() {
    super.initState();
    appendTarget = widget.targetMergeId;
    // The queue owns the truth about what is on disk, and a source can be
    // cleaned up while this panel is open; listening keeps the tiles honest.
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
      final products = await widget.runtime.mergedLibrary.list();
      if (!mounted) return;
      setState(() {
        targets = products;
        loading = false;
        error = null;
        if (appendTarget != null &&
            !products.any((video) => video.mergeId == appendTarget)) {
          appendTarget = null;
        }
        _applyIncluded();
        if (widget.preselect && selected.isEmpty) {
          selected.addAll(_selectable);
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = '合成记录读取失败，请重试';
      });
    }
  }

  /// Which tiles the current target already holds. A different target is a
  /// different answer, and an episode already inside it cannot be queued again.
  void _applyIncluded() {
    final id = appendTarget;
    if (id == null) {
      included = const {};
    } else {
      final product = targets.where((video) => video.mergeId == id).firstOrNull;
      included = {
        for (final item in product?.items ?? const <MergedItem>[]) item.key,
      };
    }
    selected.removeWhere((i) => included.contains(widget.options[i].key));
  }

  List<int> get _selectable => [
    for (var i = 0; i < widget.options.length; i++)
      if (widget.options[i].available &&
          !included.contains(widget.options[i].key))
        i,
  ];

  bool get _allSelected =>
      _selectable.isNotEmpty && selected.length == _selectable.length;

  bool get _appending => appendTarget != null;

  /// The button says how many products one click makes, so 拆成两片 is never a
  /// surprise after pressing it.
  String _actionLabel(_MergeReading read) {
    if (_appending) return '开始追加';
    final parts = read.parts.length;
    return parts > 1 ? '合成 $parts 片' : '开始合成';
  }

  /// A product needs more than one episode; growing a product that already
  /// exists needs at least the episode being added.
  bool get _enough => _appending ? selected.isNotEmpty : selected.length >= 2;

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
  /// recognises later in a list of products. A split names each 片 by its own
  /// range, so two products from one click tell apart; a typed name is numbered
  /// for the same reason.
  String _titleFor(List<merge.MergeSelection> items, int at, int total) {
    final typed = name.text.trim();
    if (typed.isNotEmpty) return total > 1 ? '$typed ${at + 1}' : typed;
    if (items.isEmpty) return '合并资源';
    final first = items.first.index, last = items.last.index;
    return first == last ? '第 $first 集' : '第 $first-$last 集';
  }

  /// The 片 the current mode would write. Empty before the precheck answers, or
  /// when this lane cannot make a product out of the selection at all.
  ///
  /// 兼容 splits with [transcodeRejectOf] -- the rule the lane applies before it
  /// spawns anything -- so a 片 named here is a job the queue will take, and the
  /// split shown is the split the encoder's own limits force.
  _MergeReading _read(MergePrecheckReport? answer) {
    if (answer == null) return const _MergeReading(parts: []);
    if (!_compatible) {
      final groups = <List<MergeProbeEntry>>[];
      for (final batch in answer.ready) {
        final keys = batch.keys.toSet();
        groups.add([
          for (final entry in answer.entries)
            if (keys.contains(entry.key)) entry,
        ]);
      }
      return _MergeReading(parts: groups, reject: answer.reject);
    }
    if (answer.entries.any((entry) => entry.error != null)) {
      // A file the tables would not open is not something an encoder can read
      // either, and the viewer has to take it out of the selection first. The
      // 无损 wording already names it, so this says the same thing.
      return _MergeReading(parts: const [], reject: answer.reject);
    }
    final parts = <List<MergeProbeEntry>>[];
    var open = <MergeProbeEntry>[];
    for (final entry in answer.entries) {
      if (open.isEmpty ||
          transcodeRejectOf(_sourcesOf([...open, entry])) == null) {
        open = [...open, entry];
      } else {
        parts.add(open);
        open = [entry];
      }
    }
    if (open.isNotEmpty) parts.add(open);
    // One episode alone is not a product: it stays on the shelf, where the
    // offline list plays it in order anyway.
    final written = parts.where((part) => part.length >= 2).toList();
    var bytes = 0;
    for (final part in written) {
      bytes += planTranscode(_sourcesOf(part)).expectedBytes;
    }
    return _MergeReading(
      parts: written,
      reject: transcodeRejectOf(_sourcesOf(answer.entries)),
      productBytes: bytes,
    );
  }

  /// The encoder's facts for these episodes: the tables 预检 already read, plus
  /// where each file sits. No file is opened here.
  List<TranscodeSource> _sourcesOf(Iterable<MergeProbeEntry> episodes) => [
    for (final entry in episodes)
      transcodeSourceOf(entry, manager.sourcePath(entry.vid, entry.quality)),
  ];

  /// Choosing the lane is not choosing the files: the tables behind 预检 stay as
  /// they are, so the same answer is simply read by another rule.
  void _setMode(String value) {
    setState(() {
      mode = value;
      error = null;
    });
  }

  /// The episodes of one 片, in the order the queue keeps.
  List<merge.MergeSelection> _itemsOf(List<MergeProbeEntry> episodes) {
    final keys = {for (final entry in episodes) entry.key};
    return _queue()
        .where((item) => keys.contains('${item.vid}_${item.quality}'))
        .toList();
  }

  /// The footer's number: what 开始合成 would actually put in the queue. A split
  /// is smaller than what was picked, and the episodes left out are said in the
  /// 预检 card rather than silently dropped from the size.
  String _footnote(_MergeReading read) {
    final parts = read.parts;
    final queued = step == _MergeStep.precheck && parts.isNotEmpty;
    final items = queued
        ? [for (final part in parts) ..._itemsOf(part)]
        : _queue();
    if (queued && _compatible) {
      return '将排入 ${parts.length} 片 · ${items.length} 集 · '
          '产物约 ${mergeBytesLabel(read.productBytes ?? 0)}';
    }
    final mb = (manager.expectedBytes(items) / 1024 / 1024).toStringAsFixed(1);
    if (!queued) {
      return '已选 ${items.length} 集 · 合计约 $mb MB';
    }
    return '将排入 ${parts.length} 片 · ${items.length} 集 · 约 $mb MB';
  }

  String get _backgroundNote => manager.television
      ? 'TV 仅在前台合成'
      : manager.mobile
      ? '退到后台会暂停，回前台继续'
      : '离开此页面仍会继续，退出 App 后需重新继续';

  /// The 预检 step asks the writer itself, off the UI isolate: one rule, so a
  /// green pill is a promise the merge keeps rather than a second opinion.
  Future<void> _toPrecheck() async {
    if (!_enough) {
      setState(() => error = _appending ? '没有要追加的剧集' : '至少选择两集');
      return;
    }
    setState(() {
      step = _MergeStep.precheck;
      report = null;
      error = null;
    });
    await _probe();
  }

  Future<void> _probe() async {
    setState(() {
      probing = true;
      error = null;
    });
    try {
      final answer = await manager.precheck(
        _queue(),
        targetMergeId: appendTarget,
      );
      if (!mounted) return;
      setState(() {
        report = answer;
        probing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        probing = false;
        error = '预检未能完成，请检查离线文件后重试';
      });
    }
  }

  Future<void> _setTarget(String? id) async {
    setState(() {
      appendTarget = id;
      _applyIncluded();
      report = null;
      // An append grows a file in place, which a re-encode cannot do, so the
      // choice of lane goes away with the choice of target.
      if (id != null) mode = 'lossless';
    });
    if (step == _MergeStep.precheck && _enough) await _probe();
  }

  /// Queue every 片 this mode's verdict accepted, in one click. A mixed selection
  /// is a set of products, and the viewer chose them together -- making them
  /// confirm each 片 would only hide that the rest were dropped.
  Future<void> _submit(_MergeReading read) async {
    final batches = read.parts;
    setState(() {
      busy = true;
      error = null;
    });
    var queued = 0;
    try {
      for (var at = 0; at < batches.length; at++) {
        final items = _itemsOf(batches[at]);
        await manager.enqueue(
          items: items,
          title: _titleFor(items, at, batches.length),
          targetMergeId: appendTarget,
          mode: _compatible ? 'compatible' : 'lossless',
        );
        queued++;
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          // Jobs already in the queue keep running; saying what landed is the
          // difference between a half-done click and a failed one.
          error = queued == 0
              ? (e is StateError ? e.message : '未能加入合成，请检查存储空间后重试')
              : '已加入 $queued/${batches.length} 片，其余未能加入：'
                    '${e is StateError ? e.message : '请检查存储空间后重试'}';
        });
      }
    }
  }

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), persist: false, showCloseIcon: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    // One reading per frame: the card, the footer and the button all quote it,
    // so 将排入 N 片 cannot disagree with what 开始合成 actually queues.
    final read = _read(step == _MergeStep.select ? null : report);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 20, right: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  step == _MergeStep.select ? '选择剧集进行合成' : '合成预检',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (step == _MergeStep.precheck)
                TextButton(
                  key: const ValueKey('merge-back'),
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          step = _MergeStep.select;
                          report = null;
                        }),
                  child: const Text('返回修改'),
                ),
              IconButton(
                tooltip: '关闭合成选集',
                onPressed: busy ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : step == _MergeStep.select
              ? _select(context)
              : _precheck(context, read),
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
                if (!busy)
                  TextButton(onPressed: _load, child: const Text('重试')),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _footnote(read),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (step == _MergeStep.select) ...[
                TextButton(
                  key: const ValueKey('merge-clear'),
                  onPressed: busy || selected.isEmpty
                      ? null
                      : () => setState(selected.clear),
                  child: const Text('清空'),
                ),
                SizedBox(
                  width: 176,
                  child: FilledButton.icon(
                    key: const ValueKey('merge-next'),
                    onPressed: busy || !_enough ? null : _toPrecheck,
                    icon: const Icon(Icons.arrow_forward),
                    label: Text(_enough ? '下一步 · 预检' : '至少选择两集'),
                  ),
                ),
              ] else
                SizedBox(
                  width: 176,
                  child: FilledButton.icon(
                    key: const ValueKey('confirm-merge'),
                    onPressed: _canStart(read) ? () => _submit(read) : null,
                    icon: const Icon(Icons.merge_type),
                    label: Text(
                      busy
                          ? '正在加入…'
                          : probing
                          ? '正在预检…'
                          : _actionLabel(read),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  bool _canStart(_MergeReading read) =>
      !busy &&
      !probing &&
      _enough &&
      report != null &&
      // The lane's own verdict on at least one 片: a green button is a promise
      // the merge keeps, whether the selection is one product or several.
      read.parts.isNotEmpty;

  // ------------------------------------------------------------------- 选择

  Widget _select(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Text(
          _appending
              ? '灰显项标出未下载与已含；只有已下载且不在该资源中的分集可加。'
              : '只有已下载并通过校验的分集可选；灰显项可跳去下载。'
                    '合成跟随源文件画质，不设画质下拉。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            TextButton(
              key: const ValueKey('merge-select-all'),
              onPressed: busy || _selectable.isEmpty
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
              child: Text(_allSelected ? '取消全选' : '全选可合'),
            ),
            const Spacer(),
            if (_selectable.isEmpty)
              Text('没有可合成的离线分集', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: math.max(
              3,
              math.min(6, (MediaQuery.sizeOf(context).width / 96).floor()),
            ),
            childAspectRatio: 1.6,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: widget.options.length,
          itemBuilder: (context, i) => _tile(i),
        ),
      ),
    ],
  );

  Widget _tile(int i) {
    final option = widget.options[i];
    final theme = Theme.of(context);
    final held = included.contains(option.key);
    final picked = selected.contains(i);
    final enabled = option.available && !held && !busy;
    final muted = theme.colorScheme.onSurface.withValues(alpha: .38);
    return GestureDetector(
      key: ValueKey('merge-episode-$i'),
      onTap: () {
        if (!option.available) {
          _notice('该集未下载，请先去下载');
          return;
        }
        if (held) {
          _notice('${option.label}已在合并资源中');
          return;
        }
        setState(() {
          if (!selected.add(i)) selected.remove(i);
        });
      },
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: picked
              ? theme.colorScheme.primaryContainer
              : enabled
              ? theme.colorScheme.surfaceContainerHighest
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: .35,
                ),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: picked ? theme.colorScheme.primary : theme.dividerColor,
            width: picked ? 2 : 1,
          ),
        ),
        child: Stack(
          children: [
            Center(
              child: Text(
                option.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: picked ? FontWeight.w700 : FontWeight.w500,
                  color: enabled ? null : muted,
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 2,
              child: Text(
                held
                    ? '已含'
                    : option.available
                    ? '已下'
                    : '未',
                style: TextStyle(
                  fontSize: 11,
                  color: option.available && !held
                      ? theme.colorScheme.primary
                      : muted,
                ),
              ),
            ),
            if (picked)
              const Positioned(
                bottom: 0,
                right: 2,
                child: Icon(Icons.check, size: 15),
              ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------- 预检

  Widget _precheck(BuildContext context, _MergeReading read) {
    final answer = report;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      children: [
        _modeSegment(context),
        if (probing || answer == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 36),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          _verdict(context, answer, read),
          // The lane's reason goes with the verdict it produced, above the fold:
          // what one confirm queues has to be readable before pressing it.
          if (read.reject != null) _rejectNote(context, answer, read),
          const SizedBox(height: 10),
          _diskCard(context, answer, read),
          if (_appending) ...[
            const SizedBox(height: 10),
            Text(
              '追加走尾部快路径：已有的视频字节不搬移，只删尾部元数据、追加数据并重写元数据。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
        const SizedBox(height: 14),
        Text('目标', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        _targetSegment(context),
        if (_appending) _targetPicker(context) else _titleField(context),
        const SizedBox(height: 8),
        Text(_backgroundNote, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  /// 合成方式: the two lanes side by side, shown only where a second lane exists.
  ///
  /// 无损 is the default and stays the recommendation -- it copies the source
  /// bytes, so nothing can be lost. 兼容 is the escape for files the writer will
  /// not take together, and the panel says what it costs: a re-encode, and a job
  /// that starts over after a pause instead of resuming where it stopped.
  Widget _modeSegment(BuildContext context) {
    if (_appending || !manager.transcoderAvailable) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('合成方式', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _segmentButton(
                  'merge-mode-lossless',
                  '无损合成',
                  on: !_compatible,
                  onTap: () => _setMode('lossless'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _segmentButton(
                  'merge-mode-compatible',
                  '兼容合成',
                  on: _compatible,
                  onTap: () => _setMode('compatible'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _compatible
                ? '${manager.transcoderLabel}：解码后重新编码再拼接，不缩放画面，'
                      '码率与帧率只取各源的最高，产物是 H.264 + AAC、元数据前置，'
                      '换到其他手机也能播。暂停或退出后从头重编。'
                : '直接搬运源文件字节，画质与源完全一致；要求各集编码参数一致。',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _segmentButton(
    String key,
    String label, {
    required bool on,
    required VoidCallback onTap,
    bool enabled = true,
  }) => OutlinedButton(
    key: ValueKey(key),
    onPressed: !busy && enabled ? onTap : null,
    style: OutlinedButton.styleFrom(
      backgroundColor: on
          ? Theme.of(context).colorScheme.secondaryContainer
          : null,
    ),
    child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
  );

  Widget _verdict(
    BuildContext context,
    MergePrecheckReport answer,
    _MergeReading read,
  ) {
    final theme = Theme.of(context);
    final labels = {
      for (final option in widget.options) option.key: option.label,
    };
    final readable = answer.entries.where((entry) => entry.error == null);
    final first = readable.isEmpty ? null : readable.first;
    final ok = read.reject == null;
    final parts = read.parts;
    // What one click puts in the queue: the whole selection when this lane took
    // it as one file, otherwise every 片 it accepts on its own.
    final inProduct = {
      for (final part in parts)
        for (final e in part) e.key,
    };
    final sizes = {
      for (final part in parts)
        if (part.isNotEmpty) '${part.first.width}×${part.first.height}',
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _pill(
                ok
                    ? _compatible
                          ? '重编码可合成一片'
                          : '编解码一致'
                    : parts.isEmpty
                    ? _compatible
                          ? '不能兼容合成'
                          : '编码参数不一致'
                    : parts.length > 1
                    ? '可拆成 ${parts.length} 片'
                    : '可合成一片',
                good: ok || parts.isNotEmpty,
              ),
              // 无损 has one size for the whole selection; 兼容 can hold two, and
              // then the honest number is the one each 片 is written at, below.
              if (!_compatible && first != null && first.width > 0)
                _pill('${first.width}×${first.height}', good: true),
              if (_compatible && sizes.length == 1)
                _pill(sizes.first, good: true),
              if (first != null && first.codec.isNotEmpty)
                _pill(
                  first.audioCodec.isEmpty
                      ? first.codec
                      : '${first.codec} + ${first.audioCodec}',
                  good: true,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _compatible
                ? '读取每部源文件的时长、画面与码率，按码率与帧率最高的一集设定目标，'
                      '再解码重编成一条 H.264。分辨率不同或边长为奇数会分开合成：'
                      '兼容合成不缩放画面，画质不降。'
                : '读取每部源文件的 trak/stsd 与 sample 表，不解码全片。'
                      '画质、编码参数、轨道构成需一致；时间基、轨道顺序、ctts 的差异由内核归一。',
            style: theme.textTheme.bodySmall,
          ),
          if (!ok && !_compatible && parts.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final part in answer.batches)
              _partRow(
                _rangeOf(part.keys.toSet()),
                part.mergeable
                    ? '${part.keys.length} 集可无损合成一片'
                    : (part.reason ?? '不能合成一片'),
                good: part.mergeable,
              ),
          ],
          if (_compatible && parts.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final part in parts)
              _partRow(
                _rangeOf({for (final entry in part) entry.key}),
                '${part.length} 集可兼容合成一片 · '
                '${part.first.width}×${part.first.height}',
                good: true,
              ),
            for (final entry in answer.entries)
              if (!inProduct.contains(entry.key))
                _partRow('第 ${entry.index} 集', '落单，不必合成', good: false),
          ],
          const SizedBox(height: 8),
          for (final entry in answer.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(
                      labels['${entry.vid}_${entry.quality}'] ??
                          '第 ${entry.index} 集',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      entry.error ??
                          '${(entry.durationMs / 1000).round()}s · '
                              '${mergeBytesLabel(entry.bytes)} · ${entry.codec}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: entry.error == null
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.error,
                      ),
                    ),
                  ),
                  if (entry.error != null)
                    const Icon(Icons.error_outline, size: 16)
                  else if (inProduct.contains(entry.key))
                    const Icon(Icons.check, size: 16)
                  else
                    // Hollow: readable, but no product this lane accepts holds it.
                    Icon(
                      Icons.radio_button_unchecked,
                      size: 16,
                      color: theme.colorScheme.outline,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// One 片 inside the verdict card: the range it holds, and what the lane would
  /// do with it.
  Widget _partRow(String range, String detail, {required bool good}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(
          width: 96,
          child: Text(range, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        Expanded(
          child: Text(
            detail,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: good
                  ? Theme.of(context).colorScheme.onSurfaceVariant
                  : Theme.of(context).colorScheme.error,
            ),
          ),
        ),
        Icon(good ? Icons.check : Icons.close, size: 16),
      ],
    ),
  );

  /// How a 片 is titled in the verdict card: the range of episodes it holds.
  String _rangeOf(Set<String> keys) {
    final indexes = [
      for (final entry in report?.entries ?? const <MergeProbeEntry>[])
        if (keys.contains(entry.key)) entry.index,
    ]..sort();
    if (indexes.isEmpty) return '一片';
    final first = indexes.first, last = indexes.last;
    return first == last ? '第 $first 集' : '第 $first-$last 集';
  }

  /// The lane's reason the whole selection is not one file. With a split on the
  /// table that is not a dead end: the 片 list above says what one confirm
  /// queues, and only episodes no 片 holds are named as left out. Where a second
  /// lane exists, a refusal is also an invitation -- and the escape says what
  /// switching would cost.
  Widget _rejectNote(
    BuildContext context,
    MergePrecheckReport answer,
    _MergeReading read,
  ) {
    final held = {
      for (final part in read.parts)
        for (final entry in part) entry.key,
    };
    final dropped = answer.entries.length - held.length;
    final reason = read.reject!;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            read.parts.isEmpty
                ? reason
                : '整体不能并成一片：$reason\n'
                      '确认后将排入 ${read.parts.length} 个合成任务'
                      '${dropped > 0 ? '；另有 $dropped 集落单，不必合成，在离线列表里连续播放即可' : ''}。',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          if (!_compatible && !_appending && manager.transcoderAvailable) ...[
            const SizedBox(height: 4),
            Text(
              '编码参数的差异无损合不成，但重编码可以：兼容合成按最高的码率与帧率'
              '重新编码，不缩放画面，代价是耗时和暂停后从头重编。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('merge-mode-escape'),
                onPressed: busy ? null : () => _setMode('compatible'),
                icon: const Icon(Icons.autorenew, size: 16),
                label: const Text('改用兼容合成'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _pill(String text, {required bool good}) {
    final theme = Theme.of(context);
    final color = good ? theme.colorScheme.primary : theme.colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: .5)),
      ),
      child: Text(text, style: TextStyle(fontSize: 12, color: color)),
    );
  }

  Widget _diskCard(
    BuildContext context,
    MergePrecheckReport answer,
    _MergeReading read,
  ) {
    final theme = Theme.of(context);
    // What a merge would actually read: every ready 片, not the episodes the
    // writer left out. With nothing accepted the number stays the picked total,
    // because the refusal is about the set as a whole.
    final parts = read.parts.length;
    if (_compatible) {
      // A re-encode writes a file of its own, sized by the rates promised to the
      // encoder rather than by the sources it read. The sources still get said:
      // they are what the viewer has on disk, and what the encode costs time on.
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '产物预检${parts > 1 ? ' · $parts 片' : ''}',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.tertiary,
                  ),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    '约 ${mergeBytesLabel(read.productBytes ?? 0)}',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '按目标码率 × 时长估算，实际以编码器写出的为准；'
              '源文件合计 ${mergeBytesLabel(answer.sourceBytes)}。',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      );
    }
    final sources = parts > 0 ? answer.batchedBytes : answer.sourceBytes;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Text(
            '磁盘预检${parts > 1 ? ' · $parts 片' : ''}',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.tertiary,
            ),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              'Σ源 ${mergeBytesLabel(sources)} + 5% ≈ '
              '${mergeBytesLabel((sources * 1.05).round())}',
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _targetSegment(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _segmentButton(
            'merge-target-new',
            '新建合并资源',
            on: !_appending,
            onTap: () => _setTarget(null),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _segmentButton(
            'merge-target-append',
            '追加到已有',
            on: _appending,
            enabled: targets.isNotEmpty,
            onTap: () => _setTarget(appendTarget ?? targets.first.mergeId),
          ),
        ),
      ],
    );
  }

  Widget _targetPicker(BuildContext context) {
    if (targets.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          '还没有可追加的合并资源，请先新建一次合成。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    final id = appendTarget;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DropdownButton<String>(
        key: const ValueKey('merge-target-select'),
        isExpanded: true,
        value: targets.any((video) => video.mergeId == id)
            ? id
            : targets.first.mergeId,
        items: [
          for (final video in targets)
            DropdownMenuItem(
              value: video.mergeId,
              child: Text(
                '${video.title}（${video.items.length} 集 · '
                '${mergeBytesLabel(video.bytes)}）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: busy ? null : _setTarget,
      ),
    );
  }

  Widget _titleField(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
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
  );
}
