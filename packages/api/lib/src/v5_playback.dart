// v5 playback request construction, mirroring hongguo-android
// api/playback/MobilePlayerV5.kt (GPL-3.0-only). The signer itself lives in
// hongguo_core (playback_sign.dart) and has been byte-for-byte checked against
// the Android carrier/digest vectors. This file only builds the query and body
// bytes and hands them to the signer; it never invents a signature.
library;

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:hongguo_core/hongguo_core.dart';

/// v5 player/v1 and video_tab endpoints. Kept as constants so diagnostics can
/// identify the route by ID without leaking a full URL.
class V5PlaybackEndpoints {
  static const player =
      'https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1';
  static const videoTab =
      'https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/video_tab/multi_video_model/v1/';
  static const playerUserAgent =
      'com.phoenix.read/73932 (Linux; U; Android 12; zh_CN_#Hans; PGT-AN10; '
      'Build/V417IR;tt-ok/3.12.13.20)';
  static const tabUserAgent =
      'com.phoenix.read/73932 (Linux; U; Android 16; zh_CN; 25053RT47C; '
      'Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 '
      'QuicVersion:c67e9834 2025-09-08)';
}

/// The full device query the official v5 client sends, in insertion order.
/// Order is part of the signature: query encoding is positional. `egdi` is
/// appended only when present, matching the Android `deviceQuery`.
Map<String, String> v5DeviceQuery({
  required String deviceId,
  required String iid,
  required String cdid,
  String? egdi,
}) {
  final values = <String, String>{
    'device_platform': 'android',
    'os': 'android',
    'ssmix': 'a',
    'cdid': cdid,
    'channel': 'vivo_8662_64',
    'aid': '8662',
    'app_name': 'novelread',
    'version_code': '74332',
    'version_name': '7.4.3.32',
    'manifest_version_code': '74332',
    'update_version_code': '74332',
    'resolution': '1920*1080',
    'dpi': '280',
    'device_type': 'PGT-AN10',
    'device_brand': 'HONOR',
    'language': 'zh',
    'os_api': '31',
    'os_version': '12',
    'ac': 'wifi',
    'host_abi': 'arm64-v8a',
    'dragon_device_type': 'phone',
    'pv_player': '74332',
    'compliance_status': '0',
    'need_personal_recommend': '1',
    'player_so_load': '1',
    'is_android_pad_screen': '0',
    'rom_version': 'V417IR+release-keys',
    'iid': iid,
    'device_id': deviceId,
  };
  if (egdi != null && egdi.isNotEmpty) values['klink_egdi'] = egdi;
  return values;
}

/// gzip-compressed player/v1 body. The gzip bytes themselves are signed and
/// sent verbatim with `Content-Encoding: gzip`; re-encoding changes the body
/// hash and the signature no longer matches.
Uint8List v5PlayerBody(String vid) {
  final payload = jsonEncode({
    'biz_param': {
      'detail_page_version': 0,
      'device_level': 1,
      'disable_digg_stat': false,
      'disable_video_relate_book': false,
      'need_all_video_definition': true,
      'need_mp4_align': false,
      'use_os_player': false,
      'use_server_dns': false,
      'video_platform': 1024,
    },
    'mixed_video_id_map': {
      '1004': [vid],
    },
    'dr_scene': 'player',
  });
  return Uint8List.fromList(gzip.encode(utf8.encode(payload)));
}

/// video_tab query = device query plus the tab-specific fields, in order.
Map<String, String> v5VideoTabQuery({
  required String vid,
  required String deviceId,
  required String iid,
  required String cdid,
  String? egdi,
}) {
  final values = v5DeviceQuery(
    deviceId: deviceId,
    iid: iid,
    cdid: cdid,
    egdi: egdi,
  );
  values.addAll({
    'video_id': vid,
    'video_id_type': '0',
    'device_level': '1',
    'need_all_video_definition': '1',
    'need_mp4_align': '0',
    'use_os_player': '0',
    'video_platform': '1024',
    'source': '0',
    'from_video_id': '',
  });
  return values;
}

/// Builds signed v5 player/tab requests with an injectable clock and signer so
/// the byte layout can be verified offline.
class V5PlaybackRequestBuilder {
  V5PlaybackRequestBuilder({
    int Function()? clockMillis,
    PlaybackSigner? signer,
  }) : clockMillis =
           clockMillis ?? (() => DateTime.now().millisecondsSinceEpoch),
       signer = signer ?? PlaybackSigner(mobileV5: true);

  final int Function() clockMillis;
  final PlaybackSigner signer;

  PlaybackRequest player(
    String vid, {
    required String deviceId,
    required String iid,
    required String cdid,
    String? egdi,
  }) {
    final body = v5PlayerBody(vid);
    final signed = signer.signPlayback(
      V5PlaybackEndpoints.player,
      v5DeviceQuery(deviceId: deviceId, iid: iid, cdid: cdid, egdi: egdi),
      body: body,
      nowMillis: clockMillis(),
    );
    return PlaybackRequest(signed.url, {
      ...signed.headers,
      'User-Agent': V5PlaybackEndpoints.playerUserAgent,
      'Accept': 'application/json',
      'Content-Encoding': 'gzip',
    }, body);
  }

  PlaybackRequest videoTab(
    String vid, {
    required String deviceId,
    required String iid,
    required String cdid,
    String? egdi,
  }) {
    final signed = signer.signPlaybackGet(
      V5PlaybackEndpoints.videoTab,
      v5VideoTabQuery(
        vid: vid,
        deviceId: deviceId,
        iid: iid,
        cdid: cdid,
        egdi: egdi,
      ),
      nowMillis: clockMillis(),
    );
    return PlaybackRequest(signed.url, {
      ...signed.headers,
      'User-Agent': V5PlaybackEndpoints.tabUserAgent,
      'Accept': 'application/json',
    }, const <int>[]);
  }
}
