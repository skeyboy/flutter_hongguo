import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hongguo_core/hongguo_core.dart';

import '../catalog.dart';
import '../media_url_policy.dart';
import '../source_adapter.dart';
import '../video_model_client.dart';

/// 河马（www.kuaikaw.cn）来源适配器。
///
/// 只移植参考 hema.js 的协议行为：公开页面取 __NEXT_DATA__、搜索接口取 JSON、
/// 播放地址只认公网明文 HTTPS。不复制任何签名密钥或远端异常原文。
class HemaAdapter implements SourceAdapter {
  HemaAdapter(this.dio, {DateTime Function()? now}) : now = now ?? DateTime.now;

  final Dio dio;

  /// 题材目录缓存的时钟注入点，便于测试 5 分钟过期逻辑。
  final DateTime Function() now;

  static const _origin = 'https://www.kuaikaw.cn';
  static final _id = RegExp(r'^\d{1,30}$');
  static final _slug = RegExp(r'^\d{1,30}(?:-\d{1,30}){0,15}$');
  static final _ipv4 = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$');

  // Dart 没有内置 HTML 解析器：用正则抠 <script id="__NEXT_DATA__"> 的内容。
  static final _nextData = RegExp(
    '<script\\b[^>]*\\bid=["\']__NEXT_DATA__["\'][^>]*>([\\s\\S]*?)</script>',
    caseSensitive: false,
  );

  List<({String slug, String label})>? _genres;
  DateTime? _genresExpiry;

  @override
  String get id => 'hema';

  @override
  String get label => '河马';

  @override
  SourceKind get kind => SourceKind.builtin;

  @override
  bool matches(String mediaId) => mediaId.startsWith('hema:');

  @override
  bool enabled(SourceSettings settings) => settings.builtin['hema'] != false;

  // ── 协议原语 ────────────────────────────────────────────────────

  ({String bookId, String chapterId, String seriesId}) _parseId(
    String value, {
    bool episode = false,
  }) {
    final parts = value.split(':');
    if (parts[0] != 'hema' ||
        parts.length != (episode ? 3 : 2) ||
        !parts.skip(1).every(_id.hasMatch)) {
      throw const SourceRejected('hema', '河马剧集编号无效');
    }
    return (
      bookId: parts[1],
      chapterId: parts.length > 2 ? parts[2] : '',
      seriesId: '${parts[0]}:${parts[1]}',
    );
  }

  Future<dynamic> _request(String path, {Map<String, dynamic>? body}) async {
    final isPost = body != null;
    final options = Options(
      // 固定官网请求头：缺 pname/Referer 时上游会返回空页面。
      headers: <String, String>{
        'User-Agent': 'Mozilla/5.0',
        'Accept': isPost ? 'application/json' : 'text/html',
        'Content-Type': 'application/json',
        'pname': 'www.kuaikaw.cn',
        'Origin': _origin,
        'Referer': '$_origin/',
      },
      followRedirects: false, // 不把官网请求头带到未校验的重定向目标。
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      responseType: isPost ? ResponseType.json : ResponseType.plain,
    );
    try {
      final response = isPost
          ? await dio.post<dynamic>(
              '$_origin$path',
              data: body,
              options: options,
            )
          : await dio.get<dynamic>('$_origin$path', options: options);
      return response.data;
    } on DioException catch (e) {
      // 只按超时类型分诊，绝不回传远端异常原文（可能含签名参数）。
      final timeout =
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout;
      throw SourceUnavailable(
        'hema',
        timeout ? '河马加载超时，请重试' : '河马来源暂不可用，请稍后重试',
      );
    } catch (_) {
      throw const SourceUnavailable('hema', '河马来源暂不可用，请稍后重试');
    }
  }

  Map<String, dynamic> _pageData(dynamic html) {
    if (html is String) {
      final match = _nextData.firstMatch(html);
      if (match != null) {
        try {
          final decoded = jsonDecode(match.group(1)!);
          final props = decoded is Map ? decoded['props'] : null;
          final data = props is Map ? props['pageProps'] : null;
          if (data is Map<String, dynamic>) return data;
          if (data is Map) return Map<String, dynamic>.from(data);
        } catch (_) {
          // 落到下方统一文案，不暴露 jsonDecode 的原文。
        }
      }
    }
    throw const SourceUnavailable('hema', '河马目录数据异常，请稍后重试');
  }

  /// 过滤 HTML 标签并压缩空白；上游标题常带 <em> 高亮。
  String _plainText(Object? value) {
    if (value == null || value == '' || value == 0) return '';
    return value.toString().replaceAll(RegExp(r'<[^>]*>'), '').trim();
  }

  /// 播放/封面地址只收公网明文 HTTPS：私网、凭据、降级 IP 一律视为无效。
  String _httpsUrl(Object? value) {
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

  List<Drama> _normalizeBooks(Object? books) {
    if (books is! List) return const <Drama>[];
    final seen = <String>{};
    final results = <Drama>[];
    for (final item in books) {
      if (item is! Map) continue;
      final bookId = item['bookId']?.toString() ?? '';
      if (!_id.hasMatch(bookId)) continue;
      final title = _plainText(item['bookName']);
      if (title.isEmpty) continue;
      final seriesId = 'hema:$bookId';
      if (!seen.add(seriesId)) continue; // 上游同页会重复推同一部剧。

      final tags = <String>[];
      final rawTags = item['bookTypeThree'];
      if (rawTags is List) {
        for (final tag in rawTags) {
          final name = tag is Map ? _plainText(tag['name']) : '';
          if (name.isEmpty) continue;
          tags.add(name);
          if (tags.length == 4) break;
        }
      }
      results.add(
        Drama(
          id: seriesId,
          title: title,
          cover: _httpsUrl(item['coverWap']),
          episodeCount:
              int.tryParse(item['totalChapterNum']?.toString() ?? '') ?? 0,
          tagNames: tags,
        ),
      );
    }
    return results;
  }

  /// URL 的域名族：普通域名取 eTLD+1 粗粒度，公网 IP 字面量则整机 host。
  List<String> _domainFamily(String host) {
    if (_ipv4.hasMatch(host)) return [host];
    final labels = host.split('.');
    if (labels.length < 2) return [host];
    return [labels.sublist(labels.length - 2).join('.')];
  }

  /// 详情数据统一在这里校验；fetchTrack 每次都新调一次，不复用付费状态。
  Future<Map<String, dynamic>> _loadDetail(String seriesId) async {
    final id = _parseId(seriesId);
    final data = _pageData(await _request('/drama/${id.bookId}'));
    final info = data['bookInfoVo'];
    final chapters = data['chapterList'];
    if (info is! Map ||
        info['bookId']?.toString() != id.bookId ||
        chapters is! List) {
      throw const SourceUnavailable('hema', '河马返回的剧集与请求不一致');
    }
    final seen = <String>{};
    for (final chapter in chapters) {
      if (chapter is! Map) {
        throw const SourceUnavailable('hema', '河马分集数据异常，请稍后重试');
      }
      final chapterId = chapter['chapterId']?.toString() ?? '';
      if (!_id.hasMatch(chapterId) || !seen.add(chapterId)) {
        throw const SourceUnavailable('hema', '河马分集数据异常，请稍后重试');
      }
      final rawBookId = chapter['bookId'];
      if (rawBookId != null && rawBookId.toString() != id.bookId) {
        throw const SourceUnavailable('hema', '河马分集数据异常，请稍后重试');
      }
    }
    return data;
  }

  // ── SourceAdapter ───────────────────────────────────────────────

  @override
  Future<CatalogPage> browse({
    String genre = '',
    String? cursor,
    String? sort,
  }) async {
    final slug = genre.isEmpty ? '0' : genre;
    final parsedPage = int.tryParse(cursor ?? '');
    final page = parsedPage ?? (cursor == null || cursor.isEmpty ? 1 : 0);
    if (page < 1 || !_slug.hasMatch(slug)) {
      throw const SourceRejected('hema', '河马题材或页码无效，请重新选择');
    }

    late final List<({String slug, String label})> genres;
    String? firstHtml;
    final expired =
        _genres == null ||
        _genresExpiry == null ||
        !now().isBefore(_genresExpiry!);
    if (expired) {
      // 首次（或缓存过期）先取 /browse 拿题材目录；可能即为目标页，复用响应。
      firstHtml = (await _request('/browse'))?.toString();
      final directory = _pageData(firstHtml);
      final raw = directory['typeThreeList'];
      if (raw is! List) {
        throw const SourceUnavailable('hema', '河马没有返回可用题材，请重试');
      }
      final seen = <String>{};
      final items = <({String slug, String label})>[];
      for (final entry in raw) {
        if (entry is! Map) continue;
        final ids = entry['typeThreeIds'];
        if (ids is! List || ids.isEmpty || ids.length > 16) continue;
        final parts = <String>[];
        var valid = true;
        for (final id in ids) {
          final text = id?.toString() ?? '';
          if (!_id.hasMatch(text)) {
            valid = false;
            break;
          }
          parts.add(text);
        }
        if (!valid) continue;
        final name = _plainText(entry['name']);
        if (name.isEmpty) continue;
        final value = parts.join('-');
        if (value == '0' || !seen.add(value)) continue; // slug '0' 是「全部」
        items.add((slug: value, label: name));
      }
      if (items.isEmpty) {
        throw const SourceUnavailable('hema', '河马没有返回可用题材，请重试');
      }
      genres = items;
      _genres = items;
      _genresExpiry = now().add(const Duration(minutes: 5));
    } else {
      genres = _genres!;
    }
    if (slug != '0' && !genres.any((item) => item.slug == slug)) {
      throw const SourceRejected('hema', '河马题材无效，请重新选择');
    }

    final apiPath = slug == '0' && page == 1
        ? '/browse'
        : '/browse/$slug${page > 1 ? '/$page' : ''}';
    final html = (apiPath == '/browse' && firstHtml != null
        ? firstHtml
        : (await _request(apiPath)).toString());
    final data = _pageData(html);
    final rawType = data['typeThreeId'];
    final typeId = (rawType == null || rawType == '' || rawType == 0)
        ? '0'
        : rawType.toString();
    if (data['bookList'] is! List ||
        int.tryParse(data['page']?.toString() ?? '') != page ||
        typeId != slug) {
      // 上游返回的页码/题材与请求不符时不能拼进游标，否则后续翻页全错。
      throw const SourceUnavailable('hema', '河马返回的目录与请求不一致，请重试');
    }
    final items = _normalizeBooks(data['bookList']);
    final hasMore =
        items.isNotEmpty &&
        RegExp(
          '<a\\b[^>]*\\shref=["\']/browse/${RegExp.escape(slug)}/${page + 1}["\']',
        ).hasMatch(html);
    return CatalogPage(items, nextCursor: hasMore ? '${page + 1}' : null);
  }

  @override
  Future<CatalogPage> search(String query, {String? cursor}) async {
    final keyword = query.trim();
    if (keyword.isEmpty) {
      throw const SourceRejected('hema', '请输入搜索关键词');
    }
    final parsed = int.tryParse(cursor ?? '');
    final page = parsed == null || parsed < 1 ? 1 : parsed;
    final response = await _request(
      '/seo/video/6007',
      body: {'sourceType': 1, 'keyword': keyword, 'index': page},
    );
    final data = response is Map ? response['data'] : null;
    if (response is! Map ||
        response['retCode'] != 0 ||
        data is! Map ||
        data['bookList'] is! List) {
      throw const SourceUnavailable('hema', '河马搜索数据异常，请稍后重试');
    }
    final items = _normalizeBooks(data['bookList']);
    final hasMore = data['isMore'] == 1 && items.isNotEmpty;
    return CatalogPage(items, nextCursor: hasMore ? '${page + 1}' : null);
  }

  @override
  Future<DramaDetail> detail(String seriesId) async {
    final data = await _loadDetail(seriesId);
    final info = data['bookInfoVo'] as Map;
    final chapters = data['chapterList'] as List;
    final title = _plainText(info['bookName']);
    final drama = Drama(
      id: seriesId,
      title: title.isEmpty ? '未命名短剧' : title,
      cover: _httpsUrl(info['coverWap']),
      episodeCount: chapters.length,
    );
    final episodes = <Episode>[];
    for (var i = 0; i < chapters.length; i++) {
      final chapter = chapters[i] as Map;
      episodes.add(
        Episode(
          vid: '$seriesId:${chapter['chapterId']}',
          index:
              int.tryParse(chapter['chapterIndex']?.toString() ?? '') ?? i + 1,
          title: _plainText(chapter['chapterName']),
          locked: chapter['isCharge'] != '0', // 仅提示，不绕过鉴权。
        ),
      );
    }
    episodes.sort((a, b) => a.index.compareTo(b.index));
    return DramaDetail(drama, episodes);
  }

  @override
  Future<VideoTrack> fetchTrack(
    String mediaId, {
    String quality = 'best',
  }) async {
    final id = _parseId(mediaId, episode: true);
    // 每次请求都重读详情：参考实现明确要求不复用上次的免费/付费判定。
    final data = await _loadDetail(id.seriesId);
    final chapters = data['chapterList'] as List;
    Map? chapter;
    for (final item in chapters) {
      if (item is Map && item['chapterId']?.toString() == id.chapterId) {
        chapter = item;
        break;
      }
    }
    if (chapter == null) {
      throw const SourceUnavailable('hema', '河马未找到该分集');
    }
    if (chapter['isCharge'] != '0') {
      final rawIndex = int.tryParse(chapter['chapterIndex']?.toString() ?? '');
      final label = rawIndex == null || rawIndex == 0 ? '' : '$rawIndex';
      throw SourceLocked('hema', '第 $label 集当前锁定，请在河马官方平台确认可看范围');
    }
    final video = chapter['chapterVideoVo'];
    final rawVideo = video is Map ? video : const <String, dynamic>{};
    final url = _httpsUrl(rawVideo['mp4720p']);
    final playable = url.isNotEmpty ? url : _httpsUrl(rawVideo['mp4']);
    if (playable.isEmpty) {
      throw const SourceUnavailable('hema', '河马未提供有效 HTTPS 播放地址');
    }
    final uri = Uri.parse(playable);
    return VideoTrack(
      url: uri,
      spadeA: '', // 河马是明文 MP4，没有红果的 CENC 密文参数。
      definition: '',
      size: 0,
      userAgent: 'Mozilla/5.0',
      referer: '$_origin/',
      source: 'hema',
      format: VideoFormat.mp4,
      policy: PublicWebPolicy(
        hosts: _domainFamily(uri.host),
        refererHost: 'www.kuaikaw.cn',
      ),
    );
  }
}
