import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_api/hongguo_native_api.dart';
import 'package:test/test.dart';

class MediaAdapter implements HttpClientAdapter {
  final Uint8List bytes = File('../core/test/fixtures/media/clear.mp4')
      .readAsBytesSync();
  int downloads = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
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
  late Directory root;
  late Dio dio;
  late MediaAdapter adapter;
  VideoTrack track() => VideoTrack(
    url: Uri.parse('https://a.qznovelvod.com/test.mp4'),
    spadeA: '',
    definition: '720p',
    size: adapter.bytes.length,
  );
  setUp(() {
    root = Directory.systemTemp.createTempSync('hongguo-schedule-');
    adapter = MediaAdapter();
    dio = Dio()..httpClientAdapter = adapter;
  });
  tearDown(() async {
    dio.close(force: true);
    await root.delete(recursive: true);
  });
  test(
    'foreground promotion skips queued prefetch and shares the same download',
    () async {
      final gates = {
        for (final id in ['1', '2', '3']) id: Completer<VideoTrack>(),
      };
      final starts = {for (final id in gates.keys) id: Completer<void>()};
      final cache = MediaCache(
        directory: root,
        dio: dio,
        maxConcurrent: 2,
        resolve: (id, _) {
          starts[id]!.complete();
          return gates[id]!.future;
        },
      );
      final bg1 = cache.prepare('1', background: true),
          bg2 = cache.prepare('2', background: true),
          bg3 = cache.prepare('3', background: true);
      await starts['1']!.future.timeout(const Duration(seconds: 2));
      expect(starts['2']!.isCompleted, isFalse);
      expect(starts['3']!.isCompleted, isFalse);
      final foreground = cache.prepare('3');
      await starts['3']!.future.timeout(const Duration(seconds: 2));
      expect(starts['2']!.isCompleted, isFalse);
      gates['3']!.complete(track());
      expect(await foreground.result, await bg3.result);
      cache.release(foreground);
      cache.release(bg3);
      gates['1']!.complete(track());
      await bg1.result;
      cache.release(bg1);
      await starts['2']!.future.timeout(const Duration(seconds: 2));
      gates['2']!.complete(track());
      await bg2.result;
      cache.release(bg2);
      expect(adapter.downloads, 3);
      cache.close();
    },
  );
  test(
    'ready background file stays reusable while playback takes over',
    () async {
      final cache = MediaCache(
        directory: root,
        dio: dio,
        resolve: (_, _) async => track(),
      );
      final bg = cache.prepare('1', background: true), path = await bg.result;
      final foreground = cache.prepare('1');
      cache.release(bg);
      await cache.clear();
      expect(await foreground.result, path);
      expect(adapter.downloads, 1);
      cache.release(foreground);
      cache.close();
    },
  );
  test(
    'byte budget evicts old unpinned files but protects the playing file',
    () async {
      final cache = MediaCache(
        directory: root,
        dio: dio,
        maxBytes: adapter.bytes.length + 10,
        resolve: (_, _) async => track(),
      );
      final first = cache.prepare('1'), firstPath = await first.result;
      cache.release(first);
      final second = cache.prepare('2'), secondPath = await second.result;
      await cache.prune();
      expect(File(firstPath).existsSync(), isFalse);
      expect(File(secondPath).existsSync(), isTrue);
      await cache.clear();
      expect(File(secondPath).existsSync(), isTrue);
      cache.release(second);
      cache.close();
    },
  );
  test('prefetch respects the budget even when the model omits size', () async {
    final cache = MediaCache(
      directory: root,
      dio: dio,
      maxBytes: 10,
      resolve: (_, _) async =>
          VideoTrack(url: track().url, spadeA: '', definition: '720p', size: 0),
    );
    final lease = cache.prepare('1', background: true);
    await expectLater(lease.result, throwsA(isA<MediaCancelled>()));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(root.listSync().where((f) => f.path.endsWith('.mp4')), isEmpty);
    cache.close();
  });
}
