// End-to-end route tests for the legacy single-episode hop
// (`/novel/player/video_model/v1/`, signed by LegacyPlayerSign). The route
// stays in the extended set; the explicit current set must not include it.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

const vid = '123';

Map<String, dynamic> singleModel() => {
  'video_list': {
    'video_1': {
      'codec_type': 'h264',
      'definition': '480p',
      'vwidth': 480,
      'vheight': 854,
      'main_url': 'https://a.fqnovelvod.com/single.mp4',
      'size': 3456,
    },
  },
};

/// parseSingleResponse accepts the model as an inline object, a JSON string
/// or a base64 string; all three must resolve to the same track.
ResponseBody singleSuccess({required String encoding}) {
  final model = singleModel();
  final dynamic payload = switch (encoding) {
    'object' => model,
    'json-string' => jsonEncode(model),
    'base64' => base64Encode(utf8.encode(jsonEncode(model))),
    _ => throw ArgumentError(encoding),
  };
  return ResponseBody.fromString(
    jsonEncode({
      'code': 0,
      'data': {'video_model': payload},
    }),
    200,
  );
}

class SingleAdapter implements HttpClientAdapter {
  SingleAdapter({this.encoding = 'json-string', this.enabled = true});
  final String encoding;
  final bool enabled;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final p = options.uri.path;
    if (p.contains('player/video_model/v1/')) {
      if (!enabled) return ResponseBody.fromString('', 200);
      // The signer's headers must travel with the request: the upstream
      // answers the exact query/body/header triple it signed.
      for (final header in const [
        'x-khronos',
        'x-ss-req-ticket',
        'x-ss-stub',
        'x-gorgon',
        'x-argus',
        'x-ladon',
      ]) {
        expect(options.headers[header], isNotNull, reason: header);
      }
      // The query is TreeMap-sorted upstream; assert the leading keys so a
      // future reorder of the query cannot slip through silently.
      // TreeMap order: '_' sorts before letters, then the rest alphabetical.
      expect(options.uri.query, startsWith('_rticket='));
      expect(options.uri.query, contains('ac=wifi'));
      expect(options.uri.query, contains('version_code=73532'));
      expect(options.uri.query, contains('version_name=7.3.5.32'));
      return singleSuccess(encoding: encoding);
    }
    // Other ladder hops answer empty; they fall through without a DioException.
    return ResponseBody.fromString('', 200);
  }

  @override
  void close({bool force = false}) {}
}

class FixedDevices extends PlaybackDeviceRegistry {
  FixedDevices() : super(dio: Dio());
  @override
  Future<PlaybackDevice> get({CancelToken? cancelToken}) async =>
      const PlaybackDevice(
        deviceId: '7661622467441478681',
        iid: '3912088544850522',
        cdid: 'fixed-cdid',
      );
}

VideoModelClient client(Dio dio, {required bool extended}) => VideoModelClient(
  dio: dio,
  devices: FixedDevices(),
  retry: NetworkRetry(delays: const [], maxRecoveries: 0),
  requestDeadline: const Duration(seconds: 8),
  builder: VideoRequestBuilder(
    protocol: AppSettings(
      playbackRouteSet: extended
          ? PlaybackRouteSet.extended
          : PlaybackRouteSet.current,
    ),
    deviceFactory: () => const {'ac': 'wifi'},
  ),
);

void main() {
  for (final encoding in const ['json-string', 'object', 'base64']) {
    test('扩展路由集：命中老单集接口（video_model=$encoding）并产出播放轨', () async {
      final adapter = SingleAdapter(encoding: encoding);
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final track = await client(dio, extended: true).fetchTrack(vid);
      expect(track.url.toString(), 'https://a.fqnovelvod.com/single.mp4');
      expect(
        adapter.requests.any(
          (r) => r.uri.path.contains('player/video_model/v1/'),
        ),
        isTrue,
      );
    });
  }

  test('current 路由集：不发起老单集请求', () async {
    final adapter = SingleAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    await expectLater(
      client(dio, extended: false).fetchTrack(vid),
      throwsA(anything),
    );
    expect(
      adapter.requests.any(
        (r) => r.uri.path.contains('player/video_model/v1/'),
      ),
      isFalse,
    );
  });
}
