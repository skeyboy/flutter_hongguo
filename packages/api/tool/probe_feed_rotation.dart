import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';

// Read-only anonymous probe for what makes the discover feed answer differently.
// Run it twice in a row to compare two launches. Paced because upstream serves an
// empty body to a burst. Reports counts, ids and overlaps only -- no bodies, URLs,
// signed headers.
//
// What is separated here:
//   * does an identical request get an identical page? (the control)
//   * does `filter_ids` exclude what was already shown? CatalogClient drops a row
//     whose id is in `seen`, so an empty answer is ambiguous on its own -- the
//     cursor the response hands back settles it: a cursor that still advanced
//     means upstream re-sent those rows and the client filtered them away.
//   * does another sort change the set?
//   * does a fresh `session_id` change the set? This is the one the official
//     clients would use for a per-visit feed, and the reference implementation
//     always sends an empty string (client.js:1132), so it has never been
//     measured from here. Two shapes are tried: a numeric id and a uuid, because
//     the accepted format is unknown.
//   * does a deeper `offset` change the set? (probe_landpage_depth.dart, and the
//     `--offset` ask below for the resume case)
Future<void> main(List<String> args) async {
  final resumeOffset = int.tryParse(_flag(args, '--offset') ?? '') ?? 0;
  final rnd = Random.secure();
  String numericSession() =>
      List.generate(19, (_) => rnd.nextInt(10).toString()).join();
  String uuidSession() {
    String hex(int n) =>
        List.generate(n, (_) => rnd.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}';
  }

  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 8)));
  CatalogClient client({String sessionId = ''}) => CatalogClient(
    dio: dio,
    deviceId: '1234567890123456',
    signLists: true,
    sessionId: sessionId,
    protocol: const AppSettings(timeoutSeconds: 10),
  );

  Future<CatalogPage?> ask(
    String label,
    Future<CatalogPage> Function() call,
  ) async {
    for (var attempt = 1; attempt <= 5; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      try {
        final page = await call();
        stderr.writeln(
          '$label (attempt $attempt) -> ${page.items.length} rows, '
          'cursor=${page.nextCursor}',
        );
        return page;
      } catch (e) {
        stderr.writeln('$label (attempt $attempt) -> FAILED ${e.runtimeType}');
      }
    }
    return null;
  }

  List<String> ids(CatalogPage? page) =>
      page?.items.map((d) => d.id).toList() ?? const <String>[];

  final plain = client();
  final first = await ask(
    'head ask #1 (session_id empty)',
    () => plain.browse(),
  );
  final second = await ask('head ask #2, same params', () => plain.browse());
  final shown = ids(first);
  final filterIds = await ask(
    'head ask with filter_ids of ask #1',
    () => plain.browse(seen: shown),
  );
  final otherSort = await ask(
    'head ask with sort=hot_score',
    () => plain.browse(sort: 'hot_score'),
  );

  final numericId = numericSession();
  final numeric = client(sessionId: numericId);
  final numericAsk1 = await ask(
    'head ask with a fresh numeric session_id',
    () => numeric.browse(),
  );
  final numericAsk2 = await ask(
    'same numeric session_id, second ask',
    () => numeric.browse(),
  );

  final uuidId = uuidSession();
  final uuidClient = client(sessionId: uuidId);
  final uuidAsk = await ask(
    'head ask with a fresh uuid session_id',
    () => uuidClient.browse(),
  );

  final resumed = await ask(
    'head ask at offset=$resumeOffset (empty session)',
    () => plain.browse(cursor: '$resumeOffset'),
  );

  final interpretation = switch (filterIds) {
    null => 'request failed',
    _ when filterIds.items.isNotEmpty => 'upstream sent rows the client kept',
    _ when filterIds.nextCursor == null => 'upstream sent no rows at all',
    _ => 'upstream re-sent the already-shown page; the client filtered it out',
  };
  stdout.write(
    '${const JsonEncoder.withIndent('  ').convert({
      'at': DateTime.now().toUtc().toIso8601String(),
      'resumeOffset': resumeOffset,
      'sameParamsIdenticalOrder': sameOrder(shown, ids(second)),
      'overlapWithAsk1': {'sameParams': shared(shown, ids(second)), 'filterIdsOfAsk1': shared(shown, ids(filterIds)), 'otherSort': shared(shown, ids(otherSort)), 'numericSession': shared(shown, ids(numericAsk1)), 'uuidSession': shared(shown, ids(uuidAsk)), 'offsetResumed': shared(shown, ids(resumed))},
      'withinOneSession': {'numericTwoAsksIdenticalOrder': sameOrder(ids(numericAsk1), ids(numericAsk2)), 'numericTwoAsksOverlap': shared(ids(numericAsk1), ids(numericAsk2))},
      'betweenSessions': shared(ids(numericAsk1), ids(uuidAsk)),
      'filterIdsInterpretation': interpretation,
      'sizes': {'ask1': shown.length, 'numeric': ids(numericAsk1).length, 'uuid': ids(uuidAsk).length, 'resumed': ids(resumed).length},
      'sampleTitles': {'ask1': first?.items.take(2).map((d) => d.title).toList() ?? const [], 'numeric': numericAsk1?.items.take(2).map((d) => d.title).toList() ?? const [], 'uuid': uuidAsk?.items.take(2).map((d) => d.title).toList() ?? const []},
    })}\n',
  );
  dio.close(force: true);
}

int shared(List<String> a, List<String> b) =>
    a.toSet().intersection(b.toSet()).length;

bool sameOrder(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String? _flag(List<String> args, String name) {
  final at = args.indexOf(name);
  return at >= 0 && at + 1 < args.length ? args[at + 1] : null;
}
