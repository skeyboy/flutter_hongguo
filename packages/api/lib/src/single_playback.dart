// Legacy single-episode request construction, mirroring hongguo-android
// AppSource.singleUrl / singleBody / fetchSingle (GPL-3.0-only). The signer
// lives in hongguo_core (player_sign.dart) and is byte-for-byte checked
// against PlayerSignTest.java. This file only builds the sorted query, the
// body and the header set; it never invents a signature.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:hongguo_core/hongguo_core.dart';

import 'playback_device.dart';
import 'video_model_client.dart'
    show VideoRequest, VideoRequestBuilder, encodeQueryPart;

class SinglePlaybackEndpoints {
  /// The single-episode hop keeps the multi host: same VIDEO_API_HOST.
  static const url =
      'https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_model/v1/';

  /// The player identity for this hop is one version behind the main client.
  static const versionCode = '73532';
  static const versionName = '7.3.5.32';

  /// VIDEO_UA with `71332` replaced by the player version code.
  static const userAgent =
      'com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; '
      'Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 '
      'QuicVersion:c67e9834 2025-09-08)';

  /// The seven player-only fields singleUrl strips from the device base.
  static const _removedFields = [
    'host_abi',
    'dragon_device_type',
    'pv_player',
    'compliance_status',
    'need_personal_recommend',
    'player_so_load',
    'is_android_pad_screen',
  ];
}

/// Request body for the single-episode hop: one vid, JSON, uncompressed.
Uint8List singlePlaybackBody(String vid) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'video_id': vid,
      'content_type': 1,
      'biz_param': {'need_all_video_definition': true, 'video_platform': 3},
    }),
  ),
);

/// Builds the fully signed single-episode request. Upstream sorts the query
/// with a TreeMap — the signature is computed over exactly these sorted
/// bytes — so the key order here is a sort, not the device template order.
VideoRequest singlePlaybackRequest(
  String vid, {
  required PlaybackDevice identity,
  required int nowMillis,
  Map<String, String> Function()? deviceFactory,
}) {
  final query = <String, String>{
    ...(deviceFactory ?? VideoRequestBuilder.defaultDevice)(),
  };
  for (final field in SinglePlaybackEndpoints._removedFields) {
    query.remove(field);
  }
  query['version_code'] = SinglePlaybackEndpoints.versionCode;
  query['manifest_version_code'] = SinglePlaybackEndpoints.versionCode;
  query['update_version_code'] = SinglePlaybackEndpoints.versionCode;
  query['version_name'] = SinglePlaybackEndpoints.versionName;
  query['device_id'] = identity.deviceId;
  query['iid'] = identity.iid;
  query['_rticket'] = '$nowMillis';
  final keys = query.keys.toList()..sort();
  final queryString = keys
      .map(
        (key) =>
            '${encodeQueryPart(key, keepLiteralStar: true)}='
            '${encodeQueryPart(query[key]!, keepLiteralStar: true)}',
      )
      .join('&');
  final url = '${SinglePlaybackEndpoints.url}?$queryString';
  final body = singlePlaybackBody(vid);
  final headers = LegacyPlayerSign.headers(
    query: queryString,
    body: body,
    nowMillis: nowMillis,
    deviceId: identity.deviceId,
  );
  return VideoRequest(url, body, {
    'User-Agent': SinglePlaybackEndpoints.userAgent,
    'Accept': 'application/json',
    'Content-Type': 'application/json; charset=utf-8',
    'x-xs-from-web': '0',
    'sdk-version': '2',
    ...headers,
  });
}
