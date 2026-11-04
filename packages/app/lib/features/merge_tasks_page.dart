import 'package:flutter/material.dart';
import 'package:hongguo_tv/hongguo_tv.dart' show TvEnvironment, TvFocusable;

import '../merge/merge_manager.dart';
import '../navigation/app_navigation.dart';
import '../platform/runtime.dart';
import 'merged_page.dart';

/// The merge queue as the viewer sees it: every job that ran, runs or waits,
/// with the controls its current phase answers to.
class MergeTasksPage extends StatefulWidget {
  final AppRuntime runtime;
  const MergeTasksPage({super.key, required this.runtime});

  @override
  State<MergeTasksPage> createState() => _MergeTasksPageState();
}

class _MergeTasksPageState extends State<MergeTasksPage> {
  MergeManager? _queue;
  bool loading = true, busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    // 队列只在有下载文件的运行时里存在；没有它的设备连入口都藏起来了。
    final runtime = widget.runtime;
    if (runtime is MergeRuntime) {
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
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final manager = _queue;
    if (manager == null) {
      if (mounted) setState(() => loading = false);
      return;
    }
    try {
      await manager.reconcile();
      if (mounted) {
        setState(() {
          loading = false;
          error = null;
        });
      }
    } catch (_) {
      // A queue that cannot be re-read keeps the cards it already has: the line
      // below says what is unknown, and 重试 stays reachable.
      if (mounted) {
        setState(() {
          loading = false;
          error = '合成记录读取失败，请重试';
        });
      }
    }
  }

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _newMerge() => showMergePicker(context, widget.runtime);

  /// One control for a queue a restart or an interrupted background left in
  /// pieces, exactly as the download shelf's 继续全部 works.
  Future<void> _resumeAll() async {
    final manager = _queue;
    if (manager == null || busy) return;
    setState(() => busy = true);
    try {
      final count = manager.resumeAll();
      _notice(count == 0 ? '没有需要继续的合成' : '已重新排队 $count 个任务');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _forget(MergeTask task) async {
    final manager = _queue;
    if (manager == null || busy) return;
    setState(() => busy = true);
    try {
      await manager.forget(task.id);
    } catch (_) {
      _notice('移除记录未完成，请重试');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _openMerge(MergeTask task) async {
    await pushAppPage<void>(
      context,
      AppScreen.merged,
      (_) => MergedPage(runtime: widget.runtime, mergeId: task.mergeId),
    );
  }

  bool _inFlight(MergePhase phase) =>
      phase == MergePhase.queued || phase == MergePhase.running;

  bool _resumable(MergePhase phase) =>
      phase == MergePhase.paused || phase == MergePhase.failed;

  bool _showsProgress(MergeTask task) =>
      _inFlight(task.phase) && task.fraction != null;

  String _messageLine(MergeTask task) {
    final percent = task.phase == MergePhase.running && task.fraction != null
        ? ' · ${(task.fraction! * 100).floor()}%'
        : '';
    return '${task.message}$percent';
  }

  /// The job's own controls, in the order the viewer should meet them. Removing a
  /// record is never the only choice a phase offers: an unfinished job keeps its
  /// 取消 until it has one.
  List<_TaskAction> _actions(MergeTask task, MergeManager manager) => [
    if (_inFlight(task.phase))
      _TaskAction('pause', '暂停合成', Icons.pause, () => manager.pause(task.id)),
    if (_resumable(task.phase))
      _TaskAction(
        'resume',
        '继续合成',
        Icons.play_arrow,
        () => manager.resume(task.id),
      ),
    if (_inFlight(task.phase) || _resumable(task.phase))
      _TaskAction('cancel', '取消合成', Icons.close, () => manager.cancel(task.id)),
    if (task.phase == MergePhase.done ||
        task.phase == MergePhase.failed ||
        task.phase == MergePhase.cancelled)
      _TaskAction('forget', '从列表移除', Icons.delete_outline, () => _forget(task)),
  ];

  /// The remote's tail targets: the product joins the job's own controls, because
  /// a card has no gesture left that opens it -- 打开 is a target like the rest.
  List<_TaskAction> _tail(MergeTask task, MergeManager manager) => [
    if (!task.isExport)
      _TaskAction(
        'open',
        '打开合并资源',
        Icons.folder_outlined,
        () => _openMerge(task),
      ),
    ..._actions(task, manager),
  ];

  /// Where the job's bytes land: an export names the file it writes, a merge
  /// points at the resource the viewer can play or deliver.
  Widget _target(MergeTask task) {
    final path = task.exportPath;
    if (path != null) {
      return Text(
        path,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return TextButton.icon(
      key: ValueKey('merge-open-${task.id}'),
      onPressed: () => _openMerge(task),
      icon: const Icon(Icons.folder_outlined, size: 18),
      label: const Text('合并资源'),
    );
  }

  Widget _progress(MergeTask task) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: LinearProgressIndicator(
      value: task.fraction?.clamp(0, 1),
      minHeight: 2,
    ),
  );

  Widget _touchTask(MergeTask task, MergeManager manager) => Card(
    elevation: 0,
    margin: const EdgeInsets.symmetric(vertical: 4),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_kindIcon(task), size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_kindLabel(task)} · ${task.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _messageLine(task),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (_showsProgress(task)) _progress(task),
                  ],
                ),
              ),
              for (final action in _actions(task, manager))
                IconButton(
                  key: ValueKey('merge-${action.name}-${task.id}'),
                  tooltip: action.label,
                  onPressed: busy ? null : action.action,
                  icon: Icon(action.icon),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 12, 0),
            child: _target(task),
          ),
        ],
      ),
    ),
  );

  Widget _tvTask(MergeTask task, MergeManager manager) {
    final actions = _tail(task, manager);
    if (actions.isEmpty) return const SizedBox.shrink();
    final first = actions.first;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TvFocusable(
              key: ValueKey('merge-${first.name}-${task.id}'),
              label: '${task.title} ${first.label}',
              onActivate: busy ? null : first.action,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Icon(first.icon, size: 26),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${_kindLabel(task)} · ${task.title}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 22),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _messageLine(task),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 17),
                          ),
                          if (task.exportPath != null)
                            Text(
                              task.exportPath!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 16),
                            ),
                          if (_showsProgress(task)) _progress(task),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          for (final action in actions.skip(1))
            TvFocusable(
              key: ValueKey('merge-${action.name}-${task.id}'),
              label: '${task.title} ${action.label}',
              onActivate: busy ? null : action.action,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                child: Icon(action.icon, size: 26),
              ),
            ),
        ],
      ),
    );
  }

  Widget _task(MergeTask task, MergeManager manager, {required bool tv}) =>
      tv ? _tvTask(task, manager) : _touchTask(task, manager);

  @override
  Widget build(BuildContext context) {
    // The flag comes from `build`, because `TvEnvironment.of` registers a
    // dependency and an async callback cannot ask again after an await.
    final tv = TvEnvironment.of(context);
    final manager = _queue;
    if (manager == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('合成任务')),
        body: const Center(
          child: Text('此设备暂不支持合成', textAlign: TextAlign.center),
        ),
      );
    }
    final tasks = manager.tasks;
    final errorColor = Theme.of(context).colorScheme.error;
    final hints = [
      if (manager.pendingCount > 0 && manager.mobile) '退到后台会暂停，回前台继续',
      if (manager.television) 'TV 仅在前台合成',
    ];
    final notice = [...hints, ?manager.warning, ?error];
    return Scaffold(
      appBar: AppBar(
        title: const Text('合成任务'),
        // On TV the remote's Back key pops this route, exactly as it does on the
        // download shelf; an arrow the ring cannot reach is decoration.
        automaticallyImplyLeading: !tv,
        actions: [
          if (tv)
            TvFocusable(
              key: const ValueKey('merge-new-tv'),
              label: '新建合成',
              onActivate: busy ? null : _newMerge,
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
              key: const ValueKey('merge-new'),
              tooltip: '新建合成',
              onPressed: busy ? null : _newMerge,
              icon: const Icon(Icons.merge_type),
            ),
          if (tv)
            TvFocusable(
              label: '刷新合成任务',
              onActivate: busy ? null : _load,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text('刷新', style: TextStyle(fontSize: 18)),
              ),
            )
          else
            IconButton(
              tooltip: '刷新合成任务',
              onPressed: busy ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: Column(
                  children: [
                    if (notice.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          tv ? 32 : 16,
                          12,
                          tv ? 32 : 16,
                          0,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (hints.isNotEmpty)
                              Text(
                                hints.join(' · '),
                                style: TextStyle(fontSize: tv ? 18 : null),
                              ),
                            if (manager.warning != null)
                              Text(
                                manager.warning!,
                                style: TextStyle(
                                  color: errorColor,
                                  fontSize: tv ? 18 : null,
                                ),
                              ),
                            if (error != null)
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      error!,
                                      style: TextStyle(
                                        color: errorColor,
                                        fontSize: tv ? 18 : null,
                                      ),
                                    ),
                                  ),
                                  if (tv)
                                    TvFocusable(
                                      label: '重试',
                                      autofocus: true,
                                      onActivate: _load,
                                      child: const Padding(
                                        padding: EdgeInsets.all(12),
                                        child: Text(
                                          '重试',
                                          style: TextStyle(fontSize: 20),
                                        ),
                                      ),
                                    )
                                  else
                                    TextButton(
                                      onPressed: _load,
                                      child: const Text('重试'),
                                    ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    if (tasks.any(
                      (task) =>
                          task.phase == MergePhase.paused ||
                          task.phase == MergePhase.failed,
                    ))
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: TextButton.icon(
                          key: const ValueKey('merge-resume-all'),
                          onPressed: busy ? null : _resumeAll,
                          icon: const Icon(Icons.play_circle_outline),
                          label: const Text('全部继续'),
                        ),
                      ),
                    if (busy) const LinearProgressIndicator(minHeight: 2),
                    Expanded(
                      child: tasks.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  '还没有合成任务\n去离线剧集里挑选想合成在一起的集数',
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
                                  for (final task in tasks)
                                    _task(task, manager, tv: tv),
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

String _kindLabel(MergeTask task) => switch (task.kind) {
  'append' => '追加',
  'export' => '导出',
  _ => '合成',
};

IconData _kindIcon(MergeTask task) => switch (task.kind) {
  'append' => Icons.playlist_add,
  'export' => Icons.ios_share,
  _ => Icons.merge_type,
};

/// One control of one task card: named for the key the phase is looked up by, so
/// the touch icon button and the remote's focus target carry the same identity.
class _TaskAction {
  final String name, label;
  final IconData icon;
  final VoidCallback action;
  const _TaskAction(this.name, this.label, this.icon, this.action);
}
