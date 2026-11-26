import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_api/src/web_source.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

const id = '7710254424689495065';

/// 可控的两路详情夹具：官网两页与 App 分集接口各自独立开关。
class DetailAdapter implements HttpClientAdapter {
  DetailAdapter({
    this.webHtml = '',
    this.appVideos = const [],
    this.appEpisodeCount = 0,
    this.failWeb = false,
    this.failApp = false,
  });

  String webHtml;
  List<Map<String, dynamic>> appVideos;
  int appEpisodeCount;
  bool failWeb;
  bool failApp;

  final requests = <RequestOptions>[];

  int get webRequests => requests
      .where(
        (r) =>
            r.path.contains('hongguoduanju.com/player/') ||
            r.path.contains('hongguoduanju.com/detail'),
      )
      .length;
  int get appRequests =>
      requests.where((r) => r.path.contains('multi_video_detail')).length;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.path.contains('multi_video_detail')) {
      if (failApp) {
        return ResponseBody.fromString(jsonEncode({'code': 110001}), 200);
      }
      return ResponseBody.fromString(
        jsonEncode({
          'code': 0,
          'data': {
            id: {
              'video_data': {
                'series_id': id,
                'series_title': '全集剧',
                if (appEpisodeCount > 0) 'episode_cnt': appEpisodeCount,
                'video_list': appVideos,
              },
            },
          },
        }),
        200,
      );
    }
    if (options.path.contains('hongguoduanju.com')) {
      if (failWeb) return ResponseBody.fromString('', 404);
      return ResponseBody.fromString(webHtml, 200);
    }
    return ResponseBody.fromString('{}', 200);
  }
}

List<Map<String, dynamic>> videos(int count) => [
  for (var i = count; i >= 1; i--)
    {'vid': '${900000000000000000 + i}', 'vid_index': i, 'title': '第 $i 集'},
];

/// 真实官网形态：`vid_list` 只有限免前缀，且 vid 是不透明 token。
String opaqueWebPage(List<String> vids, {int episodeCount = 45}) => routerPage(jsonEncode({
  'loaderData': {
    'player_(series_id)/page': {
      'isSuccess': true,
      'series_id': id,
      'seriesDetail': {
        'series_id': id,
        'series_name': '限免前缀剧',
        'series_cover': 'https://p3-sign.example.com/cover.jpg',
        'vid_list': vids,
        'episode_cnt': episodeCount,
        'accessible_episode_cnt': vids.length,
      },
    },
  },
}));

/// 旧形态：全集数字 vid，可带限免边界。
String numericWebPage(List<String> vids, {int? episodeCount, int? accessible}) =>
    routerPage(jsonEncode({
      'loaderData': {
        'player_(series_id)/page': {
          'isSuccess': true,
          'series_id': id,
          'seriesDetail': {
            'series_id': id,
            'series_name': '旧官网剧',
            'series_cover': 'https://p3-sign.example.com/cover.jpg',
            'vid_list': vids,
            'episode_cnt': ?episodeCount,
            'accessible_episode_cnt': ?accessible,
          },
        },
      },
    }));

String routerPage(String json) =>
    '<html><script>window._ROUTER_DATA=$json;</script></html>';

CatalogClient client(DetailAdapter adapter, {bool appFirst = false}) =>
    CatalogClient(
      dio: Dio()..httpClientAdapter = adapter,
      deviceId: '1234567890123456',
      retry: NetworkRetry(delays: const []),
      protocol: AppSettings(
        timeoutSeconds: 10,
        detailSourceOrder: appFirst
            ? DetailSourceOrder.appFirst
            : DetailSourceOrder.webFirst,
      ),
    );

void main() {
  group('剧集列表完整性', () {
    test('官网不透明 vid 被识别为解析失败，不伪造数字集号', () {
      final html = opaqueWebPage([
        'v1_lBVGXYsjIeI7f_z4pGzbUFbn9CI',
        'v1_5RCyQu74Lz12gCevxgZmUwF9dXk',
      ]);
      expect(parseEpisodeListHtml(html, id), isNull);
      expect(
        () => CatalogClient.parseWebEpisodes(id, '<html>$html</html>'),
        throwsA(isA<CatalogError>()),
      );
    });

    test('router 数据读出上游声明的全集数，而不是前缀长度', () {
      final web = parseEpisodeListHtml(
        numericWebPage(['101', '102'], episodeCount: 45, accessible: 2),
        id,
      )!;
      expect(web.vids, ['101', '102']);
      expect(web.episodeCount, 45);
      expect(web.accessibleEpisodes, 2);
    });

    test('默认官网优先：官网只给限免前缀时改用 App 全集', () async {
      final adapter = DetailAdapter(
        webHtml: opaqueWebPage([
          'v1_lBVGXYsjIeI7f_z4pGzbUFbn9CI',
          'v1_5RCyQu74Lz12gCevxgZmUwF9dXk',
        ]),
        appVideos: videos(45),
        appEpisodeCount: 45,
      );
      final detail = await client(adapter).detail(id);
      expect(detail.episodes, hasLength(45));
      expect(detail.episodes.first.index, 1);
      expect(detail.episodes.last.index, 45);
      expect(
        detail.episodes.map((e) => e.index),
        List<int>.generate(45, (i) => i + 1),
      );
      expect(
        detail.episodes.every((e) => RegExp(r'^\d{1,30}$').hasMatch(e.vid)),
        isTrue,
      );
      expect(adapter.webRequests, greaterThan(0));
      expect(adapter.appRequests, 1);
    });

    test('大量分集不截断到前几集，index/vid/title 与排序保持', () async {
      final adapter = DetailAdapter(
        failWeb: true,
        appVideos: videos(120),
        appEpisodeCount: 120,
      );
      final detail = await client(adapter).detail(id);
      expect(detail.episodes, hasLength(120));
      expect(detail.episodes.first.vid, '900000000000000001');
      expect(detail.episodes.first.title, '第 1 集');
      expect(detail.episodes.last.vid, '900000000000000120');
      expect(detail.episodes.last.title, '第 120 集');
      expect(
        detail.episodes.map((e) => e.index),
        List<int>.generate(120, (i) => i + 1),
      );
    });

    test('官网前缀 + episode_cnt 时取 App 全集，并按集号保留限免标记', () async {
      final adapter = DetailAdapter(
        webHtml: numericWebPage(
          ['101', '102', '103', '104', '105'],
          episodeCount: 45,
          accessible: 5,
        ),
        appVideos: videos(45),
        appEpisodeCount: 45,
      );
      final detail = await client(adapter).detail(id);
      expect(detail.episodes, hasLength(45));
      expect(
        detail.episodes.take(5).every((e) => e.accessibleCount == 5),
        isTrue,
      );
      expect(
        detail.episodes.skip(5).every((e) => e.accessibleCount == null),
        isTrue,
      );
      expect(detail.episodes.first.beyondFree, isFalse);
      expect(detail.episodes.last.beyondFree, isFalse);
    });

    test('旧官网全集不含 episode_cnt 时不额外请求 App', () async {
      final adapter = DetailAdapter(
        webHtml: numericWebPage(['101', '102'], accessible: 2),
        appVideos: videos(45),
      );
      final detail = await client(adapter).detail(id);
      expect(detail.episodes.map((e) => e.vid), ['101', '102']);
      expect(detail.episodes.map((e) => e.index), [1, 2]);
      expect(adapter.appRequests, 0);
    });

    test('两路都失败时仍抛出错误，不返回残缺列表', () async {
      final adapter = DetailAdapter(failWeb: true, failApp: true);
      await expectLater(client(adapter).detail(id), throwsA(isA<CatalogError>()));
    });

    test('App 取不到时官网前缀仍可降级，且只短存 10 分钟', () async {
      final adapter = DetailAdapter(
        webHtml: numericWebPage(['101', '102'], episodeCount: 45),
        failApp: true,
      );
      var clock = DateTime.utc(2026, 11, 27, 12);
      final dio = Dio()..httpClientAdapter = adapter;
      final catalog = CatalogClient(
        dio: dio,
        deviceId: '1234567890123456',
        now: () => clock,
        retry: NetworkRetry(delays: const []),
        protocol: const AppSettings(timeoutSeconds: 10),
      );
      final detail = await catalog.detail(id);
      expect(detail.episodes.map((e) => e.vid), ['101', '102']);
      // 前缀缓存 10 分钟内仍命中；过后重新试 App，给上游恢复的机会。
      clock = clock.add(const Duration(minutes: 9));
      expect(await catalog.detail(id), same(detail));
      adapter.failApp = false;
      adapter.appVideos = videos(45);
      adapter.appEpisodeCount = 45;
      clock = clock.add(const Duration(minutes: 2));
      final refreshed = await catalog.detail(id);
      expect(refreshed, isNot(same(detail)));
      expect(refreshed.episodes, hasLength(45));
    });
  });
}
