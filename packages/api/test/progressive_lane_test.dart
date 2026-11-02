import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_native_api.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

Uint8List bytes(String name) =>
    File('../core/test/fixtures/media/$name').readAsBytesSync();

final realKey =
    jsonDecode(
          File('../core/test/fixtures/media/real.json').readAsStringSync(),
        )['key']
        as String;

/// Plays the role of the origin for the metadata regions the transfer has not
/// reached: answers every window of [source] that is asked for.
ProgressiveRangeReader wholeSource(Uint8List source) =>
    (start, endInclusive) async {
      if (start >= source.length) return null;
      final end = endInclusive + 1 > source.length
          ? source.length
          : endInclusive + 1;
      return Uint8List.fromList(Uint8List.sublistView(source, start, end));
    };

/// A cache job seen from the lane's side: a growing `.part` file plus the
/// reports a transfer makes while it runs.
class _Harness {
  _Harness({
    required this.temp,
    required this.server,
    required this.source,
    required String key,
    required ProgressiveRangeReader fetchRange,
    required int openFloorBytes,
    required int metadataBudgetBytes,
  }) {
    part = File('${temp.path}/x.part')..writeAsBytesSync(Uint8List(0));
    clearPath = '${temp.path}/published.mp4';
    lane = ProgressiveLane(
      encryptedPath: part.path,
      clearPath: clearPath,
      keyHex: key,
      fetchRange: fetchRange,
      server: server,
      openFloorBytes: openFloorBytes,
      metadataBudgetBytes: metadataBudgetBytes,
    );
  }

  final Directory temp;
  final ProgressiveStreamServer server;
  final Uint8List source;
  late final File part;
  late final String clearPath;
  late final ProgressiveLane lane;
  int written = 0;

  /// Appends the next [chunk] ciphertext bytes and reports them, the way a
  /// download progress callback does.
  Future<void> feed(int chunk, {int? total}) async {
    written = (written + chunk).clamp(0, source.length);
    part.writeAsBytesSync(
      Uint8List.sublistView(source, 0, written),
      mode: FileMode.write,
      flush: true,
    );
    lane.notify(written, total ?? source.length);
    await Future<void>.delayed(Duration.zero);
  }

  /// The whole ciphertext at once, without a single report.
  Future<void> writeAll() async {
    written = source.length;
    part.writeAsBytesSync(source, flush: true);
  }
}

final _openLanes = <Future<void> Function()>[];
final _liveLanes = <ProgressiveLane>[];

Future<_Harness> lane(
  Uint8List source, {
  String? key,
  ProgressiveRangeReader? fetchRange,
  int openFloorBytes = 0,
  int metadataBudgetBytes = 8 * 1024 * 1024,
}) async {
  final temp = Directory.systemTemp.createTempSync('hongguo-lane-');
  final server = await ProgressiveStreamServer.bind();
  final value = _Harness(
    temp: temp,
    server: server,
    source: source,
    key: key ?? realKey,
    fetchRange: fetchRange ?? wholeSource(source),
    openFloorBytes: openFloorBytes,
    metadataBudgetBytes: metadataBudgetBytes,
  );
  _liveLanes.add(value.lane);
  // A live lane still holds its working file open; Windows refuses to delete
  // the directory until those handles are gone.
  _openLanes.add(() async {
    await server.close();
    await temp.delete(recursive: true);
  });
  return value;
}

/// Minimal range client: the shape of what a demuxer does to an origin.
Future<({int status, Uint8List body})> _get(Uri uri, {String? range}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl('GET', uri);
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

void main() {
  late Uint8List source;
  late Mp4Plan layout;
  late int mdatStart;

  setUp(() {
    source = bytes('real.cenc.mp4');
    layout = Mp4Cenc.inspect(MemorySampleStore(source));
    mdatStart = layout.top.firstWhere((b) => b.type == 'mdat').start;
  });
  tearDown(() async {
    for (final value in _liveLanes) {
      await value.discard();
    }
    _liveLanes.clear();
    for (final dispose in _openLanes) {
      try {
        await dispose();
      } finally {
        /* one locked directory cannot hide the other leaks */
      }
    }
    _openLanes.clear();
  });

  group('plan from a partial download', () {
    test('the tail moov arrives by range, not by waiting', () async {
      final harness = await lane(source);
      // One head-sized delivery: nothing near the moov is on disk yet.
      await harness.feed(512);
      final url = await harness.lane.playable.timeout(
        const Duration(seconds: 5),
      );
      expect(url, isNotNull);
      expect(harness.written, lessThan(layout.moov.start));
      expect(
        harness.lane.availableBytes,
        greaterThanOrEqualTo(layout.moov.size),
      );
    });

    test('the announced stream plays over http and finishes clear', () async {
      final harness = await lane(source);
      await harness.feed(512);
      final url = Uri.parse((await harness.lane.playable)!);
      final early = await _get(url, range: 'bytes=0-63');
      expect(early.status, HttpStatus.partialContent);

      while (harness.written < source.length) {
        await harness.feed(4096);
      }
      expect(await harness.lane.finish(source.length), harness.clearPath);

      final whole = await _get(url);
      expect(whole.status, HttpStatus.ok);
      expect(whole.body, File(harness.clearPath).readAsBytesSync());
      final reparsed = Mp4Cenc.inspect(MemorySampleStore(whole.body));
      expect(reparsed.encryptedSamples, 0);
      expect(reparsed.moov.start, mdatStart);
      expect(
        reparsed.top.firstWhere((b) => b.type == 'mdat').payload,
        mdatStart + layout.moov.size + 8,
      );
    });

    test('finish without any report streams the whole file', () async {
      final harness = await lane(source);
      // The transfer never called back: the final size alone is enough.
      await harness.writeAll();
      expect(await harness.lane.finish(source.length), harness.clearPath);
      final out = File(harness.clearPath).readAsBytesSync();
      expect(out.length, source.length);
      expect(Mp4Cenc.inspect(MemorySampleStore(out)).encryptedSamples, 0);
      expect(await harness.lane.playable, isNotNull);
    });

    test('a head-moov file keeps its layout', () async {
      final head = bytes('head.cenc.mp4');
      final headLayout = Mp4Cenc.inspect(MemorySampleStore(head));
      final harness = await lane(head);
      await harness.writeAll();
      expect(await harness.lane.finish(head.length), harness.clearPath);
      final reparsed = Mp4Cenc.inspect(
        MemorySampleStore(File(harness.clearPath).readAsBytesSync()),
      );
      expect(reparsed.encryptedSamples, 0);
      expect(reparsed.moov.start, headLayout.moov.start);
      expect(reparsed.moov.size, headLayout.moov.size);
    });
  });

  group('giving up', () {
    test('an unencrypted file is refused before a byte is written', () async {
      final plain = bytes('clear.mp4');
      final harness = await lane(plain, key: '');
      await harness.writeAll();
      expect(await harness.lane.finish(plain.length), isNull);
      expect(await harness.lane.playable, isNull);
      expect(File(harness.clearPath).existsSync(), isFalse);
    });

    test('a refused range backfill ends the lane', () async {
      final harness = await lane(
        source,
        fetchRange: (start, end) async => null,
      );
      await harness.feed(512);
      expect(await harness.lane.playable, isNull);
      expect(harness.lane.failure, isNotNull);
      expect(File(harness.clearPath).existsSync(), isFalse);
    });

    test('a budget smaller than the moov ends the lane', () async {
      final harness = await lane(source, metadataBudgetBytes: 64);
      await harness.feed(512);
      expect(await harness.lane.playable, isNull);
      expect(File(harness.clearPath).existsSync(), isFalse);
    });

    test('a transfer whose length changed is not streamed', () async {
      final harness = await lane(source);
      await harness.feed(512);
      await harness.feed(512, total: source.length + 1);
      expect(await harness.lane.playable, isNull);
      expect(harness.lane.failure, isNotNull);
    });

    test('discard unmounts and removes the half-written stream', () async {
      final harness = await lane(source);
      await harness.feed(512);
      final url = Uri.parse((await harness.lane.playable)!);
      expect(File(harness.clearPath).existsSync(), isTrue);
      await harness.lane.discard();
      expect(File(harness.clearPath).existsSync(), isFalse);
      expect((await _get(url)).status, HttpStatus.notFound);
    });

    test('detach keeps the published file and closes the mount', () async {
      final harness = await lane(source);
      await harness.writeAll();
      expect(await harness.lane.finish(source.length), harness.clearPath);
      final url = Uri.parse((await harness.lane.playable)!);
      await harness.lane.detach();
      expect(File(harness.clearPath).existsSync(), isTrue);
      expect((await _get(url)).status, HttpStatus.notFound);
      // Idempotent: a pin release that arrives late changes nothing.
      await harness.lane.detach();
    });
  });

  group('range fetcher', () {
    test('asks the origin for exactly the window and headers', () async {
      final seen = <RequestOptions>[];
      final dio = Dio()..httpClientAdapter = _EchoAdapter(source, seen);
      final fetch = progressiveRangeFetcher(
        dio,
        Uri.parse('https://a.qznovelvod.com/x.mp4'),
      );
      expect(
        await fetch(100, 199),
        Uint8List.fromList(source.sublist(100, 200)),
      );
      expect(seen.single.headers['Range'], 'bytes=100-199');
      expect(seen.single.headers['User-Agent'], 'Mozilla/5.0');
      dio.close(force: true);
    });

    test('ignores an origin that answers a mid-file window with 200', () async {
      final dio = Dio()..httpClientAdapter = _WholeAdapter(source);
      final fetch = progressiveRangeFetcher(
        dio,
        Uri.parse('https://a.qznovelvod.com/x.mp4'),
      );
      expect(await fetch(100, 199), isNull);
      expect(await fetch(0, 99), Uint8List.fromList(source.sublist(0, 100)));
      dio.close(force: true);
    });
  });
}

/// Serves the requested `bytes=start-end` window as a 206.
class _EchoAdapter implements HttpClientAdapter {
  final Uint8List source;
  final List<RequestOptions> seen;
  _EchoAdapter(this.source, this.seen);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    final header = (options.headers[HttpHeaders.rangeHeader] ?? '') as String;
    final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(header);
    if (match == null) return ResponseBody.fromBytes(const [], 400);
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

/// A misbehaving origin: always the whole body, whatever was asked.
class _WholeAdapter implements HttpClientAdapter {
  final Uint8List source;
  _WholeAdapter(this.source);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes(
    source,
    HttpStatus.ok,
    headers: {
      Headers.contentLengthHeader: ['${source.length}'],
    },
  );

  @override
  void close({bool force = false}) {}
}
