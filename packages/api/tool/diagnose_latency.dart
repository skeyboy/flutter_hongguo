import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';

// Explicit read-only diagnostic; no media download, credentials, URLs or bodies logged.
String safePath(String value) =>
    value.startsWith('/video/fplay/') ? '/video/fplay/[redacted]' : value;
Future<void> main() async {
  final events = <Map<String, Object?>>[];
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (o, h) {
        o.extra['clock'] = Stopwatch()..start();
        h.next(o);
      },
      onResponse: (r, h) {
        events.add({
          'path': safePath(r.requestOptions.uri.path),
          'ms': (r.requestOptions.extra['clock'] as Stopwatch)
              .elapsedMilliseconds,
          'status': r.statusCode,
          'bytes': utf8.encode('${r.data ?? ''}').length,
        });
        h.next(r);
      },
      onError: (e, h) {
        events.add({
          'path': safePath(e.requestOptions.uri.path),
          'ms': (e.requestOptions.extra['clock'] as Stopwatch?)
              ?.elapsedMilliseconds,
          'error': e.type.name,
        });
        h.next(e);
      },
    ),
  );
  final timings = <MetadataTiming>[];
  final client = CatalogClient(
    dio: dio,
    deviceId: '1234567890123456',
    onTiming: timings.add,
    protocol: const AppSettings(timeoutSeconds: 10),
  );
  final outcomes = <Map<String, Object?>>[];
  Future<T?> measure<T>(String label, Future<T> Function() work) async {
    final watch = Stopwatch()..start();
    final start = events.length;
    try {
      final v = await work();
      outcomes.add({
        'stage': label,
        'ms': watch.elapsedMilliseconds,
        'ok': true,
        'requests': events.sublist(start),
      });
      return v;
    } catch (e) {
      outcomes.add({
        'stage': label,
        'ms': watch.elapsedMilliseconds,
        'ok': false,
        'error': e.runtimeType.toString(),
        'requests': events.sublist(start),
      });
      return null;
    }
  }

  CatalogPage? page;
  for (var i = 0; i < 3; i++) {
    await measure('themes-$i', () => client.themes('short_play'));
    page = await measure('browse-$i', () => client.browse());
  }
  if (page != null && page.items.isNotEmpty) {
    final detail = await measure(
      'detail',
      () => client.detail(page!.items.first.id),
    );
    if (detail != null && detail.episodes.isNotEmpty) {
      final model = VideoModelClient(
        dio: dio,
        onTiming: timings.add,
        builder: VideoRequestBuilder(
          protocol: const AppSettings(timeoutSeconds: 10),
        ),
      );
      await measure(
        'video-metadata',
        () => model.fetchTrack(detail.episodes.first.vid),
      );
    }
  }
  final builder = VideoRequestBuilder();
  final sw = Stopwatch()..start();
  for (var i = 0; i < 100; i++) {
    builder.build('1234567890123456789');
  }
  final report = {
    'at': DateTime.now().toUtc().toIso8601String(),
    'timeoutSeconds': 10,
    'metadataDeadlineMs': 12000,
    'logicalRequests': [
      for (final trace in timings)
        {
          'id': trace.requestId,
          'operation': trace.operation,
          'attempts': trace.attempts,
          'cacheHit': trace.cacheHit,
          'failureType': trace.failureType,
          'elapsedMs': trace.elapsed.inMicroseconds / 1000,
          'stagesMs': trace.stages.map(
            (key, value) => MapEntry(key, value.inMicroseconds / 1000),
          ),
        },
    ],
    'anonymous': true,
    'mediaDownloaded': false,
    'signBuild100Ms': sw.elapsedMilliseconds,
    'outcomes': outcomes,
  };
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  dio.close(force: true);
}
