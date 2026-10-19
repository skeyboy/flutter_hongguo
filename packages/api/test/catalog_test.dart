import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:test/test.dart';

class CatalogAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final bodies = <Map<String, dynamic>>[];
  bool failDetail = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (data != null) {
      bodies.add(
        Map<String, dynamic>.from(
          jsonDecode(utf8.decode(await data.expand((b) => b).toList())),
        ),
      );
    }
    if (options.path.contains('/search/')) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return ResponseBody.fromString(
        '<script>{"searchList":[{"video_data":{"series_id":"7661622467441478681","series_title":"玄幻[测试]","episode_cnt":2}}]}</script>',
        200,
      );
    }
    if (options.path.contains('hongguoduanju.com/player/')) {
      return ResponseBody.fromString(
        '{"vid_list":["7661622467441478682","7661622467441478683"],"series_name":"回退剧名"}',
        200,
      );
    }
    if (options.path.contains('bookmall/cell/change/v')) {
      return ResponseBody.fromString(
        jsonEncode({
          'code': 0,
          'data': {
            'cell_view': {
              'cell_data': [
                {
                  'video_data': {
                    'series_id': '123',
                    'title': '漫剧榜单',
                    'episode_cnt': 3,
                  },
                },
              ],
              'has_more': true,
              'next_offset': 10,
            },
          },
        }),
        200,
      );
    }
    if (options.path.contains('multi_video_detail')) {
      return ResponseBody.fromString(
        jsonEncode(
          failDetail
              ? {'code': 110001}
              : {
                  'code': 0,
                  'data': {
                    '7661622467441478681': {
                      'video_data': {
                        'series_id': '7661622467441478681',
                        'series_title': '测试剧名',
                        'video_list': [
                          {'vid': '7661622467441478683', 'vid_index': 2},
                          {'vid': '7661622467441478682', 'vid_index': 1},
                        ],
                      },
                    },
                  },
                },
        ),
        200,
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'code': 0,
        'data': {
          'video_data': [
            {
              'series_id': '7661622467441478681',
              'title': '测试剧名',
              'episode_cnt': 2,
            },
          ],
          'has_more': false,
        },
      }),
      200,
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late CatalogAdapter adapter;
  late Dio dio;
  late CatalogClient client;
  setUp(() {
    adapter = CatalogAdapter();
    dio = Dio()..httpClientAdapter = adapter;
    client = CatalogClient(dio: dio, deviceId: '1234567890123456');
  });
  tearDown(() => dio.close());
  test('awaits HTML before parsing and preserves >53-bit IDs', () async {
    final page = await client.search('玄幻');
    expect(page.items.single.id, '7661622467441478681');
    expect(page.items.single.title, '玄幻[测试]');
    expect(adapter.requests, hasLength(1));
  });
  test(
    'AI classification and seen IDs map to proper landpage fields',
    () async {
      await client.browse(
        genre: 'ai_series',
        cursor: '18',
        seen: ['123'],
        theme: 'cate_7',
      );
      final body = adapter.bodies.single;
      expect(body['req_scene'], 'ai_series');
      expect(body['offset'], 18);
      expect(body['filter_ids'], '123');
      expect(body['select_items']['genre'], ['ai_series']);
      expect(body['select_items']['category_dim_theme'], ['cate_7']);
    },
  );
  test('signed details sorted, cached, and ID remains a string', () async {
    final detail = await client.detail('7661622467441478681');
    expect(detail.episodes.map((e) => e.index), [1, 2]);
    expect(detail.episodes.first.vid, '7661622467441478682');
    expect(adapter.requests.single.headers['x-medusa'], isNotEmpty);
    expect(
      identical(await client.detail('7661622467441478681'), detail),
      isTrue,
    );
    expect(adapter.requests, hasLength(1));
  });
  test('App errors fall back to awaited website episodes', () async {
    adapter.failDetail = true;
    final detail = await client.detail('7661622467441478681');
    expect(detail.drama.title, '回退剧名');
    expect(detail.episodes, hasLength(2));
  });
  test('HTML scanner respects brackets and escaped quotes inside strings', () {
    final html = jsonEncode({
      'searchList': [
        {
          'video_data': {
            'series_id': '1',
            'series_title': '文字 ] \\" [',
            'episode_cnt': 1,
          },
        },
      ],
    });
    expect(CatalogClient.parseWebSearch(html).single.title, contains(']'));
  });
  test(
    'rank uses the real comic board and upstream pagination cursor',
    () async {
      final page = await client.rank(board: 'hot');
      expect(page.items.single.title, '漫剧榜单');
      expect(page.nextCursor, '10');
      final query = adapter.requests.single.uri.queryParameters;
      expect(query['sub_selected_items'], 'comic_series_hot_play');
      expect(
        query['session_uuid'],
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    },
  );
}
