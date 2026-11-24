import 'dart:convert';

import 'package:hongguo_api/src/web_source.dart';
import 'package:test/test.dart';

Map<String, dynamic> _router({
  required String seriesId,
  required List<String> vids,
  String title = '测试短剧',
  String cover = 'https://p3-sign.example.com/cover.jpg',
  String key = 'player_(series_id)/page',
  Object? accessible,
  bool? success,
}) => {
  'loaderData': {
    key: {
      if (success != null) 'isSuccess': success,
      'series_id': seriesId,
      'seriesDetail': {
        'series_id': seriesId,
        'series_name': title,
        'series_cover': cover,
        'vid_list': vids,
        if (accessible != null) 'accessible_episode_cnt': accessible,
      },
    },
  },
};

String _page(Map<String, dynamic> router) =>
    '<html><script>window._ROUTER_DATA=${jsonEncode(router)};</script></html>';

void main() {
  group('readRouterData', () {
    test('提取并配平嵌套 JSON', () {
      final router = _router(seriesId: '123', vids: ['1']);
      final data = readRouterData(_page(router));
      expect(data, isNotNull);
      expect(data!['loaderData'], isA<Map>());
    });
    test('没有 router 数据时返回 null', () {
      expect(readRouterData('<html>plain</html>'), isNull);
    });
    test('未闭合的花括号返回 null 而不是抛出', () {
      expect(
        readRouterData('<script>window._ROUTER_DATA={"a":{"b":1</script>'),
        isNull,
      );
    });
  });

  group('parseEpisodeListHtml', () {
    test('正常解析分集与标题', () {
      final page = _page(
        _router(seriesId: '731111222233344', vids: ['101', '102', '103']),
      );
      final result = parseEpisodeListHtml(page, '731111222233344');
      expect(result, isNotNull);
      expect(result!.vids, ['101', '102', '103']);
      expect(result.seriesTitle, '测试短剧');
      expect(result.accessibleEpisodes, isNull);
    });
    test('限免集数被截断到真实分集数', () {
      final page = _page(
        _router(
          seriesId: '731111222233344',
          vids: ['101', '102'],
          accessible: 5,
        ),
      );
      expect(
        parseEpisodeListHtml(page, '731111222233344')!.accessibleEpisodes,
        2,
      );
    });
    test('剧集身份不符返回 null', () {
      final page = _page(_router(seriesId: '731111222233344', vids: ['101']));
      expect(parseEpisodeListHtml(page, '999'), isNull);
    });
    test('vid 含非数字返回 null', () {
      final page = _page(
        _router(seriesId: '731111222233344', vids: ['101', 'x']),
      );
      expect(parseEpisodeListHtml(page, '731111222233344'), isNull);
    });
    test('isSuccess=false 返回 null', () {
      final page = _page(
        _router(seriesId: '731111222233344', vids: ['101'], success: false),
      );
      expect(parseEpisodeListHtml(page, '731111222233344'), isNull);
    });
    test('vid 重复返回 null', () {
      final page = _page(
        _router(seriesId: '731111222233344', vids: ['101', '101']),
      );
      expect(parseEpisodeListHtml(page, '731111222233344'), isNull);
    });
  });

  group('extractLdJsonPlayUrl', () {
    const sid = '731111222233344', vid = '101';
    String page({required String contentUrl, String? url, String? atId}) {
      final video = {
        '@type': 'VideoObject',
        'contentUrl': contentUrl,
        if (url != null) 'url': url,
        if (atId != null) '@id': atId,
      };
      return '<html><script type="application/ld+json">${jsonEncode(video)}</script></html>';
    }

    const media = 'https://v3-fq.fqnovelvod.com/object/video101.mp4';
    test('绑定到当前 player 页的直链可提取', () {
      final html = page(contentUrl: media, url: '$siteOrigin/player/$sid/$vid');
      expect(extractLdJsonPlayUrl(html, sid, vid), media);
    });
    test('省略 vid 的当前页 + /video/public/{vid}/ 路径也可提取', () {
      final html = page(
        contentUrl: 'https://v.fqnovelvod.com/video/public/$vid/abc.mp4',
        url: '$siteOrigin/player/$sid',
      );
      expect(
        extractLdJsonPlayUrl(html, sid, vid),
        'https://v.fqnovelvod.com/video/public/$vid/abc.mp4',
      );
    });
    test('其它视频的地址被拒绝', () {
      final html = page(contentUrl: media, url: '$siteOrigin/player/$sid/999');
      expect(extractLdJsonPlayUrl(html, sid, vid), isNull);
    });
    test('非白名单域被拒绝', () {
      final html = page(
        contentUrl: 'https://evil.example.com/a.mp4',
        url: '$siteOrigin/player/$sid/$vid',
      );
      expect(extractLdJsonPlayUrl(html, sid, vid), isNull);
    });
    test('HTML 转义与 Range 参数被归一', () {
      final html = page(
        contentUrl:
            'https:\\/\\/v3-fq.fqnovelvod.com\\/o.mp4?Range=bytes%3D0-100&br=1',
        url: '$siteOrigin/player/$sid/$vid',
      );
      expect(
        extractLdJsonPlayUrl(html, sid, vid),
        'https://v3-fq.fqnovelvod.com/o.mp4?br=1',
      );
    });
  });

  group('parsePublicFallbackPlayUrl', () {
    final now = DateTime.parse('2026-11-23T00:00:00Z').millisecondsSinceEpoch;
    test('有效响应解析为 360p 直链', () {
      final url = parsePublicFallbackPlayUrl({
        'base_resp': {'StatusCode': 0},
        'main_url': 'https:\\/\\/v.fqnovelvod.com\\/x.mp4',
        'url_expire': (now + 600000) ~/ 1000,
      }, nowMillis: now);
      expect(url, isNotNull);
      expect(url!.url, 'https://v.fqnovelvod.com/x.mp4');
      expect(url.quality, '360p');
    });
    test('业务码非 0 返回 null', () {
      expect(
        parsePublicFallbackPlayUrl({
          'base_resp': {'StatusCode': 1001},
          'main_url': 'https://v.fqnovelvod.com/x.mp4',
        }, nowMillis: now),
        isNull,
      );
    });
    test('过期地址返回 null', () {
      expect(
        parsePublicFallbackPlayUrl({
          'base_resp': {'StatusCode': 0},
          'main_url': 'https://v.fqnovelvod.com/x.mp4',
          'url_expire': (now - 1000) ~/ 1000,
        }, nowMillis: now),
        isNull,
      );
    });
    test('非官方 CDN 域返回 null', () {
      expect(
        parsePublicFallbackPlayUrl({
          'base_resp': {'StatusCode': 0},
          'main_url': 'https://v3.example.com/x.mp4',
        }, nowMillis: now),
        isNull,
      );
    });
  });

  group('searchListFromJson', () {
    test('video_data 剥离与字段归一', () {
      final items = searchListFromJson({
        'searchList': [
          {
            'video_data': {
              'series_id': '731111222233344',
              'series_name': '五短剧',
              'series_cover': 'https://p.c/1.jpg',
              'episode_cnt': 99,
              'tags': [
                '恋爱',
                {'name': '逆袭'},
              ],
            },
          },
          {
            'series_id': '731111222233345',
            'name': '西饭风格条目',
            'keyword': '731111222233345',
          },
        ],
        'totalCount': 2,
        'hasMore': false,
      });
      expect(items, hasLength(2));
      expect(items[0]['series_id'], '731111222233344');
      expect(items[0]['series_title'], '五短剧');
      expect(items[0]['episode_cnt'], 99);
      expect((items[0]['tag_info'] as Map)['text'], '恋爱·逆袭');
      expect(items[1]['series_id'], '731111222233345');
    });
    test('重复 series_id 去重', () {
      final items = searchListFromJson({
        'searchList': [
          {
            'video_data': {'series_id': '731111222233344', 'series_name': 'A'},
          },
          {
            'video_data': {'series_id': '731111222233344', 'series_name': 'B'},
          },
        ],
      });
      expect(items, hasLength(1));
    });
    test('searchList 缺失抛出', () {
      expect(() => searchListFromJson({'code': 0}), throwsFormatException);
    });
    test('非空列表但零识别抛出（字段改名信号）', () {
      expect(
        () => searchListFromJson({
          'searchList': [
            {'foo': 'bar'},
          ],
        }),
        throwsFormatException,
      );
    });
    test('code 为字符串时抛出', () {
      expect(
        () => searchListFromJson({'code': 'EACCES', 'message': '拒绝'}),
        throwsFormatException,
      );
    });
  });

  group('isPublicMediaUrl / normalizeVideoUrl', () {
    test('白名单域与协议校验', () {
      expect(isPublicMediaUrl('https://v.fqnovelvod.com/a.mp4'), isTrue);
      expect(isPublicMediaUrl('https://a.b.qznovelvod.com/a.mp4'), isTrue);
      expect(isPublicMediaUrl('http://v.fqnovelvod.com/a.mp4'), isFalse);
      expect(isPublicMediaUrl('https://evil.com/a.mp4'), isFalse);
      expect(isPublicMediaUrl('https://x@fqnovelvod.com/a.mp4'), isFalse);
    });
    test('Range 剥离与转义归一', () {
      expect(
        normalizeVideoUrl(r'https:\/\/v.fqnovelvod.com\/a.mp4?Range=b0-1&br=9'),
        'https://v.fqnovelvod.com/a.mp4?br=9',
      );
    });
  });
}
