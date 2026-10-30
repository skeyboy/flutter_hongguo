import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'video_model_client.dart';
import 'network_retry.dart';
import 'ranking.dart';
import 'request_control.dart';

/// The `select_items` key of the 主题 row — the one dimension that pages inside
/// the discover pane rather than only narrowing the request.
const categoryThemeKey = 'category_dim_theme';

/// Every dimension the panel can publish, in the order `selector_rows` sends
/// them. Upstream publishes these per genre — 画风 and 状态 only exist for 漫剧 —
/// and the two newly named keys were simply never sent before. The drawer has
/// to know the whole list: naming「本次词表没给」means naming what a genre is
/// expected to publish, which only this table can say.
const catalogDimKeys = [
  categoryThemeKey,
  'category_dim_role',
  'category_dim_epoch',
  'category_dim_art_style',
  'creation_status',
  'gender',
  'online_time',
];

/// The upstream `row_name` each dimension is published under. The four captures
/// prove these labels; they do not prove that a row's `type` is spelled like the
/// `select_items` key, so both are consulted.
const catalogDimRowNames = {
  categoryThemeKey: '主题',
  'category_dim_role': '设定',
  'category_dim_epoch': '背景',
  'category_dim_art_style': '画风',
  'creation_status': '状态',
  'gender': '受众',
  'online_time': '时间',
};

/// The three sort values upstream accepts, in panel order.
const catalogSortKeys = ['online_time', 'hot_score', 'hot_collect'];

/// What each sort value is called in the 全部推荐 row the panel itself publishes
/// (all four captures send the same three, in this order). There is no 「推荐」
/// or 「追剧」档 — the app's old 推荐 chip is the *absence* of a choice, so it
/// folds back to whatever the viewer set in 设置 rather than posing as a fourth.
const catalogSortLabels = {
  'online_time': '最新上架',
  'hot_score': '最高热度',
  'hot_collect': '最高收藏',
};

/// Which dimensions each type published across the four live captures, in the
/// order the panel shows them. 画风 and 状态 are 漫剧's alone; the other two
/// types never sent them in any sample. The drawer needs this separately from
/// what a request actually returned: 「本次词表没给：画风」is only an honest
/// sentence about a type that is expected to have one.
const catalogDimKeysByGenre = <String, List<String>>{
  'short_play': [
    categoryThemeKey,
    'category_dim_role',
    'category_dim_epoch',
    'gender',
    'online_time',
  ],
  'comic_series': [
    categoryThemeKey,
    'category_dim_role',
    'category_dim_epoch',
    'gender',
    'creation_status',
    'online_time',
    'category_dim_art_style',
  ],
  'ai_series': [
    categoryThemeKey,
    'category_dim_role',
    'category_dim_epoch',
    'gender',
    'online_time',
  ],
};

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

/// One whole dimension of the upstream `selector_rows` panel: the row `type`
/// (which doubles as its `select_items` key), the upstream `row_name`, its
/// `selection_type`, and the published items. Keeping the row's own identity is
/// what lets the interface draw only what upstream actually sent — the panel
/// differs per genre (漫剧 publishes 画风 and 状态, 真人剧 does not) and differs
/// per request (four samples lost one to all three genres).
class CatalogDim {
  final String key, label;
  final int selectionType;
  final List<CatalogFilter> items;
  const CatalogDim({
    required this.key,
    required this.label,
    this.selectionType = 0,
    this.items = const [],
  });
}

/// A browse request with every dimension the user answered. `dims` maps an
/// upstream dimension key to the chosen `selector_item_id`s; a key that is
/// absent or empty sends an empty array, which is what upstream expects for
/// 「不限」.
class CatalogQuery {
  final String genre, sort;
  final Map<String, List<String>> dims;
  final String? cursor;
  final List<String> seen;
  const CatalogQuery({
    this.genre = 'short_play',
    this.sort = 'online_time',
    this.dims = const {},
    this.cursor,
    this.seen = const [],
  });
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

/// The dimensions beyond 主题, and a browse that can carry them. Separate from
/// `CatalogRepository` because the extra vocabulary is a capability, not a
/// requirement: a backend that only knows 题材 must keep compiling and keep
/// serving the two-row discover page. Callers gate on `is`, the way the rank
/// surface already does.
abstract interface class FilteredCatalogRepository
    implements CatalogRepository {
  Future<List<CatalogDim>> filterRows(String genre);
  Future<CatalogPage> browseFiltered(CatalogQuery query);
}

class CatalogError implements Exception {
  final String message;
  const CatalogError(this.message);
  @override
  String toString() => message;
}

class CatalogClient
    implements
        CatalogRepository,
        RankCatalogRepository,
        FilteredCatalogRepository {
  final NetworkRetry retry;
  final int browsePageSize;
  late final CatalogRequests _requests;

  /// The last vocabulary that came back with rows in it, per genre. Upstream
  /// sends selector rows per request, not per session — four samples in one
  /// minute lost one to all three genres — so an empty answer falls back to the
  /// previous good one instead of dropping a row the user can see.
  final _vocabulary = <String, ({DateTime expires, List<CatalogDim> value})>{};
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
  }) => browseFiltered(
    CatalogQuery(
      genre: genre,
      sort: sort,
      dims: theme == null
          ? const {}
          : {
              categoryThemeKey: [theme],
            },
      cursor: cursor,
      seen: seen,
    ),
  );

  @override
  Future<CatalogPage> browseFiltered(CatalogQuery query) async {
    for (final key in query.dims.keys) {
      if (!catalogDimKeys.contains(key)) {
        throw ArgumentError.value(key, 'dims', '上游没有发布这一维');
      }
    }
    final ids = List<String>.of(query.seen);
    final sortedDims = {
      for (final key in catalogDimKeys)
        if (query.dims[key] != null) key: List<String>.of(query.dims[key]!),
    };
    return _requests.run(
      jsonEncode([
        'browse',
        query.genre,
        query.sort,
        sortedDims,
        query.cursor,
        ids,
      ]),
      () => _browse(query: query, dims: sortedDims, seen: ids),
      label: 'catalog.browse',
    );
  }

  @override
  Future<RankPage> rankBoard({
    String track = rankSeedTrack,
    String? board,
    String? cursor,
  }) => _requests.run(
    jsonEncode(['rank', track, board, cursor]),
    () => _rankBoard(track: track, board: board, cursor: cursor),
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
  Future<List<CatalogFilter>> themes(String genre) async =>
      _themeDim(await _vocabularyFor(genre)).items;
  @override
  Future<List<CatalogDim>> filterRows(String genre) => _vocabularyFor(genre);

  /// One request serves both layers. A failed request still surfaces as an
  /// error — the page has to be able to offer 现在重试 — but an answer that came
  /// back with no rows in it falls back to the last real panel, because upstream
  /// sends the selector panel per request and the same genre measured nine
  /// dimensions in one sample and none in the next.
  Future<List<CatalogDim>> _vocabularyFor(String genre) =>
      _requests.run('themes:$genre', () async {
        final cached = _vocabulary[genre];
        if (cached != null && cached.expires.isAfter(now())) {
          RequestBudget.current.cacheHit = true;
          return cached.value;
        }
        final rows = await _filterRows(genre);
        if (rows.isEmpty) return cached?.value ?? const [];
        final values = List<CatalogDim>.unmodifiable(rows);
        _vocabulary[genre] = (
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

  /// Which `select_items` key a panel row answers for. A row that matches
  /// neither its `type` nor its `row_name` is dropped: the drawer may only
  /// offer a dimension the request body can actually carry.
  static String? _dimKeyOf(Map<String, dynamic> row) {
    final type = _text(row['type']);
    for (final key in catalogDimKeys) {
      if (type == key) return key;
    }
    if (type.isNotEmpty) {
      for (final key in catalogDimKeys) {
        if (type.contains(key)) return key;
      }
    }
    final name = _text(row['row_name']);
    for (final entry in catalogDimRowNames.entries) {
      if (name.contains(entry.value)) return entry.key;
    }
    return null;
  }

  static Map<String, dynamic> _selection(
    String genre,
    String sort,
    Map<String, List<String>> dims,
  ) => {
    for (final key in catalogDimKeys) key: dims[key] ?? const [],
    'genre': [genre],
    'sort': [sort],
  };
  Future<CatalogPage> _browse({
    required CatalogQuery query,
    Map<String, List<String>> dims = const {},
    List<String> seen = const [],
  }) async {
    final genre = query.genre, sort = query.sort, cursor = query.cursor;
    _genre(genre);
    if (!catalogSortKeys.contains(sort)) {
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
        'select_items': _selection(genre, sort, dims),
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

  /// `selector_rows` → every dimension upstream sent for this genre. Rows
  /// without a `type` or without any items are dropped rather than padded, so
  /// 「上游这次没给」and「这一维是空的」both simply do not appear.
  Future<List<CatalogDim>> _filterRows(String genre) async {
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
        'select_items': _selection(genre, 'online_time', const {}),
        'session_id': '',
      },
    );
    final rows = _list(_map(j['data'])['selector_rows']);
    final dims = <CatalogDim>[];
    for (final value in rows) {
      final row = _map(value);
      final key = _dimKeyOf(row);
      if (key == null) continue;
      final items = _list(row['items'])
          .map(
            (v) => CatalogFilter(
              _text(_map(v)['show_name']),
              _text(_map(v)['selector_item_id']),
            ),
          )
          .where((f) => f.id.isNotEmpty && f.name.isNotEmpty)
          .toList();
      if (items.isEmpty) continue;
      dims.add(
        CatalogDim(
          key: key,
          label: _text(row['row_name']),
          selectionType: _int(row['selection_type']),
          items: List.unmodifiable(items),
        ),
      );
    }
    return dims;
  }

  /// The theme row, by its request key first and by upstream's own naming
  /// second — the same row the old two-row interface only ever returned.
  static CatalogDim _themeDim(List<CatalogDim> rows) {
    for (final row in rows) {
      if (row.key == categoryThemeKey) return row;
    }
    for (final row in rows) {
      if (row.key.contains('theme') || row.label.contains('主题')) return row;
    }
    return const CatalogDim(key: categoryThemeKey, label: '全部主题');
  }

  Future<RankPage> _rankBoard({
    String track = rankSeedTrack,
    String? board,
    String? cursor,
  }) async {
    validateSelectorId(track, 'track');
    if (board != null) validateSelectorId(board, 'board');
    final offset = int.tryParse(cursor ?? '0') ?? 0;
    final j = await _api(
      '/reading/bookapi/bookmall/cell/change/v',
      signed: signLists,
      query: {
        'cell_id': rankCellId,
        'tab_type': '26',
        'client_req_type': '2',
        'client_template': '2',
        'screen_width_px': '1350',
        'selected_items': track,
        'sub_selected_items': ?board,
        'session_uuid': _requestUuid(),
        if (offset > 0) 'offset': '$offset',
      },
    );
    final data = _map(j['data']),
        view = _map(data['cell_view']),
        raw = _list(view['cell_data']);
    final entries = <RankEntry>[];
    final ids = <String>{};
    var unrecognized = 0;
    for (final value in raw) {
      final entry = parseRankCard(_map(value), entries.length + 1);
      if (entry.drama.id.isEmpty) {
        unrecognized++;
        continue;
      }
      if (!ids.add(entry.drama.id)) continue;
      entries.add(entry);
    }
    final more = view['has_more'] == true || view['has_more'] == 1;
    final next = _int(view['next_offset'] ?? view['offset']);
    return RankPage(
      entries: entries,
      unrecognizedCards: unrecognized,
      nextCursor:
          more &&
              raw.isNotEmpty &&
              (view['next_offset'] == null || next > offset)
          ? '${next > offset ? next : offset + raw.length}'
          : null,
      updatedAt: parseRankVersion(data['rank_version']),
      tracks: parseRankTracks(_map(view['cell_selector'])),
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
