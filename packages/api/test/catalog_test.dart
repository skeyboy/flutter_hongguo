import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:test/test.dart';

class CatalogAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final bodies = <Map<String, dynamic>>[];
  bool failDetail = false;

  /// 官网两页竞速（/player 与 /detail）失败开关：App 分集接口路径的测试用它
  /// 把 web 层压掉，才能测到签名请求本身。
  bool failWeb = false;
  String rankVersion = '1793325840';

  /// 搜索分页夹具：每项是 `searchList` 的一页。设了它才按 `?page=` 应答，
  /// 否则一直是同一页（老行为）。
  List<Map<String, dynamic>>? searchPages;
  bool searchHasMorePages = false;
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
    if (options.path.contains('/api/search/result')) {
      final pages = searchPages;
      if (pages == null) {
        return ResponseBody.fromString(
          jsonEncode({
            'searchList': [
              {
                'video_data': {
                  'series_id': '7661622467441478681',
                  'series_title': '玄幻[测试]',
                  'episode_cnt': 2,
                },
              },
            ],
            'hasMore': false,
          }),
          200,
        );
      }
      final page =
          int.tryParse(options.uri.queryParameters['page'] ?? '1') ?? 1;
      final index = page - 1;
      return ResponseBody.fromString(
        jsonEncode({
          'searchList': index < pages.length ? [pages[index]] : <Object>[],
          'pageNum': page,
          'hasMore': searchHasMorePages && index + 1 < pages.length,
        }),
        200,
      );
    }
    if (options.path.contains('/search/')) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return ResponseBody.fromString(
        '<script>{"searchList":[{"video_data":{"series_id":"7661622467441478681","series_title":"玄幻[测试]","episode_cnt":2}}]}</script>',
        200,
      );
    }
    if (options.path.contains('hongguoduanju.com/player/') ||
        options.path.contains('hongguoduanju.com/detail')) {
      if (failWeb) return ResponseBody.fromString('', 404);
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
            'rank_version': rankVersion,
            'cell_view': {
              'cell_selector': {
                'outer_row': {
                  'items': [
                    {
                      'show_name': '漫剧',
                      'selector_item_id': 'comic_series_rank',
                      'sub_cell_selector': {
                        'outer_row': {
                          'items': [
                            {
                              'show_name': '热播榜',
                              'selector_item_id': 'comic_series_hot_play',
                            },
                          ],
                        },
                      },
                    },
                    {
                      'show_name': '演员',
                      'selector_item_id': 'ranklist_celebrity',
                    },
                  ],
                },
              },
              'cell_data': [
                {
                  'video_data': {
                    'series_id': '123',
                    'title': '漫剧榜单',
                    'episode_cnt': 3,
                    'rec_text_item': {'RecommendText': '6182万热度'},
                    'secondary_info_list': [
                      {'content': '422.8万收藏'},
                    ],
                    'score': '8.2',
                    'tag_info': {'text': '爆剧'},
                    'sub_title': '玄幻·全100集',
                    'color_dominate': '#282828',
                    'play_cnt': 1035,
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
    // 官网 JSON 接口一发命中，不再需要 SSR 或 App 搜索。
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.path, contains('/api/search/result'));
  });
  test('搜索翻页继续走官网 JSON，不中途换成 App 搜索', () async {
    Map<String, dynamic> entry(String id, String title) => {
      'video_data': {'series_id': id, 'series_title': title, 'episode_cnt': 3},
    };
    adapter
      ..searchPages = [
        entry('7661622467441478681', '第一页'),
        entry('7661622467441478690', '第二页'),
      ]
      ..searchHasMorePages = true;
    final first = await client.search('玄幻');
    expect(first.items.single.title, '第一页');
    expect(first.nextCursor, isNotNull);
    final second = await client.search('玄幻', cursor: first.nextCursor);
    expect(second.items.single.title, '第二页');
    // 两页都由官网 JSON 应答：同一个关键词换源会让同一部剧重复出现。
    expect(
      adapter.requests.every((r) => r.path.contains('/api/search/result')),
      isTrue,
    );
    expect(adapter.requests.last.uri.queryParameters['page'], '2');
    expect(second.nextCursor, isNull);
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
    // 压掉官网两页竞速，只测 App 分集接口的签名路径。
    adapter.failWeb = true;
    final detail = await client.detail('7661622467441478681');
    expect(detail.episodes.map((e) => e.index), [1, 2]);
    expect(detail.episodes.first.vid, '7661622467441478682');
    final appRequests = adapter.requests
        .where((r) => r.path.contains('multi_video_detail'))
        .toList();
    expect(appRequests, hasLength(1));
    expect(appRequests.single.headers['x-medusa'], isNotEmpty);
    expect(
      identical(await client.detail('7661622467441478681'), detail),
      isTrue,
    );
    expect(
      adapter.requests.where((r) => r.path.contains('multi_video_detail')),
      hasLength(1),
    );
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
  test('rank sends the upstream ids it was given and reads back the tree it published', () async {
    final page = await client.rankBoard(board: 'comic_series_hot_play');
    final entry = page.entries.single;
    expect(entry.position, 1);
    expect(entry.drama.title, '漫剧榜单');
    expect(entry.heat, '6182万热度');
    expect(entry.collect, '422.8万收藏');
    expect(entry.score, '8.2');
    expect(entry.badge, '爆剧');
    expect(entry.subtitle, '玄幻·全100集');
    expect(entry.dominateColor, '#282828');
    expect(entry.drama.tagNames, ['爆剧']);
    expect(page.nextCursor, '10');
    expect(
      page.updatedAt,
      DateTime.fromMillisecondsSinceEpoch(1793325840000, isUtc: true),
    );
    expect(page.tracks.map((t) => (t.id, t.label, t.boards.length)), [
      ('comic_series_rank', '漫剧', 1),
      ('ranklist_celebrity', '演员', 0),
    ]);
    expect(page.tracks.first.boards.single.id, 'comic_series_hot_play');
    final query = adapter.requests.single.uri.queryParameters;
    expect(query['selected_items'], 'comic_series_rank');
    expect(query['sub_selected_items'], 'comic_series_hot_play');
    expect(
      query['session_uuid'],
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
  });
  test('rank refuses a selector that is not an upstream id', () async {
    // The likeliest mistake at this boundary is passing the row's show_name
    // where its selector_item_id belongs; that must not reach the wire.
    await expectLater(
      client.rankBoard(board: '热播榜'),
      throwsA(isA<ArgumentError>()),
    );
    expect(adapter.requests, isEmpty);
  });
  test('a board with no rank_version makes no time claim', () async {
    adapter.rankVersion = '';
    final page = await client.rankBoard();
    expect(page.updatedAt, isNull);
  });
}
