// End-to-end route tests for the web-anonymous guest ladder, using the pinned
// page HTML/JSON from hongguo-android PublicEpisodeSourceTest.java. The route
// stays in the extended set; default behaviour must not change.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

const series = '7000000000000000001';
const vid = '7000000000000000002';
const cdn = 'https://v3-hgweb.qznovelvod.com/fixture.mp4';

String guestPage({bool allow = true}) =>
    '<script>_ROUTER_DATA = {"loaderData":'
    '{"player_(series_id)/(vid)/page":{"isSuccess":true,'
    '"series_id":"$series","vid":"$vid",'
    '"req":{"pcLoginRequired":${!allow},"pcAuthenticatedPlayback":${!allow}},'
    '"seriesDetail":{"series_id":$series,"vid_list":[$vid],'
    '"accessible_episode_cnt":1},'
    '"publicVideoSeo":{"available":true,"seriesId":"$series",'
    '"itemId":"$vid","durationSeconds":125.14,"width":360,"height":640}}}}};</script>';

String fallbackReply() => jsonEncode({
  'base_resp': {'StatusCode': 0},
  'main_url': cdn,
  'url_expire':
      DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/
      1000,
});

class GuestAdapter implements HttpClientAdapter {
  GuestAdapter({this.pageHtml, this.pageAllowed = true});
  final String? pageHtml;
  final bool pageAllowed;
  final List<RequestOptions> requests = [];
  bool _visitedGuestPage = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final p = options.uri.path;
    if (p.startsWith('/player/$series/$vid')) {
      _visitedGuestPage = pageAllowed;
      return pageHtml == null
          ? ResponseBody.fromString('', 200)
          : ResponseBody.fromString(pageHtml!, 200);
    }
    if (p.contains('/api/video/protected/fallback-play-info')) {
      // 匿名层绝不能带 Cookie 或 Authorization。
      if (options.headers.containsKey('Cookie') ||
          options.headers.containsKey('Authorization')) {
        return ResponseBody.fromString('', 400);
      }
      // Only the guest route (which first authenticated the page) may get a
      // direct URL here. webPublic's bare POST is refused so the test proves
      // the anonymous route, not the pre-existing public hop, produced it.
      return _visitedGuestPage
          ? ResponseBody.fromString(fallbackReply(), 200)
          : ResponseBody.fromString('', 200);
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
    clockMillis: () => 1700000000123,
    deviceFactory: () => const {'ac': 'wifi'},
  ),
);

void main() {
  test('默认路由集：带 seriesId 也不发起官网访客页请求', () async {
    final adapter = GuestAdapter(pageHtml: guestPage());
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    await expectLater(
      client(dio, extended: false).fetchTrack(vid, seriesId: series),
      throwsA(anything),
    );
    expect(
      adapter.requests.any(
        (r) => r.uri.path.startsWith('/player/$series/$vid'),
      ),
      isFalse,
    );
  });

  test('扩展路由集：前面全败时命中访客取址，产出官网明文轨', () async {
    final adapter = GuestAdapter(pageHtml: guestPage());
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final track = await client(
      dio,
      extended: true,
    ).fetchTrack(vid, seriesId: series);

    expect(track.url.toString(), cdn);
    expect(track.encrypted, isFalse);
    expect(track.fromWeb, isTrue);
    expect(track.definition, '网页 360P');
    final paths = adapter.requests.map((r) => r.uri.path).toList();
    final guestAt = paths.indexOf('/player/$series/$vid');
    expect(guestAt, greaterThanOrEqualTo(0));
    expect(
      paths
          .skip(guestAt)
          .any((p) => p.contains('/api/video/protected/fallback-play-info')),
      isTrue,
    );
  });

  test('访客页拒绝时只发第一跳，不发 fallback POST', () async {
    final adapter = GuestAdapter(
      pageHtml: guestPage(allow: false),
      pageAllowed: false,
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    await expectLater(
      client(dio, extended: true).fetchTrack(vid, seriesId: series),
      throwsA(anything),
    );
    final paths = adapter.requests.map((r) => r.uri.path).toList();
    final guestAt = paths.indexOf('/player/$series/$vid');
    expect(guestAt, greaterThanOrEqualTo(0));
    expect(
      paths
          .skip(guestAt)
          .any((p) => p.contains('/api/video/protected/fallback-play-info')),
      isFalse,
      reason: 'guest page refused, so the anonymous hop must not POST',
    );
  });

  test('缺 seriesId 时访客路由被跳过', () async {
    final adapter = GuestAdapter(pageHtml: guestPage());
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    await expectLater(
      client(dio, extended: true).fetchTrack(vid),
      throwsA(anything),
    );
    expect(
      adapter.requests.any(
        (r) => r.uri.path.startsWith('/player/$series/$vid'),
      ),
      isFalse,
    );
  });
}
