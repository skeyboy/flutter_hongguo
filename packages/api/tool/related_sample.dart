// Read-only live sample for the detail-page 同题材 block
// (docs/design/2026-10-22-detail-page-and-download-policy.md §5.4).
// Prints tag mapping evidence only: no URLs, credentials, headers or bodies.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) throw ArgumentError('Pass an output JSON path.');
  final out = File(args.first).absolute;
  await out.parent.create(recursive: true);
  // --dump-schema only lifts genre ids out of category_schema; no url, header,
  // media key or whole body is ever written.
  final dumpSchema = args.contains('--dump-schema');
  final schemaIds = <String>{};
  var schemaSightings = 0;
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15)));
  if (dumpSchema) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          final body = response.data is String
              ? response.data as String
              : jsonEncode(response.data ?? '');
          for (
            var at = body.indexOf('category_schema');
            at >= 0;
            at = body.indexOf('category_schema', at + 1)
          ) {
            final window = body.substring(
              at,
              at + 240 < body.length ? at + 240 : body.length,
            );
            for (final match in RegExp(r'cate_[0-9]+').allMatches(window)) {
              schemaIds.add(match.group(0)!);
            }
            schemaSightings++;
          }
          handler.next(response);
        },
      ),
    );
  }
  final catalog = CatalogClient(dio: dio, deviceId: newCatalogDeviceId());
  final rest = args.where((a) => !a.startsWith('--')).toList();
  final seriesId = rest.length > 1 ? rest[1] : null;
  final page = await catalog.browse();
  final themes = await catalog.themes('short_play');
  final themeNames = [for (final f in themes) f.name];
  final themeIds = {for (final f in themes) f.name: f.id};
  final seeds = <Map<String, Object?>>[
    for (final d in page.items.take(12))
      {
        'id': d.id,
        'title': d.title,
        'tagNames': d.tagNames,
        'matched': d.tagNames.where(themeNames.contains).toList(),
      },
  ];
  final seed = page.items.firstWhere(
    (d) => seriesId == null || d.id == seriesId,
    orElse: () => throw StateError('Seed drama not present in page 1'),
  );
  final detail = await catalog.detail(seed.id);
  final drama = detail.drama.tagNames.isNotEmpty ? detail.drama : seed;
  final report = <String, Object?>{
    'at': DateTime.now().toIso8601String(),
    'seed': {'id': drama.id, 'title': drama.title},
    'tagNames': drama.tagNames,
    'detailTagNames': detail.drama.tagNames,
    'browseRowSample': seeds,
    'themeNames': themeNames,
    'themeIds': themeIds,
    'schemaCateIds': dumpSchema ? schemaIds.toList() : null,
    'schemaSightings': dumpSchema ? schemaSightings : null,
  };
  CatalogFilter? theme;
  for (final tag in drama.tagNames) {
    for (final filter in themes) {
      if (filter.name.trim() == tag) {
        theme = filter;
        break;
      }
    }
    if (theme != null) break;
  }
  report['themesOnPanel'] = themes.length;
  report['matchedTheme'] = theme == null
      ? null
      : {'name': theme.name, 'id': theme.id};
  final board = theme == null
      ? await catalog.browse(genre: 'short_play', sort: 'hot_score')
      : await catalog.browse(genre: 'short_play', theme: theme.id);
  final related = board.items
      .where((d) => d.id.isNotEmpty && d.id != drama.id)
      .take(12)
      .toList();
  report['relation'] = theme == null ? '平台热门' : '同题材';
  report['related'] = {
    'count': related.length,
    'titles': [for (final d in related) d.title],
    'containsSeed': related.any((d) => d.id == drama.id),
  };
  out.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  stdout.writeln(jsonEncode(report));
}
