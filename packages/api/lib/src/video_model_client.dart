import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'media_url_policy.dart';
import 'network_retry.dart';
import 'upstream_failure.dart' show classifyUpstreamFailure;
import 'playback_device.dart';
import 'playback_routes.dart';
import 'request_control.dart';
import 'web_source.dart';

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

/// The player's own query encoder. `keepLiteralStar` reproduces the one place
/// where it differs from RFC 3986 percent-encoding: the app's `quote()` leaves
/// `*` in the query bytes (`resolution=1280*2772`), and this endpoint verifies
/// signatures over the bytes it received, so re-encoding it refuses the request.
String encodeQueryPart(String value, {bool keepLiteralStar = false}) =>
    utf8.encode(value).map((b) {
      final safe =
          b >= 65 && b <= 90 ||
          b >= 97 && b <= 122 ||
          b >= 48 && b <= 57 ||
          [45, 46, 95, 126].contains(b) ||
          keepLiteralStar && b == 42;
      return safe
          ? String.fromCharCode(b)
          : '%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}';
    }).join();

class VideoRequestBuilder {
  static const endpoint =
      'https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/';

  /// The player's own UA. This hop pairs it with the signed request: the device
  /// build the list/detail traffic reports is a different one, and the player
  /// answers this request only to its own.
  static const playbackUserAgent =
      'com.phoenix.read/71532 (Linux; U; Android 9; SM-N9860; '
      'Build/PQ3A.190705.10241111;tt-ok/3.12.13.20)';

  final AppSettings protocol;
  final String playbackUA;
  final int Function() clockMillis;
  final Map<String, String> Function() deviceFactory;
  final PureSign signer;
  VideoRequestBuilder({
    this.protocol = const AppSettings(),
    String? playbackUserAgent,
    int Function()? clockMillis,
    Map<String, String> Function()? deviceFactory,
    PureSign? signer,
  }) : playbackUA = playbackUserAgent ?? VideoRequestBuilder.playbackUserAgent,
       clockMillis =
           clockMillis ?? (() => DateTime.now().millisecondsSinceEpoch),
       deviceFactory = deviceFactory ?? defaultDevice,
       signer = signer ?? PureSign() {
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
  VideoRequest build(
    String vid, {
    required PlaybackDevice device,
    String? host,
  }) {
    if (!RegExp(r'^\d{1,30}$').hasMatch(vid)) {
      throw ArgumentError.value(vid, 'vid');
    }
    if (host != null &&
        !RegExp(r'^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.fqnovel\.com$')
            .hasMatch(host)) {
      throw ArgumentError.value(host, 'host');
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
      'cdid': device.cdid,
    };
    final khronos = clockMillis() ~/ 1000;
    final ticketBase = clockMillis();
    // Upstream admits one signature branch on this hop, and the branch is a
    // function of the query bytes, so `_rticket` -- the only field the player
    // rolls per try -- is searched until the query lands on it.
    for (var attempt = 0; attempt < 128; attempt++) {
      final ticket = ticketBase + attempt;
      final params = {...query, 'ts': '$khronos', '_rticket': '$ticket'};
      final url =
          'https://${host ?? protocol.videoHost}/novel/player/multi_video_model/v1/'
          '?${params.entries.map((e) => '${encodeQueryPart(e.key, keepLiteralStar: true)}'
              '=${encodeQueryPart(e.value, keepLiteralStar: true)}').join('&')}';
      if (signer.branchOf(url, body, khronos) != 0) continue;
      return VideoRequest(url, body, {
        'User-Agent': playbackUA,
        'Accept': 'application/json; charset=utf-8,application/x-protobuf',
        'Content-Type': 'application/json; charset=UTF-8',
        'x-ss-req-ticket': '$ticket',
        'sdk-version': '2',
        'x-xs-from-web': '0',
        ...signer.sign(url, body, khronos),
        'x-tt-dt': '',
        'x-tt-store-region': 'cn',
        'x-tt-store-region-src': 'did',
      });
    }
    throw const IncompleteCatalogResponse('播放信息签名暂时无法生成，请稍后重试');
  }
}

class VideoQuality {
  final String value, label;
  final int width, height;
  const VideoQuality(this.value, this.label, {this.width = 0, this.height = 0});
}

/// 媒体封装格式。默认是红果的 [mp4]（含 CENC 加密分片）；[hls] 由第三方/
/// 自定义源使用。P0 只声明类型，HLS 播放通道在 P2 单独评估，未落地前不得
/// 把 hls 轨当成已支持。
enum VideoFormat { mp4, hls }

class VideoTrack {
  final Uri url;
  final String spadeA, definition;

  /// 官网直链層需要官方桌面 UA 与官网 Referer 才会回完整文件；App 取址的
  /// CDN 两项留空，下载层按现有约定补默认值。
  final String userAgent, referer;

  /// 这条地址来自官网层（明文 MP4）。下载层的 CDN 白名单要据此放宽到
  /// [webMediaDomains]，否则官网 CDN 会在下载前被判成非法上游。
  ///
  /// 多源接入后优先用 [policy] 判定白名单；此布尔仅为向后兼容保留，
  /// 红果官网轨仍置 true。
  final bool fromWeb;
  final int size;

  /// 归属源（hongguo/xifan/...），用于缓存键命名空间与诊断。默认红果。
  final String source;

  /// 封装格式。默认 mp4 = 现有行为。
  final VideoFormat format;

  /// 自定义源多线路候选；null 表示单线路。
  final List<VideoTrack>? candidates;

  /// 逐轨媒体安全策略；null 时下载层回退到 [fromWeb] 的旧布尔判定，
  /// 保住红果字节级行为。
  final MediaUrlPolicy? policy;

  bool get encrypted => spadeA.isNotEmpty;

  /// 返回替换指定字段后的副本。自定义源多线路候选与测试替身需要基于主轨
  /// 生成变体，保持不可变语义。
  VideoTrack copyWith({
    Uri? url,
    String? spadeA,
    String? definition,
    int? size,
    String? userAgent,
    String? referer,
    bool? fromWeb,
    String? source,
    VideoFormat? format,
    List<VideoTrack>? candidates,
    MediaUrlPolicy? policy,
  }) => VideoTrack(
    url: url ?? this.url,
    spadeA: spadeA ?? this.spadeA,
    definition: definition ?? this.definition,
    size: size ?? this.size,
    userAgent: userAgent ?? this.userAgent,
    referer: referer ?? this.referer,
    fromWeb: fromWeb ?? this.fromWeb,
    source: source ?? this.source,
    format: format ?? this.format,
    candidates: candidates ?? this.candidates,
    policy: policy ?? this.policy,
  );

  const VideoTrack({
    required this.url,
    required this.spadeA,
    required this.definition,
    required this.size,
    this.userAgent = '',
    this.referer = '',
    this.fromWeb = false,
    this.source = 'hongguo',
    this.format = VideoFormat.mp4,
    this.candidates,
    this.policy,
  });
}

/// One answered playback info, with the moment it stops being reusable. Held
/// across client rebuilds by the runtime, so a settings change in the middle of
/// a batch does not reopen every episode the upstream already answered for.
typedef PlaybackInfoEntry = ({DateTime expires, Map<String, dynamic> value});

/// Native direct-upstream POC. Web should use a remote API adapter instead.
/// Redirects are disabled so an unchecked location never receives signed headers.
class VideoModelClient {
  final Dio dio;
  final VideoRequestBuilder builder;
  final NetworkRetry retry;
  final PlaybackDeviceRegistry devices;
  final CatalogRequests _requests;

  /// How long one vid's answered playback info is kept. Every uncached episode
  /// of a batch asks this hop, and each ask costs a fresh device registration
  /// plus a signed POST; the answer itself does not change episode by episode
  /// within a short window. Kept well under the signed media URL's own life, so
  /// an old URL costs a re-ask, never a broken play.
  final Duration trackTtl;
  final DateTime Function() now;
  final Map<String, PlaybackInfoEntry> _info;

  /// 官网直链层与旧接口兜底层的开关。生产装配默认全开（对齐参考 8.0 的
  /// 三层取源）；离线测试默认关闭，让协议测试继续只覆盖 App 层的既有
  /// 请求形态，三层自身行为由专门测试覆盖。
  final bool useWebSource, useLegacySource;

  /// Diagnostic-only sink: receives route IDs and failure kinds, never URLs,
  /// signatures or cookies. Kept out of [sources], which is user-facing text.
  final void Function(String routeId, String failureType)? onRouteFailure;

  /// A batch resolves every episode it touches, so an unbounded table would
  /// keep the whole drama's answers for the length of the session.
  static const _infoCeiling = 256;
  static const _infoByteCeiling = 4 * 1024 * 1024;
  final _infoBytes = <String, int>{};
  int _infoByteTotal = 0;

  static int _estimateInfo(Map<String, dynamic> value) {
    try {
      return jsonEncode(value).length;
    } on Object {
      return 1024;
    }
  }

  void _forgetInfo(String vid) {
    _info.remove(vid);
    _infoByteTotal -= _infoBytes.remove(vid) ?? 0;
  }

  VideoModelClient({
    required this.dio,
    VideoRequestBuilder? builder,
    NetworkRetry? retry,
    PlaybackDeviceRegistry? devices,
    Duration requestDeadline = const Duration(seconds: 20),
    this.trackTtl = const Duration(minutes: 3),
    DateTime Function()? now,
    void Function(MetadataTiming)? onTiming,
    Map<String, PlaybackInfoEntry>? info,
    this.useWebSource = true,
    this.useLegacySource = true,
    this.onRouteFailure,
  }) : builder = builder ?? VideoRequestBuilder(),
       retry = retry ?? playbackRetry(),
       devices = devices ?? PlaybackDeviceRegistry(dio: dio),
       now = now ?? DateTime.now,
       _info = info ?? <String, PlaybackInfoEntry>{},
       _requests = CatalogRequests(
         deadline: requestDeadline,
         onTiming: onTiming,
       );
  void close() => _requests.cancelAll();

  /// The recovery this hop gets, which is not a catalog hop's: the player
  /// answers by a window of seconds rather than by the request, so the tries
  /// are spread past the ~1s the catalog recovery takes, and the deadline has
  /// room for the extra registration a refused identity costs.
  static NetworkRetry playbackRetry() => NetworkRetry(
    maxRecoveries: 3,
    delays: [
      Duration(milliseconds: 700 + Random().nextInt(201)),
      Duration(milliseconds: 2000 + Random().nextInt(301)),
      Duration(milliseconds: 4000 + Random().nextInt(501)),
    ],
  );

  /// Answers kept per vid are dropped after [trackTtl], or when the episode is
  /// declined upstream or its file is deleted.
  Future<Map<String, dynamic>> fetchVideoInfo(
    String vid, {
    String? host,
  }) async {
    final kept = _info[vid];
    if (kept != null && kept.expires.isAfter(now())) return kept.value;
    try {
      final value = await _requests.run(
        'video:$vid${host == null ? '' : ':alt-host'}',
        () => _fetchVideoInfo(vid, host: host),
        label: 'video.metadata',
      );
      final clock = now();
      for (final entry in _info.entries.toList()) {
        if (!entry.value.expires.isAfter(clock)) _forgetInfo(entry.key);
      }
      final size = _estimateInfo(value);
      while (_info.isNotEmpty &&
          (_info.length >= _infoCeiling ||
              _infoByteTotal + size > _infoByteCeiling)) {
        // The answer closest to its own end goes first: the queue reaches the
        // next episode long before it revisits that one.
        final oldest = _info.entries.reduce(
          (a, b) => a.value.expires.isBefore(b.value.expires) ? a : b,
        );
        _forgetInfo(oldest.key);
      }
      _info[vid] = (expires: clock.add(trackTtl), value: value);
      _infoBytes[vid] = size;
      _infoByteTotal += size;
      return value;
    } on PlaybackUnavailable {
      // A refusal is an answer about this episode, so a kept record for it can
      // only be an old one; drop it and let the next ask read upstream again.
      _forgetInfo(vid);
      rethrow;
    }
  }

  Duration _timeout(int maximum) => RequestBudget.current.timeout(
    Duration(
      seconds: builder.protocol.timeoutSeconds < maximum
          ? builder.protocol.timeoutSeconds
          : maximum,
    ),
  );

  Future<Map<String, dynamic>> _fetchVideoInfo(
    String vid, {
    String? host,
  }) async {
    final budget = RequestBudget.current;
    // Both hops answer HTTP 200 with nothing often enough that a bare decode
    // used to reach the viewer as `FormatException: Unexpected end of input`.
    // The status check and the decode are inside the recovery, so an empty or
    // truncated envelope -- not only a transport failure -- gets its bounded
    // tries within this request's own deadline. A response that *did* carry an
    // envelope and declined the episode is not in that category: repeating it
    // changes nothing, so it stops as PlaybackUnavailable.
    final model = await retry.run(() async {
      // The answer is keyed to the registered `device_id`/`iid` pair and to a
      // window of seconds: a pair that already answered comes back empty, so
      // every try -- first included -- takes a registration this process has
      // not spent, and a refusal costs only the ask it was refused on.
      final device = await budget.measure(
        'register',
        () => devices.get(cancelToken: budget.token),
      );
      final request = builder.build(vid, device: device, host: host);
      try {
        final model = await budget.transport(() async {
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
        });
        devices.markSuccess(device);
        return model;
      } on Object {
        devices.discard(device);
        rethrow;
      }
    }, budget: budget);
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

  /// 有序播放路由。默认三层与历史行为一致；`extended` 才启用 Android 的
  /// v5 / 老单集 / 换主机 / 官网匿名路径。任一路由失败只写诊断清单，最终
  /// 以第一条 App 错误的原类型抛出，避免把「可重试」压平成「不可播」。
  ///
  /// [preferApp] 给「边下边看」用：渐进通道只认带 CENC 的分片，官网直链是
  /// 明文 MP4，必须整段下完才能播，所以把官网层退到回退位。
  Future<VideoTrack> fetchTrack(
    String vid, {
    String quality = 'best',
    bool preferApp = false,
    String? seriesId,
  }) => _requests.run(
    'track:$vid${preferApp ? ':app-first' : ''}',
    () => _fetchTrack(
      vid,
      quality: quality,
      preferApp: preferApp,
      seriesId: seriesId,
    ),
    label: 'video.track',
  );

  Future<VideoTrack> _fetchTrack(
    String vid, {
    String quality = 'best',
    bool preferApp = false,
    String? seriesId,
  }) async {
    if (!RegExp(r'^\d{1,30}$').hasMatch(vid)) {
      throw ArgumentError.value(vid, 'vid');
    }
    final sources = <String>[];
    Object? appError;
    final webFirst =
        !preferApp &&
        (quality.isEmpty || quality == 'best' || quality == 'auto');
    final routes = playbackRoutes(
      webFirst: webFirst,
      set: builder.protocol.playbackRouteSet,
    );
    for (final route in routes) {
      if (route.needsSeriesId && (seriesId == null || seriesId.isEmpty)) {
        continue;
      }
      RequestBudget.current.check();
      try {
        switch (route.id) {
          case PlaybackRouteId.webPublic:
            if (!useWebSource) continue;
            final web = await _webTrack(vid, sources);
            if (web != null) return web;
          case PlaybackRouteId.appMultiV1:
          case PlaybackRouteId.appMultiV1Hl:
            try {
              return selectTrack(
                await fetchVideoInfo(vid, host: route.host),
                quality: quality,
              );
            } on Object catch (error) {
              appError = error;
              rethrow;
            }
          case PlaybackRouteId.legacyPreload:
            if (!useLegacySource) continue;
            final legacy = await _legacyTrack(vid, sources);
            if (legacy != null) return legacy;
          default:
            // v5 / 老单集 / 官网匿名路由的签名器尚未接入。只记路由 ID，
            // 不把未实现的请求伪装成成功，也不输出 URL 或签名头。
            onRouteFailure?.call(route.id.label, 'unimplemented');
        }
      } on Object catch (error) {
        onRouteFailure?.call(
          route.id.label,
          classifyUpstreamFailure(error)?.diagnosticId ??
              error.runtimeType.toString(),
        );
      }
    }
    if (appError is PlaybackUnavailable) {
      throw PlaybackUnavailable(
        sources.isEmpty
            ? appError.message
            : '${appError.message}；${sources.join('；')}',
      );
    }
    throw appError ?? const PlaybackUnavailable('暂时取不到这一集的播放信息，请稍后重试');
  }

  /// 第 1 层：官网公开兜底接口（`/api/video/protected/fallback-play-info`）。
  /// 免签 POST `{item_id: vid}`，返回的 main_url 是明文 MP4，无 CENC。
  /// 任何失败都只记入 [sources] 并返回 null——官网层是加速与救场通道，
  /// 不许把它的失败伪装成本集不可播。
  Future<VideoTrack?> _webTrack(String vid, List<String> sources) async {
    final budget = RequestBudget.current;
    // 第 1 路：公开兜底接口（player 页同款，免签 POST）。命中率最高、最便宜。
    try {
      final response = await budget.transport(
        () => dio.fetch<String>(
          Options(
                method: 'POST',
                headers: {
                  'User-Agent': webUserAgent,
                  'Accept': 'application/json',
                  'Content-Type': 'application/json',
                  'Referer': webReferer,
                },
                responseType: ResponseType.plain,
                followRedirects: false,
                sendTimeout: _timeout(5),
                receiveTimeout: _timeout(6),
              )
              .compose(
                dio.options,
                '$siteOrigin$publicFallbackPlayPath',
                data: Stream<Uint8List>.value(
                  Uint8List.fromList(utf8.encode(jsonEncode({'item_id': vid}))),
                ),
                cancelToken: budget.token,
              )
              .copyWith(connectTimeout: _timeout(5)),
        ),
      );
      if (response.statusCode != 200) {
        sources.add('官网：HTTP ${response.statusCode}');
      } else {
        final play = parsePublicFallbackPlayUrl(
          _envelope(response.data),
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        );
        if (play == null) {
          sources.add('官网：未提供可用片源');
        } else {
          return VideoTrack(
            url: Uri.parse(play.url),
            spadeA: '',
            definition: play.quality,
            size: 0,
            userAgent: webUserAgent,
            referer: webReferer,
            fromWeb: true,
          );
        }
      }
    } on Object catch (error) {
      sources.add('官网：${_sourceBrief(error)}');
    }
    // 第 2 路：公开播放页的 ld+json。走 `_` 路由，不要求调用方带 sid；页面
    // 自己给出 canonical 身份，对不上就不采信——只信接口不认的那部分。
    try {
      final page = await budget.transport(
        () => dio.get<String>(
          '$siteOrigin/player/_/$vid',
          cancelToken: budget.token,
          options: Options(
            headers: {'User-Agent': webUserAgent, 'Referer': webReferer},
            responseType: ResponseType.plain,
            followRedirects: false,
            receiveTimeout: _timeout(4),
          ),
        ),
      );
      final html = page.data ?? '';
      final status = page.statusCode ?? 0;
      final series = status == 200 ? playablePageSeries(html, vid) : null;
      final url = series == null
          ? null
          : extractLdJsonPlayUrl(html, series, vid);
      if (url == null) {
        sources.add(status == 200 ? '官网播放页：没有可播直链' : '官网播放页：HTTP $status');
      } else {
        return VideoTrack(
          url: Uri.parse(url),
          spadeA: '',
          definition: 'web',
          size: 0,
          userAgent: webUserAgent,
          referer: webReferer,
          fromWeb: true,
        );
      }
    } on Object catch (error) {
      sources.add('官网播放页：${_sourceBrief(error)}');
    }
    return null;
  }

  /// 第 3 层：旧接口 `multi_video_model/preload/v1`，免签。上游偶尔只对
  /// 这一跳留有答案（参考 8.0 保留它的原因），因此作为最后兜底而非回退。
  Future<VideoTrack?> _legacyTrack(String vid, List<String> sources) async {
    final budget = RequestBudget.current;
    try {
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
            'dr_scene': 'preload',
            'mixed_video_id_map': {
              '1004': [vid],
            },
          }),
        ),
      );
      final response = await budget.transport(
        () => dio.fetch<String>(
          Options(
                method: 'POST',
                headers: {
                  'User-Agent': builder.playbackUA,
                  'Accept':
                      'application/json; charset=utf-8,application/x-protobuf',
                  'Content-Type': 'application/json; charset=UTF-8',
                },
                responseType: ResponseType.plain,
                followRedirects: false,
                sendTimeout: _timeout(5),
                receiveTimeout: _timeout(8),
              )
              .compose(
                dio.options,
                'https://${builder.protocol.videoHost}'
                '/novel/player/multi_video_model/preload/v1/'
                '?_rticket=${builder.clockMillis()}',
                data: Stream<Uint8List>.value(body),
                cancelToken: budget.token,
              )
              .copyWith(connectTimeout: _timeout(5)),
        ),
      );
      if (response.statusCode != 200) {
        sources.add('旧接口：HTTP ${response.statusCode}');
        return null;
      }
      final outer = _envelope(response.data);
      // 业务码非 0 是一个答案而不是传输故障：不再重试，直接记为该层失败。
      final rawCode = outer['code'];
      final numeric = rawCode is num ? rawCode : num.tryParse('$rawCode');
      if (numeric != null && numeric != 0) {
        sources.add('旧接口：业务码 $numeric');
        return null;
      }
      final data = _envelope(outer['data']);
      final entry = _envelope(data[vid]);
      final model = _envelope(entry['video_model']);
      if (model.isEmpty) {
        sources.add('旧接口：未返回片源模型');
        return null;
      }
      return selectTrack(model, quality: 'best');
    } on Object catch (error) {
      sources.add('旧接口：${_sourceBrief(error)}');
      return null;
    }
  }

  static String _sourceBrief(Object error) {
    final text = '$error';
    return text.length <= 120 ? text : '${text.substring(0, 120)}…';
  }

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
            url: MediaUrlDecoder.checked(decoded, appMediaDomains),
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
