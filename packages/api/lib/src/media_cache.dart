import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_core/hongguo_native.dart';

import 'video_model_client.dart';
import 'request_control.dart';
import 'progressive_lane.dart';
import 'progressive_stream_server.dart';

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

enum _ManifestState {
  /// The sidecar says exactly what is on disk.
  current,

  /// The sidecar disagrees with the file: the bytes are not this video.
  mismatch,

  /// The sidecar is absent or unreadable -- no evidence about the file.
  stale,
}

class MediaPreparation {
  final _result = Completer<String>();
  final _early = Completer<String?>();
  final void Function(MediaProgress)? onProgress;
  void Function()? _release;
  bool _settled = false;
  Future<String> get result => _result.future;

  /// Loopback URL of a stream that plays while the transfer still runs, or
  /// null when this preparation cannot start early. It never stays pending
  /// once [result] has an answer, so a player can await both in order.
  Future<String?> get early => _early.future;
  MediaPreparation(this.onProgress);
  void cancel() {
    _settle();
    if (_result.isCompleted) return;
    _release?.call();
    _result.completeError(const MediaCancelled());
  }

  /// Stops late early-playback news: after the job settles, the only source
  /// worth handing the player is the finished file.
  void _settle() {
    _settled = true;
    if (!_early.isCompleted) _early.complete(null);
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

  /// Hands the mid-transfer URL to every lease that is still waiting for
  /// preparation, so the player can start before the file is complete.
  void announceEarly(String uri) {
    for (final lease in leases.toList()) {
      if (lease._settled || lease._early.isCompleted) continue;
      lease._early.complete(uri);
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

  /// Lets the holder of resolved playback info forget a deleted episode, so a
  /// kept answer cannot outlive the file it produced.
  final void Function(String vid, String quality)? onEvict;

  /// Turns an encrypted transfer into a mid-download loopback stream when on.
  /// The answer is sampled per job, so a settings change applies to the next
  /// preparation without restarting the cache.
  final bool Function()? progressivePlayback;

  /// Memory a progressive plan may spend on header regions the transfer has
  /// not reached yet, plus the clear prefix that must exist before the URL is
  /// handed to a player.
  final int progressiveMetadataBytes, progressiveOpenFloorBytes;

  final _jobs = <String, _Job>{};
  final _pins = <String, int>{};

  /// Live mid-download streams, by job key. A published one keeps its mount
  /// until the player releases the pin, because the URL it was opened with
  /// still reads that file.
  final _lanes = <String, ProgressiveLane>{};
  ProgressiveStreamServer? _streamServer;
  Future<ProgressiveStreamServer>? _bindingServer;

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
    this.onEvict,
    this.progressivePlayback,
    this.progressiveMetadataBytes = 8 * 1024 * 1024,
    this.progressiveOpenFloorBytes = 256 * 1024,
  });
  int get _autoPinnedBytes => _autoBytes.values.fold<int>(0, (a, b) => a + b);

  /// One loopback origin per cache, bound on the first progressive job so a
  /// disabled setting never opens a socket.
  Future<ProgressiveStreamServer> _openStreamServer() {
    final existing = _streamServer;
    if (existing != null) return Future.value(existing);
    return _bindingServer ??=
        () async {
          final server = await ProgressiveStreamServer.bind();
          if (_closed) {
            await server.close();
            throw const MediaCancelled();
          }
          return _streamServer = server;
        }().catchError((Object error, StackTrace stack) {
          _bindingServer = null;
          Error.throwWithStackTrace(error, stack);
        });
  }

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
        lease._settle();
        lease._result.complete(output.path);
      } catch (error, stack) {
        release(lease);
        lease._settle();
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
        lease._settle();
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
        lease._settle();
      }
    }
    _pending.clear();
    _jobs.clear();
    // Unpublished streams are half-written ciphertext-derived files; a job
    // that finished already handed its lane to a pin.
    for (final lane in _lanes.values) {
      unawaited(lane.discard());
    }
    _lanes.clear();
    final server = _streamServer;
    _streamServer = null;
    unawaited(server?.close());
  }

  Future<void> _run(_Job job) async {
    String? working;
    String? workingIdentity;
    ProgressiveLane? lane;
    var cacheHit = false, reported = false, streamPublished = false;
    var keepStream = false;
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
        final cipher = working;
        job.progress(const MediaProgress(MediaStage.downloading));
        // A manual download is the user's own transfer, not a stream the
        // player is waiting on; it keeps the single-pass pipeline it always
        // had. Web and TV clients never pass the callback, so they are none
        // closer to a loopback origin than before.
        final progressiveKey = track.encrypted
            ? Spade.decode(track.spadeA)?.hex
            : null;
        if (progressiveKey != null &&
            (progressivePlayback?.call() ?? false) &&
            !job.manual) {
          lane = ProgressiveLane(
            encryptedPath: working,
            clearPath: output.path,
            keyHex: progressiveKey,
            fetchRange: progressiveRangeFetcher(dio, track.url),
            server: await _openStreamServer(),
            metadataBudgetBytes: progressiveMetadataBytes,
            openFloorBytes: progressiveOpenFloorBytes,
          );
          _lanes[job.key] = lane;
          final started = lane;
          unawaited(
            started.playable.then((uri) {
              if (uri != null) job.announceEarly(uri);
            }),
          );
        }
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
          // Feeding the lane cannot disturb the transfer: a lane that fails
          // reports through its own futures.
          try {
            lane?.notify(received, total);
          } catch (_) {}
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
        // A lane that survived the transfer already wrote the finished clear
        // file under its final cache name; everything else takes the
        // whole-file path it always had.
        var clear = working;
        if (lane != null) {
          final streamed = await lane.finish(await File(working).length());
          if (streamed != null) {
            streamPublished = true;
            clear = streamed;
          }
        }
        _check(job);
        if (!streamPublished && track.encrypted) {
          job.progress(const MediaProgress(MediaStage.decrypting));
          await FileDecryptor.decrypt(working, track.spadeA);
        }
        _check(job);
        job.progress(const MediaProgress(MediaStage.validating));
        await FileDecryptor.validateClear(clear);
        _check(job);
        final length = await File(clear).length();
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
        try {
          // A lane already wrote the clear bytes under the final cache name,
          // so publishing it again is a no-op; everything else moves the
          // decrypted working file into place. Both go through the same
          // reuse-or-retry rule: Windows refuses to delete or rename over a
          // handle the player still holds, and the file under that handle is
          // the finished video, not a failure.
          await _publishClear(File(clear), output, length);
        } on FileSystemException {
          try {
            await temporaryManifest.delete();
          } on FileSystemException {
            /* the finally below and the next prune reclaim it */
          }
          rethrow;
        }
        working = null;
        await _writeManifest(manifest, {
          'version': 1,
          'size': length,
          'vid': job.vid,
          'quality': job.quality,
        }, '${output.path}.published.json');
        // The manifest itself moved under its published name; the copy written
        // beside the working file is spent either way.
        _deleteQuietly(temporaryManifest.path);
        if (_samePath(clear, output.path)) {
          if (streamPublished) {
            // The lane read every ciphertext byte to write the published file,
            // so the working copy is spent here. Retire it at the publish
            // point instead of leaving a `.part` for the tail of this method.
            _deleteQuietly(cipher);
          }
        } else {
          // The target was reused rather than replaced, so the working copy --
          // the decrypted file it did not need -- is spent. Its temporary
          // manifest sat beside it and is reclaimed the same way.
          for (final spent in [clear, '$clear.json']) {
            _deleteQuietly(spent);
          }
        }
      }
      _check(job);
      if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
      _reserved.remove(job);
      // A published stream keeps its mount until the last player lets go:
      // the URL it handed out still reads that file from disk.
      final stream = streamPublished ? _lanes.remove(job.key) : null;
      keepStream = stream != null;
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
            unawaited(stream?.detach());
          } else {
            _pins[output.path] = count;
          }
          lease._release = null;
        };
        lease._settle();
        lease._result.complete(output.path);
      }
      job.progress(const MediaProgress(MediaStage.ready));
      report(null);
      await prune();
    } catch (error, stack) {
      report(job.token.isCancelled ? const MediaCancelled() : error);
      if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
      for (final lease in job.leases.toList()) {
        lease._settle();
        if (!lease._result.isCompleted) {
          lease._result.completeError(
            job.token.isCancelled ? const MediaCancelled() : error,
            stack,
          );
        }
      }
    } finally {
      if (lane != null && !keepStream) {
        try {
          await lane.discard();
        } catch (_) {
          /* a stream that is already gone cannot block cleanup */
        }
        if (identical(_lanes[job.key], lane)) _lanes.remove(job.key);
      }
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

  /// Windows refuses to delete or rename a file another process -- normally
  /// the player's own still-open handle -- is reading, while macOS and Linux
  /// rename an open file freely. A held candidate is retried briefly, then the
  /// original error surfaces.
  static void _retryWhileHeld(void Function() operation) {
    for (var attempt = 0; ; attempt++) {
      try {
        operation();
        return;
      } on FileSystemException catch (error) {
        // errno 32 (sharing violation) or 5 (access denied): a handle, not a
        // broken disk. Anything else is genuine and must not be swallowed.
        final osError = error.osError?.errorCode;
        if (!Platform.isWindows ||
            !(osError == 32 || osError == 5) ||
            attempt >= 2) {
          rethrow;
        }
        sleep(const Duration(milliseconds: 100));
      }
    }
  }

  static bool _samePath(String a, String b) =>
      File(a).uri.toString().toLowerCase() ==
      File(b).uri.toString().toLowerCase();

  Future<void> _writeManifest(
    File manifest,
    Map<String, Object> record,
    String temporaryPath,
  ) async {
    await File(temporaryPath).writeAsString(jsonEncode(record), flush: true);
    try {
      await _publishClear(File(temporaryPath), manifest, null);
    } on FileSystemException {
      try {
        await File(temporaryPath).delete();
      } on FileSystemException {
        /* reclaimed by the next prune */
      }
      rethrow;
    }
  }

  /// Moves `source` onto `target` -- or proves it is already there, returning
  /// false when the source was left in place instead. A held target that
  /// already carries a valid clear video is reused rather than deleted: the
  /// bytes on disk are the finished result, and failing the job over an
  /// uncloseable handle is how a healthy Windows library started reading as
  /// "cannot fetch video data".
  Future<bool> _publishClear(
    File source,
    File target,
    int? expectedSize,
  ) async {
    final targetPath = target.path;
    if (_samePath(source.path, targetPath)) return true;
    if (expectedSize != null && target.existsSync()) {
      var valid = false;
      try {
        if (await target.length() == expectedSize) {
          await FileDecryptor.validateClear(target.path);
          valid = true;
        }
      } on FileSystemException {
        // A target this job cannot read at all is not a reusable file, and
        // the delete below reports the real failure.
      } on FormatException {
        // Half a video parses as garbage: not reusable.
      }
      if (valid) return false;
    }
    if (target.existsSync()) {
      _retryWhileHeld(() {
        if (target.existsSync()) target.deleteSync();
      });
    }
    _retryWhileHeld(() => source.renameSync(targetPath));
    return true;
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
      _deleteQuietly(file.path);
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
    var clearPublished = false;
    try {
      clearPublished = await _publishClear(file, output, length);
    } on FileSystemException {
      _deleteQuietly(temporary.path);
      rethrow;
    }
    if (!clearPublished) {
      // The published entry was reused, so the recovered working file -- and
      // only it -- is the spent copy here.
      _deleteQuietly(file.path);
    }
    await _writeManifest(manifest, {
      'version': 1,
      'size': length,
      'vid': vid,
      'quality': quality,
    }, '${output.path}.published.json');
    _deleteQuietly(temporary.path);
    await prune();
  }

  Future<bool> _cacheHit(File file, File manifest) async {
    if (!await file.exists()) return false;
    final length = await file.length();
    // A readable-but-stale manifest is a real mismatch. An absent or corrupt
    // one is not evidence about the video, and Windows can leave an intact
    // file stranded that way when a manifest rename loses a race with the
    // player's handle; re-downloading over that file then used to fail with a
    // sharing violation. Prove the bytes clear and rewrite the manifest.
    final recordState = _manifestState(manifest, length);
    try {
      if (recordState == _ManifestState.mismatch) return false;
      await FileDecryptor.validateClear(file.path);
      if (recordState != _ManifestState.current) {
        final temporary = '${manifest.path}.selfheal.tmp';
        try {
          await _writeManifest(manifest, {
            'version': 1,
            'size': length,
          }, temporary);
        } finally {
          _deleteQuietly(temporary);
        }
      }
      await file.setLastModified(DateTime.now());
      return true;
    } on FormatException {
      // A truncated or key-corrupted file parses as garbage -- unless its own
      // manifest vouches for the byte count and the file cannot be read at
      // all: on Windows that is the shape of a player still holding the
      // handle while its reader is denied. The download path's reuse rule
      // proves the bytes once more and takes the file back without a second
      // transfer racing the lock.
      return false;
    } on FileSystemException {
      return false;
    }
  }

  _ManifestState _manifestState(File manifest, int length) {
    try {
      final record = jsonDecode(manifest.readAsStringSync()) as Map;
      final recorded = record['size'];
      if (record['version'] != 1 || recorded != length || length <= 0) {
        return _ManifestState.mismatch;
      }
      return _ManifestState.current;
    } on FormatException {
      return _ManifestState.stale;
    } on FileSystemException {
      return _ManifestState.stale;
    } on Object {
      return _ManifestState.mismatch;
    }
  }

  void _deleteQuietly(String path) {
    try {
      File(path).deleteSync();
    } on FileSystemException {
      /* reclaimed by the next prune */
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

  /// Cache files are named by their key, so a pin is recognised by name: the
  /// paths this class joins and the ones `directory.list()` reports differ in
  /// separator on Windows and cannot be compared as strings.
  bool _isPinned(String path) {
    final name = File(path).uri.pathSegments.last;
    return _pins.keys.any(
      (pinned) => File(pinned).uri.pathSegments.last == name,
    );
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
    bool protected(File f) {
      final name = f.uri.pathSegments.last;
      return _retainedPath(f.path) ||
          _isPinned(f.path) ||
          _jobs.values.any((job) => '${job.key}.mp4' == name);
    }

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
    // Whether or not the file survives, an answer kept for it may no longer
    // be handed to a player.
    onEvict?.call(vid, quality);
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
        // The manifest names this file, and `_key` has already refused a
        // vid or quality that could not belong to it.
        if (entity.uri.pathSegments.last != '${_key(vid, quality)}.mp4') {
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
            _isPinned(entity.path) || _jobs.containsKey(_key(vid, quality)),
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
      final name = file.uri.pathSegments.last;
      if (name.endsWith('.part') || name.endsWith('.part.json')) {
        final active = _jobs.values.any(
          (job) => name.startsWith('${job.key}.mp4.'),
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
      final target = name.endsWith('.json')
          ? file.path.substring(0, file.path.length - 5)
          : file.path;
      final targetName = name.endsWith('.json')
          ? name.substring(0, name.length - 5)
          : name;
      if (_retainedPath(target) ||
          _isPinned(target) ||
          _jobs.keys.any((key) => '$key.mp4' == targetName)) {
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
