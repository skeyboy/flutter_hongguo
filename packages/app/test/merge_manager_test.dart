import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/merge/merge_manager.dart';
import 'package:hongguo_app/merge/merge_transcode.dart';
import 'package:hongguo_app/merge/merge_worker.dart';
import 'package:hongguo_app/merge/merged_library.dart';
import 'package:hongguo_app/settings/settings_store.dart';
import 'package:hongguo_core/hongguo_core.dart';

/// A queue that runs in this isolate, over a temp directory, and can be killed
/// once a write passes a byte mark -- which is what a stopped process looks like
/// to the journal without needing one.
class MemoryBackend implements PreferencesBackend {
  Map<String, dynamic>? data;
  bool fail = false;
  @override
  Future<Map<String, dynamic>?> read() async => data;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    if (fail) throw StateError('disk full');
    data = Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
  }
}

class MergeHarness {
  final Directory temp, cache, merged, journals, exports;
  final MergedLibrary library;
  final MemoryBackend backend;

  /// The compatible lane this queue was built with, kept so a restart can be
  /// handed the same one and a test can read what it was asked to run.
  final MergeTranscoder? transcoder;
  late final MergeManager manager;

  /// Writes past this fraction of the job raise instead of continuing -- which
  /// is what a killed process looks like to the journal, one checkpoint in.
  double killAt = 0;
  final List<int> resumed = <int>[];
  int started = 0;

  MergeHarness._({
    required this.temp,
    required this.cache,
    required this.merged,
    required this.journals,
    required this.exports,
    required this.library,
    required this.backend,
    this.transcoder,
  }) {
    manager = MergeManager(
      backend: backend,
      library: library,
      journals: journals,
      transcoder: transcoder,
      sourcePath: (vid, quality) => '${cache.path}/${vid}_$quality.mp4',
      run: (request, {onProgress}) {
        started++;
        return MergeHandle(
          result:
              executeMerge(
                request,
                onProgress: (done, total) {
                  if (killAt > 0 && done >= total * killAt) {
                    throw const MergeFailure('Killed', '模拟进程中断');
                  }
                  onProgress?.call(done, total);
                },
              ).then((outcome) {
                resumed.add(outcome.resumedBytes);
                return outcome;
              }),
          stop: () {},
        );
      },
    );
  }

  factory MergeHarness({MergeTranscoder? transcoder}) {
    final temp = Directory.systemTemp.createTempSync('hongguo-merge-');
    Directory dir(String name) =>
        Directory('${temp.path}/$name')..createSync(recursive: true);
    final cache = dir('media-cache'), merged = dir('merged');
    return MergeHarness._(
      temp: temp,
      cache: cache,
      merged: merged,
      journals: dir('merge-journal'),
      exports: dir('exports'),
      library: MergedLibrary(merged),
      backend: MemoryBackend(),
      transcoder: transcoder,
    );
  }

  /// A queue that reads the same disk and the same saved records as the one
  /// that stopped: what the app does on the next launch.
  MergeHarness reopen() => MergeHarness._(
    temp: temp,
    cache: cache,
    merged: merged,
    journals: journals,
    exports: exports,
    library: library,
    backend: backend,
    transcoder: transcoder,
  );

  MergeSelection episode(String vid, {int index = 1, Uint8List? bytes}) {
    File('${cache.path}/${vid}_best.mp4').writeAsBytesSync(bytes ?? _fixture());
    return MergeSelection(
      vid: vid,
      quality: 'best',
      index: index,
      title: '第 $index 集',
      dramaId: 'drama-1',
    );
  }

  Future<void> settle() async {
    for (var i = 0; i < 500; i++) {
      await Future<void>.delayed(Duration.zero);
      await manager.settle();
      if (manager.runningCount == 0) return;
    }
    throw StateError('合成队列未在预期时间内停下');
  }

  void dispose() {
    manager.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }
}

Uint8List _fixture() => File('test/fixtures/media/clear.mp4').readAsBytesSync();

/// One episode whose media timeline disagrees with its twin, byte for byte
/// anywhere else. The kernel re-dates it onto one axis, so this is the difference
/// a merge now absorbs instead of refusing.
Uint8List offTimescale() {
  final out = Uint8List.fromList(_fixture());
  final box = Mp4Cenc.inspect(MemorySampleStore(out)).moov.descendants
      .firstWhere((b) => b.type == 'mdhd');
  ByteData.sublistView(out)
      .setUint32(box.payload + (out[box.payload] == 1 ? 20 : 12), 12289);
  return out;
}

/// One episode whose `avcC` says something else than its twin's: the parameter
/// set is part of the sample description, so no re-dating reaches it and the
/// selection has to become two products.
Uint8List offCodec() {
  final out = Uint8List.fromList(_fixture());
  final box = Mp4Cenc.inspect(MemorySampleStore(out)).moov.descendants
      .firstWhere((b) => b.type == 'avcC');
  out[box.end - 1] = out[box.end - 1] + 1;
  return out;
}

MergeSource episodeSource() => Mp4Merger.read(MemorySampleStore(_fixture()));

/// The compatible lane with no FFmpeg on the machine: it obeys the command it is
/// handed by writing a real product at the output that command names, so the
/// queue's read-back check is exercised against a genuine H.264 file rather than
/// a stub. The encode is the lossless kernel here -- a stand-in for ffmpeg, in
/// the same file the tests already build their sources from.
class FakeTranscoder implements MergeTranscoder {
  /// The argument arrays the lane was asked to run, in order.
  final List<List<String>> runs = [];

  /// The promised length each encode was told to report progress against.
  final List<int> totals = [];
  int stops = 0;

  /// Cleared to leave the output unwritten, which is what an encode that died
  /// after a non-zero exit looks like to the queue.
  bool writesProduct = true;

  /// Set to make the encode never finish: the job a viewer cancels.
  Completer<void>? gate;

  @override
  bool get available => true;
  @override
  String? get encoder => 'libx264';
  @override
  String get label => 'ffmpeg · libx264';
  @override
  Future<void> warmUp() async {}
  @override
  void close() {}

  @override
  TranscodeHandle run(
    List<String> args, {
    required int totalDurationMs,
    void Function(int doneMs, int totalMs)? onProgress,
  }) {
    runs.add(args);
    totals.add(totalDurationMs);
    return TranscodeHandle(
      result: _encode(args, totalDurationMs, onProgress),
      stop: () => stops++,
    );
  }

  Future<void> _encode(
    List<String> args,
    int totalMs,
    void Function(int, int)? report,
  ) async {
    final inputs = <String>[];
    for (var at = 0; at < args.length - 1; at++) {
      if (args[at] == '-i') inputs.add(args[at + 1]);
    }
    if (writesProduct) {
      // The part file the command's last argument names, written in place: an
      // encode publishes nothing until its caller renames it.
      final part = args.last;
      await executeMerge(
        MergeRequest(
          jobId: 'fake',
          action: 'new',
          partPath: part,
          publishPath: part,
          journalPath: '$part.journal',
          inputs: [
            for (final (at, path) in inputs.indexed)
              MergeInput(path: path, vid: 'episode$at', quality: 'best'),
          ],
        ),
        onProgress: (done, total) => report?.call(
          // Milliseconds of product, the way ffmpeg reports it -- not bytes.
          totalMs * done ~/ total,
          totalMs,
        ),
      );
    }
    final waiter = gate;
    if (waiter != null) await waiter.future;
    report?.call(totalMs, totalMs);
  }
}

void main() {
  late MergeHarness h;
  setUp(() => h = MergeHarness());
  tearDown(() => h.dispose());

  test(
    'a two-episode merge publishes the product and its composition',
    () async {
      final id = await h.manager.enqueue(
        title: '玫瑰深浅处 1-2 集',
        items: [
          h.episode('7000000000000000001'),
          h.episode('7000000000000000002', index: 2),
        ],
      );
      await h.settle();

      final task = h.manager.tasks.firstWhere((t) => t.id == id);
      expect(task.phase, MergePhase.done, reason: task.message);
      final video = await h.library.read(task.mergeId);
      expect(video, isNotNull);
      expect(video!.title, '玫瑰深浅处 1-2 集');
      expect(video.items.map((i) => i.index), [1, 2]);
      expect(video.items.first.offsetMs, 0);
      expect(video.items.last.offsetMs, video.items.first.durationMs);
      expect(video.durationMs, greaterThan(video.items.first.durationMs));
      expect(video.codec, isNotNull);
      expect(video.bytes, File(video.filePath).lengthSync());

      final episode = episodeSource();
      final product = Mp4Merger.read(
        MemorySampleStore(File(video.filePath).readAsBytesSync()),
      );
      expect(product.tracks.map((t) => t.samples), [
        for (final t in episode.tracks) t.samples * 2,
      ]);
      expect(File(video.filePath).parent.path, h.merged.path);
      expect(h.journals.listSync(), isEmpty);
    },
  );

  test('a merge killed mid-write continues from its journal', () async {
    final items = [
      h.episode('7000000000000000011'),
      h.episode('7000000000000000012', index: 2),
    ];
    final reference = Mp4Merger.plan([episodeSource(), episodeSource()]);
    final sink = MemoryMergeSink();
    Mp4Merger.write(reference, sink);

    h.killAt = .85;
    final id = await h.manager.enqueue(title: '中断后继续', items: items);
    await h.settle();
    var task = h.manager.tasks.firstWhere((t) => t.id == id);
    expect(task.phase, MergePhase.failed);
    expect(File(h.library.pathFor(task.mergeId)).existsSync(), isFalse);
    expect(h.journals.listSync(), isNotEmpty);

    h.killAt = 0;
    h.manager.resume(id);
    await h.settle();
    task = h.manager.tasks.firstWhere((t) => t.id == id);
    expect(task.phase, MergePhase.done, reason: task.message);
    // The second run skipped bytes: that is the journal doing its job.
    expect(h.resumed.last, greaterThan(0));
    expect(
      File(h.library.pathFor(task.mergeId)).readAsBytesSync(),
      sink.takeBytes(),
    );
  });

  test('an append grows the product and the manifest in order', () async {
    final first = await h.manager.enqueue(
      title: '追剧合成',
      items: [
        h.episode('7000000000000000021'),
        h.episode('7000000000000000022', index: 2),
      ],
    );
    await h.settle();
    final mergeId = h.manager.tasks.firstWhere((t) => t.id == first).mergeId;
    final before = File(h.library.pathFor(mergeId)).readAsBytesSync();

    final id = await h.manager.enqueue(
      title: 'ignored',
      items: [h.episode('7000000000000000023', index: 3)],
      targetMergeId: mergeId,
    );
    await h.settle();
    final task = h.manager.tasks.firstWhere((t) => t.id == id);
    expect(task.phase, MergePhase.done, reason: task.message);
    expect(task.title, '追剧合成');

    final video = await h.library.read(mergeId);
    expect(video!.items.map((i) => i.index), [1, 2, 3]);
    expect(video.items.last.offsetMs, greaterThan(video.items[1].offsetMs));
    final product = File(h.library.pathFor(mergeId)).readAsBytesSync();
    expect(product.length, greaterThan(before.length));
    final episode = episodeSource();
    expect(
      Mp4Merger.read(MemorySampleStore(product)).tracks.map((t) => t.samples),
      [for (final t in episode.tracks) t.samples * 3],
    );
  });

  test('cancelling a killed append puts the earlier product back', () async {
    final first = await h.manager.enqueue(
      title: '可撤销的追加',
      items: [
        h.episode('7000000000000000031'),
        h.episode('7000000000000000032', index: 2),
      ],
    );
    await h.settle();
    final mergeId = h.manager.tasks.firstWhere((t) => t.id == first).mergeId;
    final product = File(h.library.pathFor(mergeId));
    final before = product.readAsBytesSync();

    h.killAt = .85;
    final id = await h.manager.enqueue(
      title: 'ignored',
      items: [h.episode('7000000000000000033', index: 3)],
      targetMergeId: mergeId,
    );
    await h.settle();
    expect(
      h.manager.tasks.firstWhere((t) => t.id == id).phase,
      MergePhase.failed,
    );

    h.manager.cancel(id);
    await h.settle();
    expect(product.readAsBytesSync(), before);
    expect(
      h.manager.tasks.firstWhere((t) => t.id == id).phase,
      MergePhase.cancelled,
    );
    final video = await h.library.read(mergeId);
    expect(video!.items.map((i) => i.index), [1, 2]);
    expect(h.journals.listSync(), isEmpty);
  });

  test('an export delivers the product and records it', () async {
    final id = await h.manager.enqueue(
      title: '交付副本',
      items: [
        h.episode('7000000000000000041'),
        h.episode('7000000000000000042', index: 2),
      ],
    );
    await h.settle();
    final mergeId = h.manager.tasks.firstWhere((t) => t.id == id).mergeId;
    final target = '${h.exports.path}/玫瑰 1-2 集.mp4';

    final export = await h.manager.enqueueExport(
      mergeId: mergeId,
      path: target,
    );
    await h.settle();
    final task = h.manager.tasks.firstWhere((t) => t.id == export);
    expect(task.phase, MergePhase.done, reason: task.message);
    final delivered = File(target);
    expect(delivered.existsSync(), isTrue);
    expect(
      delivered.lengthSync(),
      File(h.library.pathFor(mergeId)).lengthSync(),
    );
    expect(File('$target.${task.id}.part').existsSync(), isFalse);

    final video = await h.library.read(mergeId);
    expect(video!.exports.map((e) => e.mode), ['new']);
    expect(video.exports.single.present, isTrue);
    expect(video.exports.single.bytes, delivered.lengthSync());
  });

  test(
    'a product that reached disk is finished work after a restart',
    () async {
      final id = await h.manager.enqueue(
        title: '重启续位',
        items: [
          h.episode('7000000000000000051'),
          h.episode('7000000000000000052', index: 2),
        ],
      );
      await h.settle();
      final mergeId = h.manager.tasks.firstWhere((t) => t.id == id).mergeId;
      // The write published, then the process died before the task card turned
      // green -- the record on disk still says running.
      (h.backend.data!['tasks'] as List)
              .cast<Map<String, dynamic>>()
              .first['phase'] =
          'running';

      final next = h.reopen();
      await next.manager.reconcile();
      final task = next.manager.tasks.firstWhere((t) => t.id == id);
      expect(task.phase, MergePhase.done);
      expect(next.started, 0, reason: 'reconcile 不应重做已发布的合成');
      expect(await next.library.read(mergeId), isNotNull);
      next.manager.dispose();
    },
  );

  test('a missing offline file is named, not silently skipped', () async {
    final id = await h.manager.enqueue(
      title: '缺源的合成',
      items: [
        h.episode('7000000000000000061'),
        MergeSelection(vid: '7000000000000000062', quality: 'best', index: 2),
      ],
    );
    await h.settle();
    final task = h.manager.tasks.firstWhere((t) => t.id == id);
    expect(task.phase, MergePhase.failed);
    expect(task.message, contains('第 2 集'));
    expect(task.message, contains('重新下载'));
    expect(await h.library.read(task.mergeId), isNull);
  });

  test('playback takes the disk and the merge waits for it', () async {
    h.manager.playbackEntered();
    final id = await h.manager.enqueue(
      title: '让位播放',
      items: [
        h.episode('7000000000000000071'),
        h.episode('7000000000000000072', index: 2),
      ],
    );
    await h.settle();
    expect(h.started, 0);
    expect(
      h.manager.tasks.firstWhere((t) => t.id == id).message,
      contains('正在播放'),
    );

    h.manager.playbackLeft();
    await h.settle();
    expect(
      h.manager.tasks.firstWhere((t) => t.id == id).phase,
      MergePhase.done,
    );
  });

  test(
    'removing a merged resource leaves the downloaded episodes alone',
    () async {
      final id = await h.manager.enqueue(
        title: '可删除的合成',
        items: [
          h.episode('7000000000000000081'),
          h.episode('7000000000000000082', index: 2),
        ],
      );
      await h.settle();
      final mergeId = h.manager.tasks.firstWhere((t) => t.id == id).mergeId;

      await h.manager.remove(mergeId);
      expect(File(h.library.pathFor(mergeId)).existsSync(), isFalse);
      expect(h.library.manifestFor(mergeId).existsSync(), isFalse);
      expect(
        File('${h.cache.path}/7000000000000000081_best.mp4').existsSync(),
        isTrue,
      );
      expect(h.manager.tasks.where((t) => t.mergeId == mergeId), isEmpty);
    },
  );

  test('the precheck answers with the verdict the writer would give', () async {
    final first = h.episode('7000000000000000101');
    final second = h.episode('7000000000000000102', index: 2);

    final report = await h.manager.precheck([first, second]);
    expect(report.reject, isNull, reason: report.reject ?? '');
    expect(report.entries.map((e) => e.error).toList(), [null, null]);
    expect(report.entries.first.durationMs, greaterThan(0));
    expect(report.sourceBytes, greaterThan(0));
    expect(report.ready.single.keys, [
      '7000000000000000101_best',
      '7000000000000000102_best',
    ]);

    // A timeline that only disagrees in its tables is no longer the case the
    // panel let reach a failed task card: the kernel re-dates it, and the queue
    // says so with the writer's own rule.
    File('${h.cache.path}/7000000000000000102_best.mp4')
        .writeAsBytesSync(offTimescale());
    final regraded = await h.manager.precheck([first, second]);
    expect(regraded.reject, isNull, reason: regraded.reject ?? '');
    expect(regraded.batches.single.mergeable, isTrue);

    final rescaled = await h.manager.enqueue(
      title: '时间基不同的两集',
      items: [first, second],
    );
    await h.settle();
    final rescaledTask = h.manager.tasks.firstWhere((t) => t.id == rescaled);
    expect(rescaledTask.phase, MergePhase.done, reason: rescaledTask.message);
    final rescaledFile = File(h.library.pathFor(rescaledTask.mergeId))
        .readAsBytesSync();
    expect(
      Mp4Merger.read(MemorySampleStore(rescaledFile)).durationMs,
      closeTo(episodeSource().durationMs * 2, 5),
    );

    // The difference a merge genuinely cannot absorb: the parameter set lives in
    // the sample description, so the answer is the refusal in the writer's words.
    File('${h.cache.path}/7000000000000000102_best.mp4')
        .writeAsBytesSync(offCodec());
    final refused = await h.manager.precheck([first, second]);
    expect(refused.reject, contains('编码参数'));
    expect(refused.ready, isEmpty);
    expect(refused.batches, hasLength(2));
    for (final part in refused.batches) {
      expect(part.reason, contains('编码参数'));
    }

    expect((await h.manager.precheck(const [])).reject, contains('至少选择两集'));
    expect((await h.manager.precheck([first])).reject, contains('至少选择两集'));
    expect(
      (await h.manager.precheck([first], targetMergeId: 'gone')).reject,
      contains('已不存在'),
    );

    final id = await h.manager.enqueue(
      title: '预检过的追剧',
      items: [
        h.episode('7000000000000000111'),
        h.episode('7000000000000000112', index: 2),
      ],
    );
    await h.settle();
    final mergeId = h.manager.tasks.firstWhere((t) => t.id == id).mergeId;
    // An append asks about the product already on disk, and a fresh episode
    // answers the same way the queue is about to.
    final grown = h.episode('7000000000000000113', index: 3);
    expect(
      (await h.manager.precheck([grown], targetMergeId: mergeId)).reject,
      isNull,
    );
    File('${h.cache.path}/7000000000000000113_best.mp4')
        .writeAsBytesSync(offTimescale());
    expect(
      (await h.manager.precheck([grown], targetMergeId: mergeId)).reject,
      isNull,
      reason: 'an append re-dates the same way a fresh merge does',
    );
    expect(
      (await h.manager.precheck([
        grown,
      ], targetMergeId: mergeId)).ready.single.keys,
      ['7000000000000000113_best'],
    );
    File('${h.cache.path}/7000000000000000113_best.mp4')
        .writeAsBytesSync(offCodec());
    final refusedGrow = await h.manager.precheck([
      grown,
    ], targetMergeId: mergeId);
    expect(refusedGrow.reject, contains('编码参数'));
    // One product, one append: a split is not on offer when growing a file.
    expect(refusedGrow.ready, isEmpty);
    expect(refusedGrow.batches.single.keys, ['7000000000000000113_best']);
  });

  test(
    'a mixed selection prechecks into the products its writer accepts',
    () async {
      final one = h.episode('7000000000000000201');
      final two = h.episode('7000000000000000202', index: 2);
      final three = h.episode(
        '7000000000000000203',
        index: 3,
        bytes: offCodec(),
      );
      final four = h.episode(
        '7000000000000000204',
        index: 4,
        bytes: offCodec(),
      );

      final report = await h.manager.precheck([one, two, three, four]);
      expect(report.entries.map((e) => e.groupKey).toSet(), hasLength(2));
      expect(report.reject, contains('编码参数'));
      final parts = report.ready;
      expect(parts.map((p) => p.keys), [
        ['7000000000000000201_best', '7000000000000000202_best'],
        ['7000000000000000203_best', '7000000000000000204_best'],
      ]);
      // Nothing was thrown away to make the split, so the size the panel quotes is
      // the size the two jobs will read.
      expect(report.batchedBytes, report.sourceBytes);

      for (var at = 0; at < parts.length; at++) {
        final items = [one, two, three, four]
            .where(
              (item) => parts[at].keys.contains('${item.vid}_${item.quality}'),
            )
            .toList();
        await h.manager.enqueue(title: '拆片 ${at + 1}', items: items);
      }
      await h.settle();
      final products = <String, List<int>>{};
      for (final task in h.manager.tasks) {
        expect(task.phase, MergePhase.done, reason: task.message);
        products[task.title] = (await h.library.read(task.mergeId))!.items
            .map((i) => i.index)
            .toList();
      }
      expect(products, {
        '拆片 1': [1, 2],
        '拆片 2': [3, 4],
      });
    },
  );

  group('兼容合成', () {
    late FakeTranscoder lane;
    late MergeHarness compat;
    setUp(() {
      lane = FakeTranscoder();
      compat = MergeHarness(transcoder: lane);
    });
    tearDown(() => compat.dispose());

    List<MergeSelection> two({String from = '300'}) => [
      compat.episode('7000000000000000$from'),
      compat.episode('7000000000000000${int.parse(from) + 1}', index: 2),
    ];

    test('one encode pass writes the part the queue then publishes', () async {
      final id = await compat.manager.enqueue(
        title: '换台也能播',
        items: two(),
        mode: 'compatible',
      );
      await compat.settle();

      final task = compat.manager.tasks.firstWhere((t) => t.id == id);
      expect(task.phase, MergePhase.done, reason: task.message);
      expect(task.mode, 'compatible');
      expect(task.isCompatible, isTrue);
      expect(lane.runs, hasLength(1), reason: '一遍编完，不逐集转码再拼接');

      final product = compat.library.pathFor(task.mergeId);
      final args = lane.runs.single;
      expect(
        args,
        containsAllInOrder([
          '-i',
          '${compat.cache.path}/7000000000000000300_best.mp4',
          '-i',
          '${compat.cache.path}/7000000000000000301_best.mp4',
        ]),
      );
      // The encode owns a part file beside the product and nothing else: the
      // publish stays the queue's rename, after the tables have been read back.
      expect(args.last, '$product.$id.part');
      expect(args, containsAllInOrder(['-c:v', 'libx264']));
      expect(args, containsAllInOrder(['-movflags', '+faststart']));
      // One concat filter over both inputs: the whole product comes out of a
      // single decode→encode pass, not from episodes transcoded one by one.
      expect(args[args.indexOf('-filter_complex') + 1], contains('concat=n=2'));
      // Progress is media time, so the card reads the same way on every lane.
      expect(lane.totals.single, episodeSource().durationMs * 2);

      final video = await compat.library.read(task.mergeId);
      expect(video!.mode, 'compatible');
      expect(video.isCompatible, isTrue);
      expect(video.codec, 'avc1');
      expect(video.items.map((i) => i.index), [1, 2]);
      expect(video.items.last.offsetMs, video.items.first.durationMs);
      expect(File(args.last).existsSync(), isFalse);
      expect(File(product).lengthSync(), video.bytes);
      // A re-encode keeps no byte checkpoint: there is nothing to resume from.
      expect(compat.journals.listSync(), isEmpty);
    });

    test('the mode is part of the record a restart reads back', () async {
      final id = await compat.manager.enqueue(
        title: '重启后的兼容片',
        items: two(from: '310'),
        mode: 'compatible',
      );
      await compat.settle();
      final mergeId = compat.manager.tasks
          .firstWhere((t) => t.id == id)
          .mergeId;

      final next = compat.reopen();
      await next.manager.reconcile();
      expect(
        next.manager.tasks.firstWhere((t) => t.id == id).mode,
        'compatible',
      );
      expect((await next.library.read(mergeId))!.mode, 'compatible');
      expect(next.started, 0, reason: 'a finished encode is not re-run');
      next.dispose();
    });

    test('refuses to grow a product that already exists', () async {
      final first = await compat.manager.enqueue(
        title: '先无损合成',
        items: two(from: '320'),
      );
      await compat.settle();
      final mergeId = compat.manager.tasks
          .firstWhere((t) => t.id == first)
          .mergeId;

      await expectLater(
        () => compat.manager.enqueue(
          title: 'ignored',
          items: [compat.episode('7000000000000000323', index: 3)],
          targetMergeId: mergeId,
          mode: 'compatible',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('不能追加'),
          ),
        ),
      );
      expect(lane.runs, isEmpty);
    });

    test(
      'a device with no lane is told so before anything is queued',
      () async {
        // The outer harness gets the default transcoder: no ffmpeg at all, which is
        // what a phone built without one reports.
        expect(h.manager.transcoderAvailable, isFalse);
        await expectLater(
          () => h.manager.enqueue(
            title: '手机端的尝试',
            items: [
              h.episode('7000000000000000330'),
              h.episode('7000000000000000331', index: 2),
            ],
            mode: 'compatible',
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('无法执行兼容合成'), contains('ffmpeg')),
            ),
          ),
        );
        expect(h.manager.tasks, isEmpty);
      },
    );

    test('an encode that wrote no file is a failure, not a product', () async {
      lane.writesProduct = false;
      final id = await compat.manager.enqueue(
        title: '半路死掉的编码',
        items: two(from: '340'),
        mode: 'compatible',
      );
      await compat.settle();

      final task = compat.manager.tasks.firstWhere((t) => t.id == id);
      expect(task.phase, MergePhase.failed, reason: task.message);
      expect(task.message, contains('读不回来'));
      expect(File(compat.library.pathFor(task.mergeId)).existsSync(), isFalse);
      expect(await compat.library.read(task.mergeId), isNull);
    });

    test('cancelling an encode throws its part file away', () async {
      lane.gate = Completer<void>();
      final id = await compat.manager.enqueue(
        title: '中途取消的兼容合成',
        items: two(from: '350'),
        mode: 'compatible',
      );
      final task = compat.manager.tasks.firstWhere((t) => t.id == id);
      final part = File('${compat.library.pathFor(task.mergeId)}.$id.part');
      // The part only appears once bytes have been produced, so this is the
      // cancel a viewer presses mid-file rather than one pressed at the queue.
      for (var at = 0; at < 500 && !part.existsSync(); at++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(
        part.existsSync(),
        isTrue,
        reason: 'the encode never wrote a part',
      );

      compat.manager.cancel(id);
      await compat.settle();
      expect(lane.stops, 1);
      expect(task.phase, MergePhase.cancelled);
      expect(part.existsSync(), isFalse);
      expect(File(compat.library.pathFor(task.mergeId)).existsSync(), isFalse);
      expect(compat.journals.listSync(), isEmpty);
    });
  });
}
