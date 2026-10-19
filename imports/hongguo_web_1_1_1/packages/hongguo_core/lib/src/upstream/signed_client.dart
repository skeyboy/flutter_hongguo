import 'dart:convert';
import '../crypto/bytes.dart';
import '../crypto/pure_sign.dart';
import '../ports/runtime.dart';
import '../ports/transport.dart';
import 'url_codec.dart';

const videoUserAgent =
    'com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)';

class SignedClient {
  final Transport transport;
  final PureSign signer;
  final Map<String, String> sessionHeaders;
  final Map<String, String> identity;
  SignedClient(
    this.transport, {
    PureSign? signer,
    Map<String, String>? identity,
    this.sessionHeaders = const {},
  }) : signer = signer ?? PureSign(),
       identity = identity ?? createDevice(SecureRandomSource());
  static Map<String, String> createDevice(RandomSource random) {
    String id() {
      var n = BigInt.from(1000000000000000);
      var v = BigInt.zero;
      for (final b in random.bytes(6)) {
        v = (v << 8) | BigInt.from(b);
      }
      return (n + v).toString();
    }

    return {
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
      'iid': id(),
      'device_id': id(),
    };
  }

  Future<Map<String, dynamic>> request(
    String endpoint, {
    Map<String, String> query = const {},
    Map<String, dynamic>? body,
    bool signed = true,
  }) async {
    final raw = body == null
        ? null
        : utf8Bytes(jsonEncode(body)); // serialize exactly once
    final now = signer.clock.milliseconds,
        ts = signer.clock.milliseconds ~/ 1000;
    late Uri uri;
    var ticket = now;
    bool accepted = false;
    for (var offset = 0; offset < 32; offset++) {
      ticket = now + offset;
      uri = Uri.parse(
        '$endpoint?${orderedQuery({...identity, ...query, 'ts': '$ts', '_rticket': '$ticket'})}',
      );
      if (!signed || signer.branchOf(uri.toString(), raw, ts) != 1) {
        accepted = true;
        break;
      }
    }
    if (!accepted)
      throw StateError('Unable to select a supported signature branch');
    final headers = <String, String>{
      'User-Agent': videoUserAgent,
      'Accept': 'application/json; charset=utf-8,application/x-protobuf',
      'Content-Type': 'application/json; charset=UTF-8',
      'x-xs-from-web': '0',
      'x-ss-req-ticket': '$ticket',
      'x-tt-request-tag': 't=0;n=0',
      'sdk-version': '2',
      'passport-sdk-version': '50561',
      'x-vc-bdturing-sdk-version': '3.7.2.cn',
      if (raw != null) 'x-ss-stub': hex(md5Bytes(raw)).toUpperCase(),
      ...sessionHeaders,
      if (signed) ...signer.sign(uri.toString(), raw, ts),
      'x-tt-dt': '',
    };
    final result = await transport.send(
      TransportRequest(
        uri,
        method: raw == null ? 'GET' : 'POST',
        headers: headers,
        body: raw,
      ),
    );
    return result.json();
  }
}
