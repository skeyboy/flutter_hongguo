import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hongguo_tv/hongguo_tv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../features/merge_tasks_page.dart';
import '../navigation/app_navigation.dart';
import '../platform/runtime.dart';
import '../widgets/tv_confirm.dart';
import 'merge_manager.dart' as merge;
import 'merge_selection.dart' show mergeBytesLabel;
import 'merged_library.dart';

Future<void> showMergeExport(
  BuildContext context,
  AppRuntime runtime,
  MergedVideo video,
) async {
  if (runtime is! MergeRuntime) return;
  // 合并不落在 TV：遥控器没有文件管理器语义，设计里 TV 只浏览与播放。
  if (tvBuild) return;
  final size = MediaQuery.sizeOf(context);
  final bool? accepted;
  if (size.width >= 720 && size.height >= 400) {
    accepted = await showDialog<bool>(
      context: context,
      builder: (_) => Dialog(
        child: SizedBox(
          width: 560,
          height: math.min(560, size.height * .82),
          child: MergeExport(runtime: runtime, video: video),
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
          child: MergeExport(runtime: runtime, video: video),
        ),
      ),
    );
  }
  if (accepted == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('已加入导出队列，可在“我的 → 合成任务”查看'),
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

/// One delivery of a merged resource: where the copy goes, and whether it is a
/// fresh file or the tail of a copy the viewer already handed out.
class MergeExport extends StatefulWidget {
  final MergeRuntime runtime;
  final MergedVideo video;
  const MergeExport({super.key, required this.runtime, required this.video});
  @override
  State<MergeExport> createState() => _MergeExportState();
}

class _MergeExportState extends State<MergeExport> {
  late final manager = widget.runtime.merges;
  late final desktop =
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// Past deliveries newest first: the newest is the one an append most likely
  /// wants to grow, so it leads both the list and the default choice.
  late final deliveries = [...widget.video.exports]
    ..sort((a, b) => b.at.compareTo(a.at));
  late String? appendPath = deliveries.firstOrNull?.path;
  String? chosen;
  String mode = 'new';
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    // A delivery can be overtaken by playback or finish while this sheet is
    // still open; the queue is the only thing that knows, so it drives a rebuild.
    manager.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    manager.removeListener(_changed);
    super.dispose();
  }

  String get _summary {
    final video = widget.video;
    final resolution = video.width > 0 && video.height > 0
        ? ' · ${video.width}x${video.height}'
        : '';
    return '${video.title} · ${video.items.length} 集 · '
        '${mergeBytesLabel(video.bytes)}$resolution';
  }

  MergedExport? get _record {
    final path = appendPath;
    return deliveries.where((e) => e.path == path).firstOrNull;
  }

  /// The episodes the chosen delivery has never carried: whatever the manifest
  /// says was merged after that export ran.
  List<merge.MergeSelection> _itemsAfter(DateTime? since) => [
    for (final item in widget.video.items)
      if (since == null || item.addedAt.isAfter(since))
        merge.MergeSelection(
          vid: item.vid,
          quality: item.quality,
          index: item.index,
          title: item.episodeTitle,
          dramaId: item.dramaId,
        ),
  ];

  /// The title is the viewer's own text, so the target name drops what a
  /// filesystem reserves instead of failing on one later.
  String get _fileName {
    final cleaned = widget.video.title
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|\r\n]'), ' ')
        .trim();
    return cleaned.isEmpty ? '合并资源' : cleaned;
  }

  bool get _grows {
    final record = _record;
    return mode == 'append' &&
        record != null &&
        record.present &&
        _itemsAfter(record.at).isNotEmpty;
  }

  bool get _canSubmit {
    if (busy) return false;
    // An append writes to the file it grows; anything else needs a destination.
    if (_grows) return true;
    return desktop ? chosen != null : true;
  }

  Future<void> _pick() async {
    final remembered = settingsFor(widget.runtime).mergeExportDir;
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: '导出合并资源',
      initialDirectory: remembered.isEmpty ? null : remembered,
    );
    if (dir == null || !mounted) return;
    // Widened to the common supertype: `is ConfigurableRuntime` only promotes
    // from a type it can be a subtype of, and MergeRuntime is a sibling.
    final AppRuntime configurable = widget.runtime;
    if (configurable is ConfigurableRuntime &&
        configurable.settings.mergeExportDir != dir) {
      try {
        await configurable.saveSettings(
          configurable.settings.copyWith(mergeExportDir: dir),
        );
      } catch (_) {
        // 记住目录只是省一次点击：记不住也不该挡住这次导出。
      }
    }
    if (!mounted) return;
    setState(() {
      chosen = '${_trim(dir)}${Platform.pathSeparator}$_fileName.mp4';
      error = null;
    });
  }

  static String _trim(String path) => path.endsWith(Platform.pathSeparator)
      ? path.substring(0, path.length - 1)
      : path;

  /// Where this export lands. Desktop names the file inside the chosen
  /// directory and lets the queue write it; mobile has no arbitrary-directory
  /// write, so the copy stays under the app's own documents and the share
  /// sheet is what hands it out.
  Future<String> _destination() async {
    final target = chosen;
    if (desktop) {
      if (target == null) throw StateError('请先选择导出位置');
      return target;
    }
    final documents = await getApplicationDocumentsDirectory();
    final folder = Directory('${documents.path}/merged-exports')
      ..createSync(recursive: true);
    return '${folder.path}${Platform.pathSeparator}$_fileName.mp4';
  }

  /// The share sheet needs bytes it can read now, so mobile waits for its own
  /// delivery instead of handing the system a file the queue has not written.
  /// A job that yields to playback never gets here, and the queue card stays
  /// the way to collect that copy later.
  Future<void> _awaitDelivery(String jobId) async {
    for (var tries = 0; tries < 600; tries++) {
      final task = manager.tasks.where((t) => t.id == jobId).firstOrNull;
      if (task == null) return;
      if (task.phase != merge.MergePhase.queued &&
          task.phase != merge.MergePhase.running) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
    }
  }

  Future<void> _submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final record = _record;
      final pending = record == null
          ? const <merge.MergeSelection>[]
          : _itemsAfter(record.at);
      var grows = false;
      final String path;
      if (mode == 'append' &&
          record != null &&
          record.present &&
          pending.isNotEmpty) {
        grows = true;
        path = record.path;
      } else {
        path = await _destination();
        // An append with nothing left to add would rewrite the same bytes, so
        // the honest form of it is a full re-export over that file.
        if (File(path).existsSync()) {
          final overwrite = await showTvConfirm(
            context,
            title: '导出合并资源',
            body: '目标文件已存在，覆盖？\n$path',
            confirmLabel: '覆盖',
          );
          if (overwrite != true) {
            if (mounted) setState(() => busy = false);
            return;
          }
        }
      }
      final jobId = await manager.enqueueExport(
        mergeId: widget.video.mergeId,
        path: path,
        mode: grows ? 'append' : 'new',
        appendItems: grows ? pending : const [],
      );
      if (!desktop) {
        await _awaitDelivery(jobId);
        if (File(path).existsSync()) {
          try {
            await SharePlus.instance.share(
              ShareParams(files: [XFile(path)], subject: widget.video.title),
            );
          } catch (_) {
            // 分享面板被拒绝或被取消，都不该让已经排好的导出看起来失败：
            // 文件已经在应用里，任务卡是它的去处。
          }
        }
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e is StateError ? e.message : '未能加入导出，请重新选择位置后重试';
        });
      }
    }
  }

  String _appendHint() {
    final record = _record;
    if (mode != 'append') return '';
    if (record == null) return '请选择要追加到的历史导出';
    if (!record.present) return '该导出文件已不在原位置，将重新导出完整文件';
    if (_itemsAfter(record.at).isEmpty) return '该导出已包含全部分集，将覆盖重导';
    return '把 ${_itemsAfter(record.at).length} 集新分集接到文件尾部';
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 20, right: 4),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '导出合并资源',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: '关闭导出面板',
              onPressed: busy ? null : () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Text(
          _summary,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      if (desktop)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text('保存位置'),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  chosen ?? '尚未选择位置',
                  key: const ValueKey('merge-export-path'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              TextButton.icon(
                key: const ValueKey('merge-export-pick'),
                onPressed: busy ? null : _pick,
                icon: const Icon(Icons.folder_open),
                label: const Text('选择位置'),
              ),
            ],
          ),
        )
      else
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            '将通过系统分享保存到所选位置，应用内原件保留',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            RadioGroup<String>(
              groupValue: mode,
              onChanged: (v) => setState(() => mode = v ?? 'new'),
              child: Column(
                children: [
                  RadioListTile<String>(
                    key: const ValueKey('merge-export-mode-new'),
                    value: 'new',
                    enabled: !busy,
                    title: const Text('导出为新的合成片段'),
                    subtitle: const Text('在目标位置生成全新文件，不改动既往导出物'),
                  ),
                  RadioListTile<String>(
                    key: const ValueKey('merge-export-mode-append'),
                    value: 'append',
                    enabled: !busy && deliveries.isNotEmpty,
                    title: const Text('在原导出上追加'),
                    subtitle: Text(
                      deliveries.isEmpty ? '尚无历史导出' : '把本次新增分集追加到该文件尾部',
                    ),
                  ),
                  if (mode == 'append' && deliveries.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                      child: DropdownButton<String>(
                        key: const ValueKey('merge-export-target'),
                        isExpanded: true,
                        value: _record?.path,
                        items: [
                          for (final export in deliveries)
                            DropdownMenuItem(
                              value: export.path,
                              child: Text(
                                export.present
                                    ? _labelOf(export)
                                    : '${_labelOf(export)}（已不在原位置）',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: busy
                            ? null
                            : (v) => setState(() {
                                appendPath = v;
                              }),
                      ),
                    ),
                  if (_appendHint().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                      child: Text(
                        _appendHint(),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
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
                    if (manager.pendingCount > 0 && !busy)
                      TextButton(
                        onPressed: () => setState(() => error = null),
                        child: const Text('知道了'),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('confirm-export'),
            onPressed: _canSubmit ? _submit : null,
            icon: const Icon(Icons.ios_share),
            label: Text(
              busy
                  ? '正在加入…'
                  : desktop
                  ? '导出'
                  : '分享并导出',
            ),
          ),
        ),
      ),
    ],
  );

  /// A delivery row the viewer can recognise: the file name and when it went
  /// out, since the directory alone is the same for every re-export.
  String _labelOf(MergedExport export) {
    final at = export.at;
    final name = export.path.split(RegExp(r'[/\\]')).last;
    return '$name · '
        '${at.year}-${_two(at.month)}-${_two(at.day)} '
        '${_two(at.hour)}:${_two(at.minute)}';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}
