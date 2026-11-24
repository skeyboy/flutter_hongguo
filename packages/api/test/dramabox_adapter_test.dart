import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_api/src/sources/dramabox_adapter.dart';
import 'package:hongguo_core/hongguo_core.dart' show SourceSettings;
import 'package:test/test.dart';

/// 离线回放 DramaBox 英文官网：按 path 返回伪造的 __NEXT_DATA__ HTML。
/// 用自定义 HttpClientAdapter 而非真网络，测试不依赖 dramabox.com 可达性。
class _FakeDramabox implements HttpClientAdapter {
  _FakeDramabox({
    this.statusCode,
    this.locale = 'en',
    Map<String, dynamic>? browse,
    Map<String, dynamic>? search,
    Map<String, dynamic>? detail,
    this.brokenData = false,
  }) : browse = browse ?? _browseProps(),
       search = search ?? _searchProps(),
       detail = detail ?? _detailProps(chapters: [_chapter(11, 0)]);

  /// 非 null 时所有请求直接返回该状态码，用于 403/429 文案测试。
  final int? statusCode;

  /// 顶层 locale；pageProps 里刻意不放 locale，以覆盖 `data.locale` 回退分支。
  final String locale;
  final Map<String, dynamic> browse;
  final Map<String, dynamic> search;
  final Map<String, dynamic> detail;
  final bool brokenData;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (statusCode != null) {
      return ResponseBody.fromString(
        '',
        statusCode!,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
        },
      );
    }
    final path = options.uri.path;
    late final Map<String, dynamic> props;
    if (path == '/browse' || path.startsWith('/browse/')) {
      props = browse;
    } else if (path == '/search') {
      props = search;
    } else if (path.startsWith('/drama/')) {
      props = detail;
    } else {
      props = const {};
    }
    final payload = brokenData
        ? {'bad': 'no props'}
        : {
            'props': {'pageProps': props},
            'locale': locale,
          };
    final html =
        '<html><script id="__NEXT_DATA__" type="application/json">'
        '${jsonEncode(payload)}</script></html>';
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

DramaboxAdapter _adapter(_FakeDramabox fake) =>
    DramaboxAdapter(Dio()..httpClientAdapter = fake);

String _header(RequestOptions options, String name) {
  // Dio 的 Headers 内部按小写索引，这里两种拼写都试，避免测试依赖它的实现细节。
  final value =
      options.headers[name] ?? options.headers[name.toLowerCase()] ?? '';
  return '$value';
}

Map<String, dynamic> _book(
  int id, {
  String name = 'Drama Test',
  String cover = 'https://img.dramabox.com/cover.jpg',
  int chapters = 2,
  String intro = 'A short introduction.',
}) => {
  'bookId': id,
  'bookName': name,
  'cover': cover,
  'chapterCount': chapters,
  'introduction': intro,
  'tagNames': ['Romance', 'Revenge'],
};

Map<String, dynamic> _chapter(
  int id,
  int index, {
  String name = '',
  bool unlock = true,
  String mp4 = 'https://cdn.dramaboxdb.com/v/1.mp4',
  bool m3u8Flag = false,
}) => {
  'id': id,
  'index': index,
  'name': name,
  'unlock': unlock,
  'mp4': mp4,
  'm3u8Flag': m3u8Flag,
};

Map<String, dynamic> _browseProps({
  List<dynamic>? books,
  int page = 1,
  int pages = 2,
  int total = 100,
}) => {
  'bookList': books ?? [_book(1001), _book(1001), _book(1002, chapters: 30)],
  'pageNo': page,
  'pages': pages,
  'totalNum': total,
};

Map<String, dynamic> _searchProps({
  List<dynamic>? books,
  int page = 1,
  int totalPage = 3,
}) => {
  'bookList': books ?? [_book(2001, name: '<em>Love</em> Story')],
  'pageNo': page,
  'totalPage': totalPage,
};

Map<String, dynamic> _detailProps({
  required List<Map<String, dynamic>> chapters,
  int bookId = 1001,
  String name = 'Drama Test',
  int? declaredCount,
}) {
  final count = declaredCount ?? chapters.length;
  return {
    'bookInfo': _book(bookId, name: name, chapters: count),
    'chapterList': chapters,
  };
}

Matcher unavailableContaining(String text) => throwsA(
  isA<SourceUnavailable>().having((e) => e.message, 'message', contains(text)),
);

void main() {
  test('browse 归一去重、分页游标与官网请求头', () async {
    final fake = _FakeDramabox();
    final page = await _adapter(fake).browse();

    expect(page.items, hasLength(2));
    expect(page.items.map((d) => d.id), ['dramabox:1001', 'dramabox:1002']);
    expect(page.items.first.title, 'Drama Test');
    expect(page.items.first.episodeCount, 2);
    expect(page.items.last.episodeCount, 30);
    expect(page.items.first.tagNames, ['Romance', 'Revenge']);
    expect(page.nextCursor, '2');
    expect(fake.requests.single.uri.path, '/browse');
    expect(_header(fake.requests.single, 'User-Agent'), 'Mozilla/5.0');
    expect(
      _header(fake.requests.single, 'Referer'),
      'https://www.dramabox.com/',
    );
    expect(_header(fake.requests.single, 'Accept-Language'), 'en-US,en;q=0.9');
  });

  test('browse 第 2 页走 /browse/0/{page}，不跟重定向', () async {
    final fake = _FakeDramabox(browse: _browseProps(page: 2, pages: 2));
    final page = await _adapter(fake).browse(cursor: '2');
    expect(fake.requests.single.uri.path, '/browse/0/2');
    expect(page.nextCursor, isNull);
  });

  test('browse 拒绝分类；非法页码也拒绝', () async {
    final adapter = _adapter(_FakeDramabox());
    await expectLater(
      adapter.browse(genre: 'romance'),
      throwsA(isA<SourceRejected>()),
    );
    await expectLater(
      adapter.browse(cursor: 'abc'),
      throwsA(isA<SourceRejected>()),
    );
  });

  test('search 用 totalPage 翻页，关键词与页码越界拒绝', () async {
    final fake = _FakeDramabox();
    final adapter = _adapter(fake);
    final page = await adapter.search('love');
    expect(page.items.single.id, 'dramabox:2001');
    expect(page.items.single.title, 'Love Story');
    expect(page.nextCursor, '2');
    expect(fake.requests.single.uri.path, '/search');
    expect(fake.requests.single.uri.queryParameters, {
      'searchValue': 'love',
      'page': '1',
    });

    await expectLater(adapter.search('  '), throwsA(isA<SourceRejected>()));
    await expectLater(
      adapter.search('love', cursor: '51'),
      throwsA(isA<SourceRejected>()),
    );
  });

  test('detail 分集编号从 1 起、标题去标签、未解锁标注 locked', () async {
    final fake = _FakeDramabox(
      detail: _detailProps(
        chapters: [
          _chapter(11, 0, name: '<b>Pilot</b>', unlock: true),
          _chapter(12, 1, name: '', unlock: false),
        ],
      ),
    );
    final detail = await _adapter(fake).detail('dramabox:1001');

    expect(fake.requests.single.uri.path, '/drama/1001');
    expect(detail.drama.id, 'dramabox:1001');
    expect(detail.drama.episodeCount, 2);
    expect(detail.episodes.map((e) => e.vid), [
      'dramabox:1001:11',
      'dramabox:1001:12',
    ]);
    expect(detail.episodes.map((e) => e.index), [1, 2]);
    expect(detail.episodes.first.title, 'Pilot');
    expect(detail.episodes.last.title, '第 2 集');
    expect(detail.episodes.first.locked, isFalse);
    expect(detail.episodes.last.locked, isTrue);
  });

  test('fetchTrack 解锁 mp4 返回明文 VideoTrack，policy 限定官方 CDN', () async {
    final fake = _FakeDramabox(
      detail: _detailProps(
        chapters: [_chapter(11, 0, mp4: 'https://cdn.dramaboxdb.com/v/11.mp4')],
      ),
    );
    final track = await _adapter(fake).fetchTrack('dramabox:1001:11');

    expect(track.url.toString(), 'https://cdn.dramaboxdb.com/v/11.mp4');
    expect(track.spadeA, isEmpty);
    expect(track.definition, isEmpty);
    expect(track.source, 'dramabox');
    expect(track.format, VideoFormat.mp4);
    expect(track.userAgent, 'Mozilla/5.0');
    expect(track.referer, 'https://www.dramabox.com/');
    expect(track.policy, isA<PublicWebPolicy>());
    expect((track.policy as PublicWebPolicy).hosts, ['dramaboxdb.com']);
    // 取址必须重读详情，不复用 detail 的结果。
    expect(fake.requests.single.uri.path, '/drama/1001');
  });

  test('m3u8Flag 集早拒，文案点明 HLS 暂不支持', () async {
    final fake = _FakeDramabox(
      detail: _detailProps(chapters: [_chapter(11, 0, m3u8Flag: true)]),
    );
    await expectLater(
      _adapter(fake).fetchTrack('dramabox:1001:11'),
      throwsA(
        isA<SourceUnavailable>().having(
          (e) => e.message,
          'message',
          allOf(contains('HLS'), contains('暂不支持')),
        ),
      ),
    );
  });

  test('非 .mp4 路径（含 m3u8/encrypt）一律拒绝，绝不返回 HLS 轨', () async {
    for (final url in [
      'https://cdn.dramaboxdb.com/live/index.m3u8',
      'https://cdn.dramaboxdb.com/v/encrypt-11.mp4',
    ]) {
      final fake = _FakeDramabox(
        detail: _detailProps(chapters: [_chapter(11, 0, mp4: url)]),
      );
      await expectLater(
        _adapter(fake).fetchTrack('dramabox:1001:11'),
        unavailableContaining('暂不支持'),
      );
    }
  });

  test('非官方 host 片源被拒', () async {
    final fake = _FakeDramabox(
      detail: _detailProps(
        chapters: [_chapter(11, 0, mp4: 'https://cdn.example.com/v/11.mp4')],
      ),
    );
    await expectLater(
      _adapter(fake).fetchTrack('dramabox:1001:11'),
      unavailableContaining('官方 HTTPS CDN'),
    );
  });

  test('私网字面量与带凭据 URL 被拒', () async {
    for (final url in [
      'https://127.0.0.1/v.mp4',
      'https://user:pass@cdn.dramaboxdb.com/v.mp4',
      'https://cdn.dramaboxdb.com:8443/v.mp4',
      'http://cdn.dramaboxdb.com/v.mp4',
    ]) {
      final fake = _FakeDramabox(
        detail: _detailProps(chapters: [_chapter(11, 0, mp4: url)]),
      );
      await expectLater(
        _adapter(fake).fetchTrack('dramabox:1001:11'),
        unavailableContaining('官方 HTTPS CDN'),
      );
    }
  });

  test('未解锁分集抛 SourceLocked，不返回地址', () async {
    final fake = _FakeDramabox(
      detail: _detailProps(chapters: [_chapter(11, 0, unlock: false)]),
    );
    await expectLater(
      _adapter(fake).fetchTrack('dramabox:1001:11'),
      throwsA(
        isA<SourceLocked>().having(
          (e) => e.message,
          'message',
          contains('官方平台确认观看权限'),
        ),
      ),
    );
  });

  test('非法 ID 与跨源 ID 抛 SourceRejected', () async {
    final adapter = _adapter(_FakeDramabox());
    await expectLater(
      adapter.detail('dramabox:abc'),
      throwsA(isA<SourceRejected>()),
    );
    await expectLater(
      adapter.fetchTrack('dramabox:1001'),
      throwsA(isA<SourceRejected>()),
    );
    await expectLater(
      adapter.fetchTrack('hema:1001:11'),
      throwsA(isA<SourceRejected>()),
    );
  });

  test('非 en locale 与坏数据抛 SourceUnavailable', () async {
    final wrongLocale = _adapter(_FakeDramabox(locale: 'zh'));
    await expectLater(wrongLocale.browse(), unavailableContaining('语言不匹配'));
    await expectLater(
      _adapter(_FakeDramabox(brokenData: true)).browse(),
      unavailableContaining('语言不匹配'),
    );
  });

  test('403 地区受限 / 429 限流有专门文案', () async {
    await expectLater(
      _adapter(_FakeDramabox(statusCode: 403)).browse(),
      unavailableContaining('地区受限'),
    );
    await expectLater(
      _adapter(_FakeDramabox(statusCode: 429)).browse(),
      unavailableContaining('请求过于频繁'),
    );
  });

  test('分享链接 resolveSeriesId 正反例', () async {
    final adapter = _adapter(_FakeDramabox());
    expect(
      await adapter.resolveSeriesId('https://www.dramabox.com/drama/12345'),
      'dramabox:12345',
    );
    expect(
      await adapter.resolveSeriesId('https://www.dramaboxdb.com/movie/6789/'),
      'dramabox:6789',
    );
    expect(await adapter.resolveSeriesId('dramabox:42'), 'dramabox:42');

    for (final bad in [
      // parseId 默认只收剧集形态；分集 vid 不是分享链接要解析的目标。
      'dramabox:42:7',
      'http://www.dramabox.com/drama/123',
      'https://evil.com/drama/123',
      'https://www.dramabox.com:8443/drama/123',
      'https://user:pass@www.dramabox.com/drama/123',
      'https://www.dramabox.com/drama/abc',
      'https://www.dramabox.com/other/123',
      'not a url',
    ]) {
      await expectLater(
        adapter.resolveSeriesId(bad),
        throwsA(isA<SourceRejected>()),
        reason: bad,
      );
    }
  });

  test('enabled 默认关，只有显式 true 才启用', () {
    final adapter = _adapter(_FakeDramabox());
    expect(adapter.enabled(const SourceSettings()), isFalse);
    expect(
      adapter.enabled(const SourceSettings(builtin: {'dramabox': true})),
      isTrue,
    );
  });
}
