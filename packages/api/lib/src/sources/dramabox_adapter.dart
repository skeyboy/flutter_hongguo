import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hongguo_core/hongguo_core.dart';

import '../catalog.dart';
import '../media_url_policy.dart';
import '../source_adapter.dart';
import '../video_model_client.dart';

/// DramaBox 海外源适配器：只移植参考 dramabox.js 的公开英文 SSR 协议行为。
///
/// 本源没有签名密钥、没有账号、没有解锁接口；播放地址只认官方未加密 MP4。
/// 关键约束：HLS 通道在本项目尚未落地，m3u8 必须在适配器层早拒，
/// 绝不能流进只吃单文件 MP4 的 MediaCache（否则会变成"视频播放异常"静默失败）。
class DramaboxAdapter implements SourceAdapter, SourceShareLinkCapability {
  DramaboxAdapter(this.dio, {DateTime Function()? now})
    : now = now ?? DateTime.now;

  final Dio dio;

  /// 预留时钟注入点（协议本身无缓存 TTL，保持与其它适配器构造签名一致）。
  final DateTime Function() now;

  static const _origin = 'https://www.dramabox.com';
  static const _ua = 'Mozilla/5.0';
  static const _timeout = Duration(seconds: 10);
  static const _maxBytes = 8 * 1024 * 1024;

  /// 参考实现的 ID 约束：bookId/chapterId 都是 1–24 位数字。
  static final _id = RegExp(r'^\d{1,24}$');
  static final _linkPath = RegExp(r'^/(?:drama|movie)/(\d{1,24})(?:/|$)');

  // Dart 没有内置 HTML 解析器：正则抠 <script id="__NEXT_DATA__"> 的内容。
  static final _nextData = RegExp(
    '<script\\b[^>]*\\bid=["\']__NEXT_DATA__["\'][^>]*>([\\s\\S]*?)</script>',
    caseSensitive: false,
  );

  static const _safeMax = 9007199254740991; // Number.MAX_SAFE_INTEGER

  @override
  String get id => 'dramabox';

  @override
  String get label => 'DramaBox（海外）';

  @override
  SourceKind get kind => SourceKind.builtin;

  @override
  bool matches(String mediaId) => mediaId.startsWith('dramabox:');

  /// 海外源默认关：只有显式 true 才启用（契约 §4.1 默认值表）。
  @override
  bool enabled(SourceSettings settings) => settings.builtin['dramabox'] == true;

  // ── SourceShareLinkCapability ────────────────────────────────────

  @override
  Future<String?> resolveSeriesId(String url) async {
    final value = url.trim();
    if (value.startsWith('dramabox:')) return _parseId(value).seriesId;

    // 分享落地页可能是 .com 或 .db.com；协议限定 https、无端口/凭据、固定路径。
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        (uri.host != 'www.dramabox.com' && uri.host != 'www.dramaboxdb.com')) {
      throw const SourceRejected('dramabox', '请输入 DramaBox 英文官网剧集链接');
    }
    final match = _linkPath.firstMatch(uri.path);
    final bookId = match?.group(1);
    if (bookId == null) {
      throw const SourceRejected('dramabox', '请输入 DramaBox 英文官网剧集链接');
    }
    return 'dramabox:$bookId';
  }

  // ── SourceAdapter ────────────────────────────────────────────────

  @override
  Future<CatalogPage> browse({
    String genre = '',
    String? cursor,
    String? sort,
  }) async {
    if (genre.trim().isNotEmpty) {
      throw const SourceRejected('dramabox', 'DramaBox 没有分类筛选，请勿指定题材');
    }
    final page = _page(cursor, max: 10000);
    final props = await _request(page == 1 ? '/browse' : '/browse/0/$page');
    final result = _pageResult(props, page: page, pagesKey: 'pages');
    return CatalogPage(
      result.items,
      nextCursor: result.hasNext ? '${page + 1}' : null,
    );
  }

  @override
  Future<CatalogPage> search(String query, {String? cursor}) async {
    final keyword = query.trim();
    // Dart 的 String.length 与 JS 的 .length 同为 UTF-16 码元数，口径一致。
    if (keyword.isEmpty || keyword.length > 200) {
      throw const SourceRejected('dramabox', 'DramaBox 搜索词或页码无效');
    }
    final page = _page(cursor, max: 50);
    final props = await _request(
      '/search',
      query: {'searchValue': keyword, 'page': page},
    );
    final result = _pageResult(props, page: page, pagesKey: 'totalPage');
    return CatalogPage(
      result.items,
      nextCursor: result.hasNext ? '${page + 1}' : null,
    );
  }

  @override
  Future<DramaDetail> detail(String seriesId) async {
    final loaded = await _loadDetail(seriesId);
    final episodes = <Episode>[];
    for (final chapter in loaded.chapters) {
      final index = _safeInt(chapter['index'])!; // _loadDetail 已校验
      final chapterId = _text(chapter['id']);
      final title = _plainText(chapter['name']);
      episodes.add(
        Episode(
          vid: '$seriesId:$chapterId',
          index: index + 1,
          title: title.isEmpty ? '第 ${index + 1} 集' : title,
          locked: chapter['unlock'] != true,
        ),
      );
    }
    final book = loaded.book;
    return DramaDetail(
      Drama(
        id: seriesId,
        title: book.title,
        cover: book.cover,
        intro: book.intro,
        episodeCount: episodes.length,
        tagNames: book.tagNames,
      ),
      episodes,
    );
  }

  @override
  Future<VideoTrack> fetchTrack(
    String mediaId, {
    String quality = 'best',
  }) async {
    final id = _parseId(mediaId, episode: true);
    // 解锁状态是上游实时数据：每次取址都重读详情，绝不复用上次判定。
    final loaded = await _loadDetail(id.seriesId);
    Map<String, dynamic>? chapter;
    for (final item in loaded.chapters) {
      if (_text(item['id']) == id.chapterId) {
        chapter = item;
        break;
      }
    }
    if (chapter == null) {
      throw const SourceUnavailable('dramabox', 'DramaBox 未找到该分集');
    }
    if (chapter['unlock'] != true) {
      throw const SourceLocked('dramabox', '该集未公开解锁，请在 DramaBox 官方平台确认观看权限');
    }

    final uri = _assertMediaUrl(chapter['mp4']);
    // HLS 硬门槛：m3u8Flag / 非 .mp4 / 含 encrypt 一律早拒，不返回任何 HLS 轨。
    final path = uri.path.toLowerCase();
    if (chapter['m3u8Flag'] == true ||
        !path.endsWith('.mp4') ||
        path.contains('encrypt')) {
      throw const SourceUnavailable(
        'dramabox',
        '该集非公开未加密 MP4，当前版本暂不支持（HLS 通道未落地），请在 DramaBox 官方平台观看',
      );
    }

    return VideoTrack(
      url: uri,
      spadeA: '', // 明文 MP4，没有红果的 CENC 密文参数。
      definition: '',
      size: 0,
      userAgent: _ua,
      referer: '$_origin/',
      source: 'dramabox',
      format: VideoFormat.mp4,
      policy: const PublicWebPolicy(hosts: ['dramaboxdb.com']),
    );
  }

  // ── 协议请求 ────────────────────────────────────────────────────

  /// 官网 SSR：固定头、不跟重定向、10s 超时、8MB 上限；只接受 locale=en 的
  /// __NEXT_DATA__.props.pageProps。所有失败都换成固定中文文案，
  /// 绝不回传可能带签名参数的远端异常原文。
  Future<Map<String, dynamic>> _request(
    String path, {
    Map<String, dynamic> query = const {},
  }) async {
    late final Response<String> response;
    try {
      response = await dio.get<String>(
        '$_origin$path',
        queryParameters: query.isEmpty ? null : query,
        options: Options(
          headers: <String, String>{
            'User-Agent': _ua,
            'Referer': '$_origin/',
            'Accept-Language': 'en-US,en;q=0.9',
          },
          followRedirects: false,
          connectTimeout: _timeout,
          sendTimeout: _timeout,
          receiveTimeout: _timeout,
          responseType: ResponseType.plain,
        ),
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 403 || status == 451) {
        throw SourceUnavailable(
          'dramabox',
          'DramaBox 当前网络或地区受限（HTTP $status），请检查网络分流',
        );
      }
      if (status == 429) {
        throw const SourceUnavailable('dramabox', 'DramaBox 请求过于频繁，请稍后重试');
      }
      final timeout =
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout;
      throw SourceUnavailable(
        'dramabox',
        timeout ? 'DramaBox 加载超时，请重试' : 'DramaBox 连接失败，请检查网络分流或稍后重试',
      );
    } on Object {
      throw const SourceUnavailable('dramabox', 'DramaBox 连接失败，请检查网络分流或稍后重试');
    }

    if (response.statusCode != 200) {
      throw const SourceUnavailable('dramabox', 'DramaBox 连接失败，请检查网络分流或稍后重试');
    }
    final raw = response.data ?? '';
    if (utf8.encode(raw).length > _maxBytes) {
      throw const SourceUnavailable('dramabox', 'DramaBox 连接失败，请检查网络分流或稍后重试');
    }
    final match = _nextData.firstMatch(raw);
    if (match == null) {
      throw const SourceUnavailable('dramabox', 'DramaBox 官网数据或语言不匹配');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(match.group(1)!);
    } on Object {
      throw const SourceUnavailable('dramabox', 'DramaBox 官网数据或语言不匹配');
    }
    if (decoded is! Map) {
      throw const SourceUnavailable('dramabox', 'DramaBox 官网数据或语言不匹配');
    }
    final rawProps = decoded['props'];
    final props = rawProps is Map ? rawProps['pageProps'] : null;
    if (props is! Map) {
      throw const SourceUnavailable('dramabox', 'DramaBox 官网数据或语言不匹配');
    }
    // 先读 pageProps.locale，缺失才回退顶层 data.locale。
    if ((props['locale'] ?? decoded['locale']) != 'en') {
      throw const SourceUnavailable('dramabox', 'DramaBox 官网数据或语言不匹配');
    }
    return Map<String, dynamic>.from(props);
  }

  /// 详情统一在这里校验：fetchTrack 与 detail 都走这条路径，
  /// 但每次调用都会重新请求，不缓存解锁状态。
  Future<({Drama book, List<Map<String, dynamic>> chapters})> _loadDetail(
    String seriesId,
  ) async {
    final id = _parseId(seriesId);
    final props = await _request('/drama/${id.bookId}');
    final book = _normalizeBook(props['bookInfo']);
    if (book == null || book.id != seriesId) {
      throw const SourceUnavailable('dramabox', 'DramaBox 返回的剧集与请求不一致');
    }
    final raw = props['chapterList'];
    if (raw is! List || raw.isEmpty || raw.length > 10000) {
      throw const SourceUnavailable('dramabox', 'DramaBox 返回的剧集或完整分集数量不一致');
    }
    // 参考实现要求 chapterCount 必须等于真实分集数，防止拿截断列表假装完整。
    if (book.episodeCount != raw.length) {
      throw const SourceUnavailable('dramabox', 'DramaBox 返回的剧集或完整分集数量不一致');
    }
    final chapters = <Map<String, dynamic>>[];
    for (final entry in raw) {
      if (entry is! Map) {
        throw const SourceUnavailable('dramabox', 'DramaBox 分集数据异常，请稍后重试');
      }
      chapters.add(Map<String, dynamic>.from(entry));
    }
    chapters.sort(
      (a, b) =>
          (_safeInt(a['index']) ?? 0).compareTo(_safeInt(b['index']) ?? 0),
    );
    final ids = <String>{};
    for (var i = 0; i < chapters.length; i++) {
      final chapterId = _text(chapters[i]['id']);
      if (!_id.hasMatch(chapterId) ||
          !ids.add(chapterId) ||
          _safeInt(chapters[i]['index']) != i) {
        throw const SourceUnavailable('dramabox', 'DramaBox 分集编号重复或不连续');
      }
    }
    return (book: book, chapters: chapters);
  }

  // ── 列表归一 ────────────────────────────────────────────────────

  static ({List<Drama> items, bool hasNext}) _pageResult(
    Map<String, dynamic> props, {
    required int page,
    required String pagesKey,
  }) {
    final books = props['bookList'];
    if (books is! List || books.length > 500) {
      throw const SourceUnavailable('dramabox', 'DramaBox 目录数据异常，请稍后重试');
    }
    if (_safeInt(props['pageNo']) != page) {
      throw const SourceUnavailable('dramabox', 'DramaBox 官网分页与请求不一致');
    }
    final pages = _safeInt(props[pagesKey]);
    if (pages == null || pages < 0) {
      throw const SourceUnavailable('dramabox', 'DramaBox 官网分页与请求不一致');
    }
    final seen = <String>{};
    final items = <Drama>[];
    for (final entry in books) {
      final drama = _normalizeBook(entry);
      if (drama == null || !seen.add(drama.id)) continue;
      items.add(drama);
    }
    if (books.isNotEmpty && items.isEmpty) {
      throw const SourceUnavailable('dramabox', 'DramaBox 未返回有效剧集');
    }
    return (items: items, hasNext: items.isNotEmpty && page < pages);
  }

  static Drama? _normalizeBook(dynamic value) {
    if (value is! Map) return null;
    final bookId = _text(value['bookId']);
    if (!_id.hasMatch(bookId)) return null;
    final title = _plainText(value['bookName'] ?? value['name']);
    if (title.isEmpty) return null;
    return Drama(
      id: 'dramabox:$bookId',
      title: title,
      cover: _httpsUrl(value['cover'] ?? value['coverWap']),
      episodeCount:
          _safeInt(value['chapterCount'] ?? value['totalChapterNum']) ?? 0,
      intro: _plainText(value['introduction']),
      tagNames: _tagNames(value),
    );
  }

  /// 片源必须是官方 HTTPS CDN 的公网地址；端口/凭据/私网字面量一律拒绝。
  static Uri _assertMediaUrl(dynamic value) {
    final uri = Uri.tryParse(_text(value));
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        (uri.host != 'dramaboxdb.com' &&
            !uri.host.endsWith('.dramaboxdb.com')) ||
        isPublicMediaUrl(uri) != null) {
      throw const SourceUnavailable('dramabox', 'DramaBox 片源必须来自官方 HTTPS CDN');
    }
    return uri;
  }

  // ── 小工具 ──────────────────────────────────────────────────────

  static ({String bookId, String chapterId, String seriesId}) _parseId(
    String value, {
    bool episode = false,
  }) {
    final parts = _text(value).split(':');
    if (parts[0] != 'dramabox' ||
        parts.length != (episode ? 3 : 2) ||
        !parts.skip(1).every(_id.hasMatch)) {
      throw const SourceRejected('dramabox', 'DramaBox 剧集编号无效');
    }
    return (
      bookId: parts[1],
      chapterId: parts.length > 2 ? parts[2] : '',
      seriesId: '${parts[0]}:${parts[1]}',
    );
  }

  static int _page(String? cursor, {required int max}) {
    if (cursor == null || cursor.isEmpty) return 1;
    final page = int.tryParse(cursor);
    if (page == null || page < 1 || page > max) {
      throw const SourceRejected('dramabox', 'DramaBox 页码无效');
    }
    return page;
  }

  /// 对齐 JS Number.isSafeInteger：整数、有限且在 2^53-1 内。
  static int? _safeInt(dynamic value) {
    if (value is int) {
      return value.abs() <= _safeMax ? value : null;
    }
    if (value is double) {
      if (value.isFinite &&
          value == value.roundToDouble() &&
          value.abs() <= _safeMax) {
        return value.toInt();
      }
      return null;
    }
    if (value is String) {
      final parsed = num.tryParse(value);
      return parsed == null ? null : _safeInt(parsed);
    }
    return null;
  }

  /// 封面只收公网明文 HTTPS：私网/凭据/降级 IP 一律视为空串。
  static String _httpsUrl(dynamic value) {
    if (value == null) return '';
    final uri = Uri.tryParse(value.toString());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        isPublicMediaUrl(uri) != null) {
      return '';
    }
    return uri.toString();
  }

  static List<String> _tagNames(dynamic value) {
    if (value is! Map) return const [];
    final raw =
        value['tagNames'] ??
        value['tags'] ??
        value['tagList'] ??
        value['categoryList'];
    if (raw is! List) return const [];
    final names = <String>[];
    for (final entry in raw) {
      final name = _plainText(
        entry is Map ? (entry['name'] ?? entry['tagName']) : entry,
      );
      if (name.isEmpty || names.contains(name)) continue;
      names.add(name);
      if (names.length == 8) break;
    }
    return List.unmodifiable(names);
  }

  /// 上游标题常带 <em> 高亮标签，统一剥离后压缩空白。
  static String _plainText(Object? value) {
    if (value == null || value == '' || value == 0) return '';
    return value.toString().replaceAll(RegExp(r'<[^>]*>'), '').trim();
  }

  static String _text(dynamic value) => value == null ? '' : '$value';
}
