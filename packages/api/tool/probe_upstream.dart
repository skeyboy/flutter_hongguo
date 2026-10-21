import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';

// Read-only anonymous smoke probe; never reads account sessions or outputs
// signed headers, URLs, media keys or response bodies. Run explicitly, not in CI.
// --recover: include normal bounded retries. --video: probe one returned episode's
// metadata/URL/key parsing, without downloading video media.
Future<void> main(List<String> args) async {
  final recover = args.contains('--recover');
  final results = <Map<String, Object?>>[];
  for (final signed in [false, true]) {
    final dio = Dio();
    final exchanges = <Map<String, Object?>>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          exchanges.add({
            'status': response.statusCode,
            'bodyBytes': utf8.encode('${response.data ?? ''}').length,
            'signed': response.requestOptions.headers.containsKey('x-argus'),
          });
          handler.next(response);
        },
      ),
    );
    final client = CatalogClient(
      dio: dio,
      deviceId: '1234567890123456',
      signLists: signed,
      protocol: const AppSettings(timeoutSeconds: 10),
      retry: recover ? NetworkRetry() : NetworkRetry(delays: const []),
    );
    try {
      final values = await client.themes('short_play');
      results.add({
        'probe': 'themes',
        'configuredSigned': signed,
        'ok': true,
        'filters': values.length,
        'exchanges': List.of(exchanges),
      });
      if (signed && args.contains('--video')) {
        final start = exchanges.length;
        try {
          final page = await client.browse();
          if (page.items.isEmpty) throw StateError('No probe episode');
          final detail = await client.detail(page.items.first.id);
          if (detail.episodes.isEmpty) throw StateError('No probe episode');
          final model = VideoModelClient(
            dio: dio,
            builder: VideoRequestBuilder(
              protocol: const AppSettings(timeoutSeconds: 10),
            ),
          );
          final track = await model.fetchTrack(detail.episodes.first.vid);
          results.add({
            'probe': 'playback-metadata',
            'ok': true,
            'episodes': detail.episodes.length,
            'definition': track.definition,
            'encrypted': track.encrypted,
            'checkedMediaUrl': track.url.scheme == 'https',
            'contentKeyValid': track.encrypted
                ? Spade.isValidKey(Spade.unwrapV1(decodeBase64(track.spadeA)))
                : null,
            'mediaDownloaded': false,
            'exchanges': exchanges.sublist(start),
          });
        } catch (error) {
          results.add({
            'probe': 'playback-metadata',
            'ok': false,
            ...safeFailure(error),
            'exchanges': exchanges.sublist(start),
          });
        }
      }
    } catch (error) {
      results.add({
        'probe': 'themes',
        'configuredSigned': signed,
        'ok': false,
        ...safeFailure(error),
        'exchanges': List.of(exchanges),
      });
    } finally {
      dio.close(force: true);
    }
  }
  final report = {
    'at': DateTime.now().toUtc().toIso8601String(),
    'anonymous': true,
    'recoveryEnabled': recover,
    'results': results,
  };
  final text = '${const JsonEncoder.withIndent('  ').convert(report)}\n';
  final output = Platform.environment['HONGGUO_PROBE_OUTPUT'];
  if (output != null && output.isNotEmpty) {
    await File(output).writeAsString(text);
  }
  stdout.write(text);
}

Map<String, Object?> safeFailure(Object error) => {
  'errorType': error.runtimeType.toString(),
  if (error is DioException) ...{
    'transportType': error.type.name,
    'httpStatus': error.response?.statusCode,
  },
};
