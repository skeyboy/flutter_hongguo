import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

/// 离线回放河马页面：GET 返回伪造的 __NEXT_DATA__ HTML，POST 返回搜索 JSON。
/// 用 HttpClientAdapter 而非真实网络，保证测试不依赖 kuaikaw.cn 的可用性。
class _FakeHemaAdapter implements HttpClientAdapter {
  _FakeHemaAdapter({
    required this.books,
    required this.chapters,
    Map<String, dynamic>? info,
    this.searchPayload,
    this.brokenDirectory = false,
    this.brokenDetail = false,
  }) : info = info ?? _sampleInfo;

  final List<Map<String, dynamic>> books;
  final List<Map<String, dynamic>> chapters;
  final Map<String, dynamic> info;
  final Map<String, dynamic>? searchPayload;
  final bool brokenDirectory;
  final bool brokenDetail;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.uri.path;
    if (path == '/seo/video/6007') {
      final payload =
          searchPayload ??
          {
            'retCode': 0,
            'data': {'bookList': books, 'isMore': 1, 'totalSize': books.length},
          };
      return ResponseBody.fromString(
        jsonEncode(payload),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    if (path.startsWith('/drama/')) {
      final html = brokenDetail
          ? '{not-json'
          : _detailHtml(path: path, info: info, chapters: chapters);
      return ResponseBody.fromString(
        html,
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
        },
      );
    }
    final html = brokenDirectory
        ? '{not-json'
        : _directoryHtml(path: path, books: books);
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

Map<String, dynamic> _book(
  int bookId,
  String name, {
  String cover = 'https://img.kuaikaw.cn/cover.jpg',
  int chapters = 12,
  List<String> tags = const ['甜宠', '逆袭'],
}) => {
  'bookId': bookId,
  'bookName': name,
  'coverWap': cover,
  'totalChapterNum': chapters,
  'bookTypeThree': [
    for (final tag in tags) {'name': tag},
  ],
};

const _sampleInfo = <String, dynamic>{
  'bookId': 1001,
  'bookName': '河马测试剧',
  'coverWap': 'https://img.kuaikaw.cn/1001.jpg',
};

/// 两集：付费集 index=1、免费集 index=2，用来同时验证排序与 locked。
List<Map<String, dynamic>> _chapters({
  String freeUrl = 'https://v1.kuaikaw.cn/v/5001_720p.mp4',
  String fallbackUrl = 'https://v2.kuaikaw.cn/v/5001.mp4',
}) => [
  {
    'chapterId': 5001,
    'chapterIndex': 2,
    'chapterName': '<em>第二集</em>',
    'isCharge': '0',
    'bookId': 1001,
    'chapterVideoVo': {'mp4720p': freeUrl, 'mp4': fallbackUrl},
  },
  {
    'chapterId': 5002,
    'chapterIndex': 1,
    'chapterName': '第一集',
    'isCharge': '1',
    'bookId': 1001,
    'chapterVideoVo': {'mp4720p': 'https://v1.kuaikaw.cn/v/5002.mp4'},
  },
];

String _htmlWrap(Map<String, dynamic> pageProps, {String extra = ''}) {
  final payload = {
    'props': {'pageProps': pageProps},
  };
  return '<html><script id="__NEXT_DATA__" type="application/json">'
      '${jsonEncode(payload)}</script>$extra</html>';
}

String _directoryHtml({required String path, required List<dynamic> books}) {
  final parts = path.split('/').where((part) => part.isNotEmpty).toList();
  final slug = parts.length > 1 ? parts[1] : '0';
  final page = parts.length > 2 ? int.tryParse(parts[2]) ?? 1 : 1;
  return _htmlWrap({
    'typeThreeList': [
      {
        'name': '<b>恋爱</b>',
        'typeThreeIds': [1, 2],
      },
      {
        'name': '逆袭',
        'typeThreeIds': [3],
      },
      {
        'name': '重复题材',
        'typeThreeIds': [1, 2],
      }, // 同 slug，应去重
      {
        'name': '',
        'typeThreeIds': [9],
      }, // 空名，应丢弃
      {
        'name': '超限',
        'typeThreeIds': [for (var i = 10; i < 27; i++) i],
      }, // 17 段，应丢弃
    ],
    'bookList': books,
    'page': page,
    'typeThreeId': slug == '0' ? 0 : slug,
  }, extra: '<a href="/browse/$slug/${page + 1}">下一页</a>');
}

String _detailHtml({
  required String path,
  required Map<String, dynamic> info,
  required List<dynamic> chapters,
}) {
  return _htmlWrap({
    'bookInfoVo': info,
    'chapterList': chapters,
    'requestedPath': path,
  });
}

HemaAdapter _adapter(_FakeHemaAdapter fake) =>
    HemaAdapter(Dio()..httpClientAdapter = fake);

void main() {
  test('身份、开关与匹配规则', () {
    final adapter = HemaAdapter(Dio());
    expect(adapter.id, 'hema');
    expect(adapter.label, '河马');
    expect(adapter.kind, SourceKind.builtin);
    expect(adapter.matches('hema:1001'), isTrue);
    expect(adapter.matches('123'), isFalse);
    expect(adapter.enabled(const SourceSettings()), isTrue);
    expect(
      adapter.enabled(const SourceSettings(builtin: {'hema': false})),
      isFalse,
    );
  });

  test('browse 归一：分类 slug、封面、标签、去重与下一页游标', () async {
    final fake = _FakeHemaAdapter(
      books: [
        _book(101, '<b>河马剧甲</b>'),
        _book(101, '重复条目'), // 同一 bookId 必须去重
        _book(102, '河马剧乙', cover: 'http://insecure.example.com/cover.jpg'),
        _book(103, '私网封面剧', cover: 'https://127.0.0.1/cover.jpg'),
      ],
      chapters: _chapters(),
    );
    final page = await _adapter(fake).browse();

    expect(page.items, hasLength(3));
    final first = page.items.first;
    expect(first.id, 'hema:101');
    expect(first.title, '河马剧甲');
    expect(first.cover, 'https://img.kuaikaw.cn/cover.jpg');
    expect(first.episodeCount, 12);
    expect(first.tagNames, ['甜宠', '逆袭']);
    expect(page.items[1].cover, isEmpty); // http 被 httpsUrl 拒绝
    expect(page.items[2].cover, isEmpty); // 私网 IP 被公网判定拒绝
    expect(page.nextCursor, '2');
    expect(fake.requests.first.uri.path, '/browse');
  });

  test('browse 指定题材/页码并命中 5 分钟题材缓存', () async {
    final fake = _FakeHemaAdapter(
      books: [_book(201, '逆袭剧')],
      chapters: _chapters(),
    );
    final adapter = _adapter(fake);
    final page = await adapter.browse(genre: '1-2', cursor: '3');

    expect(fake.requests.first.uri.path, '/browse'); // 先取题材目录
    expect(fake.requests.last.uri.path, '/browse/1-2/3');
    expect(page.items.single.id, 'hema:201');
    expect(page.nextCursor, '4');

    await adapter.browse(genre: '3'); // 第二次命中缓存，不再请求 /browse
    expect(fake.requests.where((r) => r.uri.path == '/browse'), hasLength(1));
    expect(fake.requests.last.uri.path, '/browse/3');

    await expectLater(
      adapter.browse(genre: '9-9'),
      throwsA(isA<SourceRejected>()),
      reason: '缓存中不存在该 slug 应拒绝',
    );
  });

  test('search POST 参数、归一与 hasMore 游标', () async {
    final fake = _FakeHemaAdapter(
      books: [_book(301, '搜索剧')],
      chapters: _chapters(),
    );
    final page = await _adapter(fake).search('  逆袭  ', cursor: '2');

    expect(fake.requests.single.uri.path, '/seo/video/6007');
    expect(fake.requests.single.method, 'POST');
    expect(fake.requests.single.data, {
      'sourceType': 1,
      'keyword': '逆袭',
      'index': 2,
    });
    expect(page.items.single.id, 'hema:301');
    expect(page.nextCursor, '3');
  });

  test('search 上游 retCode 非 0 时抛 SourceUnavailable', () async {
    final fake = _FakeHemaAdapter(
      books: [_book(301, '搜索剧')],
      chapters: _chapters(),
      searchPayload: {
        'retCode': 500,
        'data': {'bookList': []},
      },
    );
    await expectLater(
      _adapter(fake).search('逆袭'),
      throwsA(
        isA<SourceUnavailable>().having(
          (e) => e.message,
          'message',
          '河马搜索数据异常，请稍后重试',
        ),
      ),
    );
  });

  test('search 空关键词抛 SourceRejected', () async {
    final fake = _FakeHemaAdapter(
      books: [_book(301, '搜索剧')],
      chapters: _chapters(),
    );
    await expectLater(
      _adapter(fake).search('   '),
      throwsA(
        isA<SourceRejected>().having((e) => e.message, 'message', '请输入搜索关键词'),
      ),
    );
  });

  test('detail 分集 locked 标记并按 index 升序', () async {
    final fake = _FakeHemaAdapter(
      books: [_book(1001, '河马测试剧')],
      chapters: _chapters(),
    );
    final detail = await _adapter(fake).detail('hema:1001');

    expect(detail.drama.id, 'hema:1001');
    expect(detail.drama.title, '河马测试剧');
    expect(detail.drama.episodeCount, 2);
    expect(detail.episodes.map((e) => e.vid), [
      'hema:1001:5002',
      'hema:1001:5001',
    ]);
    expect(detail.episodes.map((e) => e.locked), [true, false]);
    expect(detail.episodes.first.title, '第一集');
    expect(detail.episodes.first.index, 1);
    expect(detail.episodes.last.title, '第二集'); // <em> 标签已剔除
  });

  test('fetchTrack 免费集返回明文 VideoTrack', () async {
    final fake = _FakeHemaAdapter(
      books: [_book(1001, '河马测试剧')],
      chapters: _chapters(),
    );
    final track = await _adapter(fake).fetchTrack('hema:1001:5001');

    expect(track.url.toString(), 'https://v1.kuaikaw.cn/v/5001_720p.mp4');
    expect(track.source, 'hema');
    expect(track.spadeA, isEmpty); // 明文，不带红果 CENC 参数
    expect(track.definition, '');
    expect(track.userAgent, 'Mozilla/5.0');
    expect(track.referer, 'https://www.kuaikaw.cn/');
    expect(track.format, VideoFormat.mp4);
    final policy = track.policy;
    expect(policy, isA<PublicWebPolicy>());
    expect((policy as PublicWebPolicy).refererHost, 'www.kuaikaw.cn');
    expect(policy.hosts, ['kuaikaw.cn']);
  });

  test('fetchTrack 付费集抛 SourceLocked，不返回地址', () async {
    final fake = _FakeHemaAdapter(
      books: [_book(1001, '河马测试剧')],
      chapters: _chapters(),
    );
    await expectLater(
      _adapter(fake).fetchTrack('hema:1001:5002'),
      throwsA(
        isA<SourceLocked>().having(
          (e) => e.message,
          'message',
          '第 1 集当前锁定，请在河马官方平台确认可看范围',
        ),
      ),
    );
  });

  test('私网与带凭据地址被拒，mp4 回退也无效时抛 SourceUnavailable', () async {
    final fake = _FakeHemaAdapter(
      books: [_book(1001, '河马测试剧')],
      chapters: _chapters(
        freeUrl: 'https://127.0.0.1/secret.mp4',
        fallbackUrl: 'https://user:pass@cdn.kuaikaw.cn/v.mp4',
      ),
    );
    await expectLater(
      _adapter(fake).fetchTrack('hema:1001:5001'),
      throwsA(
        isA<SourceUnavailable>().having(
          (e) => e.message,
          'message',
          '河马未提供有效 HTTPS 播放地址',
        ),
      ),
    );
  });

  test('十进制回环、云元数据与 Fake-IP 等恶意 host 被拒', () async {
    for (final bad in [
      'https://2130706433/v.mp4',
      'https://169.254.169.254/latest/meta-data',
      'https://198.18.0.1/v.mp4',
    ]) {
      final fake = _FakeHemaAdapter(
        books: [_book(1001, '河马测试剧')],
        chapters: _chapters(freeUrl: bad, fallbackUrl: bad),
      );
      await expectLater(
        _adapter(fake).fetchTrack('hema:1001:5001'),
        throwsA(isA<SourceUnavailable>()),
        reason: '$bad 应被公网判定拒绝',
      );
    }
  });

  test('非法 ID 抛 SourceRejected', () async {
    final adapter = _adapter(
      _FakeHemaAdapter(books: [_book(1001, '河马测试剧')], chapters: _chapters()),
    );
    for (final bad in [
      'hema:abc',
      'hema:1001:abc',
      'xifan:1001:5001',
      'hema:1001:5001:9',
    ]) {
      await expectLater(
        adapter.fetchTrack(bad),
        throwsA(
          isA<SourceRejected>().having((e) => e.message, 'message', '河马剧集编号无效'),
        ),
        reason: bad,
      );
    }
    await expectLater(
      adapter.detail('hema:abc'),
      throwsA(isA<SourceRejected>()),
    );
  });

  test('畸形 __NEXT_DATA__ 抛 SourceUnavailable，不回传解析原文', () async {
    final brokenBrowse = _FakeHemaAdapter(
      books: [_book(1001, '河马测试剧')],
      chapters: _chapters(),
      brokenDirectory: true,
    );
    await expectLater(
      _adapter(brokenBrowse).browse(),
      throwsA(
        isA<SourceUnavailable>().having(
          (e) => e.message,
          'message',
          '河马目录数据异常，请稍后重试',
        ),
      ),
    );

    final brokenDetail = _FakeHemaAdapter(
      books: [_book(1001, '河马测试剧')],
      chapters: _chapters(),
      brokenDetail: true,
    );
    await expectLater(
      _adapter(brokenDetail).detail('hema:1001'),
      throwsA(
        isA<SourceUnavailable>().having(
          (e) => e.message,
          'message',
          '河马目录数据异常，请稍后重试',
        ),
      ),
    );
  });
}
