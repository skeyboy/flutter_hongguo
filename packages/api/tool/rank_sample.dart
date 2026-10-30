// Read-only live sample for the discover-filter and ranking design
// (docs/design/discover-filters-and-ranking.md §8.2/§8.3).
// Extracts only the catalog's own vocabulary -- filter row and item names,
// leaderboard entry fields, scalar shape keys -- never URLs, request or
// response headers, signed parameters, media keys, account data or whole
// response bodies. Run explicitly, never in CI.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';

const _shortMax = 40;

Map<String, dynamic> _map(Object? value) =>
    value is Map ? value.map((k, v) => MapEntry('$k', v)) : const {};
List<dynamic> _list(Object? value) => value is List ? value : const [];

/// A scalar-only view of a JSON subtree: lists collapse to their length and the
/// shape of their first element, maps to their key set, scalars to their value
/// when short. Cover/URL-shaped keys are dropped by `_isSensitive`; the only
/// ids kept are content ids, which the design needs in order to say which
/// dimension maps to which request parameter.
Object? shape(Object? value, {int depth = 0}) {
  if (value is Map<String, dynamic>) {
    if (depth >= 3) {
      return {r'$keys': value.keys.where((k) => !_isSensitive(k)).toList()};
    }
    final out = <String, Object?>{};
    for (final entry in value.entries) {
      if (_isSensitive(entry.key)) continue;
      out[entry.key] = shape(entry.value, depth: depth + 1);
    }
    return out;
  }
  if (value is List) {
    return {
      r'$length': value.length,
      if (value.isNotEmpty) r'$first': shape(value.first, depth: depth + 1),
    };
  }
  if (value is String) {
    return value.length <= _shortMax ? value : '<string:${value.length}>';
  }
  if (value is Map || value is List) return '<container>';
  return value;
}

/// CDN locators: never written. Content ids are a different thing -- they are
/// already published in `docs/evidence/related-dramas/live-sample.json`, and
/// the design needs them to say which dimension maps to which request.
bool _isSensitive(String key) {
  const blocked = [
    'url',
    'uri',
    'src',
    'cover',
    'icon',
    'img',
    'image',
    'domain',
    'host',
    'token',
    'cookie',
    'sign',
    'signature',
    'x-argus',
    'phone',
    'mobile',
    'email',
    'sec_user',
    'device',
    'user_id',
  ];
  final lower = key.toLowerCase();
  return blocked.any(lower.contains);
}

/// Which keys could carry a leaderboard score, a movement or a reason.
bool _isRankSignal(String key) {
  const hints = [
    'hot',
    'heat',
    'score',
    'rank',
    'mark',
    'count',
    'cnt',
    'num',
    'value',
    'trend',
    'rise',
    'reason',
    'label',
    'tag',
    'period',
    'day',
    'week',
    'month',
    'time',
    'update',
  ];
  final lower = key.toLowerCase();
  return hints.any(lower.contains);
}

Map<String, Object?> keyInventory(Map<String, dynamic> entry) {
  final scalars = <String, Object?>{};
  final signals = <String, Object?>{};
  final nested = <String, String>{};
  for (final field in entry.entries) {
    final key = field.key;
    if (_isSensitive(key)) continue;
    final value = field.value;
    if (value is Map || value is List) {
      nested[key] = value is Map
          ? 'map(${value.length})'
          : 'list(${value.length})';
    } else if (value is String) {
      final short = value.length <= _shortMax
          ? value
          : '<string:${value.length}>';
      scalars[key] = short;
      if (_isRankSignal(key)) signals[key] = short;
    } else if (value != null) {
      scalars[key] = value;
      if (_isRankSignal(key)) signals[key] = value;
    }
  }
  return {
    'keys': entry.keys.toList(),
    'scalars': scalars,
    'rankSignals': signals,
    'nested': nested,
  };
}

/// The two endpoints expose their tab and filter vocabulary through the same
/// row/item shape, so both are read through this one extractor. `sub_cell_selector`
/// is followed one level, which is where a leaderboard would publish its
/// period or sub-track tabs if it had any.
Map<String, Object?>? _selectorRow(Object? raw) {
  final row = _map(raw);
  if (row.isEmpty) return null;
  return {
    'row_name': row['row_name'],
    'type': row['type'],
    'selection_type': row['selection_type'],
    'row_keys': row.keys.toList(),
    'item_count': _list(row['items']).length,
    'item_keys_sample': _map(
      _list(row['items']).isEmpty ? null : _list(row['items']).first,
    ).keys.toList(),
    'items': [for (final item in _list(row['items'])) _selectorItem(item)],
  };
}

Map<String, Object?> _selectorItem(Object? raw) {
  final value = _map(raw);
  final sub = _selector(value['sub_cell_selector']);
  return {
    'show_name': value['show_name'],
    'selector_item_id': value['selector_item_id'],
    'is_selected': value['is_selected'],
    'selector_item_type': value['selector_item_type'],
    'sub_cell_selector': ?sub,
  };
}

Map<String, Object?>? _selector(Object? raw) {
  final map = _map(raw);
  if (map.isEmpty) return null;
  final inner = <Map<String, Object?>>[];
  for (final row in _list(map['inner_rows'])) {
    final parsed = _selectorRow(row);
    if (parsed != null) inner.add(parsed);
  }
  return {
    'outer_row': _selectorRow(map['outer_row']),
    'inner_rows': inner,
    'inner_title': map['inner_title'],
    'show_style': map['show_style'],
    'selector_display_style': map['selector_display_style'],
    'no_collapse_arrow': map['no_collapse_arrow'],
  };
}

/// Fields a leaderboard card could be built from, read off the video object
/// inside each cell entry. Account-facing comment bodies are reduced to a count.
const _videoProbeKeys = [
  'series_id',
  'title',
  'play_cnt',
  'score',
  'episode_cnt',
  'duration',
  'content_type',
  'recommend_info',
  'recommend_group_id',
  'rec_text_item',
  'recommend_reason_list',
  'secondary_info_list',
  'tag_info',
  'category_schema',
  'color_dominate',
  'sub_title',
  'sub_title_list',
  'book_exist',
  'copyright',
  'disable_play',
  'pay_info',
  'support_listen',
  'hot_comments',
];

Map<String, Object?> _videoProbe(Map<String, dynamic> video) => {
  for (final key in _videoProbeKeys)
    if (video.containsKey(key))
      key: key == 'hot_comments'
          ? {'note': 'count only', 'count': _list(video[key]).length}
          : shape(video[key]),
};

/// Which selector cells the response marks selected -- the only per-board
/// difference in the selector tree, which is otherwise identical across boards.
List<String> _selectedIds(Object? selector) {
  final found = <String>[];
  void visit(Object? node) {
    if (node is Map) {
      if (node['is_selected'] == true) {
        final id = node['selector_item_id'];
        if (id != null) found.add('$id');
      }
      for (final value in node.values) {
        visit(value);
      }
    } else if (node is List) {
      for (final value in node) {
        visit(value);
      }
    }
  }

  visit(selector);
  return found;
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: rank_sample.dart <output-json>');
    exitCode = 64;
    return;
  }
  final out = File(args.firstWhere((a) => !a.startsWith('--'))).absolute;
  await out.parent.create(recursive: true);

  // Raw text is read only to lift the filter vocabulary out of the two
  // endpoints this design depends on; the extracted names and shapes are what
  // gets written, keyed by which request produced them.
  final landpages = <Map<String, Object?>>[];
  final cells = <Map<String, Object?>>[];
  final browses = <Map<String, Object?>>[];
  var currentLabel = 'init';
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );
  dio.interceptors.add(
    InterceptorsWrapper(
      onResponse: (response, handler) {
        final text = response.data is String ? response.data as String : '';
        if (text.trim().isNotEmpty) {
          try {
            final body = _map(jsonDecode(text));
            final data = _map(body['data']);
            final rows = _list(data['selector_rows']);
            if (rows.isNotEmpty) {
              landpages.add({
                'request': currentLabel,
                'status': response.statusCode,
                'dataKeys': data.keys.toList(),
                'rows': [
                  for (final raw in rows)
                    if (_selectorRow(raw) != null) _selectorRow(raw)!,
                ],
              });
            }
            final view = _map(data['cell_view']);
            if (view.isEmpty && _list(data['video_data']).isNotEmpty) {
              final videos = [
                for (final raw in _list(data['video_data']).take(12))
                  _videoProbe(_map(raw)),
              ];
              browses.add({
                'request': currentLabel,
                'status': response.statusCode,
                'dataKeys': data.keys.toList(),
                'count': _list(data['video_data']).length,
                'nextOffset': data['next_offset'],
                'hasMore': data['has_more'],
                'cards': videos,
              });
            }
            if (view.isNotEmpty) {
              final entries = [
                for (final raw in _list(view['cell_data'])) _map(raw),
              ];
              final videos = [
                for (final entry in entries)
                  _map(
                    _list(entry['video_data']).isEmpty
                        ? null
                        : _list(entry['video_data']).first,
                  ),
              ];
              final signals = <String>{};
              for (final item in entries) {
                for (final key in item.keys) {
                  if (_isRankSignal(key)) signals.add(key);
                }
              }
              cells.add({
                'request': currentLabel,
                'status': response.statusCode,
                'dataKeys': data.keys.toList(),
                'rankVersion': data['rank_version'],
                'cellViewKeys': view.keys.toList(),
                'cellSelector': _selector(view['cell_selector']),
                'entryCount': entries.length,
                'entryKeys': entries.isEmpty
                    ? const []
                    : keyInventory(entries.first),
                'rankSignalNonNullCounts': {
                  for (final key in signals.toList())
                    key: entries.where((e) => e[key] != null).length,
                },
                'cards': [for (final video in videos) _videoProbe(video)],
                'videoSignalNonNullCounts': {
                  for (final key in _videoProbeKeys)
                    key: videos.where((v) => v[key] != null).length,
                },
              });
            }
          } on FormatException {
            // A non-JSON body carries no vocabulary; skip it.
          }
        }
        handler.next(response);
      },
    ),
  );

  final catalog = CatalogClient(
    dio: dio,
    deviceId: newCatalogDeviceId(),
    retry: NetworkRetry(delays: const []),
  );
  const genres = ['short_play', 'comic_series', 'ai_series'];
  const boards = {
    'recommend': 'comic_series_hot_rank',
    'hot': 'comic_series_hot_play',
    'new': 'comic_series_new_rank',
  };

  final filterVocabulary = <String, Object?>{};
  final feeds = <String, Object?>{};
  for (final genre in genres) {
    final before = landpages.length;
    currentLabel = 'themes($genre)';
    List<CatalogFilter> themes = const [];
    String? themeError;
    try {
      themes = await catalog.themes(genre);
    } catch (error) {
      themeError = '${error.runtimeType}: $error';
    }
    filterVocabulary[genre] = {
      'themeCount': themes.length,
      'themes': [
        for (final t in themes) {'name': t.name, 'id': t.id},
      ],
      'themeError': themeError,
      'landpageCaptures': landpages.length - before,
    };
    CatalogPage? page;
    String? feedError;
    currentLabel = 'browse($genre)';
    try {
      page = await catalog.browse(genre: genre);
    } catch (failure) {
      feedError = '${failure.runtimeType}: $failure';
    }
    feeds[genre] = {
      'ok': page != null,
      'error': feedError,
      'count': page?.items.length,
      'nextCursor': page?.nextCursor,
      'rows': [
        for (final d in page?.items ?? const <Drama>[])
          {
            'id': d.id,
            'title': d.title,
            'episodeCount': d.episodeCount,
            'tagNames': d.tagNames,
          },
      ],
    };
  }

  final leaderboards = <String, Object?>{};
  Object? selectorSample;
  for (final entry in boards.entries) {
    final before = cells.length;
    RankPage? page;
    String? error;
    currentLabel = 'rankBoard(${entry.key})';
    try {
      page = await catalog.rankBoard(board: entry.key);
    } catch (failure) {
      error = '${failure.runtimeType}: $failure';
    }
    final capture = cells.length > before ? cells.last : null;
    selectorSample ??= capture?['cellSelector'];
    leaderboards[entry.key] = {
      'sub_selected_items': entry.value,
      'ok': page != null,
      'error': error,
      'count': page?.entries.length,
      'unrecognizedCards': page?.unrecognizedCards,
      'updatedAt': page?.updatedAt?.toIso8601String(),
      'nextCursor': page?.nextCursor,
      'entries': [
        for (final e in (page?.entries ?? const <RankEntry>[]))
          {
            'position': e.position,
            'id': e.drama.id,
            'title': e.drama.title,
            'episodeCount': e.drama.episodeCount,
            'tagNames': e.drama.tagNames,
            'heat': e.heat,
            'score': e.score,
            'badge': e.badge,
          },
      ],
      'cellSelectorIsomorphicWith': selectorSample == capture?['cellSelector']
          ? 'self（完整树见顶层 cellSelectorSample）'
          : 'cellSelectorSample',
      'cellSelectorSelectedIds': _selectedIds(capture?['cellSelector']),
      'rankVersion': capture?['rankVersion'],
      'cellViewKeys': capture?['cellViewKeys'],
      'rawEntryKeys': capture?['entryKeys'],
      'rankSignalNonNullCounts': capture?['rankSignalNonNullCounts'],
      'rawCards': capture?['cards'],
      'videoSignalNonNullCounts': capture?['videoSignalNonNullCounts'],
      'dataKeys': capture?['dataKeys'],
    };
  }

  final report = <String, Object?>{
    'at': DateTime.now().toUtc().toIso8601String(),
    'anonymous': true,
    'note':
        'filter vocabulary and leaderboard field shape only; no urls, '
        'headers, signed parameters, media keys or bodies',
    'cellSelectorSample': selectorSample,
    'filterVocabulary': filterVocabulary,
    'feeds': feeds,
    'landpages': landpages,
    'browseCards': browses,
    'leaderboards': leaderboards,
  };
  final text = '${const JsonEncoder.withIndent('  ').convert(report)}\n';
  await out.writeAsString(text);
  stdout.write(text);
  dio.close(force: true);
}
