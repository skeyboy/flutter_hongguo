import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_core/hongguo_native.dart';

import 'progressive_stream_server.dart';

/// Reads `[start, endInclusive]` of the remote source, or null when the origin
/// will not answer. Used for the header regions a running download has not
/// reached yet, which is all a progressive plan needs beyond its prefix.
typedef ProgressiveRangeReader = Future<Uint8List?> Function(
  int start,
  int endInclusive,
);

/// Same headers the transfer itself uses: the origin signs the answer to the
/// identity it handed the URL to.
ProgressiveRangeReader progressiveRangeFetcher(
  Dio dio,
  Uri url, {
  Map<String, String> headers = const {'User-Agent': 'Mozilla/5.0'},
  Duration timeout = const Duration(seconds: 20),
}) {
  return (start, endInclusive) async {
    try {
      final response = await dio.get<Uint8List>(
        url.toString(),
        options: Options(
          headers: {...headers, 'Range': 'bytes=$start-$endInclusive'},
          responseType: ResponseType.bytes,
          followRedirects: false,
          receiveTimeout: timeout,
        ),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) return null;
      final wanted = endInclusive - start + 1;
      // A 200 answer ignored the request, so its body starts at zero and is
      // only usable for a window that begins there; a short 206 is still a
      // valid prefix and the caller asks again for what follows.
      if (response.statusCode != HttpStatus.partialContent && start > 0) {
        return null;
      }
      return bytes.length > wanted
          ? Uint8List.sublistView(bytes, 0, wanted)
          : bytes;
    } catch (_) {
      return null;
    }
  };
}

/// Names the offset a Range fetch has to fill before the plan can be built.
class _MissingRegion implements Exception {
  final int start;
  const _MissingRegion(this.start);
}

/// Metadata view over a transfer that is still running.
///
/// `Mp4Cenc.inspect` reads only top-level box headers and the moov, so this
/// store answers from the downloaded prefix and from previously fetched
/// windows, and otherwise throws [_MissingRegion] with the offset that would
/// unblock it. The lane refills and retries until a plan exists or the
/// metadata budget runs out; the sample payload is never read here.
class _BackfilledStore implements SampleStore {
  final String path;
  final int total;
  final ProgressiveRangeReader fetchRange;
  final int budgetBytes;
  final _windows = <int, Uint8List>{};
  final _requested = <int>{};
  int _buffered = 0;
  RandomAccessFile? _handle;

  _BackfilledStore({
    required this.path,
    required this.total,
    required this.fetchRange,
    required this.budgetBytes,
  });

  @override
  int get length => total;

  @override
  void write(int offset, Uint8List bytes) {
    throw UnsupportedError('A progressive plan never writes metadata');
  }

  /// Durable ciphertext bytes on disk; the transfer may be ahead of this and
  /// the origin behind it, so both are read from here.
  int get delivered {
    try {
      return min(_fileLength, total);
    } on FileSystemException {
      return 0;
    }
  }

  int get _fileLength =>
      (_handle ??= File(path).openSync(mode: FileMode.read)).lengthSync();

  @override
  Uint8List read(int offset, int length) {
    if (length == 0) return Uint8List(0);
    if (offset < 0 || length < 0 || offset + length > total) {
      throw FormatException('Metadata read outside the transfer');
    }
    for (final entry in _windows.entries) {
      final start = entry.key, bytes = entry.value;
      if (offset >= start && offset + length <= start + bytes.length) {
        return Uint8List.sublistView(
          bytes,
          offset - start,
          offset - start + length,
        );
      }
    }
    if (offset + length <= delivered) return _fromFile(offset, length);
    // Ask from the earliest byte of the hole a known window does not already
    // cover, so a repeated read of the same box cannot loop forever.
    var request = offset;
    for (final entry in _windows.entries) {
      final end = entry.key + entry.value.length;
      if (entry.key <= offset && end > request) request = end;
    }
    if (request >= total) throw const FormatException('Metadata past EOF');
    throw _MissingRegion(request);
  }

  Uint8List _fromFile(int offset, int length) {
    final handle = _handle!;
    handle.setPositionSync(offset);
    final bytes = Uint8List(length);
    var read = 0;
    while (read < length) {
      final n = handle.readIntoSync(bytes, read, length);
      if (n == 0) throw const FormatException('Working file ended mid-read');
      read += n;
    }
    return bytes;
  }

  /// Fetches the window a [_MissingRegion] asked for. False means the origin
  /// refused, the budget is spent, or the same offset came up twice.
  Future<bool> backfill(int start) async {
    if (start < 0 || start >= total || !_requested.add(start)) return false;
    final wanted = min(total - start, budgetBytes);
    if (_buffered + wanted > budgetBytes) return false;
    final bytes = await fetchRange(start, start + wanted - 1);
    if (bytes == null || bytes.isEmpty) return false;
    final value = bytes.length > wanted
        ? Uint8List.sublistView(bytes, 0, wanted)
        : bytes;
    _windows[start] = value;
    _buffered += value.length;
    return true;
  }

  void closeHandle() {
    try {
      _handle?.closeSync();
    } on FileSystemException {
      /* already gone */
    }
    _handle = null;
  }
}

/// Play-while-downloading lane for one cache job.
///
/// The lane turns the ciphertext working file of an in-flight transfer into a
/// clear, moov-first stream and serves that from a loopback origin, so the
/// player can open the video before the download ends. It is deliberately
/// pessimistic: a layout it cannot emit monotonically, a failed Range backfill,
/// a changed transfer length or a stalled writer leaves the lane unusable, the
/// early URL resolves null, and the caller runs whole-file preparation on the
/// same working file.
class ProgressiveLane {
  ProgressiveLane({
    required this.encryptedPath,
    required this.clearPath,
    required this.keyHex,
    required this.fetchRange,
    required this.server,
    this.metadataBudgetBytes = 8 * 1024 * 1024,
    this.openFloorBytes = 256 * 1024,
  });

  final String encryptedPath, clearPath, keyHex;
  final ProgressiveRangeReader fetchRange;
  final ProgressiveStreamServer server;

  /// Largest moov plus header window the plan builder may hold in memory.
  final int metadataBudgetBytes;

  /// Clear bytes past the metadata that must exist before the URL is handed
  /// out, so the demuxer's probe is not served by a stall alone.
  final int openFloorBytes;

  final _playable = Completer<String?>();
  ProgressiveDecrypt? _writer;
  ProgressivePlan? _plan;
  Uri? _uri;
  Future<void>? _opening, _drained;
  Object? _failure;
  bool _final = false, _finalRoundRun = false;
  bool _closed = false, _inRound = false;
  int _total = 0, _wanted = 0, _pumped = 0;

  /// Loopback URL the player can open mid-transfer, or null when this transfer
  /// cannot start early. Completes as soon as either answer is final.
  Future<String?> get playable => _playable.future;

  int get availableBytes => _writer?.availableBytes ?? 0;
  Object? get failure => _failure;

  /// Reports `[received]` durable ciphertext bytes of a `[total]` byte source.
  void notify(int received, int total) {
    if (_closed || _failure != null || received <= 0 || total <= 0) return;
    if (_total == 0) {
      _total = total;
      _wanted = received;
      _opening = _start();
      return;
    }
    if (total != _total) {
      unawaited(_fail(const FormatException('Transfer length changed')));
      return;
    }
    if (received > _wanted) _wanted = received;
    _drain();
  }

  Future<void> _start() async {
    // The metadata store only lives while the plan is being read; its file
    // handle must not outlive this attempt, whichever path leaves it.
    final store = _BackfilledStore(
      path: encryptedPath,
      total: _total,
      fetchRange: fetchRange,
      budgetBytes: metadataBudgetBytes,
    );
    try {
      final plan = await _buildPlan(store, keyHex);
      if (_closed || _failure != null) return;
      final writer = await ProgressiveDecrypt.open(
        encryptedPath,
        clearPath,
        plan,
      );
      // The transfer can be abandoned while the plan is still being read.
      // A handle opened after that has to go back, or the working file
      // outlives the job that owns it.
      if (_closed || _failure != null) {
        try {
          await writer.close();
        } catch (_) {
          /* never wrote a byte */
        }
        await _removeClear();
        return;
      }
      _plan = plan;
      _writer = writer;
      _uri = server.mount(ProgressiveFileSource(clearPath, total: plan.total));
      _drain();
      await _drained;
    } catch (error) {
      await _fail(error);
    } finally {
      store.closeHandle();
    }
  }

  static Future<ProgressivePlan> _buildPlan(
    _BackfilledStore store,
    String keyHex,
  ) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        return ProgressivePlan.build(store, keyHex);
      } on _MissingRegion catch (missing) {
        if (!await store.backfill(missing.start)) {
          throw const FormatException('Progressive metadata budget exhausted');
        }
      }
    }
    throw const FormatException('Progressive metadata did not converge');
  }

  /// Chains pump rounds so two rounds can never write the output at once.
  void _drain() {
    if (_failure != null || _writer == null || _closed) return;
    _drained = (_drained ?? Future<void>.value()).then((_) => _pumpRound());
  }

  Future<void> _pumpRound() async {
    _inRound = true;
    try {
      while (_failure == null && !_closed && _writer != null) {
        final total = _plan!.total;
        final target = min(_wanted, total);
        // The closing round has to run even when the prefix already reached
        // the end: the relocated layout still owes its completion marker.
        final closing = _final && !_finalRoundRun && target >= total;
        if (target <= _pumped && !closing) break;
        if (closing) _finalRoundRun = true;
        try {
          await _writer!.pump(target, downloadComplete: closing);
          _pumped = target;
        } catch (error) {
          await _fail(error);
        }
      }
      _announce();
    } finally {
      _inRound = false;
    }
  }

  void _announce() {
    final writer = _writer, plan = _plan, uri = _uri;
    if (writer == null ||
        plan == null ||
        uri == null ||
        _failure != null ||
        _playable.isCompleted) {
      return;
    }
    final floor = min(plan.total, plan.metadataEnd + openFloorBytes);
    if (writer.completed || writer.availableBytes >= floor) {
      _playable.complete(uri.toString());
    }
  }

  /// Called once the transfer has written every ciphertext byte. Returns the
  /// clear path when the stream is complete — the file already sits at its
  /// final cache name and keeps being served — and null when it is not, after
  /// which whole-file preparation owns the working file.
  Future<String?> finish(int encryptedBytes) async {
    if (_closed || _failure != null) {
      _closePlayable();
      return null;
    }
    if (_total == 0) _total = encryptedBytes;
    final opening = _opening;
    if (opening != null) {
      await opening;
    } else if (encryptedBytes > 0) {
      _wanted = encryptedBytes;
      await _start();
    }
    if (_failure != null || _writer == null) {
      _closePlayable();
      return null;
    }
    if (encryptedBytes < _total) {
      await _fail(const FormatException('Transfer ended short of its length'));
      return null;
    }
    _final = true;
    _wanted = _total;
    _drain();
    await _drained;
    final writer = _writer;
    if (_failure != null || writer == null || !writer.completed) {
      await _fail(
        _failure ??
            const FormatException('Progressive stream ended incomplete'),
      );
      return null;
    }
    // The player is still reading through the mounted source: close the
    // writer's own handles, keep the mount until the pin is released.
    try {
      await writer.close();
    } catch (error) {
      await _fail(error);
      return null;
    }
    _writer = null;
    if (!_playable.isCompleted) _playable.complete(_uri.toString());
    return clearPath;
  }

  /// Gives up: unmounts, releases handles and removes the half-written stream.
  Future<void> discard() async {
    await _awaitOpening();
    await _fail(_failure ?? const ProgressiveAbandoned());
  }

  /// Unmounts and releases handles, keeping the published file.
  Future<void> detach() async {
    _closePlayable();
    await _awaitOpening();
    if (_closed) return;
    _closed = true;
    final uri = _uri;
    _uri = null;
    if (uri != null) server.revoke(uri);
    await _releaseHandles();
  }

  /// A plan build still in flight owns file handles; a caller that tears the
  /// lane down has to wait for it to let go, or the working file it opened
  /// cannot be deleted.
  Future<void> _awaitOpening() async {
    final opening = _opening;
    if (opening == null) return;
    try {
      await opening;
    } catch (_) {
      /* _start reports through _fail */
    }
  }

  /// A lane that never crossed its open floor still has to answer the player:
  /// after the transfer ends there is nothing left to wait for.
  void _closePlayable() {
    if (!_playable.isCompleted) _playable.complete(null);
  }

  Future<void> _fail(Object error) async {
    _failure ??= error;
    if (_closed) return;
    final uri = _uri;
    _uri = null;
    if (uri != null) server.revoke(uri);
    await _releaseHandles();
    await _removeClear();
    _closed = true;
    if (!_playable.isCompleted) _playable.complete(null);
  }

  Future<void> _removeClear() async {
    try {
      await File(clearPath).delete();
    } on FileSystemException {
      /* never created, or already removed */
    }
  }

  Future<void> _releaseHandles() async {
    // A round that failed calls here from inside itself; awaiting its own
    // chain would wait for this method to return.
    final drained = _drained;
    if (drained != null && !_inRound) {
      try {
        await drained;
      } catch (_) {
        /* the round that failed already reported */
      }
    }
    final writer = _writer;
    _writer = null;
    if (writer != null) {
      try {
        await writer.close();
      } catch (_) {
        /* a failed stream cannot be flushed */
      }
    }
    _plan = null;
  }
}

/// The transfer or the player let the lane go before its stream was complete.
class ProgressiveAbandoned implements Exception {
  const ProgressiveAbandoned();
  @override
  String toString() => '边下边播已中止';
}
