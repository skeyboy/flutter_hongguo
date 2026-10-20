import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

class FakeAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  Uint8List? sentBody;
  final dynamic fallback;
  FakeAdapter(this.fallback);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requests.length == 1) {
      sentBody = Uint8List.fromList([
        if (requestStream != null)
          ...await requestStream.expand((b) => b).toList(),
      ]);
      return ResponseBody.fromString(
        jsonEncode({
          'code': 0,
          'data': {
            '123': {
              'video_model': jsonEncode({'fallback_api': fallback}),
            },
          },
        }),
        200,
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'code': 0,
        'video_info': {
          'Code': 0,
          'data': {
            'video_list': {
              'video_1': {
                'codec_type': 'h264',
                'definition': '720p',
                'vwidth': 720,
                'vheight': 1280,
                'main_url': 'https://a.qznovelvod.com/test.mp4',
                'size': 1234,
              },
            },
          },
        },
      }),
      200,
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  VideoRequestBuilder builder() => VideoRequestBuilder(
    clockMillis: () => 1700000000123,
    signer: PureSign(
      clockMillis: () => 1700000000123,
      entropy: (n) => Uint8List(n),
    ),
    deviceFactory: () => {
      'device_id': '7661622467441478681',
      'version_name': '7.1.3.32',
      'resolution': '1280*2772',
    },
  );
  test('quality options are real compatible resolutions, deduplicated and free of media secrets', () {
    Map<String, dynamic> row(int size, String codec, String url) => {
      'codec_type': codec,
      'definition': '${size}p',
      'vwidth': size,
      'vheight': size * 2,
      'main_url': url,
    };
    final options = VideoModelClient.availableQualities({
      'video_list': {
        '360': row(360, 'h264', 'https://a.qznovelvod.com/360.mp4'),
        '720': row(720, 'h264', 'https://a.qznovelvod.com/720.mp4'),
        '720hevc': row(720, 'hevc', 'https://a.qznovelvod.com/hevc.mp4'),
        '1080av1': row(1080, 'av1', 'https://a.qznovelvod.com/av1.mp4'),
        '1440bad': row(1440, 'h264', 'https://untrusted.example/test.mp4'),
      },
    });
    expect(options.map((q) => q.value), ['best', '720p', '360p']);
    expect(options[1].width, 720);
    expect(options[1].height, 1440);
  });
  test('quality metadata without dimensions offers automatic rather than guessed resolutions', () {
    final options = VideoModelClient.availableQualities({
      'video_list': {
        'unknown': {
          'codec_type': 'h264',
          'main_url': 'https://a.qznovelvod.com/test.mp4',
        },
      },
    });
    expect(options.map((q) => q.value), ['best']);
  });
  test('quality discovery reuses signed video info requests', () async {
    final adapter = FakeAdapter('https://test.fqnovel.com/info');
    final dio = Dio()..httpClientAdapter = adapter;
    final options = await VideoModelClient(
      dio: dio,
      builder: builder(),
    ).fetchQualities('123');
    expect(options.map((q) => q.value), ['best', '720p']);
    expect(adapter.requests.length, 2);
    dio.close();
  });
  test('query encoding matches urllib quote safe set', () {
    expect(
      encodeQueryPart("玄幻 !'()*~"),
      '%E7%8E%84%E5%B9%BB%20%21%27%28%29%2A~',
    );
  });
  test('frozen body bytes, MD5 stub and six headers agree', () {
    final request = builder().build('123');
    expect(request.url, contains('resolution=1280%2A2772'));
    expect(request.headers['x-ss-stub'], hex(md5(request.body)).toUpperCase());
    expect(
      jsonDecode(utf8.decode(request.body))['mixed_video_id_map']['1004'],
      ['123'],
    );
    expect(request.headers['Content-Length'], '${request.body.length}');
    expect(() => request.body[0] = 0, throwsUnsupportedError);
    expect(
      () => request.headers['x-medusa'] = 'changed',
      throwsUnsupportedError,
    );
    expect(() => builder().build('12/3'), throwsArgumentError);
  });
  for (final fallback in [
    'https://a.fqnovel.com/fallback',
    ['https://a.fqnovel.com/fallback'],
    {'fallback_api': 'https://a.fqnovel.com/fallback'},
    jsonEncode({'fallback_api': 'https://a.fqnovel.com/fallback'}),
  ]) {
    test(
      'Dio exact bytes and fallback envelope ${fallback.runtimeType}',
      () async {
        final adapter = FakeAdapter(fallback);
        final dio = Dio()..httpClientAdapter = adapter;
        final track = await VideoModelClient(
          dio: dio,
          builder: builder(),
        ).fetchTrack('123');
        expect(track.url.toString(), 'https://a.qznovelvod.com/test.mp4');
        expect(track.encrypted, isFalse);
        expect(adapter.sentBody, isNotEmpty);
        expect(
          hex(md5(adapter.sentBody!)).toUpperCase(),
          adapter.requests.first.headers['x-ss-stub'],
        );
        expect(adapter.requests.first.followRedirects, isFalse);
        expect(adapter.requests[1].headers.containsKey('x-medusa'), isFalse);
        dio.close();
      },
    );
  }
  test('untrusted fallback never gets a second request', () async {
    final adapter = FakeAdapter('https://attacker.invalid/fallback');
    final dio = Dio()..httpClientAdapter = adapter;
    await expectLater(
      VideoModelClient(dio: dio, builder: builder()).fetchTrack('123'),
      throwsFormatException,
    );
    expect(adapter.requests, hasLength(1));
    dio.close();
  });
  test('quality selection prefers AVC and enforces requested short side', () {
    Map<String, dynamic> row(String codec, int px) => {
      'codec_type': codec,
      'definition': '${px}p',
      'vwidth': px,
      'vheight': px * 2,
      'main_url': 'https://a.qznovelvod.com/$codec-$px.mp4',
    };
    final info = {
      'video_list': {'hevc': row('hevc', 1080), 'h264': row('h264', 720)},
    };
    expect(VideoModelClient.selectTrack(info).definition, '720p');
    expect(
      VideoModelClient.selectTrack(info, quality: '1080p').definition,
      '1080p',
    );
    expect(
      () => VideoModelClient.selectTrack(info, quality: '2160p'),
      throwsStateError,
    );
  });
  test(
    'updated protocol/session apply to signed POST, never to fallback',
    () async {
      final adapter = FakeAdapter('https://a.fqnovel.com/fallback');
      final dio = Dio()..httpClientAdapter = adapter;
      final protocol = const AppSettings().copyWith(
        videoHost: 'api3.fqnovel.com',
        videoVersion: '7.2.2.32',
        videoVersionCode: '72232',
        videoUserAgent: 'updated-agent',
      );
      await VideoModelClient(
        dio: dio,
        builder: VideoRequestBuilder(
          protocol: protocol,
          sessionHeaders: const {
            'cookie': 'test-cookie',
            'x-tt-token': 'test-token',
          },
        ),
      ).fetchTrack('123');
      final request = adapter.requests.first;
      expect(request.uri.host, 'api3.fqnovel.com');
      expect(request.uri.queryParameters['version_name'], '7.2.2.32');
      expect(request.headers['User-Agent'], 'updated-agent');
      expect(request.headers['cookie'], 'test-cookie');
      expect(adapter.requests[1].headers.containsKey('cookie'), isFalse);
      expect(adapter.requests[1].headers.containsKey('x-tt-token'), isFalse);
      dio.close();
    },
  );
}
