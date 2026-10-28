import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'network_retry.dart';
import 'playback_device.dart';
import 'request_control.dart';

/// The URL, its exact body bytes and the exact headers, frozen together: the
/// upstream answers by the pair, so a query rebuilt after signing (or after the
/// identity was chosen) is a different request.
class VideoRequest {
  final String url;
  final Uint8List body;
  final Map<String, String> headers;
  VideoRequest(this.url, Uint8List body, Map<String, String> headers)
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

  /// The player's own UA. Since 2026-10-27 this request is only answered when it
  /// is anonymous -- registered device identity, no signature headers -- and the
  /// upstream pairs that shape with this UA, which is a different build than the
  /// one the list/detail traffic reports.
  static const playbackUserAgent =
      'com.phoenix.read/71532 (Linux; U; Android 9; SM-N9860; '
      'Build/PQ3A.190705.10241111;tt-ok/3.12.13.20)';

  final AppSettings protocol;
  final String playbackUA;
  final int Function() clockMillis;
  final Map<String, String> Function() deviceFactory;
  VideoRequestBuilder({
    this.protocol = const AppSettings(),
    String? playbackUserAgent,
    int Function()? clockMillis,
    Map<String, String> Function()? deviceFactory,
  }) : playbackUA = playbackUserAgent ?? VideoRequestBuilder.playbackUserAgent,
       clockMillis =
           clockMillis ?? (() => DateTime.now().millisecondsSinceEpoch),
       deviceFactory = deviceFactory ?? defaultDevice {
    protocol.validate();
  }

  /// The fixed device template the player reports. `device_id` and `iid` are
  /// deliberately absent: they come from the anonymous registration, and a
  /// synthesised pair per request is what upstream started refusing.
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
  };
  VideoRequest build(String vid, {required PlaybackDevice device}) {
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
    // The registered identity is appended after the fixed template, in the order
    // the player itself sends it: query encoding is positional, and this request
    // is answered by the pair of URL bytes and body bytes.
    final query = {
      ...deviceFactory(),
      'version_code': protocol.videoVersionCode,
      'version_name': protocol.videoVersion,
      'manifest_version_code': protocol.videoVersionCode,
      'update_version_code': protocol.videoVersionCode,
      'pv_player': protocol.videoVersionCode,
      'device_id': device.deviceId,
      'iid': device.iid,
      '_rticket': '${clockMillis()}',
    };
    final url =
        'https://${protocol.videoHost}/novel/player/multi_video_model/v1/'
        '?${query.entries.map((e) => '${encodeQueryPart(e.key)}=${encodeQueryPart(e.value)}').join('&')}';
    // No signature headers and no session: this endpoint started refusing the
    // signed shape on 2026-10-27, and the anonymous one is what answers.
    return VideoRequest(url, body, {
      'User-Agent': playbackUA,
      'Accept': 'application/json; charset=utf-8,application/x-protobuf',
      'Content-Type': 'application/json; charset=UTF-8',
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
  final NetworkRetry retry;
  final PlaybackDeviceRegistry devices;
  final CatalogRequests _requests;
  VideoModelClient({
    required this.dio,
    VideoRequestBuilder? builder,
    NetworkRetry? retry,
    PlaybackDeviceRegistry? devices,
    Duration requestDeadline = const Duration(seconds: 12),
    void Function(MetadataTiming)? onTiming,
  }) : builder = builder ?? VideoRequestBuilder(),
       retry = retry ?? NetworkRetry(),
       devices = devices ?? PlaybackDeviceRegistry(dio: dio),
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
    // One process-wide registration buys the identity this endpoint insists on;
    // it is measured inside the same deadline rather than retried on its own, so
    // a log endpoint that is not answering cannot turn into a request storm.
    final device = await budget.measure(
      'register',
      () => devices.get(cancelToken: budget.token),
    );
    final request = builder.build(vid, device: device);
    // Both hops answer HTTP 200 with nothing often enough that a bare decode
    // used to reach the viewer as `FormatException: Unexpected end of input`.
    // The status check and the decode are inside the recovery, so an empty or
    // truncated envelope -- not only a transport failure -- gets its two bounded
    // tries within this request's own deadline, exactly as the catalog's
    // metadata hops do. A response that *did* carry an envelope and declined the
    // episode is not in that category: repeating it changes nothing, so it stops
    // as PlaybackUnavailable.
    final model = await retry.run(
      () => budget.transport(() async {
        final first = await dio.fetch<String>(
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
        );
        if (first.statusCode != 200) {
          throw const PlaybackUnavailable('暂时取不到这一集的播放信息，请稍后重试');
        }
        final outer = _envelope(first.data);
        _checkCodes(outer);
        // The answer is nested three levels deep, and any of those levels can
        // come back empty -- an envelope with no `data` is how upstream refuses
        // an identity it does not recognise, the same missing answer as an empty
        // body, so it is named and recovered the same way.
        final data = _envelope(outer['data']);
        if (data.isEmpty) {
          throw const IncompleteCatalogResponse('播放信息未返回数据，请稍后重试');
        }
        final entry = _envelope(data[vid]);
        if (entry.isEmpty) {
          throw const PlaybackUnavailable('这一集暂时没有可播的片源，请稍后重试或换一集');
        }
        return _envelope(entry['video_model']);
      }),
      budget: budget,
    );
    // The newer answer carries the tracks inside video_model itself; only the
    // shape that hands back a fallback_api still needs a second hop. Asking for
    // one when the list is already here would drop playback on an endpoint that
    // has nothing to add.
    final inlined = model['video_list'];
    final hasList =
        (inlined is Map && inlined.isNotEmpty) ||
        (inlined is List && inlined.isNotEmpty);
    if (hasList) return model;
    if (model.isEmpty) {
      throw const PlaybackUnavailable('这一集暂时没有可播的片源，请稍后重试或换一集');
    }
    final uri = MediaUrlDecoder.checked(_fallback(model['fallback_api']), [
      'fqnovel.com',
      'snssdk.com',
    ]);
    final data = await retry.run(
      () => budget.transport(() async {
        final second = await dio.fetch<String>(
          Options(
                headers: {'User-Agent': builder.protocol.videoUserAgent},
                responseType: ResponseType.plain,
                followRedirects: false,
                receiveTimeout: _timeout(8),
              )
              .compose(dio.options, uri.toString(), cancelToken: budget.token)
              .copyWith(connectTimeout: _timeout(5)),
        );
        if (second.statusCode != 200) {
          throw const PlaybackUnavailable('暂时取不到这一集的播放信息，请稍后重试');
        }
        final result = _envelope(second.data);
        _checkCodes(result);
        final info = _envelope(result['video_info']);
        _checkCodes(info);
        // The envelope inside this body is nested two more levels, and any of
        // them can arrive as an empty string from upstream -- the same missing
        // answer, so it is named the same way and recovered the same way.
        return _envelope(info['data']);
      }),
      budget: budget,
    );
    if (data.isEmpty) {
      throw const PlaybackUnavailable('这一集暂时没有可播的片源，请稍后重试或换一集');
    }
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
    final rows = _videoList(info);
    for (var index = 0; index < rows.length; index++) {
      final item = _object(rows[index]);
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
          'video_list': {'$index': rows[index]},
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
    for (final value in _videoList(info)) {
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

/// One envelope the player's own answer is built from: the body of a hop or a
/// level nested inside it. Decoded in one place because upstream answers these
/// with HTTP 200 and nothing -- or with a body cut off mid-write -- often enough
/// that a bare `jsonDecode` used to surface to the viewer as
/// `FormatException: Unexpected end of input (at character 1)`. This marker is
/// what `NetworkRetry` gives two bounded tries and what the player overlay
/// prints, so a missing answer has to be named in the viewer's language.
Map<String, dynamic> _envelope(dynamic value) {
  if (value is String) {
    if (value.trim().isEmpty) {
      throw const IncompleteCatalogResponse('播放信息未返回数据，请稍后重试');
    }
    try {
      value = jsonDecode(value);
    } on FormatException {
      throw const IncompleteCatalogResponse('播放信息返回不完整，请重试');
    }
  }
  return value is Map ? Map<String, dynamic>.from(value) : {};
}

/// A refusal that already carries an answer: the envelope arrived, declined this
/// episode, and repeating the request would ask the same question. The message is
/// what the player overlay prints under 暂时无法播放, so it is written in the
/// viewer's language rather than as a Dart error name.
class PlaybackUnavailable implements Exception {
  final String message;
  const PlaybackUnavailable(this.message);
  @override
  String toString() => message;
}

/// The rows of `video_list`, which the fallback hop returns as an object keyed by
/// resolution and the inlined model returns as an array -- the same rows either
/// way, so both are read as their values.
List<dynamic> _videoList(Map<String, dynamic> info) {
  final value = info['video_list'];
  if (value is Map) return value.values.toList();
  if (value is List) return value;
  return const [];
}

/// A field the upstream may simply leave out: an empty or unreadable value here
/// is one row without an optional envelope, not a missing answer for the whole
/// request, so it falls back to an empty map rather than to the retry marker.
Map<String, dynamic> _object(dynamic value) {
  if (value is String) {
    if (value.trim().isEmpty) return {};
    try {
      value = jsonDecode(value);
    } on FormatException {
      return {};
    }
  }
  return value is Map ? Map<String, dynamic>.from(value) : {};
}

/// A business refusal inside an envelope that did arrive. Repeating the question
/// changes nothing, so this is not the retry marker; the message replaces the raw
/// upstream code because it is what the viewer reads under 暂时无法播放.
void _checkCodes(Map<String, dynamic> data) {
  for (final key in ['Code', 'code']) {
    if (data[key] != null && '${data[key]}' != '0') {
      throw const PlaybackUnavailable('这一集暂时不能播放，请稍后重试或换一集');
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
