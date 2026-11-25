import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

/// 三层取源（官网直链 → App 取址 → 旧接口 preload）的层级测试。
///
/// 对齐参考实现 fetchPlayUrlFresh 的优先级语义：web 命中不发 App 请求、
/// App 命中不发旧接口请求、全败时错误信息带来源清单。
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

/// 按路径族应答的三层 mock：
/// - 官网兜底接口（POST fallback-play-info）：`web` 控制
/// - 官网播放页（GET /player/_/{vid}）：`page` 控制
/// - App 取址（POST multi_video_model/v1/）：`app` 控制
/// - 旧接口（POST multi_video_model/preload/v1/）：`legacy` 控制
class LayerAdapter implements HttpClientAdapter {
  LayerAdapter({this.web, this.page, this.app, this.legacy});
  final ResponseBody? Function(RequestOptions request)? web;
  final ResponseBody? Function(RequestOptions request)? page;
  final ResponseBody? Function(RequestOptions request)? app;
  final ResponseBody? Function(RequestOptions request)? legacy;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.path.contains('/api/video/protected/fallback-play-info')) {
      return web?.call(options) ?? ResponseBody.fromString('', 404);
    }
    if (options.path.contains('/player/_/')) {
      return page?.call(options) ?? ResponseBody.fromString('', 404);
    }
    if (options.path.contains('multi_video_model/preload/v1/')) {
      return legacy?.call(options) ?? ResponseBody.fromString('', 404);
    }
    if (options.path.contains('multi_video_model/v1/')) {
      return app?.call(options) ?? ResponseBody.fromString('', 404);
    }
    return ResponseBody.fromString('', 404);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody json(Object value, [int status = 200]) =>
    ResponseBody.fromString(jsonEncode(value), status);

/// App 层成功应答（内联 video_list，无需第二跳）。
ResponseBody appSuccess() => json({
  'code': 0,
  'data': {
    '123': {
      'video_model': jsonEncode({
        'video_list': {
          'video_1': {
            'codec_type': 'h264',
            'definition': '720p',
            'vwidth': 720,
            'vheight': 1280,
            'main_url': 'https://a.qznovelvod.com/app.mp4',
            'size': 1234,
          },
        },
      }),
    },
  },
});

/// 旧接口成功应答：video_model 顶层直挂 video_list。
ResponseBody legacySuccess() => json({
  'code': 0,
  'data': {
    '123': {
      'video_model': jsonEncode({
        'video_list': {
          'video_1': {
            'codec_type': 'h264',
            'definition': '360p',
            'vwidth': 360,
            'vheight': 640,
            'main_url': 'https://a.fqnovelvod.com/legacy.mp4',
            'size': 2345,
          },
        },
      }),
    },
  },
});

ResponseBody webSuccess(String url) => json({
  'base_resp': {'StatusCode': 0},
  'main_url': url,
  'url_expire':
      (DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/
      1000),
});

VideoModelClient client(Dio dio, {List<String>? failures}) => VideoModelClient(
  dio: dio,
  devices: FixedDevices(),
  retry: NetworkRetry(delays: const [], maxRecoveries: 0),
  requestDeadline: const Duration(seconds: 12),
  builder: VideoRequestBuilder(
    protocol: const AppSettings(playbackRouteSet: PlaybackRouteSet.current),
  ),
  onRouteFailure: failures == null
      ? null
      : (id, kind) => failures.add('$id:$kind'),
);

/// 公开播放页：`_ROUTER_DATA` 给身份，ld+json 给直链。
String pageHtml({
  bool protected = false,
  bool seoAvailable = true,
  String url = 'https://v.bytecdn.com/page.mp4',
}) {
  final router = jsonEncode({
    'loaderData': {
      'player_(series_id)/(vid)/page': {
        'isSuccess': true,
        'vid': '123',
        'seriesDetail': {'series_id': '456'},
        'publicVideoSeo': {
          'available': seoAvailable,
          'itemId': '123',
          'seriesId': '456',
        },
        'protectedPlayback': protected,
      },
    },
  });
  final ld = jsonEncode({
    '@type': 'VideoObject',
    'contentUrl': url,
    'url': 'https://hongguoduanju.com/player/456/123',
  });
  return '<html><script>window._ROUTER_DATA = $router;</script>'
      '<script type="application/ld+json">$ld</script></html>';
}

void main() {
  test('官网直链命中时不发 App 或旧接口请求', () async {
    final adapter = LayerAdapter(
      web: (r) => webSuccess('https://v.fqnovelvod.com/web.mp4'),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final track = await client(dio).fetchTrack('123');
    expect(track.url.toString(), 'https://v.fqnovelvod.com/web.mp4');
    // 明文 MP4：无 spade、带官网 UA 与 Referer（下载层依赖它们拿完整文件）。
    expect(track.encrypted, isFalse);
    expect(track.userAgent, contains('Chrome/'));
    expect(track.referer, 'https://hongguoduanju.com/');
    expect(
      adapter.requests.map((r) => r.path),
      everyElement(contains('/api/video/protected/fallback-play-info')),
    );
  });

  test('官网失败后 App 层接住', () async {
    final adapter = LayerAdapter(
      web: (r) => json({
        'base_resp': {'StatusCode': 1001},
      }),
      app: (r) => appSuccess(),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final track = await client(dio).fetchTrack('123');
    expect(track.url.toString(), 'https://a.qznovelvod.com/app.mp4');
    expect(track.encrypted, isFalse);
    final paths = adapter.requests.map((r) => r.path).toList();
    expect(paths.any((p) => p.contains('fallback-play-info')), isTrue);
    expect(paths.any((p) => p.contains('multi_video_model/v1/')), isTrue);
    expect(paths.any((p) => p.contains('preload/v1/')), isFalse);
  });

  test('App 层拒绝后旧接口接住', () async {
    final adapter = LayerAdapter(
      web: (r) => ResponseBody.fromString('', 404),
      app: (r) => json({'code': 110001}),
      legacy: (r) => legacySuccess(),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final track = await client(dio).fetchTrack('123');
    expect(track.url.toString(), 'https://a.fqnovelvod.com/legacy.mp4');
    final paths = adapter.requests.map((r) => r.path).toList();
    expect(paths.any((p) => p.contains('preload/v1/')), isTrue);
    expect(paths.where((p) => p.contains('fallback-play-info')), hasLength(1));
  });

  test('每一层失败都上报路由诊断，且不包含 URL 或响应正文', () async {
    final adapter = LayerAdapter(
      web: (r) => ResponseBody.fromString('secret-web-body', 503),
      page: (r) => ResponseBody.fromString('secret-page-body', 404),
      app: (r) => json({'code': 0, 'data': <String, dynamic>{}}),
      legacy: (r) => ResponseBody.fromString('', 200),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final failures = <String>[];
    await expectLater(
      client(dio, failures: failures).fetchTrack('123'),
      throwsA(isA<IncompleteCatalogResponse>()),
    );
    expect(failures, contains('web-public:transport'));
    expect(failures, contains('web-public:http-404'));
    expect(failures, contains('app-multi-v1:empty-envelope'));
    expect(failures, contains('legacy-preload:empty-envelope'));
    expect(failures.join('\n'), isNot(contains('secret-')));
    expect(failures.join('\n'), isNot(contains('https://')));
  });

  test('三层全败时抛 PlaybackUnavailable，文案带齐三层结论', () async {
    final adapter = LayerAdapter(
      web: (r) => json({
        'base_resp': {'StatusCode': 2103},
      }),
      app: (r) => json({'code': 110001}),
      legacy: (r) => json({'code': 2}),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    await expectLater(
      client(dio).fetchTrack('123'),
      throwsA(
        isA<PlaybackUnavailable>()
            // 「详情」里要看得出三层都试过，而不只是 App 那一句业务码。
            .having((e) => e.message, 'message', contains('官网'))
            .having((e) => e.message, 'message', contains('旧接口')),
      ),
    );
    // 三层都被问过：官网 1 次、App 1 次、旧接口 1 次。
    final paths = adapter.requests.map((r) => r.path).toList();
    expect(paths.any((p) => p.contains('fallback-play-info')), isTrue);
    expect(paths.any((p) => p.contains('multi_video_model/v1/')), isTrue);
    expect(paths.any((p) => p.contains('preload/v1/')), isTrue);
  });

  test('指定清晰度时 App 层优先，官网层只做回退', () async {
    final adapter = LayerAdapter(
      web: (r) => webSuccess('https://v.fqnovelvod.com/web360.mp4'),
      app: (r) => appSuccess(),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final track = await client(dio).fetchTrack('123', quality: '720p');
    expect(track.url.toString(), 'https://a.qznovelvod.com/app.mp4');
    final paths = adapter.requests.map((r) => r.path).toList();
    expect(paths.first.contains('multi_video_model/v1/'), isTrue);
    expect(paths.any((p) => p.contains('fallback-play-info')), isFalse);
  });

  test('官网直链的 UA 与 Referer 进入下载层', () async {
    // 下载头逻辑在 media_cache；这里断言 track 自身携带（契约），
    // 防止 web 层返回值丢失 UA 字段导致 CDN 拒绝。
    final adapter = LayerAdapter(
      web: (r) => webSuccess('https://v.fqnovelvod.com/web.mp4'),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final track = await client(dio).fetchTrack('123');
    expect(track.userAgent, isNotEmpty);
    expect(track.referer, isNotEmpty);
  });

  test('兜底接口没片源时，公开播放页的 ld+json 直链接住', () async {
    final adapter = LayerAdapter(
      web: (r) => json({
        'base_resp': {'StatusCode': 1001},
      }),
      page: (r) => ResponseBody.fromString(pageHtml(), 200),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final track = await client(dio).fetchTrack('123');
    expect(track.url.toString(), 'https://v.bytecdn.com/page.mp4');
    expect(track.fromWeb, isTrue);
    expect(track.encrypted, isFalse);
    // 官网层自己解决了，不下探 App 层。
    expect(
      adapter.requests.where((r) => r.path.contains('multi_video_model')),
      isEmpty,
    );
  });

  test('只挂 SEO 预览的播放页不被采信', () async {
    final adapter = LayerAdapter(
      web: (r) => json({
        'base_resp': {'StatusCode': 1001},
      }),
      page: (r) => ResponseBody.fromString(pageHtml(protected: true), 200),
      app: (r) => appSuccess(),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final track = await client(dio).fetchTrack('123');
    // 预览片时长与正片对得上，采信它等于让用户看 30 秒就断。
    expect(track.url.toString(), 'https://a.qznovelvod.com/app.mp4');
    expect(track.fromWeb, isFalse);
  });

  test('播放页身份对不上时不动用它的直链', () async {
    final adapter = LayerAdapter(
      web: (r) => json({
        'base_resp': {'StatusCode': 1001},
      }),
      page: (r) => ResponseBody.fromString(pageHtml(seoAvailable: false), 200),
      app: (r) => appSuccess(),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final track = await client(dio).fetchTrack('123');
    expect(track.url.toString(), 'https://a.qznovelvod.com/app.mp4');
  });

  test('开渐进播放时 App 层先答，官网只做回退', () async {
    final adapter = LayerAdapter(
      web: (r) => webSuccess('https://v.fqnovelvod.com/web.mp4'),
      app: (r) => appSuccess(),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final track = await client(dio).fetchTrack('123', preferApp: true);
    expect(track.url.toString(), 'https://a.qznovelvod.com/app.mp4');
    expect(track.fromWeb, isFalse);
    // 明文的官网直链一次都不问：它拿不到渐进播放要的分片。
    expect(
      adapter.requests.where((r) => r.path.contains('fallback-play-info')),
      isEmpty,
    );
  });

  test('App 层拒绝时，渐进播放仍回退到官网直链', () async {
    final adapter = LayerAdapter(
      web: (r) => webSuccess('https://v.fqnovelvod.com/web.mp4'),
      app: (r) => json({'code': 110001}),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final track = await client(dio).fetchTrack('123', preferApp: true);
    expect(track.url.toString(), 'https://v.fqnovelvod.com/web.mp4');
    expect(track.fromWeb, isTrue);
  });
}
