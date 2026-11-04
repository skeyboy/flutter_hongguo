import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_core/hongguo_native.dart';

/// One episode the merge reads, addressed by the file the media lane published.
class MergeInput {
  final String path, vid, quality;
  const MergeInput({
    required this.path,
    required this.vid,
    required this.quality,
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    'vid': vid,
    'quality': quality,
  };

  factory MergeInput.fromJson(Map<Object?, Object?> json) => MergeInput(
    path: json['path'] as String,
    vid: json['vid'] as String,
    quality: json['quality'] as String,
  );
}

/// A unit of merge work, in a shape that crosses an isolate boundary.
///
/// `new` writes [partPath] from scratch and renames it over [publishPath].
/// `append` grows whatever already sits at [partPath] in place -- media bytes
/// keep their offsets, only the tail metadata is replaced -- and republishes
/// only when the two paths differ. `copy` moves [copyFrom] to [publishPath]
/// through a part file, which is how a delivery to a user directory never
/// leaves a half-written target.
class MergeRequest {
  final String jobId, action, partPath, publishPath, journalPath;
  final List<MergeInput> inputs;
  final String? copyFrom;
  const MergeRequest({
    required this.jobId,
    required this.action,
    required this.partPath,
    required this.publishPath,
    required this.journalPath,
    this.inputs = const [],
    this.copyFrom,
  });

  Map<String, dynamic> toJson() => {
    'jobId': jobId,
    'action': action,
    'partPath': partPath,
    'publishPath': publishPath,
    'journalPath': journalPath,
    'inputs': inputs.map((i) => i.toJson()).toList(),
    'copyFrom': copyFrom,
  };

  factory MergeRequest.fromJson(Map<Object?, Object?> json) => MergeRequest(
    jobId: json['jobId'] as String,
    action: json['action'] as String,
    partPath: json['partPath'] as String,
    publishPath: json['publishPath'] as String,
    journalPath: json['journalPath'] as String,
    inputs: [
      for (final item in (json['inputs'] as List? ?? const []))
        MergeInput.fromJson(Map<Object?, Object?>.from(item as Map)),
    ],
    copyFrom: json['copyFrom'] as String?,
  );
}

/// What a finished job reports back across the isolate boundary.
class MergeOutcome {
  final int bytes, totalDurationMs, resumedBytes;

  /// One entry per [MergeRequest.inputs], in the same order, so the manifest
  /// can state each episode's length and where it starts.
  final List<int> durations;
  final String? codec;
  final int width, height;
  const MergeOutcome({
    required this.bytes,
    required this.totalDurationMs,
    required this.durations,
    required this.resumedBytes,
    this.codec,
    this.width = 0,
    this.height = 0,
  });

  Map<String, dynamic> toJson() => {
    'bytes': bytes,
    'totalDurationMs': totalDurationMs,
    'durations': durations,
    'resumedBytes': resumedBytes,
    'codec': codec,
    'width': width,
    'height': height,
  };

  factory MergeOutcome.fromJson(Map<Object?, Object?> json) => MergeOutcome(
    bytes: json['bytes'] as int,
    totalDurationMs: json['totalDurationMs'] as int,
    durations: [
      for (final value in (json['durations'] as List? ?? const []))
        value as int,
    ],
    resumedBytes: json['resumedBytes'] as int? ?? 0,
    codec: json['codec'] as String?,
    width: json['width'] as int? ?? 0,
    height: json['height'] as int? ?? 0,
  );
}

/// The reason a job stopped, in a form the UI can show verbatim.
class MergeFailure implements Exception {
  final String type, message;
  const MergeFailure(this.type, this.message);
  @override
  String toString() => '$type: $message';
}

/// A merge checkpoint: how far a write is trusted, and what to put back if the
/// job is abandoned before it can publish.
class MergeJournal {
  final String action, partPath, publishPath, tailPath;
  final int committed, workBytes, cutAt;
  const MergeJournal({
    required this.action,
    required this.partPath,
    required this.publishPath,
    required this.workBytes,
    this.committed = 0,
    this.tailPath = '',
    this.cutAt = 0,
  });

  Map<String, dynamic> toJson() => {
    'version': 1,
    'action': action,
    'partPath': partPath,
    'publishPath': publishPath,
    'committed': committed,
    'workBytes': workBytes,
    'tailPath': tailPath,
    'cutAt': cutAt,
  };

  MergeJournal withCommit(int done) => MergeJournal(
    action: action,
    partPath: partPath,
    publishPath: publishPath,
    workBytes: workBytes,
    committed: done,
    tailPath: tailPath,
    cutAt: cutAt,
  );

  /// null when nothing was ever checkpointed, or the file no longer parses.
  static MergeJournal? load(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      final json = Map<Object?, Object?>.from(
        jsonDecode(file.readAsStringSync()) as Map,
      );
      return MergeJournal(
        action: json['action'] as String,
        partPath: json['partPath'] as String,
        publishPath: json['publishPath'] as String,
        workBytes: json['workBytes'] as int? ?? 0,
        committed: json['committed'] as int? ?? 0,
        tailPath: json['tailPath'] as String? ?? '',
        cutAt: json['cutAt'] as int? ?? 0,
      );
    } on FormatException {
      return null;
    }
  }

  void save(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(toJson()), flush: true);
  }
}

/// Runs a [MergeRequest] and returns its outcome. Callable inside a worker
/// isolate or directly in a test -- nothing here needs the engine.
///
/// A killed run continues from its journal while the checkpoint still describes
/// this exact plan; otherwise the part is re-cut and the work redone. A failure
/// never leaves a file that looks published.
Future<MergeOutcome> executeMerge(
  MergeRequest request, {
  void Function(int done, int total)? onProgress,
}) async {
  if (request.action == 'copy') return _executeCopy(request, onProgress);
  if (request.action != 'new' && !await File(request.partPath).exists()) {
    throw MergeFailure('MissingFile', '待合成的文件已不存在：${request.partPath}');
  }
  Directory(File(request.partPath).parent.path).createSync(recursive: true);
  final handles = <RandomAccessFile>[];
  RandomAccessFile open(String path, {bool readOnly = true}) {
    if (readOnly && !File(path).existsSync()) {
      throw MergeFailure('MissingFile', '源文件已不存在：$path');
    }
    final file = path == request.partPath && !readOnly
        ? File(path).openSync(mode: FileMode.append)
        : File(path).openSync(mode: FileMode.read);
    handles.add(file);
    return file;
  }

  try {
    // Reading an episode parses only its sample tables, but a plan is worth
    // nothing unless every input still matches the file it came from.
    final added = [
      for (final input in request.inputs)
        Mp4Merger.read(FileSampleStore(open(input.path))),
    ];
    final durations = [for (final source in added) source.durationMs];
    final video = _videoTrack(added.isEmpty ? null : added.first);
    final MergePlan plan;
    final RandomAccessFile target;
    if (request.action == 'new') {
      plan = Mp4Merger.plan(added);
      target = open(request.partPath, readOnly: false);
    } else if (request.action == 'append') {
      plan = Mp4Merger.appendPlan(
        Mp4Merger.read(FileSampleStore(open(request.partPath))),
        added,
      );
      target = open(request.partPath, readOnly: false);
    } else {
      throw MergeFailure('BadJob', '未知的合成动作：${request.action}');
    }

    var stored = MergeJournal.load(request.journalPath);
    if (stored != null &&
        (stored.action != request.action ||
            stored.partPath != request.partPath ||
            stored.workBytes != plan.copyBytes)) {
      // The checkpoint describes different work: put the product back the way it
      // was before this job cut it, then plan again from scratch.
      await _restoreTail(stored, target);
      await _clear(request.journalPath, stored.tailPath);
      stored = null;
    }
    // The header (or, for an append, the media already in place) is what the
    // journal counts bytes beyond, and the kernel rounds the resume to a whole
    // copy so a partially written chunk cannot be trusted.
    final written = await target.length() - plan.prefixBytes;
    final resumed = stored == null || written <= 0
        ? 0
        : plan.boundary(
            written < stored.committed ? written : stored.committed,
          );
    final journal =
        stored ??
        MergeJournal(
          action: request.action,
          partPath: request.partPath,
          publishPath: request.publishPath,
          workBytes: plan.copyBytes,
          tailPath:
              request.action == 'append' &&
                  request.partPath == request.publishPath
              ? '${request.journalPath}.tail'
              : '',
          cutAt: plan.appendAt ?? 0,
        );
    if (journal.tailPath.isNotEmpty) {
      await _backupTail(target, plan, journal.tailPath);
    }
    journal.withCommit(resumed).save(request.journalPath);

    var lastCommit = resumed;
    void report(int done, int total) {
      onProgress?.call(done, total);
      // At most every 8 MB, and often enough that even a short merge is
      // checkpointed more than once. What a kill loses has to be re-read, and
      // re-reading a whole episode is what this file exists to avoid.
      final step = (total / 6)
          .toDouble()
          .clamp(8 * 1024.0, 8 * 1024 * 1024.0)
          .round();
      if (done == total || done - lastCommit >= step) {
        lastCommit = done;
        journal.withCommit(done).save(request.journalPath);
      }
    }

    if (request.action == 'new') {
      // A fresh part starts at zero, because the kernel writes the header
      // itself; a resumed one is re-cut to the trusted boundary so nothing a
      // killed write left beyond it can survive into the product.
      final start = resumed == 0 ? 0 : plan.prefixBytes + resumed;
      await target.truncate(start);
      await target.setPosition(start);
      Mp4Merger.write(
        plan,
        FileMergeSink(target),
        onProgress: report,
        resumed: resumed,
      );
    } else {
      Mp4Merger.append(plan, target, onProgress: report, resumed: resumed);
    }
    await target.flush();
    await target.close();
    handles.remove(target);

    final published = await _publish(request, plan);
    final bytes = await published.length();
    await _clear(request.journalPath, journal.tailPath);
    return MergeOutcome(
      bytes: bytes,
      totalDurationMs: plan.durationMs,
      durations: durations,
      resumedBytes: resumed,
      codec: video?.codec,
      width: video?.width ?? 0,
      height: video?.height ?? 0,
    );
  } on MergeReject catch (e) {
    throw MergeFailure('MergeReject', e.reason);
  } on FormatException catch (e) {
    throw MergeFailure('BadFile', '文件不符合预期：${e.message}');
  } finally {
    for (final file in handles) {
      try {
        file.closeSync();
      } on FileSystemException {
        // Already closed on the way out, or the file was removed under us.
      }
    }
  }
}

/// Throws away an abandoned job. An append that had cut its own metadata gets it
/// back, so the product the viewer could already play is left exactly as it was;
/// every other case is a scratch file beside the destination, and it is deleted.
Future<void> abandonMerge(MergeRequest request) async {
  final journal = MergeJournal.load(request.journalPath);
  final part = File(request.partPath);
  if (journal != null && journal.tailPath.isNotEmpty) {
    if (await part.exists()) {
      final handle = part.openSync(mode: FileMode.append);
      try {
        await _restoreTail(journal, handle);
      } finally {
        handle.closeSync();
      }
    }
  } else if (await part.exists()) {
    await part.delete();
  }
  await _clear(request.journalPath, journal?.tailPath);
}

/// Puts the metadata an in-place append cut off back on the end of the file, so
/// cancelling a job restores the product the viewer could already play.
Future<void> _restoreTail(
  MergeJournal journal,
  RandomAccessFile product,
) async {
  final tail = File(journal.tailPath);
  if (journal.tailPath.isEmpty || !await tail.exists()) return;
  await product.truncate(journal.cutAt);
  await product.setPosition(journal.cutAt);
  final bytes = await tail.readAsBytes();
  if (bytes.isNotEmpty) await product.writeFrom(bytes);
  await product.flush();
}

MergeTrack? _videoTrack(MergeSource? source) {
  if (source == null) return null;
  for (final track in source.tracks) {
    if (track.handler == 'vide') return track;
  }
  return null;
}

/// The metadata an append is about to cut, kept aside so cancelling the job can
/// put the earlier product back.
Future<void> _backupTail(
  RandomAccessFile product,
  MergePlan plan,
  String tailPath,
) async {
  final cut = plan.appendAt!;
  final length = await product.length();
  if (length <= cut) return;
  final file = File(tailPath);
  if (await file.exists()) return;
  final tail = Uint8List(length - cut);
  await product.setPosition(cut);
  var read = 0;
  while (read < tail.length) {
    final n = await product.readInto(tail, read, tail.length);
    if (n == 0) break;
    read += n;
  }
  await file.writeAsBytes(Uint8List.view(tail.buffer, 0, read), flush: true);
}

Future<File> _publish(MergeRequest request, MergePlan plan) async {
  final part = File(request.partPath), target = File(request.publishPath);
  // Read back before anything is renamed or trusted: tables that do not parse,
  // or a duration that is not the sum of the episodes, must not become a product.
  final handle = part.openSync(mode: FileMode.read);
  try {
    final checked = Mp4Merger.read(FileSampleStore(handle));
    if ((checked.durationMs - plan.durationMs).abs() > 2) {
      throw const MergeFailure('BadFile', '合成结果的时长与预期不符');
    }
  } finally {
    handle.closeSync();
  }
  if (await part.length() != plan.outputBytes) {
    throw const MergeFailure('BadFile', '合成结果的大小与预期不符');
  }
  if (part.path == target.path) return target;
  // Windows refuses a rename over an existing file, so the old copy goes first.
  if (await target.exists()) await target.delete();
  await part.rename(target.path);
  return target;
}

Future<void> _clear(String journalPath, String? tailPath) async {
  for (final path in [
    journalPath,
    if (tailPath != null && tailPath.isNotEmpty) tailPath,
  ]) {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}

Future<MergeOutcome> _executeCopy(
  MergeRequest request,
  void Function(int done, int total)? onProgress,
) async {
  final source = File(request.copyFrom ?? '');
  if (!await source.exists()) {
    throw MergeFailure('MissingFile', '源文件已不存在：${source.path}');
  }
  final total = await source.length();
  final part = File(request.partPath);
  // A part file that is shorter than the source is a copy this job abandoned:
  // appending to it continues the delivery, which is the whole point of writing
  // to a part in the target directory.
  var done = await part.exists() ? await part.length() : 0;
  if (done > total) {
    await part.delete();
    done = 0;
  }
  final skipped = done;
  final from = await source.open(mode: FileMode.read);
  final to = await part.open(mode: FileMode.append);
  try {
    await from.setPosition(done);
    final buffer = Uint8List(4 * 1024 * 1024);
    while (done < total) {
      final read = await from.readInto(buffer);
      if (read == 0) {
        throw const MergeFailure('BadFile', '源文件在导出期间被改动');
      }
      await to.writeFrom(buffer, 0, read);
      done += read;
      onProgress?.call(done, total);
    }
    await to.flush();
  } finally {
    await from.close();
    await to.close();
  }
  if (request.partPath != request.publishPath) {
    final target = File(request.publishPath);
    if (await target.exists()) await target.delete();
    await part.rename(request.publishPath);
  }
  final journal = File(request.journalPath);
  if (await journal.exists()) await journal.delete();
  return MergeOutcome(
    bytes: total,
    totalDurationMs: 0,
    durations: const [],
    resumedBytes: skipped,
  );
}

/// Runs [executeMerge] off the UI isolate and forwards its progress, which is
/// what lets 合成 keep running while the viewer is on another page.
class MergeWorker {
  static Future<MergeOutcome> run(
    MergeRequest request, {
    void Function(int done, int total)? onProgress,
  }) => start(request, onProgress: onProgress).result;

  /// The job, and the way to stop it.
  ///
  /// [MergeHandle.stop] kills the worker where it stands: the part file and its
  /// journal stay, so the next run of the same job continues from the last
  /// checkpoint instead of re-reading what it already wrote.
  static MergeHandle start(
    MergeRequest request, {
    void Function(int done, int total)? onProgress,
  }) {
    final events = ReceivePort();
    final result = Completer<MergeOutcome>();
    var settled = false, stopped = false;
    Isolate? isolate;
    void finish(FutureOr<void> Function() action) {
      if (settled) return;
      settled = true;
      unawaited(Future(action).catchError((Object _) {}));
    }

    events.listen((message) {
      if (message is! Map) {
        // An exit or an uncaught error. A stopped job is expected to exit this
        // way; the caller already knows, and its future is not the answer.
        finish(
          () => result.completeError(
            const MergeFailure('WorkerStopped', '合成进程已停止，请重试'),
          ),
        );
        return;
      }
      switch (message['event'] as String?) {
        case 'progress':
          onProgress?.call(message['done'] as int, message['total'] as int);
        case 'done':
          finish(
            () => result.complete(
              MergeOutcome.fromJson(
                Map<Object?, Object?>.from(message['value'] as Map),
              ),
            ),
          );
        default:
          finish(
            () => result.completeError(
              MergeFailure(
                message['type'] as String? ?? 'MergeFailed',
                message['message'] as String? ?? '合成未完成',
              ),
            ),
          );
      }
    });
    final started = Isolate.spawn(
      _mergeEntry,
      [events.sendPort, request.toJson()] as List<Object?>,
      onError: events.sendPort,
      onExit: events.sendPort,
      errorsAreFatal: false,
    );
    unawaited(
      started.then((value) {
        isolate = value;
        if (stopped) value.kill(priority: Isolate.beforeNextEvent);
      }),
    );
    return MergeHandle(
      result: result.future.whenComplete(() {
        events.close();
        isolate?.kill(priority: Isolate.immediate);
      }),
      stop: () {
        stopped = true;
        isolate?.kill(priority: Isolate.beforeNextEvent);
      },
    );
  }

  static void _mergeEntry(List<Object?> message) {
    final port = message[0] as SendPort;
    final request = MergeRequest.fromJson(
      Map<Object?, Object?>.from(message[1] as Map),
    );
    unawaited(
      executeMerge(
        request,
        onProgress: (done, total) {
          port.send({'event': 'progress', 'done': done, 'total': total});
        },
      ).then<void>(
        (outcome) => port.send({'event': 'done', 'value': outcome.toJson()}),
        onError: (Object error) => port.send({
          'event': 'error',
          'type': error is MergeFailure ? error.type : 'MergeFailed',
          'message': error is MergeFailure ? error.message : '$error',
        }),
      ),
    );
  }
}

/// A running job: await [result], or [stop] it and let the journal keep its
/// place for the next run.
class MergeHandle {
  final Future<MergeOutcome> result;
  final void Function() stop;
  const MergeHandle({required this.result, required this.stop});
}
