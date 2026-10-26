import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'request_control.dart';

/// Raw bytes and the exact encoded URI are frozen together before signing.
class SignedVideoRequest {
  final String url;
  final Uint8List body;
  final Map<String, String> headers;
  SignedVideoRequest(this.url, Uint8List body, Map<String, String> headers)
    : body = Uint8List.fromList(body).asUnmodifiableView(),
      headers = Map.unmodifiable(headers);
}

String encodeQueryPart(String value) => utf8.encode(value).map((b) {
  final safe =
      b >= 65 && b <= 90 ||
      b >= 97 && b <= 122 ||
      b >= 48 && b <= 57 ||
      [45, 46, 95, 126].contains(b);
  return safe
      ? String.fromCharCode(b)
      : '%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}';
}).join();

class VideoRequestBuilder {
  static const endpoint =
      'https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/';
  static const userAgent =
      'com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; '
      'Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 '
      'QuicVersion:c67e9834 2025-09-08)';
  final PureSign signer;
  final AppSettings protocol;
  final Map<String, String> sessionHeaders;
  final int Function() clockMillis;
  final Map<String, String> Function() deviceFactory;
  VideoRequestBuilder({
    this.protocol = const AppSettings(),
    this.sessionHeaders = const {},
    PureSign? signer,
    int Function()? clockMillis,
    Map<String, String> Function()? deviceFactory,
  }) : signer = signer ?? PureSign(),
       clockMillis =
           clockMillis ?? (() => DateTime.now().millisecondsSinceEpoch),
       deviceFactory = deviceFactory ?? defaultDevice {
    protocol.validate();
  }

  static String _id() {
    var value = BigInt.zero;
    for (final b in secureBytes(6)) {
      value = (value << 8) | BigInt.from(b);
    }
    return '${BigInt.parse('1000000000000000') + value}';
  }

  static Map<String, String> defaultDevice() => {
    'ac': 'wifi',
    'channel': 'update_64',
    'aid': '8662',
    'app_name': 'novelread',
    'version_code': '71332',
    'version_name': '7.1.3.32',
    'device_platform': 'android',
    'os': 'android',
    'ssmix': 'a',
    'device_type': '25053RT47C',
    'device_brand': 'Redmi',
    'language': 'zh',
    'os_api': '36',
    'os_version': '16',
    'manifest_version_code': '71332',
    'resolution': '1280*2772',
    'dpi': '520',
    'update_version_code': '71332',
    'host_abi': 'arm64-v8a',
    'dragon_device_type': 'phone',
    'pv_player': '71332',
    'compliance_status': '0',
    'need_personal_recommend': '1',
    'player_so_load': '1',
    'is_android_pad_screen': '0',
    'iid': _id(),
    'device_id': _id(),
  };
  SignedVideoRequest build(String vid) {
    if (!RegExp(r'^\d{1,30}$').hasMatch(vid)) {
      throw ArgumentError.value(vid, 'vid');
    }
    final body = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'biz_param': {
            'detail_page_version': 0,
            'device_level': 3,
            'disable_digg_stat': false,
            'need_all_video_definition': true,
            'need_mp4_align': false,
            'use_os_player': false,
            'use_server_dns': false,
            'video_platform': 1024,
          },
          'mixed_video_id_map': {
            '1004': [vid],
          },
        }),
      ),
    );
    final now = clockMillis(), ts = now ~/ 1000;
    String? url;
    var ticket = now;
    for (var offset = 0; offset < 32; offset++) {
      ticket = now + offset;
      final query = {
        ...deviceFactory(),
        'version_code': protocol.videoVersionCode,
        'version_name': protocol.videoVersion,
        'manifest_version_code': protocol.videoVersionCode,
        'update_version_code': protocol.videoVersionCode,
        'pv_player': protocol.videoVersionCode,
        'ts': '$ts',
        '_rticket': '$ticket',
      };
      url =
          'https://${protocol.videoHost}/novel/player/multi_video_model/v1/?${query.entries.map((e) => '${encodeQueryPart(e.key)}=${encodeQueryPart(e.value)}').join('&')}';
      if (signer.branchOf(url, body, ts) != 1) break;
    }
    // Fail explicitly rather than sending a known incompatible variant.
    if (signer.branchOf(url!, body, ts) == 1) {
      throw StateError('No compatible signing branch after 32 attempts');
    }
    return SignedVideoRequest(url, body, {
      'User-Agent': protocol.videoUserAgent,
      ...sessionHeaders,
      'Accept': 'application/json; charset=utf-8,application/x-protobuf',
      'Content-Type': 'application/json; charset=UTF-8',
      'Content-Length': '${body.length}',
      'x-xs-from-web': '0',
      'x-ss-req-ticket': '$ticket',
      'x-tt-request-tag': 't=0;n=0',
      'sdk-version': '2',
      'passport-sdk-version': '50561',
      'x-vc-bdturing-sdk-version': '3.7.2.cn',
      'x-ss-stub': hex(md5(body)).toUpperCase(),
      ...signer.sign(url, body, ts),
      'x-tt-dt': '',
    });
  }
}

class VideoQuality {
  final String value, label;
  final int width, height;
  const VideoQuality(this.value, this.label, {this.width = 0, this.height = 0});
}

class VideoTrack {
  final Uri url;
  final String spadeA, definition;
  final int size;
  bool get encrypted => spadeA.isNotEmpty;
  const VideoTrack({
    required this.url,
    required this.spadeA,
    required this.definition,
    required this.size,
  });
}

/// Native direct-upstream POC. Web should use a remote API adapter instead.
/// Redirects are disabled so an unchecked location never receives signed headers.
class VideoModelClient {
  final Dio dio;
  final VideoRequestBuilder builder;
  final CatalogRequests _requests;
  VideoModelClient({
    required this.dio,
    VideoRequestBuilder? builder,
    Duration requestDeadline = const Duration(seconds: 12),
    void Function(MetadataTiming)? onTiming,
  }) : builder = builder ?? VideoRequestBuilder(),
       _requests = CatalogRequests(
         deadline: requestDeadline,
         onTiming: onTiming,
       );
  void close() => _requests.cancelAll();
  Future<Map<String, dynamic>> fetchVideoInfo(String vid) => _requests.run(
    'video:$vid',
    () => _fetchVideoInfo(vid),
    label: 'video.metadata',
  );

  Duration _timeout(int maximum) => RequestBudget.current.timeout(
    Duration(
      seconds: builder.protocol.timeoutSeconds < maximum
          ? builder.protocol.timeoutSeconds
          : maximum,
    ),
  );

  Future<Map<String, dynamic>> _fetchVideoInfo(String vid) async {
    final budget = RequestBudget.current;
    final clock = Stopwatch()..start();
    final request = builder.build(vid);
    budget.record('sign', clock.elapsed);
    final first = await budget.transport(
      () => dio.fetch<String>(
        Options(
              method: 'POST',
              headers: request.headers,
              responseType: ResponseType.plain,
              followRedirects: false,
              sendTimeout: _timeout(5),
              receiveTimeout: _timeout(8),
            )
            .compose(
              dio.options,
              request.url,
              data: Stream<Uint8List>.value(request.body),
              cancelToken: budget.token,
            )
            .copyWith(connectTimeout: _timeout(5)),
      ),
    );
    if (first.statusCode != 200) {
      throw StateError('App HTTP ${first.statusCode}');
    }
    final outer = _object(first.data);
    _checkCodes(outer);
    final entry = _object(_object(outer['data'])[vid]);
    final model = _object(entry['video_model']);
    final fallback = _fallback(model['fallback_api']);
    final uri = MediaUrlDecoder.checked(fallback, [
      'fqnovel.com',
      'snssdk.com',
    ]);
    final second = await budget.transport(
      () => dio.fetch<String>(
        Options(
              headers: {'User-Agent': builder.protocol.videoUserAgent},
              responseType: ResponseType.plain,
              followRedirects: false,
              receiveTimeout: _timeout(8),
            )
            .compose(dio.options, uri.toString(), cancelToken: budget.token)
            .copyWith(connectTimeout: _timeout(5)),
      ),
    );
    if (second.statusCode != 200) {
      throw StateError('fallback HTTP ${second.statusCode}');
    }
    final result = _object(second.data);
    _checkCodes(result);
    final info = _object(result['video_info']);
    _checkCodes(info);
    final data = _object(info['data']);
    if (data.isEmpty) throw StateError('No video info');
    return data;
  }

  Future<VideoTrack> fetchTrack(String vid, {String quality = 'best'}) async =>
      selectTrack(await fetchVideoInfo(vid), quality: quality);

  Future<List<VideoQuality>> fetchQualities(String vid) async =>
      availableQualities(await fetchVideoInfo(vid));

  /// Only advertise resolutions with a compatible, validated URL/key. The UI
  /// receives descriptive metadata, never signed URLs or encryption material.
  static List<VideoQuality> availableQualities(Map<String, dynamic> info) {
    selectTrack(info); // Automatic must itself be playable.
    final options = <int, VideoQuality>{};
    for (final entry in _object(info['video_list']).entries) {
      final item = _object(entry.value);
      final meta = _object(item['video_meta']);
      var width = 0, height = 0;
      for (final pair in [
        [item['vwidth'], item['vheight']],
        [item['width'], item['height']],
        [meta['vwidth'], meta['vheight']],
        [meta['width'], meta['height']],
      ]) {
        final w = int.tryParse('${pair[0]}') ?? 0;
        final h = int.tryParse('${pair[1]}') ?? 0;
        if (w > 0 && h > 0) {
          width = w;
          height = h;
          break;
        }
      }
      final pixels = width < height ? width : height;
      if (pixels < 100 || pixels > 9999) continue;
      try {
        selectTrack({
          ...info,
          'video_list': {entry.key: entry.value},
        });
        options.putIfAbsent(
          pixels,
          () => VideoQuality(
            '${pixels}p',
            '${pixels}p',
            width: width,
            height: height,
          ),
        );
      } on StateError {
        continue;
      } on FormatException {
        continue;
      }
    }
    final resolutions = options.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      const VideoQuality('best', '自动'),
      for (final px in resolutions) options[px]!,
    ];
  }

  static VideoTrack selectTrack(
    Map<String, dynamic> info, {
    String quality = 'best',
  }) {
    final list = _object(info['video_list']);
    final seedText = info['key_seed'] as String? ?? '';
    final seed = seedText.isEmpty ? null : decodeBase64(seedText);
    final auto = quality.isEmpty || quality == 'best' || quality == 'auto';
    int pixels(String value) =>
        int.tryParse(RegExp(r'\d+').firstMatch(value)?.group(0) ?? '') ?? 0;
    final wanted = pixels(quality);
    final rows =
        <
          ({
            Map<String, dynamic> item,
            int rank,
            int shortSide,
            int px,
            String quality,
            int size,
          })
        >[];
    for (final value in list.values) {
      final item = _object(value), meta = _object(_object(value)['video_meta']);
      String first(List<dynamic> values) =>
          values
              .where((v) => v != null && '$v'.isNotEmpty)
              .map((v) => '$v')
              .firstOrNull ??
          '';
      int number(dynamic value) => int.tryParse('$value') ?? 0;
      final codec = first([item['codec_type'], meta['codec_type']])
          .toLowerCase();
      final rank = ['h264', 'avc', 'avc1'].contains(codec)
          ? 0
          : ['hevc', 'h265', 'hvc1', 'hev1', 'bytevc1'].contains(codec)
          ? 1
          : 2;
      if (rank == 2) continue;
      final q = first([
        item['quality_desc'],
        item['definition'],
        item['height'],
        item['vheight'],
        meta['definition'],
      ]);
      var shortSide = 0;
      for (final pair in [
        [item['vwidth'], item['vheight']],
        [item['width'], item['height']],
        [meta['vwidth'], meta['vheight']],
        [meta['width'], meta['height']],
      ]) {
        final w = number(pair[0]), h = number(pair[1]);
        if (w > 0 && h > 0) {
          shortSide = w < h ? w : h;
          break;
        }
      }
      if (!auto && wanted > 0 && shortSide < wanted) continue;
      rows.add((
        item: item,
        rank: rank,
        shortSide: shortSide,
        px: pixels(q),
        quality: q,
        size: number(meta['size']) != 0
            ? number(meta['size'])
            : number(item['size']),
      ));
    }
    rows.sort(
      (a, b) => auto
          ? (a.rank != b.rank ? a.rank.compareTo(b.rank) : b.px.compareTo(a.px))
          : (a.shortSide != b.shortSide
                ? a.shortSide.compareTo(b.shortSide)
                : a.rank.compareTo(b.rank)),
    );
    for (final row in rows) {
      final rawSpade = row.item['spade_a'] as String? ?? '';
      final spade = rawSpade.isNotEmpty
          ? rawSpade
          : _object(row.item['encrypt_info'])['spade_a'] as String? ?? '';
      if (spade.isNotEmpty) {
        try {
          if (!Spade.isValidKey(Spade.unwrapV1(decodeBase64(spade)))) continue;
        } on FormatException {
          continue;
        }
      }
      final candidates = [
        row.item['main_url'],
        row.item['backup_url'],
        ...?row.item['backup_url_list'] as List?,
      ];
      for (final candidate in candidates) {
        if (candidate is! String || candidate.isEmpty) continue;
        try {
          final decoded = seed == null
              ? candidate
                    .replaceAll(r'\/', '/')
                    .replaceAll(r'\u0026', '&')
                    .replaceAll('&amp;', '&')
              : MediaUrlDecoder.decrypt(candidate, seed);
          return VideoTrack(
            url: MediaUrlDecoder.checked(decoded, [
              'qznovelvod.com',
              'fqnovelvod.com',
              'douyinvod.com',
            ]),
            spadeA: spade,
            definition: row.quality.isEmpty ? '?' : row.quality,
            size: row.size,
          );
        } on FormatException {
          continue;
        } on ArgumentError {
          continue;
        }
      }
    }
    throw StateError('No compatible media URL/key');
  }
}

Map<String, dynamic> _object(dynamic value) {
  if (value is String) {
    value = jsonDecode(value);
  }
  return value is Map ? Map<String, dynamic>.from(value) : {};
}

void _checkCodes(Map<String, dynamic> data) {
  for (final key in ['Code', 'code']) {
    if (data[key] != null && '${data[key]}' != '0') {
      throw StateError('Upstream $key=${data[key]}');
    }
  }
}

String _fallback(dynamic value) {
  for (var depth = 0; depth < 4; depth++) {
    if (value is List) {
      value = value.isEmpty ? null : value.first;
      continue;
    }
    if (value is Map) {
      value = value['fallback_api'];
      continue;
    }
    if (value is! String || value.isEmpty) throw StateError('No fallback API');
    if (value.startsWith('{') ||
        value.startsWith('[') ||
        value.startsWith('"')) {
      value = jsonDecode(value);
      continue;
    }
    return value
        .replaceAll(r'\/', '/')
        .replaceAll(r'\u0026', '&')
        .replaceAll('&amp;', '&');
  }
  throw StateError('Invalid fallback API envelope');
}
