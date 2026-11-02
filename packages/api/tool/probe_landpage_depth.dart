import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';

// How deep does one landpage window list go, and does a deep window still carry
// watchable rows? This bounds the random start offset a launch-rotation can use.
// Reports counts and overlaps only -- no bodies, URLs or signed headers.
Future<void> main(List<String> args) async {
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 8)));
  final client = CatalogClient(
    dio: dio,
    deviceId: '1234567890123456',
    signLists: true,
    protocol: const AppSettings(timeoutSeconds: 10),
  );

  Future<CatalogPage?> ask(String label, int offset, String sort) async {
    for (var attempt = 1; attempt <= 5; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 4));
      try {
        final page = await client.browse(
          sort: sort,
          cursor: offset == 0 ? null : '$offset',
        );
        stderr.writeln(
          '$label (attempt $attempt) -> ${page.items.length} items, '
          'cursor=${page.nextCursor}, '
          'titles=${page.items.take(2).map((d) => d.title).join(" | ")}',
        );
        return page;
      } catch (e) {
        stderr.writeln('$label (attempt $attempt) -> FAILED ${e.runtimeType}');
      }
    }
    return null;
  }

  final head = await ask('hot-score offset=0', 0, 'hot_score');
  final ids = head?.items.map((d) => d.id).toList() ?? const <String>[];
  final depths = <String, Object?>{};
  for (final offset in [90, 360, 900, 2000, 5000]) {
    final page = await ask('hot-score offset=$offset', offset, 'hot_score');
    depths['offset$offset'] = {
      'items': page?.items.length,
      'cursor': page?.nextCursor,
      'overlapWithHead': shared(
        ids,
        page?.items.map((d) => d.id).toList() ?? const [],
      ),
      'sampleTitle': page == null || page.items.isEmpty
          ? null
          : page.items.first.title,
    };
  }

  stdout.write(
    '${const JsonEncoder.withIndent('  ').convert({
      'at': DateTime.now().toUtc().toIso8601String(),
      'headWindow': {'items': ids.length, 'cursor': head?.nextCursor},
      'depths': depths,
    })}\n',
  );
  dio.close(force: true);
}

int shared(List<String> a, List<String> b) =>
    a.toSet().intersection(b.toSet()).length;
