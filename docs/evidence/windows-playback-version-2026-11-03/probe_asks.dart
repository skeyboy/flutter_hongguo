import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';

// Scratch diagnostic: one process-wide registry, then the ask shapes the app
// actually produces (retries after a refusal, and play + prefetch + download
// queue asking at once). Read-only, anonymous, never downloads media.
Future<void> main(List<String> args) async {
  final vid = args.isNotEmpty ? args.first : '7701334783946673176';
  final dio = Dio();
  final log = <Map<String, Object?>>[];
  dio.interceptors.add(
    InterceptorsWrapper(
      onResponse: (r, h) {
        log.add({
          't': DateTime.now().toUtc().toIso8601String().substring(11, 23),
          'status': r.statusCode,
          'bytes': utf8.encode('${r.data ?? ''}').length,
          'hop': Uri.parse(r.requestOptions.uri.toString()).path.split('/').where((p) => p.isNotEmpty).join('/'),
        });
        h.next(r);
      },
    ),
  );
  final model = VideoModelClient(
    dio: dio,
    devices: PlaybackDeviceRegistry(dio: dio),
    builder: VideoRequestBuilder(
      protocol: const AppSettings(timeoutSeconds: 10),
    ),
  );
  Future<Map<String, Object?>> ask(String label) async {
    final started = DateTime.now();
    final mark = log.length;
    try {
      final track = await model.fetchTrack(vid);
      return {
        'case': label,
        'ok': true,
        'seconds':
            DateTime.now().difference(started).inMilliseconds / 1000.0,
        'definition': track.definition,
        'exchanges': log.sublist(mark),
      };
    } catch (error) {
      return {
        'case': label,
        'ok': false,
        'seconds':
            DateTime.now().difference(started).inMilliseconds / 1000.0,
        'errorType': error.runtimeType.toString(),
        'message': error.toString(),
        'exchanges': log.sublist(mark),
      };
    }
  }

  final results = <Map<String, Object?>>[
    await ask('seq-1'),
    await ask('seq-2-immediately'),
    await ask('seq-3-immediately'),
    ...await Future.wait(List.generate(4, (i) => ask('parallel-${i + 1}'))),
  ];
  stdout.write(
    const JsonEncoder.withIndent('  ').convert({
      'vid': vid,
      'successes': results.where((r) => r['ok'] == true).length,
      'total': results.length,
      'results': results,
    }),
  );
  stdout.writeln();
}
