import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_api/hongguo_native_api.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_core/hongguo_native.dart';
import 'package:test/test.dart';

class BytesAdapter implements HttpClientAdapter {
  final Uint8List bytes;
  int downloads = 0;
  BytesAdapter(this.bytes);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async {
    downloads++;
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        Headers.contentLengthHeader: ['${bytes.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory temp;
  late Dio dio;
  late BytesAdapter adapter;
  late MediaCache cache;
  late VideoTrack track;
  late String spade;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('hongguo-cache-');
    adapter = BytesAdapter(
      File('../core/test/fixtures/media/real.cenc.mp4').readAsBytesSync(),
    );
    dio = Dio()..httpClientAdapter = adapter;
    final fixture = jsonDecode(
      File('../core/test/fixtures/node_oracle.json').readAsStringSync(),
    );
    spade = base64Encode(unhex(fixture['spade'][0]['raw']));
    track = VideoTrack(
      url: Uri.parse('https://a.qznovelvod.com/test.mp4'),
      spadeA: spade,
      definition: '720p',
      size: 0,
    );
    cache = MediaCache(
      directory: temp,
      dio: dio,
      resolve: (_, _) async => track,
    );
  });
  tearDown(() async {
    dio.close(force: true);
    await temp.delete(recursive: true);
  });
  test(
    'manual downloads survive LRU and clear but remain explicitly deletable',
    () async {
      cache = MediaCache(
        directory: temp,
        dio: dio,
        resolve: (_, _) async => track,
        maxFiles: 1,
        retainFile: (vid, quality) => vid == '11',
      );
      final manual = cache.prepare('11');
      await manual.result;
      cache.release(manual);
      final ordinary = cache.prepare('12');
      await ordinary.result;
      cache.release(ordinary);
      await cache.prune();
      expect((await cache.entries()).map((e) => e.vid), ['11']);
      await cache.clear();
      expect((await cache.entries()).single.vid, '11');
      await cache.evict('11');
      expect(await cache.entries(), isEmpty);
    },
  );
  test(
    'stopping prefetch preserves only the explicit active download lease',
    () async {
      final gate = Completer<VideoTrack>();
      cache = MediaCache(
        directory: temp,
        dio: dio,
        resolve: (_, _) => gate.future,
      );
      final manual = cache.prepare('11', background: true);
      final prefetch = cache.prepare('12', background: true);
      final cancelled = expectLater(
        prefetch.result,
        throwsA(isA<MediaCancelled>()),
      );
      cache.cancelBackground(keep: (vid, quality) => vid == '11');
      await cancelled;
      gate.complete(track);
      expect(await manual.result, endsWith('11_best.mp4'));
      cache.release(manual);
    },
  );
  test(
    'stream download → spade → all tracks → clear MP4 → restart cache hit',
    () async {
      final stages = <MediaStage>[];
      final job = cache.prepare('123', onProgress: (p) => stages.add(p.stage));
      final path = await job.result;
      await FileDecryptor.validateClear(path);
      expect(
        stages,
        containsAll([
          MediaStage.downloading,
          MediaStage.decrypting,
          MediaStage.validating,
        ]),
      );
      expect(File('$path.json').existsSync(), isTrue);
      cache.release(job);
      final restarted = MediaCache(
        directory: temp,
        dio: dio,
        resolve: (_, _) => throw StateError('Cache should avoid network'),
      );
      final next = restarted.prepare('123');
      expect(await next.result, path);
      restarted.release(next);
      expect(adapter.downloads, 1);
      expect(temp.listSync().where((f) => f.path.endsWith('.part')), isEmpty);
    },
  );
  test('same-key work deduplicates and one lease cancellation does not cancel another', () async {
    final first = cache.prepare('123'), second = cache.prepare('123');
    final cancelled = expectLater(first.result, throwsA(isA<MediaCancelled>()));
    first.cancel();
    await cancelled;
    final path = await second.result;
    expect(File(path).existsSync(), isTrue);
    expect(adapter.downloads, 1);
    cache.release(second);
  });
  test(
    'all consumers cancel during resolution: no file is published',
    () async {
      final resolving = Completer<VideoTrack>();
      final started = Completer<void>();
      final pending = MediaCache(
        directory: temp,
        dio: dio,
        resolve: (_, _) {
          started.complete();
          return resolving.future;
        },
      );
      final job = pending.prepare('123');
      final cancelled = expectLater(job.result, throwsA(isA<MediaCancelled>()));
      await started.future;
      job.cancel();
      resolving.complete(track);
      await cancelled;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(adapter.downloads, 0);
      expect(temp.listSync(), isEmpty);
    },
  );
  test('wrong key never enters cache and retry succeeds', () async {
    adapter = BytesAdapter(
      File('../core/test/fixtures/media/head.cenc.mp4').readAsBytesSync(),
    );
    dio.httpClientAdapter = adapter;
    final fixture = jsonDecode(
      File('../core/test/fixtures/node_oracle.json').readAsStringSync(),
    );
    final wrong = base64Encode(unhex(fixture['spade'][1]['raw']));
    var calls = 0;
    final retry = MediaCache(
      directory: temp,
      dio: dio,
      resolve: (_, _) async => VideoTrack(
        url: track.url,
        spadeA: calls++ == 0 ? wrong : spade,
        definition: '720p',
        size: 0,
      ),
    );
    await expectLater(retry.prepare('123').result, throwsFormatException);
    final next = retry.prepare('123');
    await next.result;
    retry.release(next);
    expect(adapter.downloads, 2);
    expect(temp.listSync().where((f) => f.path.endsWith('.part')), isEmpty);
  });
  test('playing files remain pinned during cache clear; released files can be removed', () async {
    final job = cache.prepare('123'), path = await job.result;
    await cache.clear();
    expect(File(path).existsSync(), isTrue);
    cache.release(job);
    await Future<void>.delayed(Duration.zero);
    await cache.clear();
    expect(File(path).existsSync(), isFalse);
  });
  test('truncated ready file with old manifest is re-downloaded', () async {
    final job = cache.prepare('123'), path = await job.result;
    cache.release(job);
    File(path).writeAsBytesSync([1, 2, 3]);
    final again = cache.prepare('123');
    await again.result;
    cache.release(again);
    expect(adapter.downloads, 2);
  });
  test(
    'local browser lists only complete manifests and reflects active pins',
    () async {
      final job = cache.prepare('123');
      final path = await job.result;
      await File('${temp.path}/pending.part').writeAsBytes([1]);
      await File('${temp.path}/456_best.mp4').writeAsBytes([1, 2]);
      var entries = await cache.entries();
      expect(entries.length, 1);
      expect(entries.single.vid, '123');
      expect(entries.single.bytes, await File(path).length());
      expect(entries.single.inUse, isTrue);
      cache.release(job);
      entries = await cache.entries();
      expect(entries.single.inUse, isFalse);
      await cache.evict('123');
      expect(await cache.entries(), isEmpty);
    },
  );
  test('offline-only acquisition pins cached file and never resolves a missing file', () async {
    final job = cache.prepare('123');
    final path = await job.result;
    cache.release(job);
    var resolves = 0;
    final offline = MediaCache(
      directory: temp,
      dio: dio,
      resolve: (_, _) {
        resolves++;
        throw StateError('must never resolve');
      },
    );
    final local = offline.prepareCached('123');
    await offline.evict('123'); // protected even while validation is pending
    expect(await local.result, path);
    expect((await offline.entries()).single.inUse, isTrue);
    await expectLater(offline.prepareCached('999').result, throwsStateError);
    expect(resolves, 0);
    expect(adapter.downloads, 1);
    offline.release(local);
    await offline.evict('123');
    expect(await offline.entries(), isEmpty);
  });
  test(
    'cancelled local acquisition releases its pin without a download',
    () async {
      final ready = cache.prepare('123');
      await ready.result;
      cache.release(ready);
      final local = cache.prepareCached('123');
      final cancelled = expectLater(
        local.result,
        throwsA(isA<MediaCancelled>()),
      );
      local.cancel();
      await cancelled;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect((await cache.entries()).single.inUse, isFalse);
      expect(adapter.downloads, 1);
    },
  );
  test(
    'native download transport shares decrypt, manifest and completion cleanup',
    () async {
      var downloads = 0, finishes = 0;
      String? downloadPath, finishedPath;
      final native = MediaCache(
        directory: temp,
        dio: dio,
        resolve: (_, _) async => track,
        download: (vid, quality, value, path, token, progress) async {
          downloads++;
          downloadPath = path;
          expect(vid, '123');
          expect(quality, 'best');
          expect(value.spadeA, spade);
          final cipher = File('../core/test/fixtures/media/real.cenc.mp4')
              .readAsBytesSync();
          await File(path).writeAsBytes(cipher);
          progress(cipher.length, cipher.length);
        },
        onFinished: (_, _) async => finishes++,
        onJobFinished: (_, _, path) async {
          finishedPath = path;
        },
      );
      final lease = native.prepare('123');
      final path = await lease.result;
      await FileDecryptor.validateClear(path);
      native.release(lease);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(downloads, 1);
      expect(adapter.downloads, 0);
      expect(finishes, 1);
      expect(finishedPath, downloadPath);
      expect(finishedPath, endsWith('.part'));
    },
  );
  test(
    'recovery publishes completed ciphertext without resolving or downloading',
    () async {
      final raw = File('${temp.path}/123_best.mp4.100.0.part');
      await raw.writeAsBytes(
        File('../core/test/fixtures/media/real.cenc.mp4').readAsBytesSync(),
      );
      final recovered = MediaCache(
        directory: temp,
        dio: dio,
        resolve: (_, _) => throw StateError('no network'),
      );
      await recovered.adoptDownloaded('123', 'best', raw.path, spade);
      expect((await recovered.entries()).single.vid, '123');
      expect(await raw.exists(), isFalse);
      final lease = recovered.prepareCached('123');
      await FileDecryptor.validateClear(await lease.result);
      recovered.release(lease);
      expect(adapter.downloads, 0);
      await expectLater(
        recovered.adoptDownloaded(
          '123',
          'best',
          '${temp.parent.path}/outside.part',
          spade,
        ),
        throwsArgumentError,
      );
    },
  );
  test('recovery never lists a partial or corrupt video as ready', () async {
    final raw = File('${temp.path}/123_best.mp4.100.0.part')
      ..writeAsBytesSync([1, 2, 3]);
    await expectLater(
      cache.adoptDownloaded('123', 'best', raw.path, null),
      throwsA(anything),
    );
    expect(await cache.entries(), isEmpty);
  });
}
