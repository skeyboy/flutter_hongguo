import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hongguo_core/hongguo_core.dart';

import '../catalog.dart';
import '../media_url_policy.dart';
import '../source_adapter.dart';
import '../video_model_client.dart';

/// 自定义源（苹果 CMS provide/vod 接口）适配器。
///
/// 协议行为移植自参考 custom-source.js：只搬「请求形状 + 归一规则」，
/// 不复制任何签名密钥。用户可控 URL 是最强攻击面，因此：
/// 1. 配置期 [validate] 只收公网 HTTPS、无凭据地址；
/// 2. 每次请求从头读配置，并逐跳重跑公网校验（不依赖底层自动跟随）；
/// 3. 无 HLS 播放通道，m3u8 线路在适配器层早拒，绝不流进下载层。
class CustomSourceAdapter implements SourceAdapter, SourceTestCapability {
  CustomSourceAdapter({
    required this.uuid,
    required this.dio,
    required this.configOf,
    CustomSourceConfig? initial,
    CancelTokenRegistry? tokens,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now,
       initial = initial,
       _baselineUrl = CustomSourceAdapter._normalizedUrlOf(initial),
       _tokenRegistry = tokens ?? CancelTokenRegistry();

  final String uuid;
  final Dio dio;

  /// 只用于 id/label 展示与 URL 基线；请求地址始终来自 [configOf]。
  final CustomSourceConfig? initial;

  /// 每次请求都重新读设置：配置改了/删了，旧适配器必须立刻拒绝，
  /// 由注册工厂重建新实例（等价参考的 assertEnabled）。
  final CustomSourceConfig? Function() configOf;

  /// 时钟注入点：与其它适配器构造签名保持一致（协议本身无 TTL 缓存）。
  final DateTime Function() now;

  String? _baselineUrl;
  final CancelTokenRegistry _tokenRegistry;

  static const _ua = 'Mozilla/5.0';
  static const _timeout = Duration(seconds: 12);
  static const _maxBytes = 8 * 1024 * 1024;
  static const _maxRedirects = 3;
  static const _defaultPath = '/api.php/provide/vod/';

  static const _changedMessage = '该自定义源已禁用、删除或配置已变更，请重新加载';
  static const _badConfigMessage = '来源配置无效，请重新添加该片源';
  static const _badAddressMessage = '来源配置无效，地址不是公网 HTTPS 接口';
  static const _badJsonMessage = '自定义源未返回有效 JSON';
  static const _badDataMessage = '自定义源返回的苹果 CMS 数据无效';
  static const _pageMismatchMessage = '自定义源返回的页码不一致';
  static const _hlsMessage = '该剧仅提供 HLS 流，当前版本暂不支持，请在来源平台观看';
  static const _lockedMessage = '该剧当前需付费或密码，请在来源平台确认观看权限';
  static const _noTrackMessage = '自定义源未找到可直接播放的分集';
  static const _networkMessage = '自定义源请求失败，请检查公网接口与网络';
  static const _timeoutMessage = '自定义源请求已取消或超时，请重试';

  static final _uuidV4 = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );
  static final _digits = RegExp(r'^\d{1,30}$');
  static final _smallDigits = RegExp(r'^\d{1,5}$');
  static final _episodeNumber = RegExp(r'^(?:第\s*)?(\d+)\s*(?:集|话|期)?$');
  static final _extension = RegExp(r'\.(mp4|m3u8)$', caseSensitive: false);

  /// 最近一次 browse/search 拿到的分类，供设置页/UI 展示（契约 pageResult.genres）。
  List<CatalogFilter> lastGenres = const [];

  @override
  String get id => 'custom:$uuid';

  /// 名称跟着配置实时走；配置被删时退回 initial，避免来源列表出现空标题。
  @override
  String get label {
    final current = _current();
    return current == null
        ? (initial?.name.isNotEmpty == true ? initial!.name : id)
        : current.name;
  }

  @override
  SourceKind get kind => SourceKind.custom;

  @override
  bool matches(String mediaId) => mediaId.startsWith('custom:$uuid:');

  @override
  bool enabled(SourceSettings settings) => settings.isEnabled('custom:$uuid');

  // ── 配置校验 ────────────────────────────────────────────────────

  /// 保存前/每次请求前的归一校验：名字去 HTML、URL 补默认接口路径去 hash。
  ///
  /// 名称上限取 core 的 40（配置最终要过 SourceSettings.validate），
  /// URL 上限按参考的 4096；所有失败都抛自有文案的 [SourceRejected]。
  static CustomSourceConfig validate(CustomSourceConfig? draft) {
    final sourceId = draft == null || draft.uuid.isEmpty
        ? 'custom:'
        : 'custom:${draft.uuid.toLowerCase()}';
    if (draft == null) {
      throw SourceRejected(sourceId, _badConfigMessage);
    }
    final name = plainText(draft.name);
    if (name.isEmpty || name.length > 40 || RegExp(r'[\r\n]').hasMatch(name)) {
      throw SourceRejected(sourceId, '自定义源名称需为 1 至 40 个字符且不含换行');
    }
    if (!_uuidV4.hasMatch(draft.uuid)) {
      throw const SourceRejected('custom:', '自定义源编号无效');
    }
    if (draft.url.isEmpty || draft.url.length > 4096) {
      throw SourceRejected(sourceId, _badAddressMessage);
    }
    final uri = Uri.tryParse(draft.url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        isPublicMediaUrl(uri) != null) {
      throw SourceRejected(sourceId, _badAddressMessage);
    }
    // Uri.replace(fragment: '') 会留下一个裸 '#'，这里重建 URI 真正去掉 hash。
    // Dart 的 Uri.path 对裸域名是空串（JS 的 pathname 是 '/'），两者都算根路径。
    final path = uri.path.isEmpty || uri.path == '/' ? _defaultPath : uri.path;
    final normalized = Uri.https(uri.host, path, uri.queryParameters);
    return CustomSourceConfig(
      uuid: draft.uuid.toLowerCase(),
      name: name,
      url: normalized.toString(),
      enabled: draft.enabled,
    );
  }

  static String? _normalizedUrlOf(CustomSourceConfig? initial) {
    if (initial == null) return null;
    try {
      return validate(initial).url;
    } on Object {
      return initial.url;
    }
  }

  CustomSourceConfig? _current() {
    try {
      return configOf();
    } on Object {
      return null;
    }
  }

  /// 参考 check()：配置消失、被禁用或 URL 变了，立刻拒绝在途请求。
  CustomSourceConfig assertEnabled() {
    final current = _current();
    if (current == null) throw SourceRejected(id, _changedMessage);
    final config = validate(current);
    if (!config.enabled) throw SourceRejected(id, _changedMessage);
    final baseline = _baselineUrl ??= config.url;
    if (config.url != baseline) throw SourceRejected(id, _changedMessage);
    return config;
  }

  /// 撤销本源所有在途请求（配置变更/删除时由注册层调用）。
  void cancelRequests() => _tokenRegistry.cancel(uuid);

  // ── SourceAdapter ───────────────────────────────────────────────

  @override
  Future<CatalogPage> browse({
    String genre = '',
    String? cursor,
    String? sort,
  }) async {
    assertEnabled();
    final category = genre.trim();
    if (category.isNotEmpty && !_digits.hasMatch(category)) {
      throw SourceRejected(id, '自定义源分类或页码无效');
    }
    final page = _page(cursor);
    // 苹果 CMS 没有 sort 参数：sort 被有意忽略，不让调用方以为它生效。
    final data = await request({
      'pg': page,
      if (category.isNotEmpty) 't': category,
    });
    final result = pageResult(data, page: page);
    lastGenres = result.genres;
    return CatalogPage(result.items, nextCursor: result.nextCursor);
  }

  @override
  Future<CatalogPage> search(String query, {String? cursor}) async {
    assertEnabled();
    final keyword = plainText(query);
    if (keyword.isEmpty || keyword.length > 200) {
      throw SourceRejected(id, '自定义源搜索词或页码无效');
    }
    final page = _page(cursor);
    final data = await request({'wd': keyword, 'pg': page});
    final result = pageResult(data, page: page);
    lastGenres = result.genres;
    return CatalogPage(result.items, nextCursor: result.nextCursor);
  }

  @override
  Future<DramaDetail> detail(String seriesId) async {
    final loaded = await _loadDetail(seriesId);
    final drama = normalizeItem(loaded.item);
    if (drama == null) {
      throw SourceUnavailable(id, '自定义源详情无效');
    }
    final locked = isLocked(loaded.item);
    return DramaDetail(
      drama,
      _episodes(loaded.item, loaded.seriesId, locked: locked),
    );
  }

  @override
  Future<VideoTrack> fetchTrack(
    String mediaId, {
    String quality = 'best',
  }) async {
    final parsed = _parseId(mediaId, episode: true);
    final config = assertEnabled();
    // 解锁状态是上游实时数据：每次取址重读详情，绝不复用上次判定。
    final loaded = await _loadDetail(parsed.seriesId);
    if (isLocked(loaded.item)) {
      throw SourceLocked(id, _lockedMessage);
    }
    final lines = mediaLines(loaded.item);
    MediaEpisode? selected;
    for (final line in lines) {
      if (line.line == parsed.line && line.episode == parsed.episode) {
        selected = line;
        break;
      }
    }
    if (selected == null) throw SourceUnavailable(id, _noTrackMessage);
    // 本项目无 HLS 通道：被选中的线路是 m3u8 时早拒，不返回 hls 轨。
    if (selected.format != VideoFormat.mp4) {
      throw SourceUnavailable(id, _hlsMessage);
    }

    final candidates = <MediaEpisode>[selected];
    for (final line in lines) {
      if (line.format != VideoFormat.mp4 ||
          line.key != selected.key ||
          candidates.any((c) => c.url.toString() == line.url.toString())) {
        continue;
      }
      candidates.add(line);
    }
    final referer = '${Uri.parse(config.url).origin}/';
    // quality 对苹果 CMS 无意义：线路名才是它的「清晰度」，由候选集表达。
    final alternates = [
      for (final candidate in candidates.skip(1)) _track(candidate, referer),
    ];
    return _track(
      candidates.first,
      referer,
      candidates: alternates.isEmpty ? null : alternates,
    );
  }

  VideoTrack _track(
    MediaEpisode episode,
    String referer, {
    List<VideoTrack>? candidates,
  }) => VideoTrack(
    url: episode.url,
    spadeA: '', // 明文 MP4，不进红果 CENC 解密链路。
    definition: episode.title,
    size: 0,
    userAgent: _ua,
    referer: referer,
    source: id,
    format: VideoFormat.mp4,
    candidates: candidates,
    policy: PublicWebPolicy(hosts: [episode.url.host]),
  );

  // ── 连通性测试 ──────────────────────────────────────────────────

  @override
  Future<SourceTestResult> test() async {
    try {
      // draft 模式允许保存前测试：只校验草稿，不跑 enabled/基线一致性检查。
      validate(_current());
      final data = await request(const {'pg': 1}, draft: true);
      final count = genres(data).length;
      final total = (data['list'] as List).length;
      return SourceTestResult(ok: true, message: '连接成功，返回 $total 条，$count 个分类');
    } on SourceException catch (error) {
      return SourceTestResult(ok: false, message: error.message);
    } on Object {
      return SourceTestResult(ok: false, message: _networkMessage);
    }
  }

  // ── 协议请求与 SSRF ─────────────────────────────────────────────

  /// 苹果 CMS 请求形状：删掉原地址自带的控制参数，固定 ac=detail&at=json。
  static Uri _queryUrl(String sourceUrl, Map<String, dynamic> params) {
    final uri = Uri.parse(sourceUrl);
    final query = <String, String>{...uri.queryParameters};
    for (final key in ['ac', 'pg', 't', 'wd', 'ids', 'at']) {
      query.remove(key);
    }
    query['ac'] = 'detail';
    query['at'] = 'json';
    params.forEach((key, value) => query[key] = '$value');
    return uri.replace(queryParameters: query);
  }

  /// 完整 URL 每跳都过公网策略：私网/回环/Fake-IP/TEST-NET/凭据/非 https
  /// 一律在发包前拒绝，错误信息是本地固定文案，不带远端异常原文。
  void _checkPublic(Uri url) {
    try {
      checkMediaUrl(url.toString(), const PublicWebPolicy());
    } on FormatException {
      throw SourceRejected(id, _badAddressMessage);
    }
  }

  Future<Map<String, dynamic>> request(
    Map<String, dynamic> params, {
    bool draft = false,
  }) async {
    final source = draft ? validate(_current()) : assertEnabled();
    final url = _queryUrl(source.url, params);
    final token = CancelToken();
    _tokenRegistry.register(uuid, token);
    try {
      return await _fetch(url, token: token, draft: draft);
    } finally {
      _tokenRegistry.unregister(uuid, token);
    }
  }

  Future<Map<String, dynamic>> _fetch(
    Uri url, {
    required CancelToken token,
    required bool draft,
  }) async {
    var current = url;
    Response<String>? response;
    // 逐跳循环：Dio 自动跟随关掉，Location 用当前跳 resolve，
    // 每跳发包前重新查公网与配置（不先探测后连接，避免 TOCTOU）。
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      if (!draft) assertEnabled();
      _checkPublic(current);
      try {
        response = await dio.fetch<String>(
          Options(
            method: 'GET',
            responseType: ResponseType.plain,
            followRedirects: false,
            // 3xx 要留给下面的逐跳循环自己校验，不能被 Dio 当错误抛掉。
            validateStatus: (status) => status != null && status < 400,
            connectTimeout: _timeout,
            sendTimeout: _timeout,
            receiveTimeout: _timeout,
            headers: const <String, String>{
              'Accept': 'application/json',
              'User-Agent': _ua,
            },
          ).compose(dio.options, current.toString(), cancelToken: token),
        );
      } on DioException catch (error) {
        throw SourceUnavailable(
          id,
          _cancelOrTimeout(error) ? _timeoutMessage : _networkMessage,
        );
      } on SourceException {
        rethrow;
      } on Object {
        throw SourceUnavailable(id, _networkMessage);
      }

      final location = response.headers.value('location');
      final status = response.statusCode ?? 0;
      if (status >= 300 &&
          status < 400 &&
          location != null &&
          location.trim().isNotEmpty) {
        if (hop == _maxRedirects) {
          throw SourceUnavailable(id, '自定义源重定向次数过多，请重试');
        }
        current = current.resolve(location.trim());
        continue;
      }
      break;
    }
    if (!draft) assertEnabled(); // 响应后再复查一次配置。

    final finalResponse = response!;
    final status = finalResponse.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw SourceUnavailable(id, _networkMessage);
    }
    final text = finalResponse.data ?? '';
    if (utf8.encode(text).length > _maxBytes) {
      throw SourceUnavailable(id, _networkMessage);
    }
    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) data = Map<String, dynamic>.from(decoded);
    } on Object {
      data = null;
    }
    if (data == null) throw SourceUnavailable(id, _badJsonMessage);
    if (_intOf(data['code']) != 1 ||
        data['list'] is! List ||
        (data['list'] as List).length > 500) {
      throw SourceUnavailable(id, _badDataMessage);
    }
    return data;
  }

  static bool _cancelOrTimeout(DioException error) =>
      error.type == DioExceptionType.cancel ||
      error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.receiveTimeout;

  // ── 数据归一 ────────────────────────────────────────────────────

  /// 参考 isLocked：付费点播或播放密码都不给地址，引导官方平台。
  bool isLocked(Map<String, dynamic> item) {
    if (item['locked'] == true) return true;
    if ((_intOf(item['vod_points_play']) ?? 0) > 0) return true;
    if ((_intOf(item['vod_points']) ?? 0) > 0) return true;
    return plainText(item['vod_pwd_play'] ?? item['vod_pwd']).isNotEmpty;
  }

  Drama? normalizeItem(Map<String, dynamic> item) {
    final vodId = plainText(item['vod_id']);
    final title = plainText(item['vod_name']);
    if (!_digits.hasMatch(vodId) || title.isEmpty) return null;
    final tag = plainText(item['type_name']);
    return Drama(
      id: 'custom:$uuid:$vodId',
      title: title,
      cover: _httpsUrl(item['vod_pic']),
      episodeCount: _intOf(item['vod_total']) ?? 0,
      intro: plainText(item['vod_content']),
      tagNames: [if (tag.isNotEmpty) tag],
    );
  }

  ({List<Drama> items, String? nextCursor, List<CatalogFilter> genres})
  pageResult(Map<String, dynamic> data, {required int page}) {
    if (data['page'] != null && _intOf(data['page']) != page) {
      throw SourceUnavailable(id, _pageMismatchMessage);
    }
    final seen = <String>{};
    final items = <Drama>[];
    for (final value in (data['list'] as List? ?? const [])) {
      final item = value is Map
          ? Map<String, dynamic>.from(value)
          : <String, dynamic>{};
      final drama = normalizeItem(item);
      if (drama == null || !seen.add(drama.id)) continue;
      items.add(drama);
    }
    final totalPages = _intOf(data['pagecount']) ?? 0;
    final hasMore = items.isNotEmpty && page < totalPages;
    return (
      items: items,
      nextCursor: hasMore ? '${page + 1}' : null,
      genres: genres(data),
    );
  }

  /// data.class → 数字分类 ID + 非空名称；上限 500 与参考一致。
  List<CatalogFilter> genres(Map<String, dynamic> data) {
    final raw = data['class'];
    if (raw is! List) return const [];
    final result = <CatalogFilter>[];
    for (final value in raw.take(500)) {
      final item = value is Map
          ? Map<String, dynamic>.from(value)
          : <String, dynamic>{};
      final typeId = plainText(item['type_id']);
      final label = plainText(item['type_name']);
      if (!_digits.hasMatch(typeId) || label.isEmpty) continue;
      result.add(CatalogFilter(label, typeId));
    }
    return List.unmodifiable(result);
  }

  /// vod_play_from/vod_play_url 双 $$$ 分线路；每集「标题$URL」。
  /// 保留 m3u8 条目只是为了让上层能给出「仅 HLS」的专属文案，
  /// 它们不会被展开成 Episode 或 VideoTrack。
  List<MediaEpisode> mediaLines(Map<String, dynamic> item) {
    final names = plainText(item['vod_play_from']).split(r'$$$');
    final blocks = plainText(item['vod_play_url']).split(r'$$$');
    final result = <MediaEpisode>[];
    for (var line = 0; line < blocks.length && line < 32; line++) {
      final entries = blocks[line].split('#');
      for (
        var episode = 0;
        episode < entries.length && episode < 10000;
        episode++
      ) {
        final entry = entries[episode];
        final split = entry.indexOf(r'$');
        if (split < 1) continue;
        final title = plainText(entry.substring(0, split));
        final value = entry.substring(split + 1).trim();
        if (title.isEmpty) continue;
        final uri = Uri.tryParse(value);
        if (uri == null || isPublicMediaUrl(uri) != null) continue;
        final match = _extension.firstMatch(uri.path);
        if (match == null) continue;
        result.add((
          title: title,
          key: _episodeKey(title),
          url: uri,
          format: match.group(1)!.toLowerCase() == 'm3u8'
              ? VideoFormat.hls
              : VideoFormat.mp4,
          line: line,
          lineName: plainText(names.elementAtOrNull(line)),
          episode: episode,
        ));
      }
    }
    return result;
  }

  Future<({String seriesId, String vodId, Map<String, dynamic> item})>
  _loadDetail(String seriesId) async {
    final parsed = _parseId(seriesId);
    assertEnabled();
    final data = await request({'ids': parsed.vodId});
    final list = data['list'] as List;
    if (list.length != 1 ||
        list.first is! Map ||
        plainText((list.first as Map)['vod_id']) != parsed.vodId) {
      throw SourceUnavailable(id, '自定义源返回的剧集与请求不一致');
    }
    return (
      seriesId: parsed.seriesId,
      vodId: parsed.vodId,
      item: Map<String, dynamic>.from(list.first as Map),
    );
  }

  List<Episode> _episodes(
    Map<String, dynamic> item,
    String seriesId, {
    required bool locked,
  }) {
    final all = mediaLines(item);
    final playable = all.where((e) => e.format == VideoFormat.mp4).toList();
    if (playable.isEmpty) {
      throw SourceUnavailable(
        id,
        all.isEmpty ? '该剧没有可直接播放的分集，不支持网页解析' : _hlsMessage,
      );
    }
    final byLine = <int, List<MediaEpisode>>{};
    for (final entry in playable) {
      byLine.putIfAbsent(entry.line, () => <MediaEpisode>[]).add(entry);
    }
    // 与参考一致：只展开集数最多的那一条 mp4 线路。
    final best = byLine.values.reduce((a, b) => a.length >= b.length ? a : b);
    final seen = <String>{};
    final episodes = <Episode>[];
    for (final entry in best) {
      if (!seen.add(entry.key)) continue;
      episodes.add(
        Episode(
          vid: '$seriesId:${entry.line}:${entry.episode}',
          index: episodes.length + 1,
          title: entry.title,
          locked: locked,
        ),
      );
    }
    return episodes;
  }

  // ── 小工具 ──────────────────────────────────────────────────────

  ({String uuid, String vodId, String seriesId, int line, int episode})
  _parseId(String value, {bool episode = false}) {
    final parts = plainText(value).split(':');
    final valid =
        parts.length == (episode ? 5 : 3) &&
        parts[0] == 'custom' &&
        _uuidV4.hasMatch(parts[1]) &&
        parts[1].toLowerCase() == uuid &&
        _digits.hasMatch(parts[2]) &&
        (!episode || parts.skip(3).every(_smallDigits.hasMatch));
    if (!valid) throw SourceRejected(id, '自定义剧集编号无效');
    return (
      uuid: parts[1].toLowerCase(),
      vodId: parts[2],
      seriesId: 'custom:${parts[1].toLowerCase()}:${parts[2]}',
      line: parts.length > 3 ? int.parse(parts[3]) : 0,
      episode: parts.length > 4 ? int.parse(parts[4]) : 0,
    );
  }

  static int _page(String? cursor) {
    if (cursor == null || cursor.trim().isEmpty) return 1;
    final page = int.tryParse(cursor.trim());
    if (page == null || page < 1 || page > 100000) {
      throw const SourceRejected('custom:', '自定义源分类或页码无效');
    }
    return page;
  }

  static String _episodeKey(String title) {
    final match = _episodeNumber.firstMatch(title);
    return match == null ? title : 'number:${int.parse(match.group(1)!)}';
  }

  /// 封面只收公网明文 HTTPS：私网/凭据/降级 IP 一律视为空串。
  static String _httpsUrl(dynamic value) {
    if (value == null) return '';
    final uri = Uri.tryParse('$value');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        isPublicMediaUrl(uri) != null) {
      return '';
    }
    return uri.toString();
  }

  static String plainText(dynamic value) =>
      value == null ? '' : '$value'.replaceAll(RegExp(r'<[^>]*>'), '').trim();

  static int? _intOf(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// 单条可播分集的解析结果。[line]/[episode] 为线路内 0 起下标，
/// 与视频 ID 的第 4/5 段一致（参考 parseId 的 Number 语义）。
typedef MediaEpisode = ({
  String title,
  String key,
  Uri url,
  VideoFormat format,
  int line,
  String lineName,
  int episode,
});

/// 按 uuid 管理在途请求：配置变更时只撤销该源的令牌，
/// 由适配器注入共享实例（跨重建成的新适配器仍可取消旧请求）。
class CancelTokenRegistry {
  final Map<String, Set<CancelToken>> _tokens = {};

  void register(String uuid, CancelToken token) =>
      _tokens.putIfAbsent(uuid, () => <CancelToken>{}).add(token);

  void unregister(String uuid, CancelToken token) {
    final active = _tokens[uuid];
    if (active == null) return;
    active.remove(token);
    if (active.isEmpty) _tokens.remove(uuid);
  }

  void cancel(String uuid) {
    final active = _tokens[uuid];
    if (active == null) return;
    for (final token in List<CancelToken>.of(active)) {
      if (!token.isCancelled) token.cancel('custom source config changed');
    }
  }

  int get inFlightCount =>
      _tokens.values.fold(0, (sum, set) => sum + set.length);
}
