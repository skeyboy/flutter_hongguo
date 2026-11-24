import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_api/hongguo_native_api.dart';
import 'package:test/test.dart';

/// HLS 通道未落地：即使某个适配器误把 m3u8 交给下载层，也必须在写出假 mp4
/// 之前被兜底拒绝（见 docs/design/hls-channel-evaluation.md）。
class _CountingAdapter implements HttpClientAdapter {
  final List<String> urls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async {
    urls.add(options.uri.toString());
    return ResponseBody.fromBytes(
      Uint8List.fromList([1, 2, 3]),
      200,
      headers: {
        Headers.contentLengthHeader: ['3'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('hongguo-hls-guard-'));
  tearDown(() {
    for (var i = 0; i < 50; i++) {
      try {
        temp.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        sleep(const Duration(milliseconds: 20));
      }
    }
  });

  MediaCache cacheWith(Dio dio, VideoTrack track) =>
      MediaCache(directory: temp, dio: dio, resolve: (_, _) async => track);

  test('显式 hls 格式在下载前被拒，不发起网络请求', () async {
    final http = _CountingAdapter();
    final dio = Dio()..httpClientAdapter = http;
    final cache = cacheWith(
      dio,
      VideoTrack(
        url: Uri.parse('https://cdn.example.com/v/index.m3u8'),
        spadeA: '',
        definition: '',
        size: 0,
        format: VideoFormat.hls,
        // 明确放行 host，让校验走到 HLS 兜底而不是先被域名表拦下。
        policy: const DomainAllowlistPolicy(['example.com']),
      ),
    );
    addTearDown(() {
      cache.close();
      dio.close(force: true);
    });
    await expectLater(
      cache.prepare('999').result,
      throwsA(
        isA<StateError>().having(
          (e) => e.toString(),
          'message',
          contains('HLS'),
        ),
      ),
    );
    expect(http.urls, isEmpty);
  });

  test('m3u8 后缀即使标成 mp4 也被兜底拒绝', () async {
    final http = _CountingAdapter();
    final dio = Dio()..httpClientAdapter = http;
    final cache = cacheWith(
      dio,
      VideoTrack(
        url: Uri.parse('https://cdn.example.com/v/playlist.M3U8'),
        spadeA: '',
        definition: '',
        size: 0,
        policy: const DomainAllowlistPolicy(['example.com']),
      ),
    );
    addTearDown(() {
      cache.close();
      dio.close(force: true);
    });
    await expectLater(cache.prepare('998').result, throwsA(isA<StateError>()));
    expect(http.urls, isEmpty);
  });
}
