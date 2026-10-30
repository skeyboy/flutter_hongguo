import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

/// The registration is its own hop against its own endpoint, covered by
/// playback_device_test.dart. The player tests below pin it so their request
/// counts stay about the two player hops.
class FixedDevices extends PlaybackDeviceRegistry {
  static const device = PlaybackDevice(
    deviceId: '7661622467441478681',
    iid: '3912088544850522',
    cdid: 'fixed-cdid',
  );
  FixedDevices() : super(dio: Dio());
  @override
  Future<PlaybackDevice> get({CancelToken? cancelToken}) async => device;
}

/// A registration that hands out a different pair every time it is asked to
/// trade one in, so a test can see which identity each attempt carried.
class RotatingDevices extends PlaybackDeviceRegistry {
  RotatingDevices() : super(dio: Dio());
  int rotations = 0;
  @override
  Future<PlaybackDevice> get({CancelToken? cancelToken}) async =>
      _issued(issued++);
  @override
  Future<PlaybackDevice> rotate({
    String? refusedDeviceId,
    CancelToken? cancelToken,
  }) async {
    rotations++;
    return _issued(issued++);
  }

  int issued = 0;
  static PlaybackDevice _issued(int serial) => PlaybackDevice(
    deviceId: '76616224674414${serial.toString().padLeft(4, '0')}',
    iid: '39120885448${serial.toString().padLeft(4, '0')}',
    cdid: 'rotating-cdid',
  );
}

class FakeAdapter implements HttpClientAdapter {
  /// The value of `video_model.fallback_api`, unless [model] replaces the whole
  /// inlined model.
  FakeAdapter(this.fallback, {this.model});
  final dynamic fallback;
  final Map<String, dynamic>? model;
  final List<RequestOptions> requests = [];
  Uint8List? sentBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.method != 'POST') {
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
    sentBody = Uint8List.fromList([
      if (requestStream != null)
        ...await requestStream.expand((b) => b).toList(),
    ]);
    return ResponseBody.fromString(
      jsonEncode({
        'code': 0,
        'data': {
          '123': {
            'video_model': jsonEncode(model ?? {'fallback_api': fallback}),
          },
        },
      }),
      200,
    );
  }

  RequestOptions get playerRequest =>
      requests.firstWhere((options) => options.method == 'POST');

  @override
  void close({bool force = false}) {}
}

class VideoDeadlineAdapter implements HttpClientAdapter {
  final inner = FakeAdapter('https://test.fqnovel.com/info');
  final cancelled = Completer<void>();
  int calls = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    if (++calls == 1) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return inner.fetch(options, stream, cancel);
    }
    cancel?.then((_) {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    return Completer<ResponseBody>().future;
  }

  @override
  void close({bool force = false}) {}
}

/// Upstream's real flake on both metadata hops: HTTP 200 with no bytes, or a
/// body cut off mid-write. The hops are told apart by method because a recovery
/// repeats one of them.
class ThinBodyAdapter implements HttpClientAdapter {
  ThinBodyAdapter({this.emptyPosts = 0, this.emptyGets = 0, this.cutGets = 0});
  final int emptyPosts;
  final int emptyGets;
  final int cutGets;
  final List<RequestOptions> requests = [];
  int _posts = 0;
  int _gets = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.method == 'POST') {
      if (++_posts <= emptyPosts) return ResponseBody.fromString('', 200);
      return ResponseBody.fromString(
        jsonEncode({
          'code': 0,
          'data': {
            '123': {
              'video_model': jsonEncode({
                'fallback_api': 'https://test.fqnovel.com/info',
              }),
            },
          },
        }),
        200,
      );
    }
    if (++_gets <= emptyGets) return ResponseBody.fromString('', 200);
    final body = jsonEncode({
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
    });
    if (_gets <= cutGets) {
      return ResponseBody.fromString(body.substring(0, 24), 200);
    }
    return ResponseBody.fromString(body, 200);
  }

  @override
  void close({bool force = false}) {}
}

/// One player answer, for the shapes that are a real refusal rather than a
/// missing answer.
class PlayerAnswerAdapter implements HttpClientAdapter {
  PlayerAnswerAdapter(this.answer);
  final Map<String, Object?> answer;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(jsonEncode(answer), 200);
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> row(int px) => {
  'codec_type': 'h264',
  'definition': '${px}p',
  'vwidth': px,
  'vheight': px * 2,
  'main_url': 'https://a.qznovelvod.com/$px.mp4',
  'size': 1234,
};

void main() {
  VideoRequestBuilder builder() => VideoRequestBuilder(
    clockMillis: () => 1700000000123,
    deviceFactory: () => {
      'ac': 'wifi',
      'version_name': '7.1.3.32',
      'resolution': '1280*2772',
    },
  );
  VideoModelClient model(
    Dio dio, {
    NetworkRetry? retry,
    Duration? requestDeadline,
  }) => VideoModelClient(
    dio: dio,
    builder: builder(),
    devices: FixedDevices(),
    retry: retry,
    requestDeadline: requestDeadline ?? const Duration(seconds: 12),
  );
  test('simultaneous qualities and track share both metadata hops', () async {
    final adapter = FakeAdapter('https://test.fqnovel.com/info');
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final client = model(dio);
    await Future.wait<Object>([
      client.fetchTrack('123'),
      client.fetchQualities('123'),
    ]);
    expect(adapter.requests, hasLength(2));
  });
  test(
    'video metadata fallback uses the same deadline and is cancelled',
    () async {
      final adapter = VideoDeadlineAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final client = VideoModelClient(
        dio: dio,
        builder: builder(),
        devices: FixedDevices(),
        requestDeadline: const Duration(milliseconds: 120),
      );
      await expectLater(
        client.fetchTrack('123'),
        throwsA(isA<MetadataDeadlineExceeded>()),
      );
      expect(adapter.calls, 2);
      await adapter.cancelled.future.timeout(const Duration(seconds: 1));
    },
  );
  test('an empty 200 on either metadata hop is recovered before the viewer sees it', () async {
    final adapter = ThinBodyAdapter(emptyPosts: 1, emptyGets: 1);
    final dio = Dio()..httpClientAdapter = adapter;
    final track = await model(
      dio,
      retry: NetworkRetry(wait: (_) async {}),
    ).fetchTrack('123');
    expect(track.url.toString(), 'https://a.qznovelvod.com/test.mp4');
    // One empty answer and one filled answer per hop.
    expect(adapter.requests, hasLength(4));
    dio.close();
  });
  test(
    'a body cut off mid-write is the same missing answer, and is retried',
    () async {
      final adapter = ThinBodyAdapter(cutGets: 1);
      final dio = Dio()..httpClientAdapter = adapter;
      final track = await model(
        dio,
        retry: NetworkRetry(wait: (_) async {}),
      ).fetchTrack('123');
      expect(track.url.toString(), 'https://a.qznovelvod.com/test.mp4');
      expect(adapter.requests, hasLength(3));
      dio.close();
    },
  );
  test('an upstream that never fills answers in the viewer language', () async {
    final adapter = ThinBodyAdapter(emptyPosts: 99);
    final dio = Dio()..httpClientAdapter = adapter;
    final client = model(dio, retry: NetworkRetry(wait: (_) async {}));
    // What used to reach the player overlay was
    // `FormatException: Unexpected end of input (at character 1)`.
    Object? failure;
    try {
      await client.fetchTrack('123');
    } catch (error) {
      failure = error;
    }
    expect(failure, isNot(isA<FormatException>()));
    expect(
      failure,
      isA<IncompleteCatalogResponse>().having(
        (IncompleteCatalogResponse e) => '$e',
        'message',
        '播放信息未返回数据，请稍后重试',
      ),
    );
    // The first answer plus the two bounded recoveries, and no second hop.
    expect(adapter.requests, hasLength(3));
    dio.close();
  });
  test(
    'a recovery that got nothing trades the refused identity for a new one',
    () async {
      final adapter = ThinBodyAdapter(emptyPosts: 1);
      final dio = Dio()..httpClientAdapter = adapter;
      final devices = RotatingDevices();
      final track = await VideoModelClient(
        dio: dio,
        builder: builder(),
        devices: devices,
        retry: NetworkRetry(wait: (_) async {}),
      ).fetchTrack('123');
      expect(track.url.toString(), 'https://a.qznovelvod.com/test.mp4');
      // The empty answer is keyed to the pair it refused, so the next try asks
      // with a registration this process did not have before.
      expect(devices.rotations, 1);
      final posts = adapter.requests
          .where((request) => request.method == 'POST')
          .toList();
      expect(posts, hasLength(2));
      expect(
        posts[1].uri.queryParameters['device_id'],
        isNot(posts[0].uri.queryParameters['device_id']),
      );
      dio.close();
    },
  );
  test(
    'an answer on the first try keeps the identity the process already holds',
    () async {
      final adapter = FakeAdapter('https://test.fqnovel.com/info');
      final dio = Dio()..httpClientAdapter = adapter;
      final devices = RotatingDevices();
      await VideoModelClient(
        dio: dio,
        builder: builder(),
        devices: devices,
      ).fetchTrack('123');
      expect(devices.rotations, 0);
      dio.close();
    },
  );
  test('the player hop recovers over a wider window than a catalog hop', () {
    final catalog = NetworkRetry();
    final playback = VideoModelClient.playbackRetry();
    expect(catalog.maxRecoveries, 2);
    expect(playback.maxRecoveries, 3);
    expect(playback.delays, hasLength(3));
    final spread = playback.delays.fold<Duration>(
      Duration.zero,
      (a, b) => a + b,
    );
    // The block this hop is recovered from lasts seconds, not the ~1s a catalog
    // recovery spreads out, so the last try must not be reached inside that.
    expect(spread.inMilliseconds, greaterThanOrEqualTo(5000));
  });
  test(
    'an envelope with no data is the same soft block, and is retried',
    () async {
      final adapter = PlayerAnswerAdapter({'code': 0, 'data': <Object?>[]});
      final dio = Dio()..httpClientAdapter = adapter;
      await expectLater(
        model(dio, retry: NetworkRetry(wait: (_) async {})).fetchTrack('123'),
        throwsA(
          isA<IncompleteCatalogResponse>().having(
            (IncompleteCatalogResponse e) => '$e',
            'message',
            '播放信息未返回数据，请稍后重试',
          ),
        ),
      );
      expect(adapter.requests, hasLength(3));
      dio.close();
    },
  );
  test(
    'an episode the player declined stops without repeating the request',
    () async {
      final adapter = PlayerAnswerAdapter({
        'code': 0,
        'data': {'123': {}},
      });
      final dio = Dio()..httpClientAdapter = adapter;
      await expectLater(
        model(dio).fetchTrack('123'),
        throwsA(
          isA<PlaybackUnavailable>().having(
            (PlaybackUnavailable e) => '$e',
            'message',
            '这一集暂时没有可播的片源，请稍后重试或换一集',
          ),
        ),
      );
      expect(adapter.requests, hasLength(1));
      dio.close();
    },
  );
  test(
    'a business code inside the envelope is refused in the viewer language',
    () async {
      final adapter = PlayerAnswerAdapter({
        'code': 0,
        'Code': 7,
        'data': {
          '123': {
            'video_model': jsonEncode({
              'video_list': [row(720)],
            }),
          },
        },
      });
      final dio = Dio()..httpClientAdapter = adapter;
      await expectLater(
        model(dio).fetchTrack('123'),
        throwsA(
          isA<PlaybackUnavailable>().having(
            (PlaybackUnavailable e) => '$e',
            'message',
            '这一集暂时不能播放，请稍后重试或换一集',
          ),
        ),
      );
      expect(adapter.requests, hasLength(1));
      dio.close();
    },
  );
  test('tracks inlined in video_model are used without a second hop', () async {
    final adapter = FakeAdapter(
      null,
      model: {
        'video_list': [row(720), row(360)],
        'key_seed': '',
      },
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = model(dio);
    final track = await client.fetchTrack('123');
    expect(track.url.toString(), 'https://a.qznovelvod.com/720.mp4');
    expect(adapter.requests.map((options) => options.method).toList(), [
      'POST',
    ], reason: 'the inlined list must not ask the fallback_api');
    expect((await client.fetchQualities('123')).map((q) => q.value), [
      'best',
      '720p',
      '360p',
    ]);
    expect(adapter.requests.map((options) => options.method).toSet(), {
      'POST',
    }, reason: 'the inlined list must not ask the fallback_api');
    dio.close();
  });
  test('quality options are real compatible resolutions, deduplicated and free of media secrets', () {
    Map<String, dynamic> sized(int size, String codec, String url) => {
      'codec_type': codec,
      'definition': '${size}p',
      'vwidth': size,
      'vheight': size * 2,
      'main_url': url,
    };
    final options = VideoModelClient.availableQualities({
      'video_list': {
        '360': sized(360, 'h264', 'https://a.qznovelvod.com/360.mp4'),
        '720': sized(720, 'h264', 'https://a.qznovelvod.com/720.mp4'),
        '720hevc': sized(720, 'hevc', 'https://a.qznovelvod.com/hevc.mp4'),
        '1080av1': sized(1080, 'av1', 'https://a.qznovelvod.com/av1.mp4'),
        '1440bad': sized(1440, 'h264', 'https://untrusted.example/test.mp4'),
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
  test('one row with an empty nested envelope keeps the other resolutions on offer', () {
    final options = VideoModelClient.availableQualities({
      'video_list': {
        '720': {
          'codec_type': 'h264',
          'definition': '720p',
          'vwidth': 720,
          'vheight': 1280,
          'encrypt_info': '',
          'main_url': 'https://a.qznovelvod.com/720.mp4',
        },
        '360': {
          'codec_type': 'h264',
          'definition': '360p',
          'vwidth': 360,
          'vheight': 640,
          'video_meta': '{"codec_type":"h2',
          'main_url': 'https://a.qznovelvod.com/360.mp4',
        },
      },
    });
    expect(options.map((q) => q.value), ['best', '720p', '360p']);
  });
  test('quality discovery reuses the anonymous video info request', () async {
    final adapter = FakeAdapter('https://test.fqnovel.com/info');
    final dio = Dio()..httpClientAdapter = adapter;
    final options = await model(dio).fetchQualities('123');
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
  test(
    'the player request carries the registered identity and no signature',
    () {
      final request = builder().build('123', device: FixedDevices.device);
      expect(request.url, contains('resolution=1280%2A2772'));
      // The fixed template first, then the identity the platform handed out.
      expect(
        request.url.indexOf('device_id='),
        greaterThan(request.url.indexOf('is_android_pad_screen=')),
      );
      expect(request.url, contains('device_id=7661622467441478681'));
      expect(request.url, contains('iid=3912088544850522'));
      expect(request.url, contains('_rticket=1700000000123'));
      expect(request.headers['User-Agent'], isNotNull);
      expect(
        jsonDecode(utf8.decode(request.body))['mixed_video_id_map']['1004'],
        ['123'],
      );
      expect(() => request.body[0] = 0, throwsUnsupportedError);
      expect(
        () => request.headers['x-argus'] = 'changed',
        throwsUnsupportedError,
      );
      expect(
        () => builder().build('12/3', device: FixedDevices.device),
        throwsArgumentError,
      );
    },
  );
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
        final track = await model(dio).fetchTrack('123');
        expect(track.url.toString(), 'https://a.qznovelvod.com/test.mp4');
        expect(track.encrypted, isFalse);
        expect(adapter.sentBody, isNotEmpty);
        expect(
          utf8.decode(adapter.sentBody!),
          contains('"mixed_video_id_map"'),
        );
        expect(adapter.playerRequest.followRedirects, isFalse);
        expect(adapter.requests[1].headers.containsKey('x-medusa'), isFalse);
        dio.close();
      },
    );
  }
  test('untrusted fallback never gets a second request', () async {
    final adapter = FakeAdapter('https://attacker.invalid/fallback');
    final dio = Dio()..httpClientAdapter = adapter;
    await expectLater(model(dio).fetchTrack('123'), throwsFormatException);
    expect(adapter.requests, hasLength(1));
    dio.close();
  });
  test('quality selection prefers AVC and enforces requested short side', () {
    Map<String, dynamic> rowOf(String codec, int px) => {
      'codec_type': codec,
      'definition': '${px}p',
      'vwidth': px,
      'vheight': px * 2,
      'main_url': 'https://a.qznovelvod.com/$codec-$px.mp4',
    };
    final info = {
      'video_list': {'hevc': rowOf('hevc', 1080), 'h264': rowOf('h264', 720)},
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
    'protocol overrides apply to the player hop, which stays anonymous',
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
        devices: FixedDevices(),
        builder: VideoRequestBuilder(protocol: protocol),
      ).fetchTrack('123');
      final request = adapter.playerRequest;
      expect(request.uri.host, 'api3.fqnovel.com');
      expect(request.uri.queryParameters['version_name'], '7.2.2.32');
      expect(request.uri.queryParameters['version_code'], '72232');
      expect(
        request.headers['User-Agent'],
        VideoRequestBuilder.playbackUserAgent,
      );
      // The endpoint stopped accepting signed shapes on 2026-10-27, and the
      // account never travels on it either.
      for (final header in [
        'x-argus',
        'x-gorgon',
        'x-khronos',
        'x-hls5',
        'x-ladon',
        'x-ss-stub',
        'x-tt-dt',
        'cookie',
        'x-tt-token',
      ]) {
        expect(request.headers.containsKey(header), isFalse, reason: header);
      }
      // Only the player's own UA: the fallback keeps the configured one.
      expect(adapter.requests[1].headers['User-Agent'], 'updated-agent');
      dio.close();
    },
  );
}
