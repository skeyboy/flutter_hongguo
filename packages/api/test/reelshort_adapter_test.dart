import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_api/src/sources/reelshort_adapter.dart';
import 'package:test/test.dart';

/// 离线回放 ReelShort 公开页面：所有路由都返回伪造的 `__NEXT_DATA__` HTML。
/// 用 HttpClientAdapter 而非真实网络，保证测试不依赖 reelshort.com 的可用性。
class _FakeReelshortAdapter implements HttpClientAdapter {
  _FakeReelshortAdapter({
    List<dynamic>? shelves,
    List<Map<String, dynamic>>? searchBooks,
    List<Map<String, dynamic>>? onlineBase,
    Map<String, String>? videoUrls,
    this.statusCode = 200,
    this.brokenFormat = false,
  }) : shelves = shelves ?? _defaultShelves,
       searchBooks = searchBooks ?? _defaultSearchBooks,
       onlineBase = onlineBase ?? _defaultOnlineBase,
       videoUrls = videoUrls ?? _defaultVideoUrls;

  final List<dynamic> shelves;
  final List<Map<String, dynamic>> searchBooks;
  final List<Map<String, dynamic>> onlineBase;
  final Map<String, String> videoUrls;
  final int statusCode;
  final bool brokenFormat;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (statusCode != 200) {
      return ResponseBody.fromString('', statusCode);
    }

    final path = options.uri.path;
    late final Map<String, dynamic> pageProps;
    if (path == '/') {
      pageProps = {
        'fallback': {
          '/api/ms/hall/webInfo': {'bookShelfList': shelves},
        },
      };
    } else if (path == '/search') {
      pageProps = {'books': searchBooks};
    } else if (path.startsWith('/movie/')) {
      // slug 自带连字符，末段才是 bookId。
      final bookId = path.split('/').last.split('-').last;
      pageProps = {
        'data': {
          'book_id': bookId,
          'book_title': 'Reel 热剧 One',
          'book_pic': 'https://img.reelshort.com/1001.jpg',
          'special_desc': 'ReelShort 测试简介',
          'online_base': onlineBase,
        },
      };
    } else if (path.startsWith('/episodes/')) {
      final parts = path.split('/').last.split('-');
      final number = int.tryParse(parts[1]) ?? 1;
      final chapterId = parts.last;
      pageProps = {
        'data': {
          'serial_number': number,
          'chapter_id': chapterId,
          'video_url': videoUrls[chapterId] ?? '',
        },
      };
    } else {
      pageProps = {};
    }

    final html = brokenFormat
        ? '<html><script id="__NEXT_DATA__" type="application/json">{bad}</script></html>'
        : '<html><script id="__NEXT_DATA__" type="application/json">'
              '${jsonEncode({
                'props': {'pageProps': pageProps},
              })}'
              '</script></html>';
    return ResponseBody.fromString(
      html,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 书架：一本可直接归一，一本缺 ID 需走搜索补齐，一本标题重复需去重。
const _defaultShelves = [
  {
    'bookshelf_name': '<b>热门</b>',
    'books': [
      {
        'book_id': '1001',
        'book_title': 'Reel 热剧 One',
        'book_pic': 'https://img.reelshort.com/1001.jpg',
        'chapter_count': 12,
        'special_desc': '热剧简介',
      },
      {
        'book_title': 'Reel 热剧 Two', // 缺 book_id：触发 search 补 ID
      },
      {
        'book_id': '1001',
        'book_title': 'Reel 热剧 One', // 标题重复，去重
      },
    ],
  },
  {
    'bookshelf_name': '新剧',
    'books': [
      {'_id': '1003', 'book_title': 'Reel 新剧 Three', 'chapter_count': 3},
    ],
  },
];

const _defaultSearchBooks = [
  {'book_id': '1002', 'book_title': 'Reel 热剧 Two', 'chapter_count': 8},
];

/// 故意乱序：1=未锁 mp4，2=未锁 m3u8，3=锁定。
const _defaultOnlineBase = [
  {
    'serial_number': 3,
    'chapter_id': 'CH3',
    'chapter_name': '第三集',
    'locked': true,
  },
  {'serial_number': 1, 'chapter_id': 'CH1', 'chapter_name': '<em>第一集</em>'},
  {'serial_number': 2, 'chapter_id': 'CH2', 'chapter_name': ''},
];

const _defaultVideoUrls = {
  'CH1': 'https://cdn.reelshort.com/v/1001/1.mp4',
  'CH2': 'https://cdn.reelshort.com/v/1001/2.m3u8',
};

ReelshortAdapter _adapter(_FakeReelshortAdapter fake) =>
    ReelshortAdapter(Dio()..httpClientAdapter = fake);

void main() {
  test('身份、开关与匹配规则（海外默认关）', () {
    final adapter = ReelshortAdapter(Dio());
    expect(adapter.id, 'reelshort');
    expect(adapter.label, 'ReelShort（海外）');
    expect(adapter.kind, SourceKind.builtin);
    expect(adapter.matches('reelshort:1001:reel-one'), isTrue);
    expect(adapter.matches('123'), isFalse);
    expect(adapter.enabled(const SourceSettings()), isFalse);
    expect(
      adapter.enabled(const SourceSettings(builtin: {'reelshort': true})),
      isTrue,
    );
  });

  test('browse 书架归一：去重、_id 回退、标题缺失时 search 补 ID', () async {
    final fake = _FakeReelshortAdapter();
    final page = await _adapter(fake).browse();

    expect(fake.requests.first.uri.path, '/');
    expect(page.items.map((d) => d.id), [
      'reelshort:1001:reel-one',
      'reelshort:1002:reel-two',
      'reelshort:1003:reel-three',
    ]);
    expect(page.items.map((d) => d.title), [
      'Reel 热剧 One',
      'Reel 热剧 Two',
      'Reel 新剧 Three',
    ]);
    expect(page.items.first.episodeCount, 12);
    expect(page.items.first.cover, 'https://img.reelshort.com/1001.jpg');
    // 第 2 本缺 ID → 触发一次按完整标题的搜索，并取回 bookId=1002。
    expect(
      fake.requests
          .where((r) => r.uri.path == '/search')
          .single
          .uri
          .queryParameters,
      {'keywords': 'Reel 热剧 Two'},
    );
    expect(page.nextCursor, isNull); // 官网快照无游标
  });

  test('browse 第 2 页返回空列表，分类 slug 无效被拒', () async {
    final adapter = _adapter(_FakeReelshortAdapter());
    final page = await adapter.browse(cursor: '2');
    expect(page.items, isEmpty);

    await expectLater(
      adapter.browse(genre: 'shelf-999'),
      throwsA(
        isA<SourceRejected>().having(
          (e) => e.message,
          'message',
          'ReelShort 分类已变化，请重新选择',
        ),
      ),
    );
  });

  test('search 归一去重；页码 >1 返回空；空词被拒', () async {
    final fake = _FakeReelshortAdapter(
      searchBooks: [
        {'book_id': '2001', 'book_title': 'Reel 搜索剧'},
        {'_id': '2001', 'book_title': 'Reel 搜索剧'}, // 同 seriesId 去重
        {'book_id': 'http://bad', 'book_title': '无效编号剧'},
      ],
    );
    final adapter = _adapter(fake);
    final page = await adapter.search('  Reel 搜索剧  ');

    expect(fake.requests.single.uri.path, '/search');
    expect(fake.requests.single.uri.queryParameters, {'keywords': 'Reel 搜索剧'});
    expect(page.items, hasLength(1));
    // slug() 把非 [a-z0-9] 字符（含中文）转成空格，中文标题只剩 `reel`。
    expect(page.items.single.id, 'reelshort:2001:reel');

    expect((await adapter.search('任意', cursor: '2')).items, isEmpty);
    await expectLater(adapter.search('   '), throwsA(isA<SourceRejected>()));
  });

  test('detail 分集按 number 升序、locked 标记与标题兜底', () async {
    final detail = await _adapter(_FakeReelshortAdapter())
        .detail('reelshort:1001:reel-one');

    expect(detail.drama.id, 'reelshort:1001:reel-one');
    expect(detail.drama.title, 'Reel 热剧 One');
    expect(detail.drama.episodeCount, 3);
    expect(detail.episodes.map((e) => e.vid), [
      'reelshort:1001:reel-one:1:CH1',
      'reelshort:1001:reel-one:2:CH2',
      'reelshort:1001:reel-one:3:CH3',
    ]);
    expect(detail.episodes.map((e) => e.index), [1, 2, 3]);
    expect(detail.episodes.map((e) => e.locked), [false, false, true]);
    expect(detail.episodes[0].title, '第一集'); // <em> 已剔除
    expect(detail.episodes[1].title, '第 2 集'); // 空标题兜底
  });

  test('fetchTrack mp4 返回明文 VideoTrack（source/spadeA/format/policy）', () async {
    final fake = _FakeReelshortAdapter();
    final track = await _adapter(fake)
        .fetchTrack('reelshort:1001:reel-one:1:CH1');

    expect(track.url.toString(), 'https://cdn.reelshort.com/v/1001/1.mp4');
    expect(track.source, 'reelshort');
    expect(track.spadeA, isEmpty);
    expect(track.definition, isEmpty);
    expect(track.size, 0);
    expect(track.userAgent, 'Mozilla/5.0');
    expect(track.referer, 'https://www.reelshort.com/');
    expect(track.format, VideoFormat.mp4);
    expect(track.policy, isA<PublicWebPolicy>());
    expect((track.policy! as PublicWebPolicy).hosts, ['reelshort.com']);
    // 每次取址都重读详情，且不复用解锁状态。
    expect(fake.requests.first.uri.path, '/movie/reel-one-1001');
    expect(fake.requests.last.uri.queryParameters, {'play_time': '1'});
  });

  test('m3u8 集抛 SourceUnavailable，文案含「HLS」「暂不支持」', () async {
    await expectLater(
      _adapter(_FakeReelshortAdapter())
          .fetchTrack('reelshort:1001:reel-one:2:CH2'),
      throwsA(
        isA<SourceUnavailable>().having(
          (e) {
            expect(e.message, contains('HLS'));
            expect(e.message, contains('暂不支持'));
            return e.message;
          },
          'message',
          '该集为 HLS 流，当前版本暂不支持，请在 ReelShort 官方平台观看',
        ),
      ),
    );
  });

  test('锁集抛 SourceLocked，不返回地址', () async {
    final fake = _FakeReelshortAdapter();
    await expectLater(
      _adapter(fake).fetchTrack('reelshort:1001:reel-one:3:CH3'),
      throwsA(
        isA<SourceLocked>().having(
          (e) => e.message,
          'message',
          '该集已锁定，请在 ReelShort 官方平台确认观看权限',
        ),
      ),
    );
    // 锁集在详情阶段就被拦下，不应再请求 episodes 接口。
    expect(
      fake.requests.any((r) => r.uri.path.startsWith('/episodes/')),
      isFalse,
    );
  });

  test('私网/带凭据的 video_url 被拒', () async {
    for (final bad in [
      'https://127.0.0.1/secret.mp4',
      'https://user:pass@cdn.reelshort.com/v.mp4',
      'http://cdn.reelshort.com/v.mp4',
    ]) {
      final fake = _FakeReelshortAdapter(videoUrls: {'CH1': bad});
      await expectLater(
        _adapter(fake).fetchTrack('reelshort:1001:reel-one:1:CH1'),
        throwsA(
          isA<SourceUnavailable>().having(
            (e) => e.message,
            'message',
            'ReelShort 未提供可直接播放的 HTTPS MP4 或 M3U8 地址',
          ),
        ),
        reason: '$bad 应被公网判定拒绝',
      );
    }
  });

  test('非法 ID 抛 SourceRejected', () async {
    final adapter = _adapter(_FakeReelshortAdapter());
    for (final bad in [
      'reelshort:abc-def:reel-one:1:CH1', // bookId 含连字符，非法
      'reelshort:1001:Reel-One:1:CH1', // slug 含大写
      'reelshort:1001:reel-one:0:CH1', // number=0
      'xifan:1001:reel-one:1:CH1', // 跨源
      'reelshort:1001', // 剧集段数不足
    ]) {
      await expectLater(
        adapter.fetchTrack(bad),
        throwsA(
          isA<SourceRejected>().having(
            (e) => e.message,
            'message',
            'ReelShort 剧集编号无效',
          ),
        ),
        reason: bad,
      );
    }
    await expectLater(
      adapter.detail('reelshort:1001'),
      throwsA(isA<SourceRejected>()),
    );
  });

  test('分享链接 resolveSeriesId 正反例', () async {
    final adapter = _adapter(_FakeReelshortAdapter());
    expect(
      await adapter.resolveSeriesId('reelshort:1001:reel-one'),
      'reelshort:1001:reel-one',
    );
    expect(
      await adapter.resolveSeriesId(
        'https://www.reelshort.com/movie/reel-one-1001',
      ),
      'reelshort:1001:reel-one',
    );
    for (final bad in [
      'https://evil.com/movie/reel-one-1001',
      'https://user:pass@www.reelshort.com/movie/reel-one-1001',
      'https://www.reelshort.com/other/reel-one-1001',
      'not a url',
    ]) {
      await expectLater(
        adapter.resolveSeriesId(bad),
        throwsA(
          isA<SourceRejected>().having(
            (e) => e.message,
            'message',
            '请输入 ReelShort 官网剧集链接',
          ),
        ),
        reason: bad,
      );
    }
  });

  test('__NEXT_DATA__ 格式变化抛固定文案，不回传 jsonDecode 原文', () async {
    await expectLater(
      _adapter(_FakeReelshortAdapter(brokenFormat: true)).browse(),
      throwsA(
        isA<SourceUnavailable>().having(
          (e) => e.message,
          'message',
          'ReelShort 官网数据格式已变化，请等待适配',
        ),
      ),
    );
  });

  test('403 返回地区不可用文案，不回传远端原文', () async {
    await expectLater(
      _adapter(_FakeReelshortAdapter(statusCode: 403)).browse(),
      throwsA(
        isA<SourceUnavailable>().having(
          (e) => e.message,
          'message',
          'ReelShort 当前地区或网络暂不可用（HTTP 403）',
        ),
      ),
    );
  });
}
