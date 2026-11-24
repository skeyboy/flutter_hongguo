import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hongguo_core/hongguo_core.dart';

import '../catalog.dart';
import '../media_url_policy.dart';
import '../source_adapter.dart';
import '../video_model_client.dart';

/// 西饭源适配器：只移植参考 xifan.js 的协议行为，不复制任何签名密钥。
///
/// 与红果不同，西饭返回明文 MP4，没有 CENC：因此 [VideoTrack.spadeA] 留空，
/// 逐轨安全策略用 [PublicWebPolicy] 声明，由下载层在每一跳复用。
class XifanAdapter implements SourceAdapter {
  XifanAdapter(this.dio, {DateTime Function()? now})
    : now = now ?? DateTime.now;

  final Dio dio;
  final DateTime Function() now;

  static const _api = 'https://xifan-api-cn.youlishipin.com';
  static const _timeout = Duration(seconds: 10);
  static const _genreTtl = Duration(minutes: 5);

  /// 参考实现的段约束：渠道号/剧集号/分集号共用同一正则（含 `-`）。
  /// source_id.dart 的渠道号不含 `-`，故这里自行严格校验，不复用 parseSourceId。
  static final _idSegment = RegExp(r'^[A-Za-z0-9_-]{1,200}$');

  ({List<_Genre> items, DateTime expires})? _genreCache;

  @override
  String get id => 'xifan';

  @override
  String get label => '西饭';

  @override
  SourceKind get kind => SourceKind.builtin;

  @override
  bool matches(String mediaId) => mediaId.startsWith('xifan:');

  /// 默认开：只有显式设为 false 才关闭，与契约默认值表一致。
  @override
  bool enabled(SourceSettings settings) => settings.builtin['xifan'] != false;

  @override
  Future<CatalogPage> browse({
    String genre = '',
    String? cursor,
    String? sort,
  }) async {
    final items = await _genres();
    // 未指定题材时优先「都市」，与参考实现一致；找不到再退回第一个。
    final selected = genre.isEmpty
        ? (items.where((g) => g.label == '都市').firstOrNull ?? items.firstOrNull)
        : items.where((g) => g.slug == genre).firstOrNull;
    if (selected == null) {
      throw const SourceRejected('xifan', '西饭题材无效，请重新选择');
    }
    final page = _page(cursor);
    final result = await _request('/xifan/drama/portalPage', {
      'reqType': 'aggregationPage',
      'offset': (page - 1) * 30,
      'categoryId': selected.categoryId,
      'categoryNames': selected.label,
      'categoryVersion': selected.version,
    });
    return _normalizeList(result, page: page, categoryItems: items);
  }

  @override
  Future<CatalogPage> search(String query, {String? cursor}) async {
    final keyword = query.trim();
    if (keyword.isEmpty) {
      throw const SourceRejected('xifan', '请输入搜索关键词');
    }
    final page = _page(cursor);
    final result = await _request('/xifan/search/getSearchList', {
      'keyword': keyword,
      'pageIndex': page,
    });
    return _normalizeList(result, page: page);
  }

  @override
  Future<DramaDetail> detail(String seriesId) async {
    final id = _parseId(seriesId);
    final result = await _detailResult(id);
    final episodes = _episodes(result, seriesId);
    return DramaDetail(
      Drama(
        id: seriesId,
        title: _plainText(result['title']),
        cover: _httpsUrl(result['coverImageUrl']),
        episodeCount: episodes.length,
        tagNames: _tagNames(result['categories']),
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
    // 解锁状态是上游实时数据：每次取址都重读详情，不复用之前的缓存。
    final result = await _detailResult(id);
    Map<String, dynamic>? found;
    for (final value in result['episodeList'] as List) {
      final episode = _map(value);
      if (_text(episode['episodeId']) == id.episodeId) {
        found = episode;
        break;
      }
    }
    if (found == null) {
      throw const SourceUnavailable('xifan', '西饭未找到该分集');
    }
    if (found['unlock'] != true) {
      final index = _int(found['index']);
      // 参考实现在 index 缺失时留空，不显示「第 0 集」。
      final number = index > 0 ? '$index' : '';
      throw SourceLocked('xifan', '第 $number 集当前锁定，请在西饭官方 App 确认可看范围');
    }
    final url = _httpsUrl(found['playUrl']);
    if (url.isEmpty) {
      throw const SourceUnavailable('xifan', '西饭未提供有效 HTTPS 播放地址');
    }
    final uri = Uri.parse(url);
    return VideoTrack(
      url: uri,
      spadeA: '', // 明文 MP4：明文不进 CENC，绝不塞签名参数。
      definition: '',
      size: 0,
      userAgent: 'Mozilla/5.0',
      source: 'xifan',
      format: VideoFormat.mp4,
      policy: PublicWebPolicy(hosts: _hostFamily(uri.host)),
    );
  }

  // ── 协议请求 ────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _request(
    String path,
    Map<String, dynamic> params,
  ) async {
    late final Response<String> response;
    try {
      response = await dio.get<String>(
        '$_api$path',
        queryParameters: {
          ...params,
          'version': 2001001,
          'androidVersionCode': 28,
        },
        options: Options(
          headers: {'User-Agent': 'Mozilla/5.0', 'Accept': 'application/json'},
          followRedirects: false,
          receiveTimeout: _timeout,
          responseType: ResponseType.plain,
        ),
      );
    } on DioException catch (error) {
      final isTimeout =
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.connectionTimeout;
      throw SourceUnavailable(
        'xifan',
        isTimeout ? '西饭加载超时，请重试' : '西饭来源暂不可用，请稍后重试',
      );
    } on Object {
      throw const SourceUnavailable('xifan', '西饭来源暂不可用，请稍后重试');
    }

    Map<String, dynamic>? decoded;
    try {
      final raw = response.data;
      decoded = raw is String ? _map(jsonDecode(raw)) : _map(raw);
    } on Object {
      decoded = null;
    }
    if (decoded == null || decoded['ret'] != 0 || decoded['result'] is! Map) {
      // 远端异常原文可能带签名，统一替换为固定中文文案。
      throw const SourceUnavailable('xifan', '西饭来源暂不可用，请稍后重试');
    }
    return Map<String, dynamic>.from(decoded['result'] as Map);
  }

  Future<Map<String, dynamic>> _detailResult(
    ({String source, String duanjuId, String episodeId, String seriesId}) id,
  ) async {
    final result = await _request('/xifan/drama/getDuanjuInfo', {
      'source': id.source,
      'duanjuId': id.duanjuId,
    });
    if (_text(result['source']) != id.source ||
        _text(result['duanjuId']) != id.duanjuId ||
        result['episodeList'] is! List) {
      throw const SourceUnavailable('xifan', '西饭返回的剧集与请求不一致');
    }
    return result;
  }

  // ── 分类与列表 ──────────────────────────────────────────────────

  Future<List<_Genre>> _genres() async {
    final cached = _genreCache;
    if (cached != null && now().isBefore(cached.expires)) return cached.items;

    final result = await _request('/xifan/drama/portalPage', {
      'reqType': 'duanjuCategory',
    });
    final seen = <String>{};
    final items = <_Genre>[];
    for (final entry in _contents(result)) {
      final category = _map(entry['categoryItemVo']);
      if (category.isEmpty) continue;
      final subs = category['subCategories'];
      final candidates = subs is List && subs.isNotEmpty
          ? subs
          : <dynamic>[category];
      for (final value in candidates) {
        final item = _map(value);
        final rawId = item['categoryId'];
        final categoryId = rawId is num
            ? rawId.toInt()
            : int.tryParse(_text(rawId));
        // Number.isSafeInteger：小数 categoryId 不算合法分类。
        if (categoryId == null ||
            categoryId <= 0 ||
            (rawId is double && rawId != rawId.roundToDouble())) {
          continue;
        }
        final rawLabel = _text(item['oppoCategory']);
        final label = _plainText(rawLabel);
        if (label.isEmpty) continue;
        final slug = '$categoryId-${_hex(rawLabel)}';
        if (!seen.add(slug)) continue;
        final version = _int(item['version']);
        items.add((
          slug: slug,
          label: label,
          categoryId: categoryId,
          version: version < 1 ? 1 : version,
        ));
      }
    }
    if (items.isEmpty) {
      throw const SourceUnavailable('xifan', '西饭没有返回可用分类，请重试');
    }
    final values = List<_Genre>.unmodifiable(items);
    _genreCache = (items: values, expires: now().add(_genreTtl));
    return values;
  }

  CatalogPage _normalizeList(
    Map<String, dynamic> result, {
    required int page,
    List<_Genre> categoryItems = const [],
  }) {
    final seen = <String>{};
    final items = <Drama>[];
    for (final entry in _contents(result)) {
      final item = _map(entry['duanjuVo']);
      if (item.isEmpty) continue;
      final source = _text(item['source']);
      final duanjuId = _text(item['duanjuId']);
      final title = _plainText(item['title']);
      if (!_idSegment.hasMatch(source) ||
          !_idSegment.hasMatch(duanjuId) ||
          title.isEmpty) {
        continue;
      }
      final seriesId = 'xifan:$source:$duanjuId';
      if (!seen.add(seriesId)) continue;
      items.add(
        Drama(
          id: seriesId,
          title: title,
          cover: _httpsUrl(item['coverImageUrl']),
          episodeCount: _int(item['total']),
          tagNames: _tagNames(item['categories']),
        ),
      );
    }
    final hasMore = result['hasMore'] == true && items.isNotEmpty;
    return CatalogPage(items, nextCursor: hasMore ? '${page + 1}' : null);
  }

  List<Episode> _episodes(Map<String, dynamic> result, String seriesId) {
    final episodes = <Episode>[];
    for (final value in result['episodeList'] as List) {
      final episode = _map(value);
      final episodeId = _text(episode['episodeId']);
      if (!_idSegment.hasMatch(episodeId)) continue;
      episodes.add(
        Episode(
          vid: '$seriesId:$episodeId',
          index: _int(episode['index']),
          title: _plainText(episode['title']),
          locked: episode['unlock'] != true,
        ),
      );
    }
    episodes.sort((a, b) => a.index.compareTo(b.index));
    return episodes;
  }

  // ── 小工具 ──────────────────────────────────────────────────────

  ({String source, String duanjuId, String episodeId, String seriesId})
  _parseId(String value, {bool episode = false}) {
    final parts = _text(value).split(':');
    if (parts.length != (episode ? 4 : 3) ||
        parts[0] != 'xifan' ||
        !parts.skip(1).every(_idSegment.hasMatch)) {
      throw const SourceRejected('xifan', '西饭剧集编号无效');
    }
    return (
      source: parts[1],
      duanjuId: parts[2],
      episodeId: parts.length > 3 ? parts[3] : '',
      seriesId: parts.take(3).join(':'),
    );
  }

  /// 参考 httpsUrl：必须 https、无凭据，且过 core 的公网字面量判定。
  String _httpsUrl(dynamic value) {
    final uri = Uri.tryParse(_text(value));
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        isPublicMediaUrl(uri) != null) {
      return '';
    }
    return uri.toString();
  }

  /// 从播放地址派生域名族（eTLD+1 的近似），交给逐轨策略在每跳复用。
  List<String> _hostFamily(String host) {
    final labels = host.split('.');
    if (labels.length >= 2) {
      return [labels.sublist(labels.length - 2).join('.')];
    }
    return [host];
  }

  static int _page(String? cursor) {
    final page = int.tryParse(cursor ?? '') ?? 1;
    return page < 1 ? 1 : page;
  }

  static List<Map<String, dynamic>> _contents(Map<String, dynamic> result) {
    final elements = result['elements'];
    if (elements is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final value in elements) {
      final contents = _map(value)['contents'];
      if (contents is! List) continue;
      for (final entry in contents) {
        out.add(_map(entry));
      }
    }
    return out;
  }

  static List<String> _tagNames(dynamic value) {
    if (value is! List) return const [];
    final names = <String>[];
    for (final entry in value) {
      final name = _plainText(entry);
      if (name.isNotEmpty && !names.contains(name)) names.add(name);
    }
    return List.unmodifiable(names.take(4));
  }

  static String _hex(String value) => utf8
      .encode(value)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();

  static String _text(dynamic value) => value == null ? '' : '$value';
  static String _plainText(dynamic value) =>
      _text(value).replaceAll(RegExp(r'<[^>]*>'), '').trim();
  static int _int(dynamic value) =>
      value is num ? value.toInt() : int.tryParse(_text(value)) ?? 0;
  static Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
}

typedef _Genre = ({String slug, String label, int categoryId, int version});
