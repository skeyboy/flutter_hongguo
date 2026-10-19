import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_flutter/adapters/native/media_repository.dart';
import 'package:hongguo_flutter/adapters/native/file_store.dart';

class NoTransport implements Transport {
  @override
  Future<TransportResponse> send(TransportRequest request) =>
      throw StateError('No upstream calls allowed in fixture tests');
}

class FixtureSource extends AppSource {
  final PlaybackTrack track;
  int calls = 0;
  FixtureSource(this.track) : super(SignedClient(NoTransport()));
  @override
  Future<PlaybackTrack> fetch(String vid, {String quality = 'best'}) async {
    calls++;
    return track;
  }
}

void main() {
  late Directory cache;
  late HttpServer server;
  late FixtureSource source;
  late NativePlaybackRepository repository;
  var downloads = 0;
  final bytes = File(
    '../../packages/hongguo_core/test/fixtures/spade-media.mp4',
  ).readAsBytesSync();
  final truths =
      jsonDecode(
            File(
              '../../packages/hongguo_core/test/fixtures/spade.json',
            ).readAsStringSync(),
          )
          as List;
  final spade = base64Encode(unhex(truths[0][0]));
  setUp(() async {
    cache = await Directory.systemTemp.createTemp('hongguo-dart-media-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    downloads = 0;
    server.listen((request) async {
      downloads++;
      if (request.uri.path == '/redirect') {
        request.response.statusCode = 302;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'https://example.invalid/media',
        );
      } else if (request.uri.path == '/bad') {
        request.response.add([1, 2, 3, 4]);
      } else {
        request.response.add(bytes);
      }
      await request.response.close();
    });
    source = FixtureSource(
      PlaybackTrack(
        url: Uri.parse('http://127.0.0.1:${server.port}/fixture'),
        spadeA: spade,
      ),
    );
    repository = NativePlaybackRepository(source, cache);
  });
  tearDown(() async {
    await server.close(force: true);
    await cache.delete(recursive: true);
  });
  test(
    'Native streaming download, isolate decrypt, publish, restart cache hit',
    () async {
      final states = <PreparationState>[];
      final ready = await repository.prepare('123', onState: states.add);
      expect(ready.isLocal, isTrue);
      expect(states, [
        PreparationState.queued,
        PreparationState.downloading,
        PreparationState.decrypting,
        PreparationState.remuxing,
        PreparationState.ready,
      ]);
      final file = File(ready.location).openSync();
      try {
        final store = NativeFileStore(file),
            span = findMoov(store),
            analysis = analyzeMp4(
              ByteView(store.read(span.start, span.size), span.start),
            );
        final plain = jsonDecode(
          File(
            '../../packages/hongguo_core/test/fixtures/mp4.json',
          ).readAsStringSync(),
        );
        expect(analysis.tracks.single.encrypted, isFalse);
        for (var i = 0; i < 2; i++) {
          final t = analysis.tracks.single;
          expect(
            hex(store.read(t.offsets[i], t.sizes[i])),
            plain['samples'][i],
          );
        }
      } finally {
        file.closeSync();
      }
      expect(File('${ready.location}.ready.json').existsSync(), isTrue);
      final restarted = NativePlaybackRepository(source, cache);
      expect((await restarted.prepare('123')).location, ready.location);
      expect(source.calls, 1);
      expect(downloads, 1);
    },
  );
  test('Concurrent same-key requests share completed artifact', () async {
    final results = await Future.wait([
      repository.prepare('456'),
      repository.prepare('456'),
    ]);
    expect(results[0].location, results[1].location);
    expect(downloads, 1);
    expect(source.calls, 1);
  });
  test('Invalid MP4 is never published and retry fetches again', () async {
    final bad = FixtureSource(
      PlaybackTrack(url: Uri.parse('http://127.0.0.1:${server.port}/bad')),
    );
    final repo = NativePlaybackRepository(bad, cache);
    await expectLater(repo.prepare('789'), throwsA(isA<Exception>()));
    expect(await cache.list().toList(), isEmpty);
    await expectLater(repo.prepare('789'), throwsA(isA<Exception>()));
    expect(downloads, 2);
  });
  test('Cancellation during download removes partial files', () async {
    final token = CancellationToken();
    await expectLater(
      repository.prepare(
        '100',
        cancellation: token,
        onState: (s) {
          if (s == PreparationState.downloading) token.cancel();
        },
      ),
      throwsA(isA<PreparationCancelled>()),
    );
    expect(await cache.list().toList(), isEmpty);
  });
  test('Cancellation before queued task prevents a source request', () async {
    final token = CancellationToken()..cancel();
    await expectLater(
      repository.prepare('200', cancellation: token),
      throwsA(isA<PreparationCancelled>()),
    );
    expect(source.calls, 0);
  });
  test('Cache eviction removes old artifact and marker', () async {
    final repo = NativePlaybackRepository(source, cache, maxFiles: 1);
    final a = await repo.prepare('111');
    final b = await repo.prepare('222');
    expect(File(a.location).existsSync(), isFalse);
    expect(File('${a.location}.ready.json').existsSync(), isFalse);
    expect(File(b.location).existsSync(), isTrue);
  });
  test(
    'An untrusted media redirect is rejected before another request',
    () async {
      final redirected = FixtureSource(
        PlaybackTrack(
          url: Uri.parse('http://127.0.0.1:${server.port}/redirect'),
        ),
      );
      final repo = NativePlaybackRepository(redirected, cache);
      await expectLater(repo.prepare('333'), throwsA(isA<HttpException>()));
      expect(downloads, 1);
      expect(await cache.list().toList(), isEmpty);
    },
  );
}
