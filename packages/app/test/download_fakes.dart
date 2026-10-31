import 'dart:async';
import 'dart:convert';

import 'package:hongguo_app/downloads/download_manager.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_app/catalog/library_cache.dart';
import 'package:hongguo_app/settings/settings_store.dart';

import 'fakes.dart';

class DownloadBackend implements PreferencesBackend {
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

class DownloadJob implements PlaybackJob {
  final completer = Completer<String>();
  final void Function(PreparationProgress) progress;
  bool cancelled = false;
  int releases = 0;
  DownloadJob(this.progress);
  @override
  Future<String> get source => completer.future;
  @override
  void cancel() {
    cancelled = true;
    if (!completer.isCompleted) {
      completer.completeError(StateError('cancelled'));
    }
  }

  @override
  void release() {
    releases++;
  }
}

class DownloadFakeRuntime extends FakeRuntime
    implements DownloadRuntime, LibraryCacheRuntime {
  final DownloadBackend backend;
  @override
  final libraryCache = LibraryCache();
  final files = <LocalEpisode>[];
  final jobs = <String, DownloadJob>{};
  final calls = <String>[];
  @override
  late final DownloadManager downloads;
  DownloadFakeRuntime({
    DownloadBackend? backend,
    bool mobile = false,
    bool television = false,
  }) : backend = backend ?? DownloadBackend() {
    downloads = DownloadManager(
      backend: this.backend,
      settings: () => settings,
      files: localEpisodes,
      mobile: mobile,
      television: television,
      remember: libraryCache.rememberDetail,
      deleteFile: (vid, quality) async {
        files.removeWhere((f) => f.vid == vid && f.quality == quality);
      },
      prepare: (task, progress) {
        calls.add(task.key);
        return jobs[task.key] = DownloadJob(progress);
      },
    );
  }
  @override
  Future<List<LocalEpisode>> localEpisodes() async => List.of(files);

  /// Mirrors `NativeRuntime.evict`: an in-use file refuses to go, and the queue
  /// record only drops once the file is really gone.
  @override
  Future<void> evict(String vid, {String quality = 'best'}) async {
    final file = files
        .where((f) => f.vid == vid && f.quality == quality)
        .firstOrNull;
    if (file?.inUse == true) {
      throw StateError('正在使用该视频，请结束播放后再删除');
    }
    files.removeWhere((f) => f.vid == vid && f.quality == quality);
    await downloads.forget(vid, quality);
  }

  @override
  PlaybackJob prepareLocal(String vid, {String quality = 'best'}) =>
      throw UnimplementedError();
  Future<void> complete(
    String key, {
    int bytes = 100,
    bool inUse = false,
  }) async {
    final task = downloads.tasks.firstWhere((t) => t.key == key);
    files.add(
      LocalEpisode(
        vid: task.episode.vid,
        quality: task.quality,
        bytes: bytes,
        modified: DateTime.now(),
        inUse: inUse,
        detail: await libraryCache.readDetail(task.drama.id),
      ),
    );
    jobs[key]!.completer.complete('/local/$key.mp4');
  }

  @override
  Future<void> dispose() async {
    await downloads.shutdown();
    downloads.dispose();
    await super.dispose();
  }
}

Future<void> queueTick() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
