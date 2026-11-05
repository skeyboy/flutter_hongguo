import 'dart:convert';
import 'dart:io';

import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/merge/merge_manager.dart';
import 'package:hongguo_app/merge/merge_transcode.dart';
import 'package:hongguo_app/merge/merge_worker.dart';
import 'package:hongguo_app/merge/merged_library.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_app/settings/settings_store.dart';

import 'fakes.dart';

class MergeMemoryBackend implements PreferencesBackend {
  Map<String, dynamic>? data;
  @override
  Future<Map<String, dynamic>?> read() async => data;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    data = Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
  }
}

/// The `merged/` library as the widget tests see it: the record lives in
/// memory, the bytes stay on disk.
///
/// A `testWidgets` body runs in a fake-async zone where a real disk read never
/// resumes, so the pages cannot go through [MergedLibrary]'s IO here. The
/// manifests and videos are still written synchronously by
/// [MergeFakeRuntime.seedProduct] -- enough for the existence checks -- and the
/// library itself is exercised for real in `merge_manager_test.dart`.
class MergeMemoryLibrary extends MergedLibrary {
  MergeMemoryLibrary(super.directory);
  final _videos = <String, MergedVideo>{};

  void seed(MergedVideo video) => _videos[video.mergeId] = video;

  @override
  Future<List<MergedVideo>> list() async {
    final out =
        _videos.values
            .where((video) => File(video.filePath).existsSync())
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  @override
  Future<MergedVideo?> read(String mergeId) async => _videos[mergeId];

  @override
  Future<void> write(MergedVideo video) async => seed(video);

  @override
  Future<void> delete(String mergeId) async {
    _videos.remove(mergeId);
  }
}

/// A runtime that owns a real merge queue over a temp directory.
///
/// The queue never runs a job here: playback is entered as the manager is built,
/// which is the state that holds a job queued. What this file checks is what the
/// viewer can see and press, not the bytes -- those are `merge_manager_test.dart`'s
/// job.
class MergeFakeRuntime extends FakeRuntime implements MergeRuntime {
  final Directory temp;
  final Directory cacheDir;
  @override
  final MergeMemoryLibrary mergedLibrary;
  @override
  late final MergeManager merges;
  final files = <LocalEpisode>[];
  final mergedPaths = <String>[];
  final preparedLocal = <String>[];

  /// The precheck's verdict, when a test wants the panel to refuse. null lets
  /// the fake answer 可以无损合成 for every episode it can still see.
  String? probeReject;

  /// The 片 a refused precheck finds inside the selection: the episode indexes of
  /// each candidate, in selection order. A group of one keeps [probeReject] as
  /// its reason, the way the worker's split leaves a lone episode out.
  List<List<int>>? probeGroups;

  /// How many files each 预检 was asked about, in the order the panel handed them.
  final probed = <int>[];

  /// The encoder lane this machine has: null means there is no ffmpeg, which is
  /// the phone case -- the panel then never offers 兼容合成.
  final MergeTranscoder? lane;
  MergeFakeRuntime._(
    this.temp,
    this.cacheDir,
    this.mergedLibrary, {
    this.lane,
  }) {
    merges = MergeManager(
      backend: MergeMemoryBackend(),
      library: mergedLibrary,
      journals: Directory('${temp.path}/merge-journal')
        ..createSync(recursive: true),
      sourcePath: (vid, quality) =>
          '${cacheDir.path}${Platform.pathSeparator}${vid}_$quality.mp4',
      // No job is meant to reach the runner here. If one escapes the held queue,
      // it fails at once instead of leaving the suite waiting on a merge that
      // never started.
      run: (request, {onProgress}) => MergeHandle(
        result: Future.error(
          StateError('the merge UI fake holds the queue; a job must not run'),
        ),
        stop: () {},
      ),
      // The seeded files are zero-filled, so the real reader would refuse them
      // for the wrong reason. This answers the same question the worker asks --
      // one entry per file, one verdict for the set -- off the tables the
      // fixture owns.
      probe: (requests, productPath) async {
        probed.add(requests.length);
        final entries = [
          for (final request in requests)
            MergeProbeEntry(
              vid: request.vid,
              quality: request.quality,
              index: request.index,
              bytes: 1024 * 1024,
              durationMs: 60000,
              width: 1080,
              height: 1920,
              codec: 'hvc1',
              audioCodec: 'mp4a',
              videoBitrate: 2000000,
              audioBitrate: 128000,
              fpsMilli: 30000,
              error: File(request.path).existsSync() ? null : '离线文件已不存在，请先重新下载',
            ),
        ];
        final broken = entries
            .where((entry) => entry.error != null)
            .firstOrNull;
        final reject =
            probeReject ??
            (broken == null
                ? null
                : '第 ${broken.index} 集不能作为合成输入：${broken.error}');
        return MergePrecheckReport(
          entries: entries,
          reject: reject,
          // The same shape the worker's split answers with: one 片 for the whole
          // set when the writer takes it, otherwise the groups the test asks for
          // -- and a 片 that holds one episode is never a product.
          batches: [
            if (reject == null)
              MergeBatch(keys: [for (final entry in entries) entry.key])
            else if (probeReject != null && broken == null)
              for (final group in probeGroups ?? const <List<int>>[])
                MergeBatch(
                  keys: [
                    for (final entry in entries)
                      if (group.contains(entry.index)) entry.key,
                  ],
                  reason: group.length < 2 ? probeReject : null,
                ),
          ],
        );
      },
      // A device without an ffmpeg: 兼容合成 stays unoffered, exactly as on a
      // phone, until a test hands this runtime a lane of its own.
      transcoder: lane ?? const UnavailableTranscoder(),
    );
    // Playback is the state that keeps a job queued, so every test inherits it:
    // the viewer can still press everything, and the queue shows what it was
    // told to do without writing bytes.
    merges.playbackEntered();
  }

  factory MergeFakeRuntime({bool mobile = false, MergeTranscoder? lane}) {
    final temp = Directory.systemTemp.createTempSync('hongguo-merge-ui-');
    Directory dir(String name) =>
        Directory('${temp.path}/$name')..createSync(recursive: true);
    final merged = dir('merged');
    final runtime = MergeFakeRuntime._(
      temp,
      dir('media-cache'),
      MergeMemoryLibrary(merged),
      lane: lane,
    );
    runtime.mobile = mobile;
    return runtime;
  }

  bool mobile = false;

  /// The episodes on disk, as the cache scan would report them.
  void seedFiles(String dramaId, List<int> indexes) {
    final detail = DramaDetail(
      Drama(id: dramaId, title: '山海之间', episodeCount: indexes.length),
      [for (final i in indexes) Episode(vid: '$i', index: i, title: '第 $i 集')],
    );
    for (final i in indexes) {
      File('${cacheDir.path}/${i}_best.mp4')
          .writeAsBytesSync(List<int>.filled(1024 * 1024, 0));
      files.add(
        LocalEpisode(
          vid: '$i',
          quality: 'best',
          bytes: 2 * 1024 * 1024,
          modified: DateTime.now(),
          inUse: false,
          detail: detail,
        ),
      );
    }
  }

  /// A finished product, its manifest and the copy it handed out.
  ///
  /// Every fixture write is synchronous: a widget-test body runs in a fake-async
  /// zone, where an awaited disk write never finishes.
  MergedVideo seedProduct({
    String mergeId = 'm1',
    String title = '山海之间 合集',
    List<MergedItem> items = const [],
    List<MergedExport> exports = const [],
    String mode = 'lossless',
    String? codec = 'h264',
  }) {
    final now = DateTime.now();
    final video = MergedVideo(
      mergeId: mergeId,
      title: title,
      filePath: mergedLibrary.pathFor(mergeId),
      createdAt: now,
      updatedAt: now,
      codec: codec,
      width: 1080,
      height: 1920,
      bytes: 4 * 1024 * 1024,
      items: items,
      exports: exports,
      mode: mode,
    );
    File(mergedLibrary.pathFor(mergeId))
        .writeAsBytesSync(List<int>.filled(4 * 1024 * 1024, 0));
    mergedLibrary
        .manifestFor(mergeId)
        .writeAsStringSync(jsonEncode(video.toJson()));
    mergedLibrary.seed(video);
    return video;
  }

  @override
  Future<List<LocalEpisode>> localEpisodes() async => List.of(files);

  @override
  String mediaPath(String vid, String quality) =>
      '${cacheDir.path}${Platform.pathSeparator}${vid}_$quality.mp4';

  @override
  PlaybackJob prepareLocal(String vid, {String quality = 'best'}) {
    preparedLocal.add(vid);
    return _StaticJob(
      'file:///${mediaPath(vid, quality).replaceAll(r'\', '/')}',
    );
  }

  @override
  PlaybackJob prepareMerged(String mergeId) {
    mergedPaths.add(mergeId);
    return _StaticJob(
      'file:///${mergedLibrary.pathFor(mergeId).replaceAll(r'\', '/')}',
    );
  }

  /// Teardown of a widget test runs after the fake clock stops, where an awaited
  /// write never resumes. No job runs here, so the queue owns no handle and only
  /// the temp tree has to go.
  void cleanUp() => temp.deleteSync(recursive: true);
}

class _StaticJob implements PlaybackJob {
  final String uri;
  _StaticJob(this.uri);
  @override
  Future<String> get source => Future.value(uri);
  @override
  void cancel() {}
  @override
  void release() {}
}

/// The encoder lane as a widget test sees it: present, named, and never asked to
/// run -- the fake queue holds every job, so an encode that reached this would
/// be a panel bug rather than a test.
class MergeUiTranscoder implements MergeTranscoder {
  @override
  bool get available => true;
  @override
  String? get encoder => 'libx264';
  @override
  String get label => 'ffmpeg · libx264';
  @override
  Future<void> warmUp() async {}
  @override
  TranscodeHandle run(
    List<String> args, {
    required int totalDurationMs,
    void Function(int doneMs, int totalMs)? onProgress,
  }) => TranscodeHandle(
    result: Future.error(
      StateError('the merge UI fake holds the queue; an encode must not run'),
    ),
    stop: () {},
  );

  @override
  void close() {}
}

MergedItem item(int index, {String? vid, DateTime? addedAt}) => MergedItem(
  vid: vid ?? '$index',
  quality: 'best',
  episodeTitle: '第 $index 集',
  dramaId: 'd1',
  sourceName: '${vid ?? index}_best.mp4',
  index: index,
  sourceSize: 2 * 1024 * 1024,
  sourceModifiedMs: 0,
  durationMs: 60000,
  offsetMs: (index - 1) * 60000,
  addedAt: addedAt ?? DateTime(2026, 11, 1, 9),
);
