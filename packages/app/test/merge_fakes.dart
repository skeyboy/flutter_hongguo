import 'dart:convert';
import 'dart:io';

import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/merge/merge_manager.dart';
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

  MergeFakeRuntime._(this.temp, this.cacheDir, this.mergedLibrary) {
    merges = MergeManager(
      backend: MergeMemoryBackend(),
      library: mergedLibrary,
      journals: Directory('${temp.path}/merge-journal')
        ..createSync(recursive: true),
      sourcePath: (vid, quality) =>
          '$cacheDir${Platform.pathSeparator}${vid}_$quality.mp4',
      // No job is meant to reach the runner here. If one escapes the held queue,
      // it fails at once instead of leaving the suite waiting on a merge that
      // never started.
      run: (request, {onProgress}) => MergeHandle(
        result: Future.error(
          StateError('the merge UI fake holds the queue; a job must not run'),
        ),
        stop: () {},
      ),
    );
    // Playback is the state that keeps a job queued, so every test inherits it:
    // the viewer can still press everything, and the queue shows what it was
    // told to do without writing bytes.
    merges.playbackEntered();
  }

  factory MergeFakeRuntime({bool mobile = false}) {
    final temp = Directory.systemTemp.createTempSync('hongguo-merge-ui-');
    Directory dir(String name) =>
        Directory('${temp.path}/$name')..createSync(recursive: true);
    final merged = dir('merged');
    final runtime = MergeFakeRuntime._(
      temp,
      dir('media-cache'),
      MergeMemoryLibrary(merged),
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
  }) {
    final now = DateTime.now();
    final video = MergedVideo(
      mergeId: mergeId,
      title: title,
      filePath: mergedLibrary.pathFor(mergeId),
      createdAt: now,
      updatedAt: now,
      codec: 'h264',
      width: 1080,
      height: 1920,
      bytes: 4 * 1024 * 1024,
      items: items,
      exports: exports,
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
      '$cacheDir${Platform.pathSeparator}${vid}_$quality.mp4';

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
