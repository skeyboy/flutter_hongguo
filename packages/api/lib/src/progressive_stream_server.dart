import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// A clear MP4 whose playable prefix keeps growing while its download runs.
///
/// The server only ever serves bytes the source reports as ready, so a source
/// can be a live progressive writer, a finished file or a test double.
abstract class ProgressiveSource {
  /// The size the file will reach once the download completes. It is what the
  /// origin advertises, so a player treats a short prefix as "still coming"
  /// rather than as the end of the media.
  int get total;

  /// Contiguous clear bytes that can be read right now.
  int get availableBytes;

  /// Reads [length] bytes at [start]; must not return fewer bytes than asked
  /// for while [start] + [length] is within [availableBytes].
  Future<Uint8List> read(int start, int length);

  /// Completes with true once [position] bytes are ready, or false when the
  /// wait runs out and the response has to be cut short.
  Future<bool> readyFor(int position, Duration timeout);
}

/// Serves the growing clear file a progressive writer appends to.
///
/// Growth is observed by polling: the writer flushes in blocks, so the poll
/// interval only delays bytes the player has not reached yet.
class ProgressiveFileSource implements ProgressiveSource {
  final String path;
  @override
  final int total;
  final Duration pollInterval;

  ProgressiveFileSource(
    this.path, {
    this.total = 0,
    this.pollInterval = const Duration(milliseconds: 100),
  });

  @override
  int get availableBytes {
    try {
      final length = File(path).lengthSync();
      return total > 0 && length > total ? total : length;
    } on FileSystemException {
      return 0;
    }
  }

  @override
  Future<Uint8List> read(int start, int length) async {
    final available = availableBytes;
    if (length <= 0 || start < 0 || start + length > available) {
      throw const FormatException('Read beyond the progressive prefix');
    }
    final bytes = Uint8List(length);
    final handle = await File(path).open(mode: FileMode.read);
    try {
      await handle.setPosition(start);
      var read = 0;
      while (read < length) {
        final n = await handle.readInto(bytes, read, length);
        if (n == 0) {
          throw const FormatException('Progressive file shrank mid-read');
        }
        read += n;
      }
    } finally {
      await handle.close();
    }
    return bytes;
  }

  @override
  Future<bool> readyFor(int position, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (availableBytes < position) {
      if (total > 0 && position > total) return false;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return false;
      await Future<void>.delayed(
        remaining < pollInterval ? remaining : pollInterval,
      );
    }
    return true;
  }
}

/// Loopback origin for play-while-downloading.
///
/// media_kit plays a local clear file or an HTTP URL, never remote CENC bytes,
/// so the decrypted prefix has to be re-served over HTTP for playback to start
/// before the transfer ends. HEAD and `Range` are mandatory: the demuxer probes
/// the length, seeks by re-requesting a byte window, and sends `bytes=0-` for a
/// plain sequential start.
class ProgressiveStreamServer {
  ProgressiveStreamServer._(this._server, this.stallTimeout);

  final HttpServer _server;

  /// How long a request waits for new bytes before its response is cut short;
  /// the player then re-requests the window it still needs.
  final Duration stallTimeout;

  final Map<String, ProgressiveSource> _sources = {};
  final _rng = Random.secure();
  static const _chunkBytes = 64 * 1024;

  int get port => _server.port;

  static Future<ProgressiveStreamServer> bind({
    int port = 0,
    Duration stallTimeout = const Duration(seconds: 20),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final instance = ProgressiveStreamServer._(server, stallTimeout);
    server.listen(
      instance._handleRequest,
      onError: (Object _) {
        /* A failed request stream cannot affect the other players. */
      },
      cancelOnError: false,
    );
    return instance;
  }

  /// Exposes [source] under an unguessable path and returns its URL.
  Uri mount(ProgressiveSource source) {
    final token = List<int>.generate(
      16,
      (_) => _rng.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    _sources[token] = source;
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: _server.port,
      path: '/$token.mp4',
    );
  }

  void revoke(Uri uri) {
    final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    _sources.remove(name.split('.').first);
  }

  Future<void> close() async {
    _sources.clear();
    await _server.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    final segments = request.uri.pathSegments;
    final name = segments.length == 1 ? segments.single : '';
    final source = name.endsWith('.mp4')
        ? _sources[name.substring(0, name.length - 4)]
        : null;
    if (source == null) {
      response
        ..contentLength = 0
        ..statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final total = source.total;
    final range = _parseRange(
      request.headers.value(HttpHeaders.rangeHeader),
      total,
    );
    if (range.rejected) {
      response
        ..contentLength = 0
        ..headers.set(HttpHeaders.contentRangeHeader, '*/$total')
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await response.close();
      return;
    }
    // Unbuffered: a response that is cut short by a stall still has to have
    // delivered every byte it already wrote, which Dart's output buffer would
    // otherwise drop on the early close.
    response
      ..bufferOutput = false
      ..headers.contentType = ContentType('video', 'mp4')
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..contentLength = range.end - range.start + 1
      ..statusCode = range.partial ? HttpStatus.partialContent : HttpStatus.ok;
    if (range.partial) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${range.start}-${range.end}/$total',
      );
    }
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    var cursor = range.start;
    try {
      while (cursor <= range.end) {
        final available = source.availableBytes;
        if (cursor >= available) {
          if (!await source.readyFor(cursor + 1, stallTimeout)) break;
          continue;
        }
        final bytes = await source.read(
          cursor,
          min(min(_chunkBytes, range.end + 1 - cursor), available - cursor),
        );
        if (bytes.isEmpty) break;
        response.add(bytes);
        cursor += bytes.length;
        await response.flush();
      }
    } on Object {
      // A stalled transfer, a vanished file or a hung-up player all end this
      // response early; the player re-requests what it still needs.
    }
    if (cursor == range.start) {
      // Nothing was ever written, so the header block is still ours: a seek
      // into bytes the download has not reached is a plain 416 rather than a
      // half-promised body.
      response
        ..contentLength = 0
        ..headers.set(HttpHeaders.contentRangeHeader, '*/$total')
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable;
    }
    try {
      await response.close();
    } on Object {
      /* the player gave up first */
    }
  }
}

class _Range {
  const _Range(this.start, this.end) : partial = false, rejected = false;
  const _Range.partialRange(this.start, this.end)
    : partial = true,
      rejected = false;
  const _Range.reject() : start = 0, end = -1, partial = false, rejected = true;

  final int start;
  final int end;
  final bool partial;
  final bool rejected;
}

/// A header we cannot parse is served as a full body, as RFC 7233 asks of a
/// recipient-side failure; an out-of-range one is a 416.
_Range _parseRange(String? header, int length) {
  if (length <= 0) return const _Range.reject();
  final whole = _Range(0, length - 1);
  if (header == null || header.isEmpty) return whole;
  const prefix = 'bytes=';
  if (!header.startsWith(prefix)) return whole;
  final clause = header.substring(prefix.length).split(',').first.trim();
  final dash = clause.indexOf('-');
  if (dash < 0) return whole;
  final rawStart = clause.substring(0, dash).trim();
  final rawEnd = clause.substring(dash + 1).trim();
  if (rawStart.isEmpty) {
    final suffix = int.tryParse(rawEnd);
    if (suffix == null || suffix <= 0) return const _Range.reject();
    return suffix >= length
        ? whole
        : _Range.partialRange(length - suffix, length - 1);
  }
  final start = int.tryParse(rawStart);
  if (start == null || start >= length) return const _Range.reject();
  final end = rawEnd.isEmpty
      ? length - 1
      : min(int.tryParse(rawEnd) ?? length - 1, length - 1);
  if (start > end) return const _Range.reject();
  return start == 0 && end == length - 1
      ? whole
      : _Range.partialRange(start, end);
}
