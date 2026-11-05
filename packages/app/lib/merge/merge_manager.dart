import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../settings/settings_store.dart';
import 'merge_transcode.dart';
import 'merge_worker.dart';
import 'merged_library.dart';

enum MergePhase { queued, running, paused, done, failed, cancelled }

/// One episode chosen for a merge, as the queue remembers it.
///
/// Only the identity is stored: the file a merge reads is whatever the media
/// lane has published for this vid and quality when the job actually runs, so a
/// re-download between queuing and running cannot be missed.
class MergeSelection {
  final String vid, quality, title, dramaId;
  final int index;
  const MergeSelection({
    required this.vid,
    required this.quality,
    required this.index,
    this.title = '',
    this.dramaId = '',
  });

  Map<String, dynamic> toJson() => {
    'vid': vid,
    'quality': quality,
    'index': index,
    'title': title,
    'dramaId': dramaId,
  };

  factory MergeSelection.fromJson(Map<String, dynamic> json) => MergeSelection(
    vid: json['vid'] as String,
    quality: json['quality'] as String,
    index: json['index'] as int? ?? 0,
    title: json['title'] as String? ?? '',
    dramaId: json['dramaId'] as String? ?? '',
  );
}

/// A merge, an append, or a delivery, as the persisted queue holds it.
class MergeTask {
  final String id, mergeId, title, kind;
  final List<MergeSelection> items;
  final DateTime createdAt;

  /// `lossless` rewrites only the tables and copies every byte of media;
  /// `compatible` re-encodes the whole selection into one H.264 product, which
  /// is what a phone without the source codec can play. The kind stays the shape
  /// of the work, the mode says how the bytes were made.
  final String mode;

  /// For `append`: the merge this job grows. For `export`: the merge delivered.
  final String? targetMergeId;

  /// Only an export sets these: the destination file, and whether it replaces
  /// (`new`) or grows (`append`) an earlier delivery.
  final String? exportPath, exportMode;
  MergePhase phase;
  String message;
  double? fraction;
  bool automaticPause;
  MergeTask({
    required this.id,
    required this.mergeId,
    required this.title,
    required this.kind,
    required this.items,
    required this.createdAt,
    this.mode = 'lossless',
    this.targetMergeId,
    this.exportPath,
    this.exportMode,
    this.phase = MergePhase.queued,
    this.message = '等待合成',
    this.fraction,
    this.automaticPause = false,
  });

  bool get isExport => kind == 'export';

  /// A compatible job re-encodes, so it has no checkpoint to return to and a
  /// different sentence to say while it runs.
  bool get isCompatible => mode == 'compatible';

  Map<String, dynamic> toJson() => {
    'id': id,
    'mergeId': mergeId,
    'title': title,
    'kind': kind,
    'mode': mode,
    'items': items.map((i) => i.toJson()).toList(),
    'targetMergeId': targetMergeId,
    'exportPath': exportPath,
    'exportMode': exportMode,
    'createdAt': createdAt.toIso8601String(),
    'phase': phase.name,
    'message': message,
    'fraction': fraction,
    'autoResume': automaticPause,
  };

  factory MergeTask.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String;
    if (!const ['merge', 'append', 'export'].contains(kind)) {
      throw const FormatException('Invalid merge kind');
    }
    // A queue written before the compatible lane existed is a lossless queue.
    final mode = json['mode'] as String? ?? 'lossless';
    if (!const ['lossless', 'compatible'].contains(mode)) {
      throw const FormatException('Invalid merge mode');
    }
    return MergeTask(
      id: json['id'] as String,
      mergeId: json['mergeId'] as String,
      title: json['title'] as String? ?? '合并视频',
      kind: kind,
      mode: mode,
      items: [
        for (final item in (json['items'] as List? ?? const []))
          MergeSelection.fromJson(Map<String, dynamic>.from(item as Map)),
      ],
      targetMergeId: json['targetMergeId'] as String?,
      exportPath: json['exportPath'] as String?,
      exportMode: json['exportMode'] as String?,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      phase: MergePhase.values.byName(json['phase'] as String),
      message: json['message'] as String? ?? '',
      fraction: (json['fraction'] as num?)?.toDouble().clamp(0, 1),
      automaticPause: json['autoResume'] == true,
    );
  }
}

class _ActiveMerge {
  final MergeTask task;

  /// Whatever can stop the work in flight: a killed isolate for a lossless job,
  /// a killed process for a compatible one.
  void Function()? stop;
  DateTime? lastProgress, lastCheckpoint;
  _ActiveMerge(this.task);
}

/// How a job is executed: the isolate worker in the app, and anything a test
/// wants to stand in for it.
typedef MergeRunner = MergeHandle Function(
  MergeRequest request, {
  void Function(int done, int total)? onProgress,
});

/// How the precheck is answered: the same worker isolate the jobs run in, and a
/// stand-in for the widget tests, where a real isolate never resumes.
typedef MergeProbeRunner = Future<MergePrecheckReport> Function(
  List<MergeProbeRequest> requests,
  String? productPath,
);

/// The merge queue: one job at a time, out of the UI isolate, yielded to
/// playback, and durable across a restart.
///
/// A task's status never claims a product exists -- the manifest written next to
/// the video is the record, and [reconcile] reads both before the queue shows
/// anything.
class MergeManager extends ChangeNotifier with WidgetsBindingObserver {
  final PreferencesBackend backend;
  final MergedLibrary library;
  final Directory journals;

  /// The published media-cache file for one episode. Existence is checked when
  /// the job runs, not when it is queued.
  final String Function(String vid, String quality) sourcePath;
  final bool mobile, television;
  final MergeRunner run;

  /// The precheck reader, injectable for the same reason [run] is.
  final MergeProbeRunner probe;

  /// The compatible lane's only door to a native FFmpeg. The default is a device
  /// with none, so an app built without a transcoder keeps the behaviour it had:
  /// 无损合成 only, and the panel never offers the other.
  final MergeTranscoder transcoder;
  MergeManager({
    required this.backend,
    required this.library,
    required this.journals,
    required this.sourcePath,
    this.mobile = false,
    this.television = false,
    MergeRunner? run,
    MergeProbeRunner? probe,
    MergeTranscoder? transcoder,
  }) : run =
           run ??
           ((request, {onProgress}) =>
               MergeWorker.start(request, onProgress: onProgress)),
       probe =
           probe ??
           ((requests, productPath) =>
               probeMerge(requests, productPath: productPath)),
       transcoder = transcoder ?? const UnavailableTranscoder();

  final _tasks = <String, MergeTask>{};
  final _active = <_ActiveMerge>{};
  final _abandons = <Future<void>>[];
  Future<void>? _loading;
  Future<void> _writes = Future.value(), _mutations = Future.value();
  bool _loaded = false,
      _closed = false,
      _attached = false,
      _foreground = true,
      _transcoderWarmed = false;
  int _players = 0, _sequence = 0;
  String? warning;

  List<MergeTask> get tasks =>
      List.unmodifiable(_tasks.values.toList().reversed);
  int get pendingCount => _tasks.values
      .where(
        (t) => t.phase == MergePhase.queued || t.phase == MergePhase.running,
      )
      .length;
  int get runningCount => _active.length;

  /// A merge streams the whole product in one pass, so it takes the player's
  /// bandwidth and disk: playback gets the free run and the job keeps its
  /// checkpoint until the viewer is done.
  String? get _blocked {
    if (_players > 0) return '正在播放，等待空闲后继续';
    if (!_foreground && television) return '回到前台后继续';
    return null;
  }

  bool _notificationScheduled = false;
  void _emit() {
    if (_closed || _notificationScheduled) return;
    _notificationScheduled = true;
    scheduleMicrotask(() {
      _notificationScheduled = false;
      if (!_closed) notifyListeners();
    });
  }

  Future<void> load() => _loading ??= _load().catchError((Object e) {
    _loading = null;
    throw e;
  });

  Future<void> _load() async {
    final data = await backend.read();
    if (data != null) {
      if (data['version'] != 1) throw StateError('合成记录版本不受支持');
      final parsed = <String, MergeTask>{};
      for (final json in (data['tasks'] as List? ?? const [])) {
        final task = MergeTask.fromJson(Map<String, dynamic>.from(json as Map));
        if (task.phase == MergePhase.running ||
            task.phase == MergePhase.queued) {
          // The write died with the process; its journal says how much of it the
          // next run gets to keep.
          task.phase = MergePhase.queued;
          task.automaticPause = true;
          task.message = '等待合成';
        } else if (task.phase == MergePhase.paused && task.automaticPause) {
          task.phase = MergePhase.queued;
          task.automaticPause = false;
        } else {
          task.message = switch (task.phase) {
            MergePhase.done => '已完成',
            MergePhase.failed => '上次合成未完成，请重试',
            MergePhase.cancelled => '已取消',
            MergePhase.paused => '已暂停，点击继续',
            _ => '等待合成',
          };
        }
        parsed[task.id] = task;
      }
      _tasks.addAll(parsed);
    }
    _loaded = true;
    _emit();
    if (!_transcoderWarmed) {
      // The panel asks 能不能兼容合成 before the viewer has pressed anything, so
      // the machine is asked once, here, and the card repaints when it answers.
      _transcoderWarmed = true;
      unawaited(transcoder.warmUp().then((_) => _emit()));
    }
  }

  Future<void> _save() {
    if (!_loaded) return Future.error(StateError('合成记录尚未读取，未写入变更'));
    final result = _writes.then((_) async {
      await backend.write({
        'version': 1,
        'tasks': _tasks.values.map((t) => t.toJson()).toList(),
      });
      if (warning != null) {
        warning = null;
        _emit();
      }
    });
    _writes = result.catchError((Object _) {
      warning = '合成记录保存失败，请检查存储空间；未保存的任务可能在重启后丢失';
      _emit();
    });
    return result;
  }

  void _checkpoint() {
    if (!_loaded) return;
    unawaited(_save().catchError((Object _) {}));
  }

  Future<void> flush() => _writes;

  /// Adopts whatever the previous run left: a product that reached disk is
  /// finished work even if its task card never saw the end, so the queue does
  /// not redo a merge the viewer can already play.
  Future<void> reconcile() async {
    await load();
    for (final task in _tasks.values) {
      if (task.phase == MergePhase.running) {
        task.phase = MergePhase.queued;
      }
      if (task.isExport) continue;
      final video = await library.read(task.mergeId);
      if (video != null &&
          task.items.every((i) => video.contains(i.vid, i.quality))) {
        task.phase = MergePhase.done;
        task.fraction = 1;
        task.message = '已合成';
      }
    }
    await _save();
    _emit();
    _pump();
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _mutations.then((_) => action());
    _mutations = result.then<void>((_) {}).catchError((Object _) {});
    return result;
  }

  String _newId(String prefix) =>
      '$prefix${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${(_sequence++).toRadixString(36)}';

  /// Queues a merge of [items]: a new product when [targetMergeId] is null, or
  /// an append that grows an existing one. [mode] chooses the lane -- `lossless`
  /// copies every media byte, `compatible` re-encodes them into one H.264 file.
  /// Returns the job id.
  Future<String> enqueue({
    required List<MergeSelection> items,
    required String title,
    String? targetMergeId,
    String mode = 'lossless',
  }) => _serialized(() => _enqueue(items, title, targetMergeId, mode));

  Future<String> _enqueue(
    List<MergeSelection> items,
    String title,
    String? targetMergeId,
    String mode,
  ) async {
    if (_closed) throw StateError('合成队列已关闭');
    await load();
    if (items.isEmpty) throw StateError('没有要合成的剧集');
    // A product has to hold more than one episode; growing an existing one is
    // the next episode on its own.
    if (targetMergeId == null && items.length < 2) throw StateError('至少选择两集');
    if (items.length > 200) throw StateError('一次最多合成 200 集');
    if (mode == 'compatible') {
      // An append grows a file in place by keeping its media bytes where they
      // are, which is the one thing a re-encode cannot do.
      if (targetMergeId != null) {
        throw StateError('兼容合成只能新建合集，不能追加到已有资源，请整体重新合成');
      }
      if (!transcoderAvailable) {
        // The lane says why in a full sentence -- nothing here repeats it, and
        // 无损 stays the default the panel has already shown.
        throw StateError('无法执行兼容合成：$transcoderLabel');
      }
    }
    for (final item in items) {
      if (!RegExp(r'^\d{1,30}$').hasMatch(item.vid) ||
          !RegExp(r'^(best|auto|\d{3,4}p)$').hasMatch(item.quality)) {
        throw StateError('合成的剧集标识不合法');
      }
    }
    final String mergeId;
    if (targetMergeId == null) {
      mergeId = _newId('m');
    } else {
      final existing = await library.read(targetMergeId);
      if (existing == null) throw StateError('要追加的合并资源已不存在');
      final known = existing.items.map((i) => '${i.vid}_${i.quality}').toSet();
      if (items.any((i) => known.contains('${i.vid}_${i.quality}'))) {
        throw StateError('这些剧集已经在合并资源里了');
      }
      mergeId = targetMergeId;
      title = existing.title;
    }
    final task = MergeTask(
      id: _newId('j'),
      mergeId: mergeId,
      title: title,
      kind: targetMergeId == null ? 'merge' : 'append',
      mode: mode,
      targetMergeId: targetMergeId,
      items: items,
      createdAt: DateTime.now(),
      message: _blocked ?? (mode == 'compatible' ? '等待兼容合成' : '等待合成'),
    );
    _tasks[task.id] = task;
    try {
      await _save();
    } catch (_) {
      _tasks.remove(task.id);
      rethrow;
    }
    _emit();
    _pump();
    return task.id;
  }

  /// Queues a delivery of [mergeId] to [path]. `append` grows a file the viewer
  /// already exported with [appendItems]; `new` writes a fresh one.
  Future<String> enqueueExport({
    required String mergeId,
    required String path,
    String mode = 'new',
    List<MergeSelection> appendItems = const [],
  }) => _serialized(() => _enqueueExport(mergeId, path, mode, appendItems));

  Future<String> _enqueueExport(
    String mergeId,
    String path,
    String mode,
    List<MergeSelection> appendItems,
  ) async {
    if (_closed) throw StateError('合成队列已关闭');
    await load();
    final video = await library.read(mergeId);
    if (video == null) throw StateError('要导出的合并资源已不存在');
    if (!File(path).parent.existsSync()) {
      throw StateError('导出目录不存在，请重新选择');
    }
    if (mode == 'append' && appendItems.isEmpty) {
      throw StateError('没有可追加到导出文件的新剧集');
    }
    final task = MergeTask(
      id: _newId('j'),
      mergeId: mergeId,
      title: '导出 ${video.title}',
      kind: 'export',
      targetMergeId: mergeId,
      exportPath: path,
      exportMode: mode,
      items: mode == 'append' ? appendItems : const [],
      createdAt: DateTime.now(),
      message: '等待导出',
    );
    _tasks[task.id] = task;
    try {
      await _save();
    } catch (_) {
      _tasks.remove(task.id);
      rethrow;
    }
    _emit();
    _pump();
    return task.id;
  }

  void _pump() {
    if (_closed || !_loaded || _blocked != null || _active.isNotEmpty) return;
    final task = _tasks.values
        .where((t) => t.phase == MergePhase.queued)
        .firstOrNull;
    if (task == null) return;
    final active = _ActiveMerge(task);
    _active.add(active);
    task.phase = MergePhase.running;
    task.message = task.isExport ? '正在准备导出' : '正在准备';
    task.fraction = null;
    _emit();
    unawaited(_run(active));
  }

  bool _current(_ActiveMerge a) =>
      !_closed && _active.contains(a) && identical(_tasks[a.task.id], a.task);

  Future<void> _run(_ActiveMerge active) async {
    final task = active.task;
    try {
      await _save();
      if (!_current(active)) return;
      final sources = await _resolve(task);
      if (!_current(active)) return;
      final video = await library.read(
        task.isExport ? task.targetMergeId! : task.mergeId,
      );
      if (!_current(active)) return;
      final outcome = await _perform(active, sources, video);
      if (!_current(active)) return;
      await _finish(task, outcome, video);
    } on MergeFailure catch (e) {
      // The worker's own sentence -- a refused merge says which episode differs,
      // not that an exception type was thrown.
      if (_current(active)) _fail(task, e.message);
    } on TranscodeReject catch (e) {
      // The panel's 画质优先 rule, re-asked at run time: the split it refused to
      // promise is the split this job reports.
      if (_current(active)) _fail(task, e.reason);
    } on TranscodeFailure catch (e) {
      if (_current(active)) _fail(task, e.message);
    } on FileSystemException catch (e) {
      if (_current(active)) {
        _fail(task, '写入失败，请检查剩余空间：${e.osError?.message ?? e.message}');
      }
    } catch (e) {
      if (_current(active)) _fail(task, '合成未完成：$e');
    } finally {
      _active.remove(active);
      _pump();
    }
  }

  /// The published media-cache file behind every chosen episode. A missing one
  /// is the viewer's to fix, so the message names the episode.
  Future<List<MergeInput>> _resolve(MergeTask task) async {
    final out = <MergeInput>[];
    for (final item in task.items) {
      final path = sourcePath(item.vid, item.quality);
      if (!File(path).existsSync()) {
        throw MergeFailure('MissingFile', '第 ${item.index} 集的离线文件已不存在，请重新下载');
      }
      out.add(MergeInput(path: path, vid: item.vid, quality: item.quality));
    }
    return out;
  }

  Future<MergeOutcome> _perform(
    _ActiveMerge active,
    List<MergeInput> sources,
    MergedVideo? video,
  ) async {
    final task = active.task;
    if (task.isExport) {
      final target = task.exportPath!;
      final part = '$target.${task.id}.part';
      // The delivery always writes beside the target and moves in at the end:
      // a failed export leaves the file the viewer already had untouched.
      final copy = await _execute(
        active,
        MergeRequest(
          jobId: task.id,
          action: 'copy',
          partPath: part,
          publishPath: task.exportMode == 'append' ? part : target,
          journalPath: _journalFor(task.id),
          copyFrom: video!.filePath,
        ),
      );
      if (task.exportMode != 'append') return copy;
      return _execute(
        active,
        MergeRequest(
          jobId: '${task.id}-append',
          action: 'append',
          partPath: part,
          publishPath: target,
          journalPath: _journalFor('${task.id}-append'),
          inputs: sources,
        ),
      );
    }
    final product = library.pathFor(task.mergeId);
    if (task.isCompatible) return _transcode(active, task, product);
    final grows = task.kind == 'append' && video != null;
    return _execute(
      active,
      MergeRequest(
        jobId: task.id,
        action: grows ? 'append' : 'new',
        // An append of the product itself is the fast path the design asks for:
        // the media already there keeps its offsets, only the tail is replaced.
        partPath: grows ? product : '$product.${task.id}.part',
        publishPath: product,
        journalPath: _journalFor(task.id),
        inputs: sources,
      ),
    );
  }

  String _journalFor(String jobId) => '${journals.path}/$jobId.json';

  Future<MergeOutcome> _execute(
    _ActiveMerge active,
    MergeRequest request,
  ) async {
    final task = active.task;
    final handle = run(
      request,
      onProgress: (done, total) {
        _report(
          active,
          total <= 0 ? null : (done / total).clamp(0.0, 1.0),
          switch (task.kind) {
            'export' => '正在导出',
            'append' => '正在追加剧集',
            _ => '正在合成',
          },
        );
      },
    );
    active.stop = handle.stop;
    try {
      return await handle.result;
    } finally {
      active.stop = null;
    }
  }

  /// One card repaint per 200 ms and one saved record per second, whichever lane
  /// is moving.
  void _report(_ActiveMerge active, double? fraction, String message) {
    if (!_current(active)) return;
    active.task.fraction = fraction;
    active.task.message = message;
    final now = DateTime.now();
    if (active.lastProgress == null ||
        now.difference(active.lastProgress!).inMilliseconds >= 200) {
      active.lastProgress = now;
      _emit();
    }
    if (active.lastCheckpoint == null ||
        now.difference(active.lastCheckpoint!).inSeconds >= 1) {
      active.lastCheckpoint = now;
      _checkpoint();
    }
  }

  /// The compatible lane: ask the tables what has to be preserved, run one
  /// encode pass into a part file, and publish only a product that reads back as
  /// the H.264 file the mode promised.
  ///
  /// Nothing here resumes. A re-encode cannot pick up mid-stream, so a pause, a
  /// playback hand-off or a killed process starts the job over -- the price 画质优
  /// 先 pays for a file another phone can play, and what the task card says out
  /// loud instead of hiding.
  Future<MergeOutcome> _transcode(
    _ActiveMerge active,
    MergeTask task,
    String product,
  ) async {
    final encoder = transcoder.encoder;
    if (encoder == null || !transcoderAvailable) {
      throw TranscodeFailure('这台设备没有可用的 H.264 编码器：$transcoderLabel');
    }
    // The same tables the panel showed, read again now: an episode re-downloaded
    // between 确认 and 执行 is this lane's to notice, not the panel's.
    final report = await precheck(task.items);
    final plan = planTranscode([
      for (final entry in report.entries)
        transcodeSourceOf(entry, sourcePath(entry.vid, entry.quality)),
    ]);
    final part = '$product.${task.id}.part';
    final handle = transcoder.run(
      ffmpegArgs(plan, encoder: encoder, output: part),
      totalDurationMs: plan.totalDurationMs,
      onProgress: (done, total) => _report(
        active,
        total <= 0 ? null : (done / total).clamp(0.0, 1.0),
        '正在兼容合成',
      ),
    );
    active.stop = handle.stop;
    try {
      await handle.result;
    } finally {
      active.stop = null;
    }
    // Read the encode back through the same table reader the queue trusts: a
    // product that is not the length it promised, or not H.264 at all, never
    // reaches 合并资源 as a finished thing.
    final written = await probe([
      MergeProbeRequest(
        path: part,
        vid: task.items.first.vid,
        quality: task.items.first.quality,
        index: 1,
      ),
    ], null);
    final check = written.entries.firstOrNull;
    if (check == null || check.error != null) {
      throw TranscodeFailure('兼容合成的产物读不回来：${check?.error ?? 'ffmpeg 没有写出文件'}');
    }
    if (!h264Fourcc.contains(check.codec)) {
      throw TranscodeFailure('兼容合成的产物不是 H.264（实际为 ${check.codec}），未发布');
    }
    if ((check.durationMs - plan.totalDurationMs).abs() >
        _durationSlack(plan)) {
      throw const TranscodeFailure('兼容合成的时长与预期不符，请重试');
    }
    final file = File(part);
    final bytes = await file.length();
    if (await File(product).exists()) await File(product).delete();
    await file.rename(product);
    return MergeOutcome(
      bytes: bytes,
      totalDurationMs: check.durationMs,
      durations: [for (final source in plan.sources) source.durationMs],
      resumedBytes: 0,
      codec: check.codec,
      width: check.width,
      height: check.height,
    );
  }

  /// How far a re-encode may land from the sum of its sources. Each segment is
  /// rounded to a frame boundary the encoder chooses, not the one the source
  /// table used, so a few frames per 片 is expected; anything larger is a
  /// truncated or half-written file and must not be trusted.
  int _durationSlack(TranscodePlan plan) {
    final frameMs = plan.fpsMilli <= 0 ? 40 : 1000000 ~/ plan.fpsMilli;
    final slack = frameMs * 2 * plan.sources.length + 500;
    return slack > 1000 ? slack : 1000;
  }

  /// Publishes the record next to the bytes: the composition the viewer reads
  /// back, with each episode's length and where it starts in the product.
  Future<void> _finish(
    MergeTask task,
    MergeOutcome outcome,
    MergedVideo? video,
  ) async {
    if (task.isExport) {
      final delivered = video!;
      await library.recordExport(
        delivered,
        MergedExport(
          path: task.exportPath!,
          mode: task.exportMode ?? 'new',
          at: DateTime.now(),
          bytes: outcome.bytes,
          targetOf: task.exportMode == 'append' ? task.exportPath : null,
        ),
      );
      task.phase = MergePhase.done;
      task.fraction = 1;
      task.message = '已导出到 ${task.exportPath}';
      await _save();
      _emit();
      return;
    }
    final carried = task.kind == 'append' && video != null
        ? video.items
        : const <MergedItem>[];
    final now = DateTime.now();
    var offset = carried.isEmpty
        ? 0
        : carried.last.offsetMs + carried.last.durationMs;
    final added = <MergedItem>[];
    for (var i = 0; i < task.items.length; i++) {
      final item = task.items[i];
      final source = File(sourcePath(item.vid, item.quality));
      final exists = source.existsSync();
      added.add(
        MergedItem(
          vid: item.vid,
          quality: item.quality,
          episodeTitle: item.title.isEmpty ? '第 ${item.index} 集' : item.title,
          dramaId: item.dramaId,
          sourceName: '${item.vid}_${item.quality}.mp4',
          index: item.index,
          sourceSize: exists ? source.lengthSync() : 0,
          sourceModifiedMs: exists
              ? source.lastModifiedSync().millisecondsSinceEpoch
              : 0,
          durationMs: i < outcome.durations.length ? outcome.durations[i] : 0,
          offsetMs: offset,
          addedAt: now,
        ),
      );
      offset += added.last.durationMs;
    }
    await library.write(
      MergedVideo(
        mergeId: task.mergeId,
        title: task.title,
        filePath: library.pathFor(task.mergeId),
        codec: outcome.codec,
        width: outcome.width,
        height: outcome.height,
        bytes: outcome.bytes,
        mode: task.mode,
        createdAt: video?.createdAt ?? now,
        updatedAt: now,
        items: [...carried, ...added],
        exports: video?.exports ?? const [],
      ),
    );
    task.phase = MergePhase.done;
    task.fraction = 1;
    task.message = '已合成 ${carried.length + added.length} 集';
    await _save();
    _emit();
  }

  void _fail(MergeTask task, String reason) {
    task.phase = MergePhase.failed;
    task.message = reason;
    task.fraction = null;
    _checkpoint();
    _emit();
  }

  /// Stops a job where it stands and keeps every byte it wrote: the journal is
  /// what lets 继续 pick up from the last checkpoint instead of re-reading the
  /// episode it was working on. Throwing the work away is [cancel]'s call.
  void _stop(MergeTask task) {
    for (final active in _active.where((a) => a.task == task).toList()) {
      _active.remove(active);
      active.stop?.call();
    }
  }

  /// Everything the queue still owes: an abandoned job restores its product
  /// asynchronously, and a test or a shutdown has to wait for that to be true.
  Future<void> settle() async {
    while (_active.isNotEmpty || _abandons.isNotEmpty) {
      final waits = List<Future<void>>.of(_abandons);
      _abandons.clear();
      await Future.wait(waits);
      if (_active.isNotEmpty) await Future<void>.delayed(Duration.zero);
    }
  }

  /// The requests a task could have been running, so abandoning it finds every
  /// journal and part file it may have left.
  List<MergeRequest> _requestsOf(MergeTask task) {
    if (task.isExport) {
      final part = '${task.exportPath}.${task.id}.part';
      return [
        MergeRequest(
          jobId: task.id,
          action: 'copy',
          partPath: part,
          publishPath: task.exportMode == 'append' ? part : task.exportPath!,
          journalPath: _journalFor(task.id),
        ),
        if (task.exportMode == 'append')
          MergeRequest(
            jobId: '${task.id}-append',
            action: 'append',
            partPath: part,
            publishPath: task.exportPath!,
            journalPath: _journalFor('${task.id}-append'),
          ),
      ];
    }
    final product = library.pathFor(task.mergeId);
    if (task.isCompatible) {
      // The encode owns one file and no journal: abandoning it is throwing the
      // part away, which is what [abandonMerge] does for an action it has never
      // checkpointed.
      return [
        MergeRequest(
          jobId: task.id,
          action: 'transcode',
          partPath: '$product.${task.id}.part',
          publishPath: product,
          journalPath: _journalFor(task.id),
        ),
      ];
    }
    return [
      MergeRequest(
        jobId: task.id,
        action: task.kind == 'append' ? 'append' : 'new',
        partPath: task.kind == 'append' ? product : '$product.${task.id}.part',
        publishPath: product,
        journalPath: _journalFor(task.id),
      ),
    ];
  }

  void pause(String id) {
    final task = _tasks[id];
    if (task == null ||
        ![MergePhase.queued, MergePhase.running].contains(task.phase)) {
      return;
    }
    _stop(task);
    task.phase = MergePhase.paused;
    // A lossless job keeps the bytes it wrote; a re-encode keeps nothing, and the
    // card has to say which of the two the viewer is waiting for.
    task.message = task.isCompatible ? '已暂停，继续时重新从头编码' : '已暂停，继续时从检查点接着写';
    task.automaticPause = false;
    _checkpoint();
    _emit();
    _pump();
  }

  void resume(String id) {
    final task = _tasks[id];
    if (task == null || !_resumable(task)) return;
    task.phase = MergePhase.queued;
    task.message = task.isExport ? '等待导出' : '等待合成';
    task.fraction = null;
    task.automaticPause = false;
    _checkpoint();
    _emit();
    _pump();
  }

  bool _resumable(MergeTask task) => [
    MergePhase.paused,
    MergePhase.failed,
    MergePhase.cancelled,
  ].contains(task.phase);

  /// One control for a queue a restart or a playback interruption left in
  /// pieces: re-queues every task that is not already waiting or done.
  int resumeAll() {
    if (_closed) return 0;
    final targets = _tasks.values.where(_resumable).toList();
    for (final task in targets) {
      task.phase = MergePhase.queued;
      task.message = task.isExport ? '等待导出' : '等待合成';
      task.fraction = null;
      task.automaticPause = false;
    }
    if (targets.isEmpty) return 0;
    _checkpoint();
    _emit();
    _pump();
    return targets.length;
  }

  /// Stops the job and throws its work away, whether it was still running or a
  /// failed attempt left its part file and journal behind.
  void cancel(String id) {
    final task = _tasks[id];
    if (task == null || task.phase == MergePhase.done) return;
    _stop(task);
    for (final request in _requestsOf(task)) {
      _abandons.add(abandonMerge(request).catchError((Object _) {}));
    }
    task.phase = MergePhase.cancelled;
    task.message = '已取消';
    task.automaticPause = false;
    _checkpoint();
    _emit();
    _pump();
  }

  Future<void> forget(String id) => _serialized(() async {
    if (_tasks[id]?.phase == MergePhase.running) cancel(id);
    final old = _tasks.remove(id);
    try {
      await _save();
    } catch (_) {
      if (old != null) _tasks[id] = old;
      rethrow;
    }
    _emit();
  });

  /// Removes a merged resource and its manifest. The downloaded episodes it was
  /// built from stay -- they are the viewer's, not this product's.
  Future<void> remove(String mergeId) => _serialized(() async {
    for (final task
        in _tasks.values
            .where((t) => t.mergeId == mergeId && t.phase == MergePhase.running)
            .toList()) {
      cancel(task.id);
    }
    await library.delete(mergeId);
    for (final task
        in _tasks.values
            .where((t) => !t.isExport && t.mergeId == mergeId)
            .toList()) {
      _tasks.remove(task.id);
    }
    await _save();
    _emit();
  });

  /// Why a queued job is standing still, in the words the task card would use.
  /// The panel hands it to the viewer at enqueue time: 已加入队列 with no reason
  /// reads as a merge that will not start, when it is waiting for the player.
  String? get holdReason => _blocked;

  /// Whether this device can re-encode, and what it would use. The panel shows
  /// the 兼容 mode only when this answers true, and the label travels onto the
  /// task card so the promise can be audited after the fact.
  bool get transcoderAvailable => transcoder.available;
  String get transcoderLabel => transcoder.label;

  /// What the writer would say about these episodes before a single byte is
  /// written: the panel's 预检 step, answered off the UI isolate.
  ///
  /// [targetMergeId] makes it the append question -- can that product grow in
  /// place behind the episodes it already holds.
  Future<MergePrecheckReport> precheck(
    List<MergeSelection> items, {
    String? targetMergeId,
  }) async {
    if (items.isEmpty) {
      return const MergePrecheckReport(entries: [], reject: '至少选择两集');
    }
    String? productPath;
    if (targetMergeId != null) {
      productPath = library.pathFor(targetMergeId);
      if (!File(productPath).existsSync()) {
        return MergePrecheckReport(
          entries: const [],
          reject: '要追加的合并资源已不存在，请整体重新合成',
        );
      }
    }
    return probe([
      for (final item in items)
        MergeProbeRequest(
          path: sourcePath(item.vid, item.quality),
          vid: item.vid,
          quality: item.quality,
          index: item.index,
        ),
    ], productPath);
  }

  /// What a merge of these episodes needs on disk. An estimate, not a
  /// measurement: no cross-platform free-space question can be asked without a
  /// new dependency, so the panel states the size it is about to write and a
  /// full disk reports itself when the write gets there.
  int expectedBytes(List<MergeSelection> items) {
    var total = 0;
    for (final item in items) {
      final file = File(sourcePath(item.vid, item.quality));
      if (file.existsSync()) total += file.lengthSync();
    }
    return (total * 1.05).round();
  }

  void playbackEntered() {
    _players++;
    _applyPolicy();
  }

  void playbackLeft() {
    if (_players > 0) _players--;
    _applyPolicy();
  }

  void _applyPolicy() {
    final blocked = _blocked;
    if (blocked != null) {
      for (final task
          in _tasks.values
              .where(
                (t) =>
                    t.phase == MergePhase.running ||
                    t.phase == MergePhase.queued,
              )
              .toList()) {
        _stop(task);
        task.phase = MergePhase.queued;
        task.automaticPause = true;
        task.message = blocked;
      }
    }
    _checkpoint();
    _emit();
    _pump();
  }

  void setForeground(bool value) {
    _foreground = value;
    _applyPolicy();
  }

  void attachLifecycle() {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      setForeground(false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) setForeground(true);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      setForeground(false);
    }
  }

  Future<void> shutdown() async {
    if (_closed) return;
    _closed = true;
    if (_attached) WidgetsBinding.instance.removeObserver(this);
    // A merge is left where its journal says: the process is ending, but the
    // bytes already written are the next run's starting point.
    for (final active in _active.toList()) {
      _active.remove(active);
      active.stop?.call();
    }
    for (final task in _tasks.values) {
      if (task.phase == MergePhase.running || task.phase == MergePhase.queued) {
        task.phase = MergePhase.paused;
        task.message = '上次合成未完成，点击继续';
        task.automaticPause = !television;
      }
    }
    await _save().catchError((Object _) {});
    await flush();
  }
}
