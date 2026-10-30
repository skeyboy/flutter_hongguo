import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';

// Read-only refusal matrix. The viewer-facing question is whether an empty
// playback answer belongs to the episode (the same vid answers empty every
// time, so repeating it cannot help) or to the moment (the next ask succeeds).
// One anonymous registration is shared for the whole run, and the vid order is
// shuffled by taking the first, middle and last episodes of each series so a
// position effect cannot look like an episode effect.
// Reports only statuses and byte counts -- never a media URL, seed or key.
Future<void> main(List<String> args) async {
  final asks = int.tryParse(_flag(args, '--asks') ?? '') ?? 3;
  final seriesCount = int.tryParse(_flag(args, '--series') ?? '') ?? 3;
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 8)));
  final catalog = CatalogClient(
    dio: dio,
    deviceId: '1234567890123456',
    protocol: const AppSettings(timeoutSeconds: 10),
  );
  final builder = VideoRequestBuilder(
    protocol: const AppSettings(timeoutSeconds: 10),
  );
  final device = await PlaybackDeviceRegistry(dio: dio).get();

  final page = await catalog.browse();
  final rows = <Map<String, Object?>>[];
  for (final drama in page.items.take(seriesCount)) {
    final detail = await catalog.detail(drama.id);
    final episodes = detail.episodes;
    if (episodes.isEmpty) continue;
    final picked = <({int index, String vid})>[
      (index: 0, vid: episodes.first.vid),
      (index: episodes.length ~/ 2, vid: episodes[episodes.length ~/ 2].vid),
      (index: episodes.length - 1, vid: episodes.last.vid),
    ];
    for (final episode in picked) {
      final attempts = <String>[];
      for (var ask = 0; ask < asks; ask++) {
        attempts.add(await _ask(dio, builder, device, episode.vid));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      rows.add({
        'seriesId': drama.id,
        'episodeIndex': episode.index,
        'vid': episode.vid,
        'episodes': episodes.length,
        'attempts': attempts,
      });
    }
  }

  final report = {
    'at': DateTime.now().toUtc().toIso8601String(),
    'asksPerVid': asks,
    'registration': 'one anonymous device shared for the run',
    'rows': rows,
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

/// `status/bytes/data|none`, the same privacy-safe shape the identity probe uses.
Future<String> _ask(
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
    return '${response.statusCode}/${utf8.encode(body).length}/'
        '${hasData ? 'data' : 'none'}';
  } on DioException catch (error) {
    return '${error.response?.statusCode}/0/transport-${error.type.name}';
  }
}
