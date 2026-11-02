import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:hongguo_api/hongguo_native_api.dart';
import 'package:test/test.dart';

/// An in-memory progressive lane: [delivered] is what the writer has flushed.
class FakeSource implements ProgressiveSource {
  final Uint8List all;
  int delivered;
  int reads = 0;
  FakeSource(this.all, this.delivered);

  @override
  int get total => all.length;

  @override
  int get availableBytes => delivered;

  @override
  Future<Uint8List> read(int start, int length) async {
    reads++;
    if (length <= 0 || start < 0 || start + length > delivered) {
      throw const FormatException('Read beyond the delivered prefix');
    }
    return Uint8List.sublistView(all, start, start + length);
  }

  @override
  Future<bool> readyFor(int position, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (delivered < position) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return false;
      await Future<void>.delayed(
        remaining < const Duration(milliseconds: 5)
            ? remaining
            : const Duration(milliseconds: 5),
      );
    }
    return true;
  }
}

class _Response {
  final int status;
  final HttpHeaders headers;
  final Uint8List body;
  final bool truncated;
  _Response(this.status, this.headers, this.body, this.truncated);

  int? get contentLength => int.tryParse(headers.value('content-length') ?? '');
}

Future<_Response> _fetch(Uri uri, {String? range, bool head = false}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = head ? await client.headUrl(uri) : await client.getUrl(uri);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    final body = BytesBuilder(copy: false);
    var truncated = false;
    try {
      await for (final chunk in response) {
        body.add(chunk);
      }
    } on Object {
      // The origin cut a promised-length body short, exactly what a stalled
      // download looks like to a player.
      truncated = true;
    }
    return _Response(
      response.statusCode,
      response.headers,
      body.toBytes(),
      truncated,
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  late ProgressiveStreamServer server;
  late FakeSource source;
  late Uri uri;
  final all = Uint8List.fromList(List.generate(4096, (i) => i % 251));

  setUp(() async {
    // A short stall timeout keeps the truncation cases fast.
    server = await ProgressiveStreamServer.bind(
      stallTimeout: const Duration(milliseconds: 60),
    );
    source = FakeSource(all, 1000);
    uri = server.mount(source);
  });

  tearDown(() => server.close());

  test('binds to loopback only and hides the token from other paths', () async {
    expect(uri.host, '127.0.0.1');
    expect(uri.pathSegments.single.endsWith('.mp4'), isTrue);
    final other = uri.replace(path: '/not-ours.mp4');
    expect((await _fetch(other)).status, HttpStatus.notFound);
    expect((await _fetch(uri.replace(path: '/'))).status, HttpStatus.notFound);
  });

  test('HEAD advertises the final length and byte ranges', () async {
    final response = await _fetch(uri, head: true);
    expect(response.status, HttpStatus.ok);
    expect(response.contentLength, all.length);
    expect(response.body, isEmpty);
    expect(response.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
    expect(response.headers.contentType?.mimeType, 'video/mp4');
  });

  test('an unseekable range header is served as the whole body', () async {
    source.delivered = all.length;
    final response = await _fetch(uri, range: 'items=0-9');
    expect(response.status, HttpStatus.ok);
    expect(response.body.length, all.length);
  });

  test('range windows are served as 206 slices', () async {
    source.delivered = all.length;
    final response = await _fetch(uri, range: 'bytes=100-199');
    expect(response.status, HttpStatus.partialContent);
    expect(response.contentLength, 100);
    expect(response.body, all.sublist(100, 200));
    expect(
      response.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 100-199/${all.length}',
    );
    final open = await _fetch(uri, range: 'bytes=4000-');
    expect(open.status, HttpStatus.partialContent);
    expect(open.body, all.sublist(4000));
    final suffix = await _fetch(uri, range: 'bytes=-16');
    expect(suffix.body, all.sublist(all.length - 16));
  });

  test('ranges past the final length get 416', () async {
    for (final range in ['bytes=4096-', 'bytes=9999-10000', 'bytes=abc-def']) {
      final response = await _fetch(uri, range: range);
      expect(
        response.status,
        HttpStatus.requestedRangeNotSatisfiable,
        reason: range,
      );
      expect(response.body, isEmpty);
    }
  });

  test('a stall cuts the body at the contiguous prefix', () async {
    final response = await _fetch(uri, range: 'bytes=0-2000');
    expect(response.status, HttpStatus.partialContent);
    expect(response.body, all.sublist(0, 1000));
    expect(response.truncated, isTrue);
  });

  test('bytes written while a request waits extend what it receives', () async {
    final pending = _fetch(uri, range: 'bytes=0-2000');
    final timer = Timer(const Duration(milliseconds: 20), () {
      source.delivered = all.length;
    });
    final response = await pending;
    timer.cancel();
    // `bytes=0-2000` is an inclusive window: 2001 bytes.
    expect(response.body, all.sublist(0, 2001));
    expect(response.truncated, isFalse);
  });

  test('a seek into undelivered bytes waits, then answers 416', () async {
    final response = await _fetch(uri, range: 'bytes=3000-3100');
    expect(response.status, HttpStatus.requestedRangeNotSatisfiable);
    expect(response.body, isEmpty);
    expect(response.truncated, isFalse);
    expect(
      response.headers.value(HttpHeaders.contentRangeHeader),
      '*/${all.length}',
    );
    expect(source.reads, 0);
  });

  test('revoking the lease stops serving', () async {
    server.revoke(uri);
    expect((await _fetch(uri, head: true)).status, HttpStatus.notFound);
  });

  group('file source', () {
    late Directory temp;
    late String path;
    setUp(() {
      temp = Directory.systemTemp.createTempSync('hongguo-progressive-');
      path = '${temp.path}/x.stream';
      File(path).writeAsBytesSync(Uint8List(0));
    });
    tearDown(() => temp.deleteSync(recursive: true));

    ProgressiveFileSource source() => ProgressiveFileSource(
      path,
      total: 300,
      pollInterval: const Duration(milliseconds: 10),
    );

    test('tracks the bytes the writer has flushed', () async {
      final live = source();
      expect(live.availableBytes, 0);
      File(path).writeAsBytesSync(Uint8List(100));
      expect(live.availableBytes, 100);
      expect(await live.read(0, 100), Uint8List(100));
      await expectLater(live.read(0, 101), throwsFormatException);
      await expectLater(live.read(100, 1), throwsFormatException);
      // A file longer than the plan is still clamped to it.
      File(path).writeAsBytesSync(Uint8List(400));
      expect(live.availableBytes, 300);
    });

    test('a wait is satisfied by growth and refused past the plan', () async {
      final live = source();
      final pending = live.readyFor(300, const Duration(seconds: 2));
      Timer(const Duration(milliseconds: 30), () {
        File(path).writeAsBytesSync(Uint8List(300));
      });
      expect(await pending, isTrue);
      expect(
        await live.readyFor(301, const Duration(milliseconds: 50)),
        isFalse,
      );
      expect(await live.readyFor(1, const Duration(milliseconds: 50)), isTrue);
    });

    test('the origin plays a file that is still being written', () async {
      final streamer = await ProgressiveStreamServer.bind(
        stallTimeout: const Duration(seconds: 2),
      );
      try {
        final live = source();
        final url = streamer.mount(live);
        File(path).writeAsBytesSync(Uint8List(120));
        final head = await _fetch(url, head: true);
        expect(head.contentLength, 300);
        final pending = _fetch(url, range: 'bytes=0-');
        Timer(const Duration(milliseconds: 40), () {
          File(path).writeAsBytes(
            Uint8List.fromList([for (var i = 120; i < 300; i++) i % 251]),
            mode: FileMode.append,
            flush: true,
          );
        });
        final response = await pending;
        expect(response.body.length, 300);
        expect(response.body[299], 299 % 251);
        expect(response.truncated, isFalse);
      } finally {
        await streamer.close();
      }
    });
  });
}
