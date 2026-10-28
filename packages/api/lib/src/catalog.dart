import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'video_model_client.dart';
import 'network_retry.dart';
import 'request_control.dart';

String _text(dynamic value) => value == null ? '' : '$value';
int _int(dynamic value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;
Map<String, dynamic> _map(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<dynamic> _list(dynamic value) => value is List ? value : [];
String _clean(String value) => value.replaceAll(RegExp(r'<[^>]*>'), '').trim();
String _first(Iterable<dynamic> values) =>
    values.map(_text).where((s) => s.isNotEmpty).firstOrNull ?? '';

/// Upstream genre names live in `category_schema` — a stringified JSON array of
/// `{"name": …}` entries present on both browse rows and `video_detail`
/// (references/hongguo-web/server/src/service/client.js:324,1058) — with the
/// single `tag_info.text` as fallback. `cover_tag_info_list` is deliberately
/// ignored: it is cover badge copy (爆剧/新剧/独播, client.js:336-348) and can
/// never equal a theme-panel name, so matching on it would label the 同题材
/// block a lie. Missing or malformed everywhere yields an empty list.
List<String> _tagNames(List<Map<String, dynamic>> sources) {
  for (final source in sources) {
    final names = <String>[];
    void add(dynamic value) {
      final name = _clean(_text(value));
      if (name.isNotEmpty && !names.contains(name)) names.add(name);
    }

    final schema = source['category_schema'];
    if (schema is String) {
      for (final match in RegExp(
        '"name"\\s*:\\s*"([^"]+)"',
      ).allMatches(schema)) {
        add(match.group(1));
      }
    } else if (schema is List) {
      for (final entry in schema) {
        if (entry is Map) add(entry['name']);
      }
    }
    if (names.isEmpty) {
      final tag = source['tag_info'];
      if (tag is Map) {
        add(tag['text']);
      } else {
        add(tag);
      }
    }
    if (names.isNotEmpty) return List.unmodifiable(names);
  }
  return const [];
}

/// A fresh anonymous device identity, for first launch and for the settings
/// rotation. The catalog reports this number on list and detail requests; the
/// player never sees it -- it asks the platform to register its own identity
/// instead (see PlaybackDeviceRegistry), and the two are deliberately unrelated.
String newCatalogDeviceId() {
  var value = BigInt.zero;
  for (final byte in secureBytes(6)) {
    value = (value << 8) | BigInt.from(byte);
  }
  return '${BigInt.parse('1000000000000000') + value}';
}

String _requestUuid() {
  final bytes = secureBytes(16);
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final value = hex(bytes);
  return '${value.substring(0, 8)}-${value.substring(8, 12)}-${value.substring(12, 16)}-${value.substring(16, 20)}-${value.substring(20)}';
}

class Drama {
  final String id, title, cover, intro;
  final int episodeCount;
  final List<String> tagNames;
  const Drama({
    required this.id,
    required this.title,
    this.cover = '',
    this.intro = '',
    this.episodeCount = 0,
    this.tagNames = const [],
  });
  factory Drama.fromJson(Map<String, dynamic> value) {
    var raw = value['video_data'];
    if (raw is List) raw = raw.firstOrNull;
    final data = _map(raw).isNotEmpty ? _map(raw) : value;
    final detail = _map(data['video_detail']);
    return Drama(
      id: _first([
        data['series_id'],
        data['book_id'],
        value['book_id'],
        value['search_result_id'],
      ]),
      title: _clean(
        _first([
          data['series_title'],
          data['title'],
          detail['series_title'],
          value['name'],
        ]),
      ),
      cover: _first([
        data['series_cover'],
        data['cover'],
        detail['series_cover'],
      ]),
      intro: _clean(
        _first([
          data['series_intro'],
          data['video_desc'],
          detail['series_intro'],
        ]),
      ),
      episodeCount: _int(data['episode_cnt'] ?? detail['episode_cnt']),
      tagNames: _tagNames([data, detail]),
    );
  }
}

class Episode {
  final String vid, title;
  final int index;
  const Episode({required this.vid, required this.index, this.title = ''});
}

class DramaDetail {
  final Drama drama;
  final List<Episode> episodes;
  const DramaDetail(this.drama, this.episodes);
}

class CatalogPage {
  final List<Drama> items;
  final String? nextCursor;
  const CatalogPage(this.items, {this.nextCursor});
}

class CatalogFilter {
  final String name, id;
  const CatalogFilter(this.name, this.id);
}

abstract interface class CatalogRepository {
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  });
  Future<CatalogPage> search(String query, {String? cursor});
  Future<DramaDetail> detail(String id);
  Future<List<CatalogFilter>> themes(String genre);
}

abstract interface class RankCatalogRepository implements CatalogRepository {
  Future<CatalogPage> rank({String board = 'recommend', String? cursor});
}

class CatalogError implements Exception {
  final String message;
  const CatalogError(this.message);
  @override
  String toString() => message;
}

class CatalogClient implements CatalogRepository, RankCatalogRepository {
  final NetworkRetry retry;
  final int browsePageSize;
  late final CatalogRequests _requests;
  final _themeCache =
      <String, ({DateTime expires, List<CatalogFilter> value})>{};
  final DateTime Function() now;
  final Dio dio;
  final String deviceId;
  final PureSign signer;
  final Map<String, String> sessionHeaders;
  final bool signLists;
  bool _listSignatureRequired = false;
  final AppSettings protocol;
  final _requestClock = Stopwatch()..start();
  Duration _lastRequest = const Duration(milliseconds: -260);
  Future<void> _queue = Future.value();
  final _details = <String, ({DateTime expires, DramaDetail value})>{};
  CatalogClient({
    this.browsePageSize = 18,
    Duration requestDeadline = const Duration(seconds: 12),
    DateTime Function()? now,
    void Function(MetadataTiming)? onTiming,
    NetworkRetry? retry,
    required this.dio,
    required this.deviceId,
    PureSign? signer,
    this.sessionHeaders = const {},
    this.signLists = true,
    this.protocol = const AppSettings(),
  }) : now = now ?? DateTime.now,
       retry = retry ?? NetworkRetry(),
       signer = signer ?? PureSign() {
    protocol.validate();
    _requests = CatalogRequests(deadline: requestDeadline, onTiming: onTiming);
    if (browsePageSize < 1 || browsePageSize > 50) {
      throw ArgumentError('Browse page size must be 1–50');
    }
    if (!RegExp(r'^\d{10,20}$').hasMatch(deviceId)) {
      throw ArgumentError('Invalid device identity');
    }
  }
  void close() => _requests.cancelAll();

  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) {
    final ids = List<String>.of(seen);
    return _requests.run(
      jsonEncode(['browse', genre, sort, theme, cursor, ids]),
      () => _browse(
        genre: genre,
        sort: sort,
        theme: theme,
        cursor: cursor,
        seen: ids,
      ),
      label: 'catalog.browse',
    );
  }

  @override
  Future<CatalogPage> rank({String board = 'recommend', String? cursor}) =>
      _requests.run(
        jsonEncode(['rank', board, cursor]),
        () => _rank(board: board, cursor: cursor),
        label: 'catalog.rank',
      );
  @override
  Future<CatalogPage> search(String query, {String? cursor}) => _requests.run(
    jsonEncode(['search', query.trim(), cursor]),
    () => _search(query, cursor: cursor),
    label: 'catalog.search',
  );
  @override
  Future<DramaDetail> detail(String id) =>
      _requests.run('detail:$id', () => _detail(id), label: 'catalog.detail');
  @override
  Future<List<CatalogFilter>> themes(String genre) =>
      _requests.run('themes:$genre', () async {
        final cached = _themeCache[genre];
        if (cached != null && cached.expires.isAfter(now())) {
          RequestBudget.current.cacheHit = true;
          return cached.value;
        }
        final values = List<CatalogFilter>.unmodifiable(await _themes(genre));
        _themeCache[genre] = (
          expires: now().add(const Duration(hours: 6)),
          value: values,
        );
        return values;
      }, label: 'catalog.themes');

  Duration _timeout(int seconds) {
    final configured = Duration(
      seconds: protocol.timeoutSeconds < seconds
          ? protocol.timeoutSeconds
          : seconds,
    );
    return RequestBudget.current.timeout(configured);
  }

  Future<Map<String, dynamic>> _api(
    String path, {
    Map<String, dynamic>? body,
    Map<String, String> query = const {},
    bool signed = true,
  }) {
    final budget = RequestBudget.current;
    return retry.run(() async {
      // Serialize request starts only: a slow request must not block other genres.
      final slot = _queue.then((_) async {
        budget.check();
        final wait =
            const Duration(milliseconds: 260) -
            (_requestClock.elapsed - _lastRequest);
        if (wait > Duration.zero) {
          await budget.guard(Future<void>.delayed(wait));
        }
        budget.check();
        _lastRequest = _requestClock.elapsed;
      });
      _queue = slot.catchError((Object _) {});
      await budget.measure('queue', () => slot);
      final signingClock = Stopwatch()..start();
      final effectiveSigned = signed || _listSignatureRequired;
      final bytes = body == null
          ? null
          : Uint8List.fromList(utf8.encode(jsonEncode(body)));
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final now = DateTime.now().millisecondsSinceEpoch;
      String url = '';
      for (var attempt = 0; attempt < 32; attempt++) {
        final params = {
          'aid': '8662',
          'app_name': 'novelread',
          'version_code': protocol.catalogVersionCode,
          'version_name': protocol.catalogVersion,
          'channel': 'audit',
          'device_platform': 'android',
          'device_type': 'audit-windows',
          'os_version': '12',
          'update_version_code': protocol.catalogVersionCode,
          'device_id': deviceId,
          ...query,
          '_rticket': '${now + attempt}',
        };
        url =
            'https://${protocol.apiHost}$path?${params.entries.map((e) => '${encodeQueryPart(e.key)}=${encodeQueryPart(e.value)}').join('&')}';
        if (!effectiveSigned || signer.branchOf(url, bytes, ts) != 1) break;
      }
      if (effectiveSigned && signer.branchOf(url, bytes, ts) == 1) {
        throw const CatalogError('签名暂时无法生成，请重试');
      }
      final signature = effectiveSigned
          ? signer.sign(url, bytes, ts)
          : <String, String>{};
      budget.record('sign', signingClock.elapsed);
      final response = await budget.transport(
        () => dio.fetch<String>(
          Options(
                method: bytes == null ? 'GET' : 'POST',
                followRedirects: false,
                responseType: ResponseType.plain,
                receiveTimeout: _timeout(8),
                sendTimeout: _timeout(5),
                headers: {
                  'user-agent': 'hongguo-web/1.0',
                  'x-tt-store-region': 'cn-sh',
                  'x-tt-store-region-src': 'uid',
                  'passport-sdk-version': '5051452',
                  'sdk-version': '2',
                  ...sessionHeaders,
                  if (bytes != null) ...{
                    'content-type': 'application/json; charset=utf-8',
                    'content-length': '${bytes.length}',
                    'x-ss-stub': hex(md5(bytes)).toUpperCase(),
                  },
                  ...signature,
                },
              )
              .compose(
                dio.options,
                url,
                cancelToken: budget.token,
                data: bytes == null ? null : Stream<Uint8List>.value(bytes),
              )
              .copyWith(connectTimeout: _timeout(5)),
        ),
      );
      if (response.statusCode != 200) {
        throw CatalogError('内容接口 HTTP ${response.statusCode}');
      }
      final text = response.data ?? '';
      if (text.trim().isEmpty) {
        // Some upstream list endpoints changed from unsigned responses to
        // HTTP 200 + empty body. Upgrade only this client's request policy;
        // do not rotate identity or manufacture/refresh account credentials.
        if (!effectiveSigned) _listSignatureRequired = true;
        throw const IncompleteCatalogResponse('内容接口未返回数据，请稍后重试');
      }
      final data = _map(jsonDecode(text));
      final code = data['code'] ?? data['Code'] ?? data['status_code'];
      if (code != null && _int(code) != 0) {
        throw CatalogError(
          '内容接口返回 $code：${_first([data['message'], data['msg'], '暂时不可用'])}',
        );
      }
      if (body?['need_selector_panel'] == true &&
          _map(data['data'])['selector_rows'] is! List) {
        throw const IncompleteCatalogResponse('题材响应不完整，请重试');
      }
      if (body?['req_type'] == 'only_content' &&
          _map(data['data'])['video_data'] is! List) {
        throw const IncompleteCatalogResponse('影视列表响应不完整，请重试');
      }
      return data;
    }, budget: budget);
  }

  static void _genre(String genre) {
    if (!['short_play', 'comic_series', 'ai_series'].contains(genre)) {
      throw ArgumentError('Invalid genre');
    }
  }

  static Map<String, dynamic> _selection(
    String genre,
    String sort,
    String? theme,
  ) => {
    'category_dim_epoch': [],
    'online_time': [],
    'gender': [],
    'category_dim_role': [],
    'genre': [genre],
    'sort': [sort],
    'category_dim_theme': theme == null ? [] : [theme],
  };
  Future<CatalogPage> _browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) async {
    _genre(genre);
    if (!['online_time', 'hot_score', 'hot_collect'].contains(sort)) {
      throw ArgumentError('Invalid sort');
    }
    final offset = int.tryParse(cursor ?? '0') ?? 0;
    final j = await _api(
      '/reading/distribution/category/landpage/v',
      signed: signLists,
      body: {
        'filter_ids': seen.join(','),
        'req_scene': genre == 'short_play' ? 'default' : genre,
        'offset': offset,
        'need_selector_panel': false,
        'limit': browsePageSize,
        'select_items': _selection(genre, sort, theme),
        'session_id': '',
        'req_type': 'only_content',
        'client_req_type': 3,
      },
    );
    final data = _map(j['data']), raw = _list(data['video_data']);
    final items = raw
        .map((v) => Drama.fromJson(_map(v)))
        .where((v) => v.id.isNotEmpty && !seen.contains(v.id))
        .toList();
    final more =
        data['has_more'] == true ||
        data['has_more'] == 1 ||
        (data['has_more'] == null && raw.length >= browsePageSize);
    final next = _int(data['next_offset'] ?? data['offset']);
    return CatalogPage(
      _unique(items),
      nextCursor:
          more &&
              raw.isNotEmpty &&
              (data['next_offset'] == null || next > offset)
          ? '${next > offset ? next : offset + raw.length}'
          : null,
    );
  }

  Future<List<CatalogFilter>> _themes(String genre) async {
    _genre(genre);
    final j = await _api(
      '/reading/distribution/category/landpage/v',
      signed: signLists,
      body: {
        'filter_ids': '',
        'req_scene': genre == 'short_play' ? 'default' : genre,
        'offset': 0,
        'limit': 1,
        'need_selector_panel': true,
        'req_type': 'default',
        'client_req_type': 3,
        'select_items': _selection(genre, 'online_time', null),
        'session_id': '',
      },
    );
    final rows = _list(_map(j['data'])['selector_rows']);
    for (final value in rows) {
      final row = _map(value);
      if (_text(row['type']).contains('theme') ||
          _text(row['row_name']).contains('主题')) {
        return _list(row['items'])
            .map(
              (v) => CatalogFilter(
                _text(_map(v)['show_name']),
                _text(_map(v)['selector_item_id']),
              ),
            )
            .where((f) => f.id.isNotEmpty && f.name.isNotEmpty)
            .toList();
      }
    }
    return [];
  }

  Future<CatalogPage> _rank({
    String board = 'recommend',
    String? cursor,
  }) async {
    const boards = {
      'recommend': 'comic_series_hot_rank',
      'hot': 'comic_series_hot_play',
      'new': 'comic_series_new_rank',
    };
    if (!boards.containsKey(board)) throw ArgumentError('Invalid rank board');
    final offset = int.tryParse(cursor ?? '0') ?? 0;
    final j = await _api(
      '/reading/bookapi/bookmall/cell/change/v',
      signed: signLists,
      query: {
        'cell_id': '7470092475068071998',
        'tab_type': '26',
        'client_req_type': '2',
        'client_template': '2',
        'screen_width_px': '1350',
        'selected_items': 'comic_series_rank',
        'sub_selected_items': boards[board]!,
        'session_uuid': _requestUuid(),
        if (offset > 0) 'offset': '$offset',
      },
    );
    final view = _map(_map(j['data'])['cell_view']),
        raw = _list(view['cell_data']);
    final items = _unique(
      raw
          .map((v) => Drama.fromJson(_map(v)))
          .where((d) => d.id.isNotEmpty)
          .toList(),
    );
    final more = view['has_more'] == true || view['has_more'] == 1;
    final next = _int(view['next_offset'] ?? view['offset']);
    return CatalogPage(
      items,
      nextCursor:
          more &&
              raw.isNotEmpty &&
              (view['next_offset'] == null || next > offset)
          ? '${next > offset ? next : offset + raw.length}'
          : null,
    );
  }

  Future<CatalogPage> _search(String query, {String? cursor}) async {
    query = query.trim();
    if (query.isEmpty) return const CatalogPage([]);
    if (cursor == null) {
      try {
        final html = await RequestBudget.current.phase(
          const Duration(seconds: 6),
          () => _html(
            'https://hongguoduanju.com/search/${encodeQueryPart(query)}',
          ),
        );
        final web = parseWebSearch(html);
        if (web.isNotEmpty) return CatalogPage(web);
      } on Object {
        /* App source fallback is surfaced if it also fails. */
      }
    }
    final state = cursor == null
        ? <String, dynamic>{}
        : _map(
            jsonDecode(
              utf8.decode(base64Url.decode(base64Url.normalize(cursor))),
            ),
          );
    final j = await _api(
      '/reading/bookapi/search/tab/v',
      query: {
        'query': query,
        'tab_name': 'feed',
        'search_source': '1',
        'offset': _text(state['offset'] ?? 0),
        'count': '10',
        'use_correct': 'true',
        if (state['passback'] != null) 'passback': _text(state['passback']),
        if (state['search_id'] != null) 'search_id': _text(state['search_id']),
      },
    );
    final tabs = _list(j['search_tabs']);
    if (tabs.isEmpty) return const CatalogPage([]);
    final tab = _map(tabs.first), raw = _list(tab['data']);
    final items = raw
        .map((v) => Drama.fromJson(_map(v)))
        .where((v) => v.id.isNotEmpty && v.episodeCount > 0)
        .toList();
    final next = _int(tab['next_offset']);
    final more =
        (tab['has_more'] == true || tab['has_more'] == 1) &&
        raw.isNotEmpty &&
        next > _int(state['offset']);
    return CatalogPage(
      _unique(items),
      nextCursor: more
          ? base64Url.encode(
              utf8.encode(
                jsonEncode({
                  'offset': next,
                  'passback': tab['passback'],
                  'search_id': tab['search_id'],
                }),
              ),
            )
          : null,
    );
  }

  Future<DramaDetail> _detail(String id) async {
    if (!RegExp(r'^\d{1,30}$').hasMatch(id)) {
      throw ArgumentError('Invalid series ID');
    }
    final cached = _details[id];
    if (cached != null && cached.expires.isAfter(now())) {
      RequestBudget.current.cacheHit = true;
      return cached.value;
    }
    DramaDetail? result;
    Object? firstError;
    try {
      final j = await RequestBudget.current.phase(
        const Duration(seconds: 7),
        () => _api(
          '/novel/player/multi_video_detail/preload/v1',
          body: {
            'series_id': id,
            'dr_scene': 'preload',
            'biz_param': {
              'detail_page_version': 0,
              'disable_digg_stat': false,
              'image_shrink_datas_str': 'W3siaW1hZ2VfdHlwZSI6MywiaW1hZ2Vfd2lkdGgiOjkwMCwic2hyaW5rX3R5cGUiOjN9LHsiaW1hZ2VfdHlwZSI6NCwiaW1hZ2Vfd2lkdGgiOjU0LCJzaHJpbmtfdHlwZSI6NH1d',
              'need_all_video_definition': false,
              'need_mp4_align': false,
              'screen_width_px': '900',
              'source': 7,
              'use_os_player': false,
              'use_server_dns': false,
            },
          },
        ),
      );
      final data = _map(_map(_map(j['data'])[id])['video_data']);
      final episodes =
          _list(data['video_list'])
              .map((v) {
                final e = _map(v);
                return Episode(
                  vid: _text(e['vid']),
                  index: _int(e['vid_index']),
                  title: _clean(_text(e['title'])),
                );
              })
              .where((e) => e.vid.isNotEmpty && e.index > 0)
              .toList()
            ..sort((a, b) => a.index.compareTo(b.index));
      if (episodes.isEmpty) throw const CatalogError('没有可用分集');
      result = DramaDetail(
        Drama.fromJson({...data, 'series_id': id}),
        episodes,
      );
    } on Object catch (e) {
      firstError = e;
    }
    if (result == null) {
      RequestBudget.current.check();
      try {
        result = parseWebEpisodes(
          id,
          await _html('https://hongguoduanju.com/player/$id'),
        );
      } on Object {
        RequestBudget.current.check();
        throw firstError ?? const CatalogError('无法获取分集');
      }
    }
    if (_details.length >= 100) _details.remove(_details.keys.first);
    _details[id] = (
      expires: now().add(const Duration(hours: 6)),
      value: result,
    );
    return result;
  }

  Future<String> _html(String url) async {
    final budget = RequestBudget.current;
    final res = await retry.run(
      () => budget.transport(
        () => dio.fetch<String>(
          Options(
                responseType: ResponseType.plain,
                followRedirects: false,
                receiveTimeout: _timeout(8),
                sendTimeout: _timeout(5),
                headers: {
                  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/122.0.0.0 Safari/537.36',
                  'Accept': 'text/html',
                  'Accept-Language': 'zh-CN,zh;q=0.9',
                  'Referer': 'https://hongguoduanju.com/',
                },
              )
              .compose(dio.options, url, cancelToken: budget.token)
              .copyWith(connectTimeout: _timeout(5)),
        ),
      ),
      budget: budget,
    );
    if (res.statusCode != 200) throw CatalogError('官网 HTTP ${res.statusCode}');
    return res.data ?? '';
  }

  static List<Drama> _unique(List<Drama> values) {
    final ids = <String>{};
    return values.where((v) => ids.add(v.id)).toList();
  }

  static List<Drama> parseWebSearch(String html) {
    final start = html.indexOf('"searchList"');
    if (start < 0) return [];
    final array = html.indexOf('[', start);
    if (array < 0) return [];
    var depth = 0, inString = false, escape = false;
    for (var i = array; i < html.length; i++) {
      final ch = html[i];
      if (inString) {
        if (escape) {
          escape = false;
        } else if (ch == r'\') {
          escape = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
        continue;
      }
      if (ch == '[') depth++;
      if (ch == ']' && --depth == 0) {
        return _unique(
          _list(jsonDecode(html.substring(array, i + 1)))
              .map((v) => Drama.fromJson(_map(v)))
              .where((v) => v.id.isNotEmpty)
              .toList(),
        );
      }
    }
    return [];
  }

  static DramaDetail parseWebEpisodes(String id, String html) {
    final match = RegExp(r'"vid_list"\s*:\s*\[([^\]]*)\]').firstMatch(html);
    if (match == null) throw const CatalogError('官网没有分集信息');
    final vids = RegExp(r'\d+')
        .allMatches(match.group(1)!)
        .map((m) => m.group(0)!)
        .toList();
    if (vids.isEmpty) throw const CatalogError('官网分集列表为空');
    String field(String key) {
      final m = RegExp('"$key"\\s*:\\s*("(?:[^"\\\\]|\\\\.)*")')
          .firstMatch(html);
      return m == null ? '' : _text(jsonDecode(m.group(1)!));
    }

    return DramaDetail(
      Drama(
        id: id,
        title: field('series_name'),
        cover: field('series_cover'),
        episodeCount: vids.length,
      ),
      [
        for (var i = 0; i < vids.length; i++)
          Episode(vid: vids[i], index: i + 1),
      ],
    );
  }
}
