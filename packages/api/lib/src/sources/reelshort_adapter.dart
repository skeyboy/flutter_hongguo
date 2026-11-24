import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hongguo_core/hongguo_core.dart';

import '../catalog.dart';
import '../media_url_policy.dart';
import '../source_adapter.dart';
import '../video_model_client.dart';

/// ReelShort（海外）来源适配器。
///
/// 只移植参考 reelshort.js 的公开页面协议行为，不复制任何签名密钥或远端
/// 异常原文。HLS 通道尚未落地（见 docs/design/hls-channel-evaluation.md）：
/// m3u8 集必须在适配器层早拒，绝不交给只吃单文件 MP4 的下载层。
class ReelshortAdapter implements SourceAdapter, SourceShareLinkCapability {
  ReelshortAdapter(this.dio, {DateTime Function()? now})
    : now = now ?? DateTime.now;

  final Dio dio;

  /// 书架补 ID 时多次搜索共用同一 deadline 的时钟注入点。
  final DateTime Function() now;

  static const _origin = 'https://www.reelshort.com';
  static const _ua = 'Mozilla/5.0';
  static final _timeout = Duration(seconds: 10);

  /// 参考实现的段约束：bookId/chapterId `[A-Za-z0-9_]{1,100}`，
  /// slug 为小写字母数字以单个连字符相连，number 为 1–9999 正整数。
  static final _idPattern = RegExp(r'^[A-Za-z0-9_]{1,100}$');
  static final _slugPattern = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');
  static final _numberPattern = RegExp(r'^[1-9]\d{0,3}$');

  /// Dart 没有内置 HTML 解析器：正则抠 `<script id="__NEXT_DATA__">`。
  static final _nextData = RegExp(
    '<script\\b(?=[^>]*\\bid=["\']__NEXT_DATA__["\'])[^>]*>([\\s\\S]*?)</script\\s*>',
    caseSensitive: false,
  );
  static final _moviePath = RegExp(r'^/movie/([a-z0-9-]+)-([A-Za-z0-9_]+)/?$');
  static final _extension = RegExp(r'\.(mp4|m3u8)$', caseSensitive: false);
  static const _lockedKeys = ['locked', 'is_locked', 'is_lock', 'isCharge'];

  @override
  String get id => 'reelshort';

  @override
  String get label => 'ReelShort（海外）';

  @override
  SourceKind get kind => SourceKind.builtin;

  @override
  bool matches(String mediaId) => mediaId.startsWith('reelshort:');

  /// 海外源默认关闭：只有显式 true 才启用。
  @override
  bool enabled(SourceSettings settings) =>
      settings.builtin['reelshort'] == true;

  // ── 可选能力：分享链接 ──────────────────────────────────────────

  @override
  Future<String?> resolveSeriesId(String url) async {
    if (url.startsWith('reelshort:')) return _parseId(url).seriesId;
    final Uri parsed;
    try {
      parsed = Uri.parse(url);
    } on Object {
      throw const SourceRejected('reelshort', '请输入 ReelShort 官网剧集链接');
    }
    final match = _moviePath.firstMatch(parsed.path);
    // origin 一致即同时保证 https、host 与端口；userInfo 必须为空。
    // 相对 URL 没有 scheme，访问 origin 会抛 StateError，须先拦下。
    if (!parsed.hasScheme ||
        parsed.origin != _origin ||
        parsed.userInfo.isNotEmpty ||
        match == null) {
      throw const SourceRejected('reelshort', '请输入 ReelShort 官网剧集链接');
    }
    return _parseId('reelshort:${match.group(2)}:${match.group(1)}').seriesId;
  }

  // ── SourceAdapter ───────────────────────────────────────────────

  @override
  Future<CatalogPage> browse({
    String genre = '',
    String? cursor,
    String? sort,
  }) async {
    final page = _page(cursor);
    if (page < 1) {
      throw const SourceRejected('reelshort', 'ReelShort 页码无效');
    }
    // 官网快照没有游标：第 2 页起直接空，不制造假的分页。
    if (page > 1) return const CatalogPage([]);

    final deadline = now().add(_timeout);
    final props = await _request('/', deadline: deadline);
    final fallback = _map(props['fallback'])['/api/ms/hall/webInfo'];
    final shelves = _map(fallback)['bookShelfList'];
    if (shelves is! List || shelves.length > 100) {
      throw const SourceUnavailable('reelshort', 'ReelShort 官网片单格式已变化，请等待适配');
    }

    final genres = <({String slug, String label})>[];
    for (var i = 0; i < shelves.length; i++) {
      final label = _plainText(_map(shelves[i])['bookshelf_name']);
      if (label.isNotEmpty) genres.add((slug: 'shelf-$i', label: label));
    }
    final selected = genre.isEmpty
        ? null
        : genres.where((g) => g.slug == genre).firstOrNull;
    if (genre.isNotEmpty && selected == null) {
      throw const SourceRejected('reelshort', 'ReelShort 分类已变化，请重新选择');
    }

    final Iterable<dynamic> entries;
    if (selected == null) {
      entries = shelves.expand((shelf) {
        final books = _map(shelf)['books'];
        return books is List ? books : const <dynamic>[];
      });
    } else {
      final index = int.tryParse(selected.slug.substring(6)) ?? -1;
      if (index < 0 || index >= shelves.length) {
        throw const SourceUnavailable('reelshort', 'ReelShort 官网片单格式已变化，请等待适配');
      }
      final books = _map(shelves[index])['books'];
      entries = books is List ? books : const <dynamic>[];
    }

    final books = <dynamic>[];
    final seen = <String>{};
    for (final book in entries) {
      final title = _plainText(_map(book)['book_title']);
      final key = title.toLowerCase();
      if (title.isEmpty || !seen.add(key)) continue;
      if (_normalizeBook(book) != null) {
        books.add(book);
      } else {
        // 书架会省略 ID：复用上游精确标题搜索补齐，最多 12 本、共用 deadline。
        final results = await _searchBooks(title, 1, deadline: deadline);
        final matches = results
            .where((item) => item.title.toLowerCase() == key)
            .toList();
        if (matches.length != 1) {
          throw const SourceUnavailable(
            'reelshort',
            'ReelShort 片单缺少唯一对应的剧集编号，请按完整剧名搜索',
          );
        }
        books.add({
          ..._map(book),
          'book_id': _parseId(matches.single.id).bookId,
        });
      }
      if (books.length >= 12) break;
    }
    return CatalogPage(_pageResult(books));
  }

  @override
  Future<CatalogPage> search(String query, {String? cursor}) async {
    final keyword = _plainText(query);
    final page = _page(cursor);
    if (keyword.isEmpty || keyword.length > 200 || page < 1) {
      throw const SourceRejected('reelshort', 'ReelShort 搜索词或页码无效');
    }
    if (page > 1) return const CatalogPage([]);
    return CatalogPage(await _searchBooks(keyword, page));
  }

  @override
  Future<DramaDetail> detail(String seriesId) async {
    final id = _parseId(seriesId);
    final data = await _detailResult(id);
    final title = _plainText(data['book_title']);
    if (title.isEmpty) {
      throw const SourceUnavailable('reelshort', 'ReelShort 缺少剧集标题，请等待适配');
    }
    final episodes = _episodes(data, seriesId);
    return DramaDetail(
      Drama(
        id: seriesId,
        title: title,
        cover: _mediaUrl(data['book_pic']),
        intro: _plainText(data['special_desc']),
        episodeCount: episodes.length,
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
    // 解锁状态是上游实时数据：每次取址都重读详情，不复用上一次的免费/付费判定。
    final data = await _detailResult(id);
    final episodes = _episodes(data, id.seriesId);
    Episode? found;
    for (final episode in episodes) {
      if (episode.vid == mediaId) {
        found = episode;
        break;
      }
    }
    if (found == null) {
      throw const SourceUnavailable('reelshort', 'ReelShort 未找到该分集');
    }
    if (found.locked) {
      throw const SourceLocked('reelshort', '该集已锁定，请在 ReelShort 官方平台确认观看权限');
    }

    final props = await _request(
      '/episodes/episode-${id.number}-${id.slug}-${id.bookId}-${id.chapterId}',
      query: {'play_time': 1},
    );
    final play = props['data'];
    final rawNumber = _map(play)['serial_number'];
    final number = rawNumber is num
        ? rawNumber.toInt()
        : int.tryParse(_text(rawNumber));
    final rawChapterId = _map(play)['chapter_id'];
    if (play is! Map ||
        number != id.number ||
        (rawChapterId != null &&
            rawChapterId != '' &&
            _text(rawChapterId) != id.chapterId)) {
      throw const SourceUnavailable('reelshort', 'ReelShort 返回的分集与请求不一致');
    }
    if (_locked(play) || _text(play['video_url']).isEmpty) {
      throw const SourceLocked(
        'reelshort',
        '该集未提供公开播放地址，请在 ReelShort 官方平台确认观看权限',
      );
    }

    final url = _mediaUrl(play['video_url']);
    final extension = _extension
        .firstMatch(Uri.tryParse(url)?.path ?? '')
        ?.group(1)
        ?.toLowerCase();
    if (extension == null) {
      throw const SourceUnavailable(
        'reelshort',
        'ReelShort 未提供可直接播放的 HTTPS MP4 或 M3U8 地址',
      );
    }
    // 硬门槛：HLS 播放通道未落地，m3u8 早拒，不返回 format=hls 的轨。
    if (extension == 'm3u8') {
      throw const SourceUnavailable(
        'reelshort',
        '该集为 HLS 流，当前版本暂不支持，请在 ReelShort 官方平台观看',
      );
    }
    final uri = Uri.parse(url);
    return VideoTrack(
      url: uri,
      spadeA: '', // 明文 MP4，不塞红果 CENC 签名参数。
      definition: '',
      size: 0,
      userAgent: _ua,
      referer: '$_origin/',
      source: 'reelshort',
      format: VideoFormat.mp4,
      policy: PublicWebPolicy(hosts: _hostFamily(uri.host)),
    );
  }

  // ── 协议请求 ────────────────────────────────────────────────────

  /// 统一取 `__NEXT_DATA__.props.pageProps`；所有远端异常原文都被替换为
  /// 固定中文文案（可能含签名参数，不得回传）。
  Future<Map<String, dynamic>> _request(
    String route, {
    Map<String, dynamic> query = const {},
    DateTime? deadline,
  }) async {
    // 共享 deadline 可能在书架补 ID 的多次搜索里耗尽，需先于网络请求检查。
    final remaining = deadline == null ? _timeout : deadline.difference(now());
    if (remaining <= Duration.zero) {
      throw const SourceUnavailable('reelshort', 'ReelShort 加载超时，请重试');
    }
    final timeout = remaining < _timeout ? remaining : _timeout;

    late final Response<String> response;
    try {
      response = await dio.get<String>(
        '$_origin$route',
        queryParameters: query.isEmpty ? null : query,
        options: Options(
          headers: {
            'User-Agent': _ua,
            'Referer': '$_origin/',
            'Accept-Language': 'en-US,en;q=0.9',
          },
          followRedirects: false, // 不把官网请求头带到未校验的重定向目标。
          connectTimeout: timeout,
          sendTimeout: timeout,
          receiveTimeout: timeout,
          responseType: ResponseType.plain,
        ),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 403 || status == 451) {
        throw SourceUnavailable(
          'reelshort',
          'ReelShort 当前地区或网络暂不可用（HTTP $status）',
        );
      }
      if (status == 429) {
        throw const SourceUnavailable('reelshort', 'ReelShort 请求过于频繁，请稍后重试');
      }
      final isTimeout =
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout;
      throw SourceUnavailable(
        'reelshort',
        isTimeout ? 'ReelShort 加载超时，请重试' : 'ReelShort 连接失败，请检查网络或稍后重试',
      );
    } on Object {
      throw const SourceUnavailable('reelshort', 'ReelShort 连接失败，请检查网络或稍后重试');
    }

    final status = response.statusCode ?? 0;
    if (status == 403 || status == 451) {
      throw SourceUnavailable(
        'reelshort',
        'ReelShort 当前地区或网络暂不可用（HTTP $status）',
      );
    }
    if (status == 429) {
      throw const SourceUnavailable('reelshort', 'ReelShort 请求过于频繁，请稍后重试');
    }
    if (status != 200) {
      throw const SourceUnavailable('reelshort', 'ReelShort 连接失败，请检查网络或稍后重试');
    }

    final raw = response.data ?? '';
    if (utf8.encode(raw).length > 4 * 1024 * 1024) {
      throw const SourceUnavailable('reelshort', 'ReelShort 官网数据格式已变化，请等待适配');
    }
    final match = _nextData.firstMatch(raw);
    if (match == null) {
      throw const SourceUnavailable('reelshort', 'ReelShort 官网数据格式已变化，请等待适配');
    }
    Map<String, dynamic>? pageProps;
    try {
      final decoded = jsonDecode(match.group(1)!);
      final props = decoded is Map ? decoded['props'] : null;
      final data = props is Map ? props['pageProps'] : null;
      if (data is Map) pageProps = Map<String, dynamic>.from(data);
    } on Object {
      // 不回传 jsonDecode 原文，统一落到下方文案。
    }
    if (pageProps == null) {
      throw const SourceUnavailable('reelshort', 'ReelShort 官网数据格式已变化，请等待适配');
    }
    return pageProps;
  }

  Future<Map<String, dynamic>> _detailResult(
    ({
      String bookId,
      String slug,
      int number,
      String chapterId,
      String seriesId,
    })
    id,
  ) async {
    final props = await _request('/movie/${id.slug}-${id.bookId}');
    final data = props['data'];
    if (data is! Map || data['online_base'] is! List) {
      throw const SourceUnavailable('reelshort', 'ReelShort 返回的剧集与请求不一致');
    }
    final episodes = data['online_base'] as List;
    if (episodes.length > 10000) {
      throw const SourceUnavailable('reelshort', 'ReelShort 返回的剧集与请求不一致');
    }
    final rawId =
        (data['book_id'] == null ||
            data['book_id'] == '' ||
            data['book_id'] == 0)
        ? data['_id']
        : data['book_id'];
    if (rawId != null && _text(rawId) != id.bookId) {
      throw const SourceUnavailable('reelshort', 'ReelShort 返回的剧集与请求不一致');
    }
    return Map<String, dynamic>.from(data);
  }

  Future<List<Drama>> _searchBooks(
    String keyword,
    int page, {
    DateTime? deadline,
  }) async {
    final props = await _request(
      '/search',
      query: {'keywords': keyword},
      deadline: deadline,
    );
    final books = props['books'];
    if (books is! List) {
      throw const SourceUnavailable('reelshort', 'ReelShort 官网搜索格式已变化，请等待适配');
    }
    return _pageResult(books);
  }

  // ── 归一 ────────────────────────────────────────────────────────

  static List<Drama> _pageResult(List<dynamic> books) {
    final seen = <String>{};
    final results = <Drama>[];
    for (final value in books.take(500)) {
      final drama = _normalizeBook(value);
      if (drama == null || !seen.add(drama.id)) continue;
      results.add(drama);
    }
    if (books.isNotEmpty && results.isEmpty) {
      throw const SourceUnavailable('reelshort', 'ReelShort 片单缺少可用剧集编号，请等待适配');
    }
    return results;
  }

  static Drama? _normalizeBook(dynamic value) {
    if (value is! Map) return null;
    final book = Map<String, dynamic>.from(value);
    final rawId = book['book_id'];
    final bookId = (rawId == null || rawId == '' || rawId == 0)
        ? _text(book['_id'])
        : _text(rawId);
    final title = _plainText(book['book_title']);
    final path = _slug(title);
    if (!_idPattern.hasMatch(bookId) ||
        title.isEmpty ||
        !_slugPattern.hasMatch(path) ||
        path.length > 200) {
      return null;
    }
    return Drama(
      id: 'reelshort:$bookId:$path',
      title: title,
      cover: _mediaUrl(book['book_pic']),
      intro: _plainText(book['special_desc']),
      episodeCount: _int(book['chapter_count']),
      tagNames: const [],
    );
  }

  static List<Episode> _episodes(Map<String, dynamic> data, String seriesId) {
    final episodes = <Episode>[];
    final seen = <int, String>{};
    for (final value in data['online_base'] as List) {
      if (value is! Map) continue;
      final raw = value['serial_number'];
      // 参考实现要求 Number.isSafeInteger：小数/超大数直接丢弃。
      if (raw is double && raw != raw.roundToDouble()) continue;
      final number = raw is num ? raw.toInt() : int.tryParse(_text(raw));
      if (number == null || number < 1 || number > 9999) continue;
      final chapterId = _text(value['chapter_id']);
      if (!_idPattern.hasMatch(chapterId)) continue;
      final vid = '$seriesId:$number:$chapterId';
      final prior = seen[number];
      if (prior != null) {
        if (prior != vid) {
          throw const SourceUnavailable('reelshort', 'ReelShort 分集编号冲突，请等待适配');
        }
        continue; // 完全重复的条目去重。
      }
      seen[number] = vid;
      final title = _plainText(value['chapter_name']);
      episodes.add(
        Episode(
          vid: vid,
          index: number,
          title: title.isEmpty ? '第 $number 集' : title,
          locked: _locked(value),
        ),
      );
    }
    episodes.sort((a, b) => a.index.compareTo(b.index));
    if (episodes.isEmpty) {
      throw const SourceUnavailable('reelshort', 'ReelShort 分集列表为空');
    }
    return episodes;
  }

  // ── 小工具 ──────────────────────────────────────────────────────

  ({String bookId, String slug, int number, String chapterId, String seriesId})
  _parseId(String value, {bool episode = false}) {
    final parts = _text(value).split(':');
    if (parts.length != (episode ? 5 : 3) ||
        parts[0] != 'reelshort' ||
        !_idPattern.hasMatch(parts[1]) ||
        !_slugPattern.hasMatch(parts[2]) ||
        parts[2].length > 200 ||
        (episode &&
            (!_numberPattern.hasMatch(parts[3]) ||
                !_idPattern.hasMatch(parts[4])))) {
      throw const SourceRejected('reelshort', 'ReelShort 剧集编号无效');
    }
    return (
      bookId: parts[1],
      slug: parts[2],
      number: episode ? int.parse(parts[3]) : 0,
      chapterId: episode ? parts[4] : '',
      seriesId: parts.take(3).join(':'),
    );
  }

  /// 只收以 https 开头且通过公网字面量判定的地址；私网/凭据/降级 IP 留空。
  static String _mediaUrl(dynamic value) {
    if (value is! String || !value.startsWith('https://')) return '';
    final uri = Uri.tryParse(value);
    if (uri == null || isPublicMediaUrl(uri) != null) return '';
    return value;
  }

  static bool _locked(dynamic item) {
    if (item is! Map) return false;
    for (final key in _lockedKeys) {
      final value = item[key];
      if (value == true || value == 1 || value == '1') return true;
    }
    return false;
  }

  /// 从播放地址派生域名族（eTLD+1 的近似），交给逐轨策略在每跳复用。
  static List<String> _hostFamily(String host) {
    final labels = host.split('.');
    if (labels.length >= 2) {
      return [labels.sublist(labels.length - 2).join('.')];
    }
    return [host];
  }

  static int _page(String? cursor) {
    if (cursor == null || cursor.isEmpty) return 1;
    return int.tryParse(cursor) ?? 0;
  }

  static String _text(dynamic value) => value == null ? '' : '$value';

  /// 去 HTML 标签；上游标题常带 `<em>` 高亮。
  static String _plainText(dynamic value) =>
      _text(value).replaceAll(RegExp(r'<[^>]*>'), '').trim();

  /// 参考 slug()：小写、非字母数字转空格、空格转连字符。
  static String _slug(dynamic title) =>
      _plainText(title)
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
          .trim()
          .replaceAll(RegExp(r' +'), '-');

  static int _int(dynamic value) =>
      value is num ? value.toInt() : int.tryParse(_text(value)) ?? 0;

  static Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
}
