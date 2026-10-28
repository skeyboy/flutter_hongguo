import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_core/hongguo_native.dart';

import 'video_model_client.dart';
import 'request_control.dart';

enum MediaStage {
  queued,
  resolving,
  downloading,
  waitingNetwork,
  decrypting,
  validating,
  ready,
}

class MediaProgress {
  final MediaStage stage;
  final int received, total;
  const MediaProgress(this.stage, {this.received = 0, this.total = 0});
  double? get fraction => total > 0 ? received / total : null;
}

/// Preparation ends at a verified local file, not at the player's first frame.
class MediaPreparationTiming {
  final Duration elapsed;
  final Map<String, Duration> stages;
  final bool cacheHit, background;
  final String? failureType;
  MediaPreparationTiming({
    required this.elapsed,
    required Map<String, Duration> stages,
    required this.cacheHit,
    required this.background,
    this.failureType,
  }) : stages = Map.unmodifiable(stages);
}

class MediaCancelled implements Exception {
  const MediaCancelled();
  @override
  String toString() => '准备已取消';
}

class MediaPreparation {
  final _result = Completer<String>();
  final void Function(MediaProgress)? onProgress;
  void Function()? _release;
  Future<String> get result => _result.future;
  MediaPreparation(this.onProgress);
  void cancel() {
    if (_result.isCompleted) return;
    _release?.call();
    _result.completeError(const MediaCancelled());
  }
}

class _Job {
  final String key, vid, quality;
  final token = CancelToken();
  final metadataScope = CatalogRequestScope();
  final clock = Stopwatch()..start();
  final timings = <String, Duration>{};
  String timingStage = 'queued';
  Duration lastMark = Duration.zero;
  void mark(String stage) {
    if (stage == timingStage) return;
    final elapsed = clock.elapsed;
    timings[timingStage] =
        (timings[timingStage] ?? Duration.zero) + elapsed - lastMark;
    timingStage = stage;
    lastMark = elapsed;
  }

  final leases = <MediaPreparation>{};
  bool background;

  /// The user explicitly asked for this file (a manual download) rather than
  /// the automatic prefetch lane producing it. Manual jobs run in their own
  /// concurrency budget and are never stopped by prefetch policy changes.
  bool manual;
  MediaProgress? latest;
  _Job(
    this.key,
    this.vid,
    this.quality,
    this.background, {
    this.manual = false,
  }) {
    unawaited(token.whenCancel.then((_) => metadataScope.cancel()));
  }
  void progress(MediaProgress p) {
    mark(p.stage.name);
    latest = p;
    for (final lease in leases.toList()) {
      // UI observation cannot corrupt a download or make it fail.
      try {
        lease.onProgress?.call(p);
      } catch (_) {}
    }
  }
}

/// Streams ciphertext to private working files. Only verified, atomically
/// renamed files with a size manifest become cache hits. Same-key work shares
/// a job, while each consumer owns an independent cancellation lease.
class MediaCache {
  final Directory directory;
  final Dio dio;
  final void Function(MediaPreparationTiming)? onTiming;
  final Future<void> Function(
    String vid,
    String quality,
    VideoTrack track,
    String path,
    CancelToken token,
    void Function(int, int) progress,
  )?
  download;
  final Future<void> Function(String vid, String quality)? onFinished;
  final Future<void> Function(String vid, String quality, String? workingPath)?
  onJobFinished;
  final Future<VideoTrack> Function(String vid, String quality) resolve;
  int maxFiles, maxBytes, maxConcurrent;

  /// Concurrent transfers for manual downloads. Separate from [maxConcurrent],
  /// which budgets playback and automatic prefetch, so that raising the
  /// download count cannot starve the next episode the player needs.
  int maxDownloadConcurrent;

  /// Explicit user downloads survive ordinary LRU and cache clearing.
  final bool Function(String vid, String quality)? retainFile;
  final _jobs = <String, _Job>{};
  final _pins = <String, int>{};

  /// Pinned bytes split by ownership: automatic cache files count against the
  /// maxBytes budget, manual (retained) downloads never squeeze that budget.
  final _autoBytes = <String, int>{};
  final _retainedBytes = <String, int>{};
  final _reserved = <_Job, int>{};
  final _pending = <_Job>[];
  final _active = <_Job>{};

  /// High-water marks of transfers the scheduler had in flight at the same
  /// instant, one per lane. Sampling from outside the scheduler cannot see
  /// them: a short episode finishes inside one sample interval, so a UI-side
  /// poll reports fewer concurrent transfers than actually ran. The count is
  /// taken where a job leaves the queue, which is also where the limit is
  /// enforced, so it is both the ceiling and the proof the ceiling was hit.
  int _peakManual = 0, _peakAutomatic = 0;
  int get peakManualTransfers => _peakManual;
  int get peakAutomaticTransfers => _peakAutomatic;

  /// Starts a fresh measurement window without disturbing running transfers.
  void resetPeakTransfers() => _peakManual = _peakAutomatic = 0;
  bool _closed = false;
  int _serial = 0;
  MediaCache({
    required this.directory,
    required this.dio,
    this.onTiming,
    this.download,
    this.onFinished,
    this.onJobFinished,
    required this.resolve,
    this.maxFiles = 30,
    this.maxBytes = 512 * 1024 * 1024,
    this.maxConcurrent = 2,
    this.maxDownloadConcurrent = 1,
    this.retainFile,
  });
  int get _autoPinnedBytes => _autoBytes.values.fold<int>(0, (a, b) => a + b);

  void _trackPin(String path, int size) {
    (_retainedPath(path) ? _retainedBytes : _autoBytes)[path] = size;
  }

  void _untrackPin(String path) {
    _autoBytes.remove(path);
    _retainedBytes.remove(path);
  }

  String _key(String vid, String quality) {
    if (!RegExp(r'^\d{1,30}$').hasMatch(vid) ||
        !RegExp(r'^(best|auto|\d{3,4}p)$').hasMatch(quality)) {
      throw ArgumentError('Invalid video ID or quality');
    }
    return '${vid}_$quality';
  }

  MediaPreparation prepare(
    String vid, {
    String quality = 'best',
    void Function(MediaProgress)? onProgress,
    bool background = false,
    bool manual = false,
  }) {
    if (_closed) throw StateError('Media cache is closed');
    final key = _key(vid, quality);
    final lease = MediaPreparation(onProgress);
    var job = _jobs[key];
    final isNew = job == null;
    job ??= _Job(key, vid, quality, background, manual: manual);
    // An explicit download claims the automatic job already fetching this file
    // rather than starting a second transfer of it.
    if (manual) job.manual = true;
    if (!background) {
      job.background = false;
      _reserved.remove(job);
    }
    _jobs[key] = job;
    job.leases.add(lease);
    final active = job;
    lease._release = () {
      active.leases.remove(lease);
      if (active.leases.isEmpty) {
        active.token.cancel('No active consumers');
        if (identical(_jobs[key], active)) _jobs.remove(key);
        _pending.remove(active);
        _pump();
      }
    };
    if (isNew) {
      active.progress(const MediaProgress(MediaStage.queued));
      _pending.add(active);
    } else if (active.latest != null) {
      try {
        onProgress?.call(active.latest!);
      } catch (_) {
        /* observer only */
      }
    }
    _pump();
    return lease;
  }

  /// Pins before any asynchronous validation. Never resolves or downloads.
  MediaPreparation prepareCached(String vid, {String quality = 'best'}) {
    if (_closed) throw StateError('Media cache is closed');
    final output = File('${directory.path}/${_key(vid, quality)}.mp4');
    final lease = MediaPreparation(null);
    _pins[output.path] = (_pins[output.path] ?? 0) + 1;
    lease._release = () {
      final count = (_pins[output.path] ?? 1) - 1;
      if (count <= 0) {
        _pins.remove(output.path);
        _untrackPin(output.path);
      } else {
        _pins[output.path] = count;
      }
      lease._release = null;
    };
    unawaited(() async {
      try {
        if (!await _cacheHit(output, File('${output.path}.json'))) {
          throw StateError('本地缓存已失效，请返回列表重新下载。');
        }
        if (lease._result.isCompleted) return;
        _trackPin(output.path, output.lengthSync());
        lease._result.complete(output.path);
      } catch (error, stack) {
        release(lease);
        if (!lease._result.isCompleted) {
          lease._result.completeError(error, stack);
        }
      }
    }());
    return lease;
  }

  void _pump() {
    if (_closed) return;
    _pending.removeWhere((job) => job.token.isCancelled || job.leases.isEmpty);
    _drain((job) => job.manual, maxDownloadConcurrent);
    _drain((job) => !job.manual, maxConcurrent, reserveForPlayer: true);
  }

  /// Starts pending jobs of one lane while that lane has room.
  ///
  /// [reserveForPlayer] keeps the last automatic slot free of queued prefetch,
  /// so background preparation can never delay the episode being watched.
  /// Manual downloads need neither reservation nor a share of that budget:
  /// they are the user's own request, capped by the download setting.
  void _drain(
    bool Function(_Job job) lane,
    int limit, {
    bool reserveForPlayer = false,
  }) {
    while (_active.where(lane).length < limit) {
      var index = _pending.indexWhere((job) => lane(job) && !job.background);
      if (index < 0) {
        if (reserveForPlayer) {
          final backgroundLimit = limit > 1 ? limit - 1 : 1;
          if (_active.where((job) => lane(job) && job.background).length >=
              backgroundLimit) {
            return;
          }
        }
        index = _pending.indexWhere(lane);
      }
      if (index < 0) return;
      final job = _pending.removeAt(index);
      _active.add(job);
      final running = _active.where(lane).length;
      if (job.manual) {
        if (running > _peakManual) _peakManual = running;
      } else if (running > _peakAutomatic) {
        _peakAutomatic = running;
      }
      unawaited(
        _run(job).whenComplete(() {
          _active.remove(job);
          _pump();
        }),
      );
    }
  }

  Future<void> configure({
    required int files,
    required int bytes,
    required int concurrency,
    required int downloadConcurrency,
  }) async {
    if (files < 1 ||
        bytes < 1 ||
        concurrency < 1 ||
        concurrency > 3 ||
        downloadConcurrency < 1) {
      throw ArgumentError('Invalid cache limits');
    }
    maxFiles = files;
    maxBytes = bytes;
    maxConcurrent = concurrency;
    maxDownloadConcurrent = downloadConcurrency;
    _pump();
    await prune();
  }

  /// Stops queued automatic work. A manual download is never cancelled here:
  /// the caller changes the prefetch policy, not the user's download queue.
  void cancelBackground({bool Function(String vid, String quality)? keep}) {
    for (final job
        in _jobs.values
            .where(
              (j) =>
                  j.background &&
                  !j.manual &&
                  !(keep?.call(j.vid, j.quality) ?? false),
            )
            .toList()) {
      job.token.cancel('Background prefetch stopped');
      _pending.remove(job);
      if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
      for (final lease in job.leases.toList()) {
        if (!lease._result.isCompleted) {
          lease._result.completeError(const MediaCancelled());
        }
      }
    }
    _pump();
  }

  void close() {
    _closed = true;
    for (final job in _jobs.values.toList()) {
      job.token.cancel('Cache disposed');
      for (final lease in job.leases.toList()) {
        if (!lease._result.isCompleted) {
          lease._result.completeError(const MediaCancelled());
        }
      }
    }
    _pending.clear();
    _jobs.clear();
  }

  Future<void> _run(_Job job) async {
    String? working;
    String? workingIdentity;
    var cacheHit = false, reported = false;
    void report(Object? error) {
      if (reported) return;
      reported = true;
      job.mark('finished');
      try {
        onTiming?.call(
          MediaPreparationTiming(
            elapsed: job.clock.elapsed,
            stages: job.timings,
            cacheHit: cacheHit,
            background: job.background,
            failureType: error?.runtimeType.toString(),
          ),
        );
      } catch (_) {
        /* Timing observers cannot interrupt preparation. */
      }
    }

    try {
      _check(job);
      job.mark('cacheLookup');
      await directory.create(recursive: true);
      final output = File('${directory.path}/${job.key}.mp4');
      final manifest = File('${output.path}.json');
      cacheHit = await _cacheHit(output, manifest);
      if (!cacheHit) {
        _check(job);
        job.progress(const MediaProgress(MediaStage.resolving));
        final track = await job.metadataScope.run(
          () => resolve(job.vid, job.quality),
        );
        _check(job);
        // Manual downloads own a separate ledger: the byte budget below only
        // accounts for automatic cache files so prefetch is never squeezed by
        // retained downloads (and vice versa).
        final retainedJob = _retainedPath(output.path);
        if (job.background && !retainedJob && maxBytes > 0) {
          _reserved[job] = track.size > 0 ? track.size : 0;
          if (_autoPinnedBytes +
                  _reserved.values.fold<int>(0, (a, b) => a + b) >
              maxBytes) {
            _reserved.remove(job);
            throw StateError('缓存空间不足，已暂停该集预缓存');
          }
        }
        MediaUrlDecoder.checked(track.url.toString(), [
          'qznovelvod.com',
          'fqnovelvod.com',
          'douyinvod.com',
        ]);
        working =
            '${output.path}.${DateTime.now().microsecondsSinceEpoch}.${_serial++}.part';
        workingIdentity = working;
        job.progress(const MediaProgress(MediaStage.downloading));
        void report(int received, int total) {
          if (job.background && !retainedJob && maxBytes > 0) {
            if (received > (_reserved[job] ?? 0)) _reserved[job] = received;
            final allocated =
                _autoPinnedBytes +
                _reserved.values.fold<int>(0, (a, b) => a + b);
            if (allocated > maxBytes) {
              job.token.cancel('Background cache budget exceeded');
            }
          }
          job.progress(
            MediaProgress(
              total == -1 ? MediaStage.waitingNetwork : MediaStage.downloading,
              received: received,
              total: total,
            ),
          );
        }

        if (download != null) {
          await download!(
            job.vid,
            job.quality,
            track,
            working,
            job.token,
            report,
          );
        } else {
          await dio.download(
            track.url.toString(),
            working,
            cancelToken: job.token,
            deleteOnError: true,
            options: Options(
              followRedirects: false,
              headers: {'User-Agent': 'Mozilla/5.0'},
              receiveTimeout: const Duration(seconds: 120),
            ),
            onReceiveProgress: report,
          );
        }
        _check(job);
        if (track.encrypted) {
          job.progress(const MediaProgress(MediaStage.decrypting));
          await FileDecryptor.decrypt(working, track.spadeA);
        }
        _check(job);
        job.progress(const MediaProgress(MediaStage.validating));
        await FileDecryptor.validateClear(working);
        _check(job);
        final length = await File(working).length();
        final temporaryManifest = File('$working.json');
        await temporaryManifest.writeAsString(
          jsonEncode({
            'version': 1,
            'size': length,
            'vid': job.vid,
            'quality': job.quality,
          }),
          flush: true,
        );
        // No await between cancellation check and atomic file publication.
        _check(job);
        if (output.existsSync()) output.deleteSync();
        File(working).renameSync(output.path);
        if (manifest.existsSync()) manifest.deleteSync();
        temporaryManifest.renameSync(manifest.path);
        working = null;
      }
      _check(job);
      if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
      _reserved.remove(job);
      // A ready result stays pinned while its consumer/player is using it.
      for (final lease in job.leases.toList()) {
        if (lease._result.isCompleted) continue;
        _pins[output.path] = (_pins[output.path] ?? 0) + 1;
        _trackPin(output.path, output.lengthSync());
        lease._release = () {
          final count = (_pins[output.path] ?? 1) - 1;
          if (count <= 0) {
            _pins.remove(output.path);
            _untrackPin(output.path);
          } else {
            _pins[output.path] = count;
          }
          lease._release = null;
        };
        lease._result.complete(output.path);
      }
      job.progress(const MediaProgress(MediaStage.ready));
      report(null);
      await prune();
    } catch (error, stack) {
      report(job.token.isCancelled ? const MediaCancelled() : error);
      if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
      for (final lease in job.leases.toList()) {
        if (!lease._result.isCompleted) {
          lease._result.completeError(
            job.token.isCancelled ? const MediaCancelled() : error,
            stack,
          );
        }
      }
    } finally {
      try {
        await onJobFinished?.call(job.vid, job.quality, workingIdentity);
      } catch (_) {
        /* Keep recovery metadata when cleanup is unavailable. */
      }
      try {
        await onFinished?.call(job.vid, job.quality);
      } catch (_) {
        /* Retry journal cleanup on next launch. */
      }
      _reserved.remove(job);
      if (working != null) {
        for (final path in [working, '$working.json']) {
          try {
            await File(path).delete();
          } on FileSystemException {
            /* already removed */
          }
        }
      }
      if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
    }
  }

  static void _check(_Job job) {
    if (job.token.isCancelled || job.leases.isEmpty) {
      throw const MediaCancelled();
    }
  }

  /// Startup recovery of an already downloaded private working file. Never
  /// resolves a URL. The caller must serialize this before exposing the runtime.
  Future<void> adoptDownloaded(
    String vid,
    String quality,
    String path,
    String? spade,
  ) async {
    final key = _key(vid, quality);
    final file = File(path);
    if (file.parent.path != directory.path ||
        !file.uri.pathSegments.last.startsWith('$key.mp4.') ||
        !path.endsWith('.part')) {
      throw ArgumentError('Invalid recovered cache path');
    }
    final output = File('${directory.path}/$key.mp4');
    if (_closed || _jobs.containsKey(key) || _pins.containsKey(output.path)) {
      throw StateError('Cache entry is in use');
    }
    if (await _cacheHit(output, File('${output.path}.json'))) {
      if (await file.exists()) await file.delete();
      return;
    }
    if (!_retainedPath(output.path) && await file.length() > maxBytes) {
      throw StateError('Recovered cache exceeds budget');
    }
    var clear = false;
    try {
      await FileDecryptor.validateClear(path);
      clear = true;
    } catch (_) {}
    if (!clear) await FileDecryptor.decrypt(path, spade ?? '');
    await FileDecryptor.validateClear(path);
    final length = await file.length();
    final manifest = File('${output.path}.json');
    final temporary = File('$path.json');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'size': length,
        'vid': vid,
        'quality': quality,
      }),
      flush: true,
    );
    if (output.existsSync()) output.deleteSync();
    file.renameSync(output.path);
    if (manifest.existsSync()) manifest.deleteSync();
    temporary.renameSync(manifest.path);
    await prune();
  }

  Future<bool> _cacheHit(File file, File manifest) async {
    try {
      final record = jsonDecode(await manifest.readAsString()) as Map;
      if (record['version'] != 1 ||
          record['size'] != await file.length() ||
          (record['size'] as int) <= 0) {
        return false;
      }
      await FileDecryptor.validateClear(file.path);
      await file.setLastModified(DateTime.now());
      return true;
    } on Object {
      return false;
    }
  }

  /// Release a ready lease on player disposal. Call release() for ready pins.
  void release(MediaPreparation lease) {
    lease._release?.call();
    lease._release = null;
  }

  bool _retainedPath(String path) {
    final match = RegExp(r'^(\d{1,30})_(best|auto|\d{3,4}p)\.mp4$')
        .firstMatch(File(path).uri.pathSegments.last);
    return match != null && (retainFile?.call(match[1]!, match[2]!) ?? false);
  }

  Future<void> prune() async {
    if (!await directory.exists()) return;
    await _reclaimOrphanPartials();
    final files = await directory
        .list()
        .where((f) => f is File && f.path.endsWith('.mp4'))
        .cast<File>()
        .toList();
    final stats = <String, FileStat>{};
    for (final file in files) {
      try {
        final stat = await file.stat();
        if (stat.type == FileSystemEntityType.file) stats[file.path] = stat;
      } on FileSystemException {
        /* concurrently removed */
      }
    }
    files.removeWhere((file) => !stats.containsKey(file.path));
    files.sort(
      (a, b) => stats[b.path]!.modified.compareTo(stats[a.path]!.modified),
    );
    bool protected(File f) =>
        _retainedPath(f.path) ||
        _pins.containsKey(f.path) ||
        _jobs.values.any((job) => f.path == '${directory.path}/${job.key}.mp4');
    var kept = files.where(protected).length;
    var keptBytes = files
        .where(protected)
        .fold<int>(0, (sum, f) => sum + stats[f.path]!.size);
    for (final file in files.where((f) => !protected(f))) {
      final size = stats[file.path]!.size;
      if ((maxFiles > 0 && kept >= maxFiles) ||
          (maxBytes > 0 && keptBytes + size > maxBytes)) {
        try {
          await file.delete();
          await File('${file.path}.json').delete();
        } on FileSystemException {
          /* concurrent cleanup */
        }
      } else {
        kept++;
        keptBytes += size;
      }
    }
  }

  /// A transfer cut short by process exit leaves a working file that no
  /// cancellation path can reach, and it stays unusable ciphertext. Reclaim the
  /// stale ones no job owns; a real transfer writes inside this margin.
  Future<void> _reclaimOrphanPartials() async {
    final staleBefore = DateTime.now().subtract(const Duration(hours: 1));
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.endsWith('.part') && !name.endsWith('.part.json')) continue;
      if (_jobs.values.any((job) => name.startsWith('${job.key}.mp4.'))) {
        continue;
      }
      try {
        if ((await entity.lastModified()).isAfter(staleBefore)) continue;
        await entity.delete();
      } on FileSystemException {
        /* concurrently removed */
      }
    }
  }

  Future<void> evict(String vid, {String quality = 'best'}) async {
    final path = '${directory.path}/${_key(vid, quality)}.mp4';
    if (_pins.containsKey(path)) return;
    for (final name in [path, '$path.json']) {
      try {
        await File(name).delete();
      } on FileSystemException {
        /* absent */
      }
    }
  }

  /// Lists only atomically published MP4s with a matching completion manifest.
  Future<List<CachedMediaEntry>> entries() async {
    final values = <CachedMediaEntry>[];
    if (!await directory.exists()) return values;
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.mp4')) continue;
      try {
        final record =
            jsonDecode(await File('${entity.path}.json').readAsString()) as Map;
        final vid = record['vid'] as String,
            quality = record['quality'] as String;
        if (entity.path != '${directory.path}/${_key(vid, quality)}.mp4') {
          continue;
        }
        final stat = await entity.stat();
        if (record['version'] != 1 ||
            record['size'] != stat.size ||
            stat.size <= 0) {
          continue;
        }
        values.add(
          CachedMediaEntry(
            vid,
            quality,
            stat.size,
            stat.modified,
            _pins.containsKey(entity.path) ||
                _jobs.containsKey(_key(vid, quality)),
          ),
        );
      } catch (_) {
        /* Incomplete, removed or invalid entries are not ready. */
      }
    }
    values.sort((a, b) => b.modified.compareTo(a.modified));
    return values;
  }

  Future<int> cacheBytes() async {
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final file in directory.list()) {
      if (file is File && file.path.endsWith('.mp4')) {
        total += await file.length();
      }
    }
    return total;
  }

  Future<void> clear() async {
    if (!await directory.exists()) return;
    await for (final file in directory.list()) {
      if (file is! File) continue;
      if (file.path.endsWith('.part') || file.path.endsWith('.part.json')) {
        final active = _jobs.values.any(
          (job) => file.path.startsWith('${directory.path}/${job.key}.mp4.'),
        );
        if (!active) {
          try {
            await file.delete();
          } on FileSystemException {
            /* already removed */
          }
        }
        continue;
      }
      final target = file.path.endsWith('.json')
          ? file.path.substring(0, file.path.length - 5)
          : file.path;
      if (_retainedPath(target) ||
          _pins.containsKey(target) ||
          _jobs.keys.any((key) => target == '${directory.path}/$key.mp4')) {
        continue;
      }
      if (file.path.endsWith('.mp4') || file.path.endsWith('.mp4.json')) {
        try {
          await file.delete();
        } on FileSystemException {
          /* concurrently removed */
        }
      }
    }
  }
}

class CachedMediaEntry {
  final String vid, quality;
  final int bytes;
  final DateTime modified;
  final bool inUse;
  const CachedMediaEntry(
    this.vid,
    this.quality,
    this.bytes,
    this.modified,
    this.inUse,
  );
}
