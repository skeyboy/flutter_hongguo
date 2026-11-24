import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart' show SourceSettings;
import 'package:test/test.dart';

Map<String, dynamic> _ep(String id, int index, bool unlock, String playUrl) => {
  'episodeId': id,
  'index': index,
  'title': '第 $index 集',
  'unlock': unlock,
  'playUrl': playUrl,
};

/// 离线 HTTP 层：按 path + reqType 分发假 JSON，记录每次请求的 query/header。
class XifanFixture implements HttpClientAdapter {
  XifanFixture({
    this.ret = 0,
    this.timeout = false,
    Map<String, dynamic>? detail,
  }) : detail = detail ?? defaultDetail;

  int ret;
  bool timeout;
  Map<String, dynamic> detail;
  final urls = <Uri>[];
  final queries = <Map<String, dynamic>>[];
  final headers = <List<String>>[];

  static const categories = {
    'elements': [
      {
        'contents': [
          {
            'categoryItemVo': {
              'categoryId': 1,
              'oppoCategory': '都市',
              'version': 3,
            },
          },
          {
            'categoryItemVo': {
              'categoryId': 2,
              'oppoCategory': '<b>古装</b>',
              'version': 1,
              'subCategories': [
                {'categoryId': 3, 'oppoCategory': '穿越', 'version': 2},
              ],
            },
          },
        ],
      },
    ],
  };

  static const list = {
    'hasMore': true,
    'elements': [
      {
        'contents': [
          {
            'duanjuVo': {
              'source': 'jiuzhou',
              'duanjuId': '253',
              'title': '<i>都市</i>逆袭',
              'coverImageUrl': 'https://cdn.xifan.tv/cover.jpg',
              'total': 12,
              'categories': ['热血', '<b>逆袭</b>', '热血', '都市', '商战', 'extra'],
            },
          },
          {
            // 同一 seriesId 重复，应被归一层去重。
            'duanjuVo': {
              'source': 'jiuzhou',
              'duanjuId': '253',
              'title': '重复剧',
            },
          },
          {
            // source 含非法字符，应被丢弃。
            'duanjuVo': {
              'source': 'bad.source',
              'duanjuId': '9',
              'title': '非法剧',
            },
          },
          {
            // cover 是 http，归一后应为空串。
            'duanjuVo': {
              'source': 'jiuzhou',
              'duanjuId': '254',
              'title': '另一部',
              'coverImageUrl': 'http://cdn.xifan.tv/cover.jpg',
            },
          },
        ],
      },
    ],
  };

  static Map<String, dynamic> get defaultDetail => {
    'source': 'jiuzhou',
    'duanjuId': '253',
    'title': '<b>测试短剧</b>',
    'coverImageUrl': 'https://cdn.xifan.tv/cover.jpg',
    'categories': ['都市', '逆袭'],
    'episodeList': [
      _ep('1', 1, true, 'https://cdn.xifan.tv/v/1.mp4'),
      _ep('2', 2, false, 'https://cdn.xifan.tv/v/2.mp4'),
    ],
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async {
    urls.add(options.uri);
    queries.add(options.queryParameters);
    headers.add([
      '${options.headers['User-Agent'] ?? ''}',
      '${options.headers['Accept'] ?? ''}',
    ]);
    if (timeout) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.receiveTimeout,
      );
    }
    final path = options.uri.path;
    Object result;
    if (path == '/xifan/drama/portalPage' &&
        options.queryParameters['reqType'] == 'duanjuCategory') {
      result = categories;
    } else if (path == '/xifan/drama/portalPage') {
      result = list;
    } else if (path == '/xifan/search/getSearchList') {
      result = list;
    } else if (path == '/xifan/drama/getDuanjuInfo') {
      result = detail;
    } else {
      result = <String, dynamic>{};
    }
    return ResponseBody.fromString(
      jsonEncode({'ret': ret, 'result': result}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  XifanAdapter adapterFor(XifanFixture fixture, {DateTime Function()? now}) {
    final dio = Dio()..httpClientAdapter = fixture;
    addTearDown(() => dio.close());
    return XifanAdapter(dio, now: now);
  }

  test('身份、匹配与默认启用', () {
    final adapter = adapterFor(XifanFixture());
    expect(adapter.id, 'xifan');
    expect(adapter.label, '西饭');
    expect(adapter.kind, SourceKind.builtin);
    expect(adapter.matches('xifan:a:b'), isTrue);
    expect(adapter.matches('hema:a'), isFalse);
    expect(adapter.enabled(const SourceSettings()), isTrue);
    expect(
      adapter.enabled(const SourceSettings(builtin: {'xifan': false})),
      isFalse,
    );
  });

  test('browse 归一：去 HTML、tags 去重截断、重复项去重、翻页游标', () async {
    final fixture = XifanFixture();
    final page = await adapterFor(fixture).browse();

    expect(page.items, hasLength(2));
    final first = page.items.first;
    expect(first.id, 'xifan:jiuzhou:253');
    expect(first.title, '都市逆袭');
    expect(first.cover, 'https://cdn.xifan.tv/cover.jpg');
    expect(first.episodeCount, 12);
    expect(first.tagNames, ['热血', '逆袭', '都市', '商战']);
    expect(page.items.last.cover, isEmpty); // http 封面被 httpsUrl 拒绝
    expect(page.nextCursor, '2');

    final query = fixture.queries.last;
    expect(query['reqType'], 'aggregationPage');
    expect(query['offset'], 0);
    expect(query['categoryNames'], '都市');
    expect(query['version'], 2001001);
    expect(query['androidVersionCode'], 28);
    expect(fixture.headers.last, ['Mozilla/5.0', 'application/json']);
  });

  test('分类缓存 5 分钟，过期后重新拉取', () async {
    var now = DateTime(2026, 1, 1);
    final fixture = XifanFixture();
    final adapter = adapterFor(fixture, now: () => now);

    await adapter.browse();
    final count = fixture.urls
        .where((u) => u.queryParameters['reqType'] == 'duanjuCategory')
        .length;
    now = now.add(const Duration(minutes: 4));
    await adapter.browse();
    expect(
      fixture.urls.where(
        (u) => u.queryParameters['reqType'] == 'duanjuCategory',
      ),
      hasLength(count),
    );
    now = now.add(const Duration(minutes: 2));
    await adapter.browse();
    expect(
      fixture.urls.where(
        (u) => u.queryParameters['reqType'] == 'duanjuCategory',
      ),
      hasLength(count + 1),
    );
  });

  test('search 归一与空关键词拒绝', () async {
    final fixture = XifanFixture();
    final adapter = adapterFor(fixture);
    final page = await adapter.search('  逆袭  ');
    expect(page.items.first.id, 'xifan:jiuzhou:253');
    expect(fixture.queries.last['keyword'], '逆袭');
    expect(fixture.queries.last['pageIndex'], 1);

    await expectLater(
      adapter.search('   '),
      throwsA(
        isA<SourceRejected>().having((e) => e.message, 'message', '请输入搜索关键词'),
      ),
    );
  });

  test('detail 分集按 index 升序并标注 locked', () async {
    final detail = await adapterFor(XifanFixture()).detail('xifan:jiuzhou:253');
    expect(detail.drama.title, '测试短剧');
    expect(detail.drama.cover, 'https://cdn.xifan.tv/cover.jpg');
    expect(detail.drama.tagNames, ['都市', '逆袭']);
    expect(detail.episodes.map((e) => e.vid), [
      'xifan:jiuzhou:253:1',
      'xifan:jiuzhou:253:2',
    ]);
    expect(detail.episodes.map((e) => e.title), ['第 1 集', '第 2 集']);
    expect(detail.episodes.map((e) => e.locked), [false, true]);
  });

  test('fetchTrack 解锁集返回明文 VideoTrack', () async {
    final fixture = XifanFixture();
    final track = await adapterFor(fixture).fetchTrack('xifan:jiuzhou:253:1');
    expect(track.url.toString(), 'https://cdn.xifan.tv/v/1.mp4');
    expect(track.source, 'xifan');
    expect(track.spadeA, isEmpty);
    expect(track.definition, isEmpty);
    expect(track.userAgent, 'Mozilla/5.0');
    expect(track.format, VideoFormat.mp4);
    expect(track.policy, isA<PublicWebPolicy>());
    expect((track.policy! as PublicWebPolicy).hosts, ['xifan.tv']);
  });

  test('fetchTrack 锁集抛 SourceLocked', () async {
    final adapter = adapterFor(XifanFixture());
    await expectLater(
      adapter.fetchTrack('xifan:jiuzhou:253:2'),
      throwsA(
        isA<SourceLocked>().having(
          (e) => e.message,
          'message',
          contains('第 2 集当前锁定'),
        ),
      ),
    );
  });

  test('fetchTrack 每次重读详情，不复用缓存的解锁状态', () async {
    final fixture = XifanFixture();
    final adapter = adapterFor(fixture);
    await expectLater(
      adapter.fetchTrack('xifan:jiuzhou:253:2'),
      throwsA(isA<SourceLocked>()),
    );

    // 上游刚解锁：第二次取址必须反映最新状态。
    fixture.detail = {
      ...fixture.detail,
      'episodeList': [
        _ep('1', 1, true, 'https://cdn.xifan.tv/v/1.mp4'),
        _ep('2', 2, true, 'https://cdn.xifan.tv/v/2.mp4'),
      ],
    };
    final track = await adapter.fetchTrack('xifan:jiuzhou:253:2');
    expect(track.url.toString(), 'https://cdn.xifan.tv/v/2.mp4');
    expect(
      fixture.urls.where((u) => u.path == '/xifan/drama/getDuanjuInfo'),
      hasLength(2),
    );
  });

  test('私网/凭据/非 HTTPS 的 playUrl 被拒', () async {
    for (final bad in [
      'http://cdn.xifan.tv/v.mp4',
      'https://user:pass@cdn.xifan.tv/v.mp4',
      'https://127.0.0.1/v.mp4',
      'https://192.168.1.1/v.mp4',
    ]) {
      final fixture = XifanFixture();
      fixture.detail = {
        ...fixture.detail,
        'episodeList': [_ep('1', 1, true, bad)],
      };
      await expectLater(
        adapterFor(fixture).fetchTrack('xifan:jiuzhou:253:1'),
        throwsA(
          isA<SourceUnavailable>().having(
            (e) => e.message,
            'message',
            '西饭未提供有效 HTTPS 播放地址',
          ),
        ),
      );
    }
  });

  test('恶意 host 被 PublicWebPolicy 拒绝', () async {
    final track = await adapterFor(XifanFixture())
        .fetchTrack('xifan:jiuzhou:253:1');
    expect(
      () => checkMediaUrl('https://evil.example.com/v.mp4', track.policy!),
      throwsA(isA<FormatException>()),
    );
    // 同域名族仍放行：策略基于 eTLD+1，而不是只认单台边缘机。
    expect(
      checkMediaUrl('https://other.xifan.tv/v.mp4', track.policy!).host,
      'other.xifan.tv',
    );
  });

  test('非法 ID 抛 SourceRejected', () async {
    final adapter = adapterFor(XifanFixture());
    for (final id in [
      'xifan:jiuzhou', // 段数不足
      'xifan:jiuzhou:253:1:extra', // 段数过多
      'xifan:jiuzhou:bad.id', // 非法字符
      'other:jiuzhou:253', // 前缀不符
    ]) {
      await expectLater(
        adapter.detail(id),
        throwsA(
          isA<SourceRejected>().having((e) => e.message, 'message', '西饭剧集编号无效'),
        ),
      );
    }
    await expectLater(
      adapter.fetchTrack('xifan:jiuzhou:253'), // 分集形态缺一段
      throwsA(isA<SourceRejected>()),
    );
  });

  test('详情与请求不一致抛 SourceUnavailable', () async {
    final fixture = XifanFixture();
    fixture.detail = {...fixture.detail, 'duanjuId': '999'};
    await expectLater(
      adapterFor(fixture).detail('xifan:jiuzhou:253'),
      throwsA(
        isA<SourceUnavailable>().having(
          (e) => e.message,
          'message',
          '西饭返回的剧集与请求不一致',
        ),
      ),
    );
  });

  test('超时抛 SourceUnavailable（超时文案）', () async {
    await expectLater(
      adapterFor(XifanFixture(timeout: true)).browse(),
      throwsA(
        isA<SourceUnavailable>().having(
          (e) => e.message,
          'message',
          '西饭加载超时，请重试',
        ),
      ),
    );
  });

  test('ret != 0 抛 SourceUnavailable，不回传远端原文', () async {
    await expectLater(
      adapterFor(XifanFixture(ret: 500)).browse(),
      throwsA(
        isA<SourceUnavailable>().having(
          (e) => e.message,
          'message',
          '西饭来源暂不可用，请稍后重试',
        ),
      ),
    );
  });
}
