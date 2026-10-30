import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';

// Discriminating read-only probe: when the playback POST answers HTTP 200 with
// nothing, is the answer bound to the registered identity, or is it upstream
//抖动 that any repeat beats? One process-shared identity is asked `--rounds`
// times, then a freshly registered identity is asked the same number of times.
// Anonymous, no media download. Only statuses, byte counts and whether a `data`
// envelope was present are reported -- never URLs, seeds or content keys.
Future<void> main(List<String> args) async {
  final rounds = int.tryParse(_flag(args, '--rounds') ?? '') ?? 8;
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 8)));
  final catalog = CatalogClient(
    dio: dio,
    deviceId: '1234567890123456',
    protocol: const AppSettings(timeoutSeconds: 10),
  );
  final page = await catalog.browse();
  if (page.items.isEmpty) throw StateError('No probe series');
  final detail = await catalog.detail(page.items.first.id);
  if (detail.episodes.isEmpty) throw StateError('No probe episode');
  final vid = detail.episodes.first.vid;
  final builder = VideoRequestBuilder(
    protocol: const AppSettings(timeoutSeconds: 10),
  );

  final shared = await PlaybackDeviceRegistry(dio: dio).get();
  final sharedAsks = <Map<String, Object?>>[];
  final freshAsks = <Map<String, Object?>>[];
  // Interleaved in one time window: the same identity asked again and again,
  // against an identity that has only ever answered once.
  for (var index = 0; index < rounds; index++) {
    sharedAsks.add(await _ask(dio, builder, shared, vid));
    final device = await PlaybackDeviceRegistry(dio: dio).get();
    freshAsks.add(await _ask(dio, builder, device, vid));
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  Map<String, Object?> summarize(List<Map<String, Object?>> asks) => {
    'answered': asks.where((a) => a['hasData'] == true).length,
    'emptyBody': asks.where((a) => (a['bodyBytes'] as int) == 0).length,
    'sequence': [
      for (final ask in asks)
        '${ask['status']}/${ask['bodyBytes']}/'
            '${ask['hasData'] == true ? 'data' : 'none'}',
    ],
  };

  final report = {
    'at': DateTime.now().toUtc().toIso8601String(),
    'rounds': rounds,
    'sharedIdentity': summarize(sharedAsks),
    'freshIdentityEachAsk': summarize(freshAsks),
  };
  final text = '${const JsonEncoder.withIndent('  ').convert(report)}\n';
  final output = Platform.environment['HONGGUO_PROBE_OUTPUT'];
  if (output != null && output.isNotEmpty) {
    await File(output).writeAsString(text);
  }
  stdout.write(text);
  dio.close(force: true);
}

String? _flag(List<String> args, String name) {
  for (final arg in args) {
    if (arg.startsWith('$name=')) return arg.substring(name.length + 1);
  }
  return null;
}

Future<Map<String, Object?>> _ask(
  Dio dio,
  VideoRequestBuilder builder,
  PlaybackDevice device,
  String vid,
) async {
  final request = builder.build(vid, device: device);
  try {
    final response = await dio.fetch<String>(
      Options(
            method: 'POST',
            headers: request.headers,
            responseType: ResponseType.plain,
            followRedirects: false,
            sendTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 8),
          )
          .compose(
            dio.options,
            request.url,
            data: Stream<Uint8List>.value(request.body),
          )
          .copyWith(connectTimeout: const Duration(seconds: 5)),
    );
    final body = response.data ?? '';
    var hasData = false;
    if (body.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(body);
        hasData = decoded is Map && decoded['data'] is Map;
      } on FormatException {
        hasData = false;
      }
    }
    return {
      'status': response.statusCode,
      'bodyBytes': utf8.encode(body).length,
      'hasData': hasData,
    };
  } on DioException catch (error) {
    return {
      'status': error.response?.statusCode,
      'bodyBytes': 0,
      'hasData': false,
      'transport': error.type.name,
    };
  }
}
