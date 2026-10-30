import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'network_retry.dart';

/// A playback identity the platform itself handed out.
///
/// Since 2026-10-27 the player endpoint validates the device identity carried by
/// a media-URL request: a freshly synthesised, mutually unrelated `iid`/`device_id`
/// per request is soft-blocked with HTTP 200 and zero bytes -- which is exactly
/// what used to reach the viewer as `FormatException: Unexpected end of input
/// (at character 1)`. Registering once and reusing what comes back is what makes
/// the same request answer with a real payload.
class PlaybackDevice {
  final String deviceId, iid, cdid;
  const PlaybackDevice({
    required this.deviceId,
    required this.iid,
    required this.cdid,
  });
}

/// Anonymous registration against the log endpoint, held in memory only.
///
/// The envelope mirrors the reference client: the device fingerprint is gzipped
/// as `ss_app_log`, prefixed by its own SHA-512, and sealed with AES-128-CBC
/// under `sha512(sha512(random) || salt)`. Nothing but `device_id`, `iid` and
/// `cdid` is kept, and nothing is persisted -- these are not account credentials,
/// and a token or cookie must never end up in this object.
class PlaybackDeviceRegistry {
  static const registerUrl =
      'https://log5-applog-lf.fqnovel.com/service/2/device_register/'
      '?tt_data=a&cronet_version=8d40f833_2026-03-03'
      '&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1';
  static const registerUserAgent =
      'com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; '
      'Build/BP2A.250605.031.A3)';
  static const kdfSaltHex =
      '4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524'
      'f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58';
  static const _prefix = '746305100000';

  final Dio dio;
  final Duration timeout;
  final int Function() clockMillis;
  final Uint8List Function(int) entropy;
  final String Function() uuid;

  PlaybackDeviceRegistry({
    required this.dio,
    this.timeout = const Duration(seconds: 8),
    int Function()? clockMillis,
    Uint8List Function(int)? entropy,
    String Function()? uuid,
  }) : clockMillis =
           clockMillis ?? (() => DateTime.now().millisecondsSinceEpoch),
       entropy = entropy ?? secureBytes,
       uuid = uuid ?? _uuid;

  /// One registration is shared by every concurrent caller and kept for the
  /// process; a failure is not cached, so the next request may ask again instead
  /// of bricking playback until restart.
  Future<PlaybackDevice>? _pending;
  Future<PlaybackDevice> get({CancelToken? cancelToken}) =>
      _pending ??= _register(cancelToken: cancelToken);

  /// The identity the platform last admitted to this process, if any.
  PlaybackDevice? _issued;

  /// Trade the identity that just got refused for a newly registered one.
  ///
  /// The player endpoint answers by the pair of registered `device_id`/`iid` and
  /// request bytes, so a recovery that replays the pair the answer came back
  /// empty for asks the same question. Whoever holds the refused pair drops it;
  /// a caller whose identity was already replaced by another in-flight recovery
  /// keeps the newer one instead of stampeding the registration endpoint.
  Future<PlaybackDevice> rotate({
    String? refusedDeviceId,
    CancelToken? cancelToken,
  }) {
    if (_issued == null ||
        (refusedDeviceId != null && _issued!.deviceId != refusedDeviceId)) {
      return get(cancelToken: cancelToken);
    }
    _issued = null;
    _pending = null;
    return get(cancelToken: cancelToken);
  }

  Future<PlaybackDevice> _register({CancelToken? cancelToken}) async {
    final now = clockMillis();
    final cdid = uuid();
    final body = buildBody(now, cdid);
    try {
      final response = await dio.fetch<String>(
        Options(
              method: 'POST',
              headers: requestHeaders(now, body),
              responseType: ResponseType.plain,
              followRedirects: false,
              sendTimeout: timeout,
              receiveTimeout: timeout,
            )
            .compose(
              dio.options,
              registerUrl,
              data: Stream<Uint8List>.value(body),
              cancelToken: cancelToken,
            )
            .copyWith(connectTimeout: timeout),
      );
      if (response.statusCode != 200) {
        throw StateError('register HTTP ${response.statusCode}');
      }
      final device = parseDevice(response.data ?? '', cdid);
      _issued = device;
      return device;
    } on Object {
      _pending = null;
      rethrow;
    }
  }

  /// The envelope bytes, split out so a test can replay a pinned oracle vector
  /// with the same clock, cdid and session random.
  Uint8List buildBody(int now, String cdid, {Uint8List? random}) {
    final compressed = Uint8List.fromList(
      gzip.encode(
        utf8.encode(
          jsonEncode({
            'magic_tag': 'ss_app_log',
            'header': header(now, cdid),
            '_gen_time': now,
          }),
        ),
      ),
    );
    final session = random ?? entropy(32);
    final derived = sha512([...sha512(session), ...unhex(kdfSaltHex)]);
    return Uint8List.fromList([
      ...unhex(_prefix),
      ...session,
      ...aesCbcEncryptPkcs7(
        Uint8List.sublistView(derived, 0, 16),
        Uint8List.sublistView(derived, 16, 32),
        Uint8List.fromList([...sha512(compressed), ...compressed]),
      ),
    ]);
  }

  Map<String, Object?> header(int now, String cdid) => {
    'display_name': '红果免费短剧',
    'update_version_code': 73932,
    'manifest_version_code': 73932,
    'app_version_minor': '7.3.9.32',
    'aid': 8662,
    'channel': 'update_64',
    'package': 'com.phoenix.read',
    'app_version': '7.3.9.32',
    'version_code': 73932,
    'sdk_version': '3.7.0-rc.34-fanqie-xiaoshuo',
    'sdk_target_version': 29,
    'git_hash': '3a88f4e',
    'os': 'Android',
    'os_version': '16',
    'os_api': 36,
    'device_model': '25053RT47C',
    'device_brand': 'Redmi',
    'device_manufacturer': 'Redmi',
    'cpu_abi': 'arm64-v8a',
    'release_build': 'b5e187f',
    'density_dpi': 520,
    'display_density': 'mdpi',
    'resolution': '1280x2772',
    'language': 'zh',
    'timezone': 8,
    'access': 'wifi',
    'not_request_sender': 0,
    'carrier': 'CHINA MOBILE',
    'mcc_mnc': '46000',
    'rom': 'eng.root.20231116.160340',
    'rom_version': 'W528JS release-keys',
    'cdid': cdid,
    'sig_hash': '56a962410c494bbaf0b58dba20cae56f',
    'openudid': hex(entropy(8)),
    'clientudid': uuid(),
    'ipv6_list': <Object?>[],
    'region': 'CN',
    'tz_name': 'Asia/Shanghai',
    'tz_offset': 28800,
    'sim_region': 'cn',
    'sim_serial_number': <Object?>[],
    'oaid_may_support': false,
    'req_id': uuid(),
    'device_platform': 'android',
    'custom': {
      'account_region_src': 'fallback',
      'account_region': 'cn',
      'host_bit': 64,
      'dragon_device_type': 'phone',
    },
    'pre_installed_channel': '',
    'apk_first_install_time': now,
    'is_system_app': 0,
    'sdk_flavor': 'china',
    'guest_mode': 0,
  };

  static Map<String, String> requestHeaders(int now, Uint8List body) => {
    'User-Agent': registerUserAgent,
    'Accept': 'application/json',
    'Content-Type': 'application/octet-stream;tt-data=a',
    'log-encode-type': 'gzip',
    'x-ss-dp': '8662',
    'x-ss-req-ticket': '$now',
    'x-vc-bdturing-sdk-version': '4.0.3.cn',
    'lc': '101',
    'sdk-version': '2',
    'passport-sdk-version': '5051452',
    'x-neptune': '-8|50:51:59:30:40:47:49:39',
    'x-ss-stub': hex(md5(body)).toUpperCase(),
  };

  /// `device_id_str`/`install_id_str` win over the numeric fields, which lose
  /// precision past 2^53 in any JSON reader that is not arbitrary-precision. The
  /// `cdid` stays the one this process generated; the response's is not trusted.
  static PlaybackDevice parseDevice(String text, String cdid) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      decoded = null;
    }
    final data = decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    final code = data == null ? null : (data['code'] ?? data['Code']);
    if (data == null || data.isEmpty || (code != null && '$code' != '0')) {
      throw const IncompleteCatalogResponse('播放设备注册未返回数据，请稍后重试');
    }
    String identifier(String textual, String numeric) {
      for (final value in [data[textual], data[numeric]]) {
        if (RegExp(r'^[1-9]\d{0,29}$').hasMatch('$value')) return '$value';
      }
      return '';
    }

    final deviceId = identifier('device_id_str', 'device_id');
    final iid = identifier('install_id_str', 'install_id');
    if (deviceId.isEmpty || iid.isEmpty) {
      throw const IncompleteCatalogResponse('播放设备注册失败，请稍后重试');
    }
    return PlaybackDevice(deviceId: deviceId, iid: iid, cdid: cdid);
  }
}

String _uuid() {
  final bytes = secureBytes(16);
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final value = hex(bytes);
  return '${value.substring(0, 8)}-${value.substring(8, 12)}'
      '-${value.substring(12, 16)}-${value.substring(16, 20)}'
      '-${value.substring(20)}';
}
