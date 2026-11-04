import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/merge/merge_manager.dart';
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
  }) {
    manager = MergeManager(
      backend: backend,
      library: library,
      journals: journals,
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

  factory MergeHarness() {
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
  );

  MergeSelection episode(String vid, {int index = 1}) {
    File('${cache.path}/${vid}_best.mp4').writeAsBytesSync(_fixture());
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

MergeSource episodeSource() => Mp4Merger.read(MemorySampleStore(_fixture()));

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
}
