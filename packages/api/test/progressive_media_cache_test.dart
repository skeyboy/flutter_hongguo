import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_api/hongguo_native_api.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_core/hongguo_native.dart';
import 'package:test/test.dart';

const _chunkBytes = 2048;

Uint8List bytes(String name) =>
    File('../core/test/fixtures/media/$name').readAsBytesSync();

/// A transfer the test drives one chunk at a time, with a pause the lane has
/// to ride through: mid-download behaviour is only observable while the
/// download is still inside this await.
class _GatedTransfer {
  final Uint8List source;

  int calls = 0;
  bool paused = false;
  final gate = Completer<void>();
  _GatedTransfer(this.source);

  Future<void> call(
    String vid,
    String quality,
    VideoTrack track,
    String path,
    CancelToken token,
    void Function(int received, int total) progress,
  ) async {
    calls++;
    final file = File(path);
    for (var at = 0; at < source.length; at += _chunkBytes) {
      if (token.isCancelled) return;
      final end = min(at + _chunkBytes, source.length);
      file.writeAsBytesSync(
        Uint8List.sublistView(source, 0, end),
        mode: FileMode.write,
        flush: true,
      );
      progress(end, source.length);
      if (!paused) {
        paused = true;
        // A real transfer gives up when its token is cancelled; a gate that
        // only answers [gate] would park this write past the cancellation.
        await Future.any([gate.future, token.whenCancel]);
      }
    }
  }
}

/// Answers `bytes=start-end` the way the real origin does, which is what lets
/// a lane read a tail moov before the transfer reaches it.
class _RangeAdapter implements HttpClientAdapter {
  final Uint8List source;
  int rangeRequests = 0;
  _RangeAdapter(this.source);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async {
    final header = (options.headers[HttpHeaders.rangeHeader] ?? '') as String;
    final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(header);
    if (match == null) {
      return ResponseBody.fromBytes(
        source,
        HttpStatus.ok,
        headers: {
          Headers.contentLengthHeader: ['${source.length}'],
        },
      );
    }
    rangeRequests++;
    final start = int.parse(match.group(1)!);
    final end = int.parse(match.group(2)!);
    return ResponseBody.fromBytes(
      source.sublist(start, end + 1),
      HttpStatus.partialContent,
      headers: {
        Headers.contentLengthHeader: ['${end - start + 1}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Answers the transfer but refuses every range request, so a lane that needs
/// the tail moov has no way to build a plan.
class _NoRangeAdapter implements HttpClientAdapter {
  final Uint8List source;
  int rangeRequests = 0;
  _NoRangeAdapter(this.source);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async {
    if (options.headers[HttpHeaders.rangeHeader] != null) {
      rangeRequests++;
      return ResponseBody.fromBytes(
        const [],
        HttpStatus.requestedRangeNotSatisfiable,
      );
    }
    return ResponseBody.fromBytes(
      source,
      HttpStatus.ok,
      headers: {
        Headers.contentLengthHeader: ['${source.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

bool _containsAscii(List<int> bytes, String needle) {
  final codes = needle.codeUnits;
  for (var at = 0; at + codes.length <= bytes.length; at++) {
    var hit = true;
    for (var i = 0; i < codes.length; i++) {
      if (bytes[at + i] != codes[i]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

Future<({int status, Uint8List body})> _get(Uri uri, {String? range}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    final body = BytesBuilder(copy: false);
    await for (final chunk in response) {
      body.add(chunk);
    }
    return (status: response.statusCode, body: body.toBytes());
  } finally {
    client.close(force: true);
  }
}

/// Cleanup after a cancellation runs in the preparation's `finally`, which is
/// already past the point where the lease errored, so the assertions have to
/// wait for that tail rather than race it.
Future<void> _settled(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('the cancelled preparation never finished cleaning up');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory temp;
  late Uint8List source;
  late VideoTrack track;
  late int mdatStart, moovSize;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('hongguo-progressive-cache-');
    source = bytes('real.cenc.mp4');
    final layout = Mp4Cenc.inspect(MemorySampleStore(source));
    mdatStart = layout.top.firstWhere((b) => b.type == 'mdat').start;
    moovSize = layout.moov.size;
    final oracle = jsonDecode(
      File('../core/test/fixtures/node_oracle.json').readAsStringSync(),
    );
    track = VideoTrack(
      url: Uri.parse('https://a.qznovelvod.com/test.mp4'),
      spadeA: base64Encode(
        unhex((oracle['spade'] as List)[0]['raw'] as String),
      ),
      definition: '720p',
      size: source.length,
    );
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  MediaCache cacheFor({
    required _GatedTransfer transfer,
    bool Function()? progressivePlayback,
    HttpClientAdapter? adapter,
  }) {
    final dio = Dio()..httpClientAdapter = adapter ?? _RangeAdapter(source);
    return MediaCache(
      directory: temp,
      dio: dio,
      resolve: (_, _) async => track,
      download: transfer.call,
      progressivePlayback: progressivePlayback,
      // The fixture is smaller than a real episode's open floor.
      progressiveOpenFloorBytes: 0,
    );
  }

  List<String> leftovers() => temp
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((name) => name.endsWith('.part') || name.endsWith('.part.json'))
      .toList();

  test('the stream is playable while the transfer is still paused', () async {
    final transfer = _GatedTransfer(source);
    final cache = cacheFor(transfer: transfer, progressivePlayback: () => true);
    addTearDown(cache.close);
    final job = cache.prepare('11');
    final url = await job.early.timeout(const Duration(seconds: 5));
    expect(url, isNotNull);
    // Mid-download: the cache file exists but is not yet a hit.
    final partial = File('${temp.path}/11_best.mp4');
    expect(partial.lengthSync(), lessThan(source.length));
    expect(File('${temp.path}/11_best.mp4.json').existsSync(), isFalse);
    // The early URL already serves clear, moov-first bytes. The window is
    // bounded by what the writer has published: an unbounded GET would ask
    // the origin to hold a response open until the paused transfer resumes.
    final prefix = partial.lengthSync();
    final served = (await _get(
      Uri.parse(url!),
      range: 'bytes=0-${prefix - 1}',
    )).body;
    expect(served.length, prefix);
    // The output only grows, so the served window is exactly its head.
    expect(served, partial.readAsBytesSync().sublist(0, prefix));
    // Faststart, already: the patched moov sits where the mdat header was,
    // and its encryption signalling is gone.
    expect(served.length, greaterThan(mdatStart + 8));
    expect(latin1.decode(served.sublist(mdatStart + 4, mdatStart + 8)), 'moov');
    final moovWindow = served.sublist(mdatStart, mdatStart + moovSize);
    for (final marker in ['encv', 'enca', 'sinf', 'pssh']) {
      expect(
        _containsAscii(moovWindow, marker),
        isFalse,
        reason: '$marker still signals encryption',
      );
    }

    transfer.gate.complete();
    final path = await job.result.timeout(const Duration(seconds: 10));
    expect(path, endsWith('11_best.mp4'));
    await FileDecryptor.validateClear(path);
    expect(File('$path.json').existsSync(), isTrue);
    expect(leftovers(), isEmpty);
    cache.release(job);
  });

  test('a stream published mid-download is a cache hit afterwards', () async {
    final transfer = _GatedTransfer(source);
    final cache = cacheFor(transfer: transfer, progressivePlayback: () => true);
    final job = cache.prepare('11');
    expect(await job.early, isNotNull);
    transfer.gate.complete();
    final path = await job.result;
    expect(File('$path.json').existsSync(), isTrue);
    cache.release(job);
    await cache.prune();

    // The second preparation never touches the network again.
    final again = _GatedTransfer(source);
    final reopened = MediaCache(
      directory: temp,
      dio: Dio()..httpClientAdapter = _NoRangeAdapter(source),
      resolve: (_, _) async => throw StateError('Cache should avoid network'),
      download: again.call,
      progressivePlayback: () => true,
      progressiveOpenFloorBytes: 0,
    );
    addTearDown(reopened.close);
    final hit = reopened.prepare('11');
    expect(await hit.early, isNull);
    expect(await hit.result, endsWith('11_best.mp4'));
    expect(again.calls, 0);
    reopened.release(hit);
    cache.close();
  });

  test('a disabled setting keeps the whole-file pipeline', () async {
    final transfer = _GatedTransfer(source);
    final cache = cacheFor(transfer: transfer);
    addTearDown(cache.close);
    final stages = <MediaStage>[];
    final job = cache.prepare('12', onProgress: (p) => stages.add(p.stage));
    transfer.gate.complete();
    final early = await job.early.timeout(const Duration(seconds: 5));
    expect(early, isNull);
    final path = await job.result;
    expect(
      stages,
      containsAll([MediaStage.downloading, MediaStage.decrypting]),
    );
    await FileDecryptor.validateClear(path);
    expect(File('$path.json').existsSync(), isTrue);
    expect(leftovers(), isEmpty);
    cache.release(job);
  });

  test(
    'an origin without range support falls back to whole-file decrypt',
    () async {
      final adapter = _NoRangeAdapter(source);
      final transfer = _GatedTransfer(source);
      final cache = cacheFor(
        transfer: transfer,
        progressivePlayback: () => true,
        adapter: adapter,
      );
      addTearDown(cache.close);
      final job = cache.prepare('13');
      transfer.gate.complete();
      expect(await job.early, isNull);
      final path = await job.result;
      expect(adapter.rangeRequests, greaterThan(0));
      await FileDecryptor.validateClear(path);
      // The half-written stream was taken back, so the published file is the
      // only copy and it is complete.
      expect(File(path).lengthSync(), source.length);
      expect(leftovers(), isEmpty);
      cache.release(job);
    },
  );

  test('cancelling mid-stream leaves no file and no mount', () async {
    final transfer = _GatedTransfer(source);
    final cache = cacheFor(transfer: transfer, progressivePlayback: () => true);
    addTearDown(cache.close);
    final job = cache.prepare('14');
    final url = Uri.parse((await job.early)!);
    final cancelled = expectLater(job.result, throwsA(isA<MediaCancelled>()));
    job.cancel();
    await cancelled;
    final clear = File('${temp.path}/14_best.mp4');
    await _settled(
      () =>
          !clear.existsSync() &&
          !File('${clear.path}.json').existsSync() &&
          leftovers().isEmpty,
    );
    expect(await cache.entries(), isEmpty);
    expect((await _get(url)).status, HttpStatus.notFound);
  });

  test('an unencrypted source is never streamed', () async {
    final plain = bytes('clear.mp4');
    track = VideoTrack(
      url: track.url,
      spadeA: '',
      definition: '720p',
      size: plain.length,
    );
    final transfer = _GatedTransfer(plain);
    final cache = cacheFor(
      transfer: transfer,
      progressivePlayback: () => true,
      adapter: _NoRangeAdapter(plain),
    );
    addTearDown(cache.close);
    final job = cache.prepare('15');
    transfer.gate.complete();
    expect(await job.early, isNull);
    expect(await job.result, endsWith('15_best.mp4'));
    expect(leftovers(), isEmpty);
    cache.release(job);
  });
}
