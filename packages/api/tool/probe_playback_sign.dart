import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';

/// Read-only probe for the playback admission regime. It sends the production
/// request plus two variants and records only status, byte count and whether
/// the envelope carried episodes -- never a media URL, seed or content key.
///
/// `dart run tool/probe_playback_sign.dart [vid] [rounds] [out.json]`
Future<void> main(List<String> args) async {
  final vid = args.isNotEmpty ? args.first : '7701334783946673176';
  final rounds = args.length > 1 ? int.parse(args[1]) : 3;
  final out = args.length > 2
      ? args[2]
      : 'build/playback-sign-${DateTime.now().toIso8601String().substring(0, 10)}.json';
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 8)));
  final builder = VideoRequestBuilder();
  final signer = PureSign();
  final readings = <Map<String, Object?>>[];
  for (var round = 0; round < rounds; round++) {
    final device = await PlaybackDeviceRegistry(dio: dio).get();
    final production = builder.build(vid, device: device);
    final shapes = <String, VideoRequest>{
      'production': production,
      'escaped_star': _resign(
        production,
        signer,
        (url) => url.replaceAll('*', '%2A'),
      ),
      'unsigned': VideoRequest(
        production.url,
        production.body,
        Map.of(production.headers)
          ..removeWhere((key, _) => _signatureHeaders.contains(key)),
      ),
    };
    for (final entry in shapes.entries) {
      final request = entry.value;
      final record = <String, Object?>{
        'round': round,
        'shape': entry.key,
        'deviceIdTail': device.deviceId.substring(device.deviceId.length - 4),
        // Read from the production headers: the `unsigned` variant has just
        // lost `x-khronos`, and a branch computed against khronos 0 would
        // report a number the endpoint never saw.
        'branch': signer.branchOf(
          request.url,
          request.body,
          int.parse(production.headers['x-khronos']!),
        ),
        'ticket': request.headers['x-ss-req-ticket'],
        'literalStar': request.url.contains('1280*2772'),
        'signatureHeaders': request.headers.keys
            .where(_signatureHeaders.contains)
            .length,
      };
      try {
        final response = await dio.fetch<String>(
          Options(
                method: 'POST',
                headers: request.headers,
                responseType: ResponseType.plain,
                followRedirects: false,
                sendTimeout: const Duration(seconds: 6),
                receiveTimeout: const Duration(seconds: 10),
              )
              .compose(
                dio.options,
                request.url,
                data: Stream<Uint8List>.value(request.body),
              )
              .copyWith(connectTimeout: const Duration(seconds: 6)),
        );
        final body = response.data ?? '';
        record['status'] = response.statusCode;
        record['bytes'] = utf8.encode(body).length;
        record.addAll(_verdict(body, vid));
      } catch (error) {
        record['error'] = '$error';
      }
      readings.add(record);
      stdout.writeln('${entry.key.padRight(14)} ${jsonEncode(record)}');
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
  }
  await File(out).parent.create(recursive: true);
  await File(out).writeAsString(
    '${jsonEncode({'vid': vid, 'capturedAt': DateTime.now().toIso8601String(), 'readings': readings})}\n',
  );
  dio.close(force: true);
}

const _signatureHeaders = {
  'x-gorgon',
  'x-khronos',
  'x-ladon',
  'x-argus',
  'x-helios',
  'x-medusa',
};

/// Re-sign the same body over rewritten query bytes. The branch is a function
/// of those bytes, so `_rticket` is rolled until the rewrite lands on branch 0
/// again; without that the variant would be refused for the wrong reason.
VideoRequest _resign(
  VideoRequest base,
  PureSign signer,
  String Function(String) rewrite,
) {
  final khronos = int.parse(base.headers['x-khronos']!);
  final rewritten = rewrite(base.url);
  final ticketBase = DateTime.now().millisecondsSinceEpoch;
  for (var attempt = 0; attempt < 128; attempt++) {
    final ticket = ticketBase + attempt;
    final url = rewritten.replaceFirst(
      RegExp(r'_rticket=\d+$'),
      '_rticket=$ticket',
    );
    if (signer.branchOf(url, base.body, khronos) != 0) continue;
    final headers = Map.of(base.headers)
      ..['x-ss-req-ticket'] = '$ticket'
      ..addAll(signer.sign(url, base.body, khronos));
    return VideoRequest(url, base.body, headers);
  }
  throw StateError('no branch-0 ticket for the rewritten query');
}

Map<String, Object?> _verdict(String body, String vid) {
  if (body.trim().isEmpty) return const {'verdict': 'empty'};
  try {
    final outer = jsonDecode(body);
    if (outer is! Map) return const {'verdict': 'not-a-map'};
    var data = outer['data'];
    if (data is String) data = jsonDecode(data);
    var rows = -1;
    if (data is Map && data[vid] != null) {
      var model = data[vid]['video_model'];
      if (model is String) model = jsonDecode(model);
      final list = model is Map ? model['video_list'] : null;
      rows = list is List ? list.length : (list is Map ? list.length : -3);
    }
    return {
      'verdict':
          'code=${outer['code'] ?? outer['Code']} dataKeys=${data is Map ? data.length : -1} videoRows=$rows',
    };
  } catch (_) {
    return {'verdict': 'unparsed bytes=${body.length}'};
  }
}
