import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/catalog/artwork_cache_native.dart';

class PosterAdapter implements HttpClientAdapter {
  int calls = 0;
  bool html = false, huge = false;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    requests.add(options);
    final bytes = html
        ? utf8.encode('<html>error page</html>')
        : base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aPioAAAAASUVORK5CYII=',
          );
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        Headers.contentLengthHeader: [
          '${huge ? 3 * 1024 * 1024 : bytes.length}',
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory root;
  late PosterAdapter adapter;
  late ArtworkCache cache;
  const drama = Drama(
    id: '1',
    title: '故事',
    cover: 'https://img.example/poster.png',
  );
  setUp(() {
    root = Directory.systemTemp.createTempSync('hongguo-artwork-');
    adapter = PosterAdapter();
    cache = ArtworkCache(root, dio: Dio()..httpClientAdapter = adapter);
  });
  tearDown(() async {
    cache.close();
    await root.delete(recursive: true);
  });
  test('posters persist, deduplicate and avoid credential headers', () async {
    await Future.wait([cache.ensure(drama), cache.ensure(drama)]);
    expect(adapter.calls, 1);
    expect(cache.lookup(drama), isNotNull);
    final restored = ArtworkCache(
      root,
      dio: Dio()..httpClientAdapter = adapter,
    );
    await restored.ensure(drama);
    expect(adapter.calls, 1);
    expect(
      adapter.requests.single.headers.keys.map((s) => s.toLowerCase()),
      isNot(contains('cookie')),
    );
    expect(
      adapter.requests.single.headers.keys.map((s) => s.toLowerCase()),
      isNot(contains('x-tt-token')),
    );
    restored.close();
  });
  test(
    'failed or oversized artwork never publishes an invalid cache entry',
    () async {
      adapter.html = true;
      await cache.ensure(drama);
      expect(cache.lookup(drama), isNull);
      adapter.html = false;
      adapter.huge = true;
      await cache.ensure(drama);
      expect(cache.lookup(drama), isNull);
      expect(root.listSync(), isEmpty);
      await cache.ensure(
        const Drama(
          id: '2',
          title: 'unsafe',
          cover: 'http://img.example/poster',
        ),
      );
      expect(adapter.calls, 2);
    },
  );
}
