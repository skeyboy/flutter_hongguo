// Pure Dart port of hongguo-android api/playback/Signer.kt (GPL-3.0-only),
// adapted from N3urda/hongguoTV 6672b55 and drpys 22261ad. This is a SEPARATE
// signing family from account_sign.dart: the v5 AesV3 uses a different sbox,
// con/order tables, initial word, wire/compact layout, and mobileV5 hashF13
// uses a fixed chosen table plus a 0x20 checksum flag. Never route these
// headers through AccountSigner or PureSign.
library;

import 'dart:convert';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'account_sign_constants.dart' show accountHashTable;
import 'bytes.dart' show hex, md5, secureBytes, sm3, unhex;
import 'playback_sign_constants.dart';
import 'pure_sign.dart'
    show be32, le32, proto, reverseBits, ror, rotl, xorBytes;

int _u32v(int v) => v & 0xffffffff;
int _i32(int v) => v.toUnsigned(32).toSigned(32);
int _ushr(int v, int n) => _u32v(v) >> n;
int _inv32(int v) => _i32(~v);
int _i64(List<int> bytes, int at) =>
    ByteData.sublistView(Uint8List.fromList(bytes)).getInt64(at, Endian.little);
Uint8List _le64(int value) {
  final bytes = Uint8List(8);
  ByteData.sublistView(bytes).setInt64(0, value, Endian.little);
  return bytes;
}

int _rotr64(int value, int n) {
  final k = n & 63;
  if (k == 0) return value;
  final lowMask = (1 << (64 - k)) - 1;
  return ((value >> k) & lowMask) | (value << (64 - k));
}

Uint8List _concat(Iterable<List<int>> parts) =>
    Uint8List.fromList([for (final part in parts) ...part]);
Uint8List _md5(List<int> value) => md5(value);
Uint8List _sm3(List<int> value) => sm3(value);

int _getIv(int initial, List<int> data) {
  var value = initial;
  for (var i = 0; i < data.length; i++) {
    value = (i & 1) == 0
        ? _i32(_ushr(value, 4) ^ _u32v(value) ^ _i32(value << 6) ^ data[i])
        : _inv32(
            _ushr(value, 7) ^ _u32v(value) ^ (data[i] | _i32(value << 12)),
          );
  }
  return value;
}

int _iv(List<int> query, List<int> body, int ts) =>
    _getIv(_getIv(_getIv(0x20230928, query), body), le32(ts));

int _sumMd5(List<int> data) {
  var check = 0x20220420;
  for (var i = 0; i < 12; i++) {
    final temp = _i32(_ushr(check, (i & 1) == 0 ? 3 : 5) ^ _u32v(check));
    check = (i & 1) == 0
        ? _i32(data[i] ^ _i32(check << 7))
        : _inv32(data[i] | _i32(check << 11));
    check = _i32(check ^ temp);
  }
  return _i32((_u32v(check) | 4) ^ 0x1000000);
}

/// Protocol-specific AES transform for the v5 playback family. Not standard
/// AES and NOT interchangeable with [AccountAesV3] in account_sign.dart.
class PlaybackAesV3 {
  PlaybackAesV3(this.key, this.timestamp, {this.v5 = false}) {
    final word = timestamp & 3;
    final sbox = unhex(playbackV5SboxHex);
    _box = List<int>.from(sbox.sublist(word * 256, (word + 1) * 256));
    _con = const [
      [2, 0, 3, 1],
      [1, 3, 2, 0],
      [3, 2, 1, 0],
      [2, 3, 1, 0],
    ][word];
    _order = const [
      [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
      [0, 9, 14, 11, 4, 13, 2, 3, 8, 1, 6, 15, 12, 5, 10, 7],
      [0, 9, 14, 3, 4, 13, 2, 15, 8, 1, 6, 11, 12, 5, 10, 7],
      [0, 9, 14, 15, 4, 13, 2, 3, 8, 1, 6, 11, 12, 5, 10, 7],
    ][word];
    final initial = const [
      0xbbb5de72,
      0xd4638d5b,
      0x92a5f73b,
      0x89f8a1c9,
    ].map(_i32).toList()[word];
    final seedWords = _concat([
      le32(initial),
      le32(initial),
      le32(initial),
      le32(initial),
    ]);
    final expanded = <int>[
      ...List<int>.generate(16, (i) => seedWords[i] ^ key[i % key.length]),
      ...List<int>.filled(32, 0),
    ];
    var rounds = 8;
    for (var i = 4; i < 12; i++) {
      final at = 4 * (i - 1);
      var a = expanded[at], b = expanded[at + 1];
      var c = expanded[at + 2], d = expanded[at + 3];
      if (i & 3 == 0) {
        // Kotlin uses Int.shr (arithmetic), which matches Dart's >> on a
        // negative 32-bit signed seed.
        final t = ((initial >> (rounds & 24)) ^ _box[b]) & 255;
        b = _box[c];
        c = _box[d];
        d = _box[a];
        a = t;
      }
      rounds += 2;
      expanded[at + 4] = a ^ expanded[at - 12];
      expanded[at + 5] = b ^ expanded[at - 11];
      expanded[at + 6] = c ^ expanded[at - 10];
      expanded[at + 7] = d ^ expanded[at - 9];
    }
    _keys = List.generate(
      12,
      (i) => List<int>.from(expanded.sublist(i * 4, i * 4 + 4)),
    );
  }

  final List<int> key;
  final int timestamp;
  final bool v5;
  late final List<int> _box, _con, _order;
  late final List<List<int>> _keys;

  Uint8List _block(List<int> value) {
    final rows = List.generate(
      4,
      (i) => List<int>.from(value.sublist(i * 4, i * 4 + 4)),
    );
    void addCon(int offset) {
      for (var i = 0; i < 4; i++) {
        for (var j = 0; j < 4; j++) {
          rows[i][j] ^= _keys[offset + i][_con[j]];
        }
      }
    }

    addCon(0);
    for (var round = 1; round <= 2; round++) {
      for (var i = 0; i < 4; i++) {
        for (var j = 0; j < 4; j++) {
          rows[i][j] = _box[rows[i][j]];
        }
      }
      final before = rows.map((r) => List<int>.from(r)).toList();
      for (var i = 0; i < 4; i++) {
        rows[i] = List<int>.from(before[_con[i]]);
      }
      final flat = rows.expand((r) => r).toList();
      for (var i = 0; i < 16; i++) {
        rows[i ~/ 4][i % 4] = flat[_order[i]];
      }
      if (round == 1) {
        for (var i = 0; i < 4; i++) {
          final old = List<int>.from(rows[i]);
          rows[i] = List.generate(4, (j) => old[_con[j]]);
        }
        int xt(int x) => ((x << 1) ^ ((x & 128) != 0 ? 0x1b : 0)) & 255;
        for (var i = 0; i < 4; i++) {
          final t = rows[0][i] ^ rows[1][i] ^ rows[2][i] ^ rows[3][i];
          final u = rows[0][i];
          rows[0][i] ^= t ^ xt(rows[0][i] ^ rows[1][i]);
          rows[1][i] ^= t ^ xt(rows[1][i] ^ rows[2][i]);
          rows[2][i] ^= t ^ xt(rows[2][i] ^ rows[3][i]);
          rows[3][i] ^= t ^ xt(rows[3][i] ^ u);
        }
      }
      addCon(round * 4);
    }
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) {
        rows[i][j] ^= _keys[4 + i][j];
      }
    }
    return Uint8List.fromList(rows.expand((r) => r).toList());
  }

  Uint8List encrypt(List<int> source, List<int> iv) {
    if (source.length < 248) throw ArgumentError('AesV3 payload too short');
    const wire = [6, 5, 3, 4, 2, 7, 1, 0];
    const compact = [1, 7, 3, 6, 2, 0, 4, 5];
    final plaintext = List<int>.filled(32, 0);
    for (var i = 0; i < 31; i++) {
      for (var j = 0; j < 8; j++) {
        plaintext[i] |= (_ushr(source[i * 8 + j], wire[j]) & 1) << compact[j];
      }
    }
    plaintext[31] = 1;
    final first = _block(xorBytes(plaintext.sublist(0, 16), iv));
    final key = _concat([
      first,
      _block(xorBytes(plaintext.sublist(16, 32), first)),
    ]);
    final out = Uint8List.fromList(source);
    for (var i = 0; i < 31; i++) {
      for (var j = 0; j < 8; j++) {
        final at = i * 8 + j;
        out[at] =
            (out[at] & (0xff ^ (1 << wire[j]))) |
            ((_ushr(key[i], compact[j]) & 1) << wire[j]);
      }
    }
    return Uint8List.fromList([key.last, ...out]);
  }
}

class PlaybackRequest {
  PlaybackRequest(this.url, this.headers, List<int>? body)
    : body = body == null ? null : Uint8List.fromList(body);
  final String url;
  final Map<String, String> headers;
  final Uint8List? body;
}

/// The v5 playback signer. [mobileV5] selects branch-0 / hashF13 / AesV3(v5)
/// and the v04.10.03 medusa envelope; with mobileV5=false it mirrors the
/// playback legacy branch of Signer.kt. TODO(realnet): default routes still
/// keep this signer behind the extended route set until live A/B confirms it.
class PlaybackSigner {
  PlaybackSigner({
    int Function()? clockMillis,
    Map<String, String>? device,
    double Function()? random,
    String? processNonce,
    this.mobileV5 = true,
  }) : clockMillis =
           clockMillis ?? (() => DateTime.now().millisecondsSinceEpoch),
       device = device ?? Map<String, String>.from(defaultDevice),
       random = random ?? PlaybackSigner._defaultRandom,
       processNonce = processNonce ?? PlaybackSigner._defaultNonce(),
       processStarted =
           (clockMillis ?? (() => DateTime.now().millisecondsSinceEpoch))() {
    // processStarted is fixed at construction, matching the Kotlin signer.
  }

  static double _defaultRandom() => _secureRandom.nextDouble();
  static final Random _secureRandom = Random.secure();
  static String _defaultNonce() =>
      base64Url.encode(secureBytes(18)).replaceAll('=', '');

  static const playerUserAgent =
      'com.phoenix.read/71532 (Linux; U; Android 9; SM-N9860; '
      'Build/PQ3A.190705.10241111;tt-ok/3.12.13.20)';
  static const accept =
      'application/json; charset=utf-8,application/x-protobuf';

  static const defaultDevice = <String, String>{
    'iid': '1905892595382586',
    'device_id': '1905892595378490',
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

  final int Function() clockMillis;
  final Map<String, String> device;
  final double Function() random;
  final String processNonce;
  final int processStarted;
  final bool mobileV5;

  int rand() => (random() * 4294967296).floor().toSigned(32);

  int branch(String query, List<int>? body, int ts) {
    final value =
        _u32v(
          _iv(
            _sm3(utf8.encode(query)),
            body == null ? List<int>.filled(16, 0) : _md5(body),
            ts,
          ),
        ) &
        15;
    if (mobileV5) return value == 12 ? 0 : 1;
    return value % 3;
  }

  Uint8List hashF13(List<int> query, List<int> body, int ts) {
    final low = _u32v(_iv(query, body, ts)) & 15;
    if (mobileV5) {
      if (low != 12) throw StateError('Unsupported hash branch');
    } else if (low % 3 != 0) {
      throw StateError('Unsupported hash branch');
    }
    final index = low ~/ 3;
    final ivV1 = mobileV5
        ? _i32(0x9d4a97c2)
        : const [
            0xc4a78580,
            0xb3c0fd39,
            0xc58c5686,
            0xc9aa3ba7,
            0xf5a7adf2,
            0x963c2ed1,
          ].map(_i32).toList()[index];
    final count = _i32(ivV1 + ts);
    final tt = accountHashTable
        .map((it) => ror(it, (_u32v(count) + 1) & 255))
        .toList();
    final shift = (_u32v(count) + 2) & 7;
    final pad = <int>[
      0xfa,
      0x45,
      0x61,
      0xd7,
    ].map((it) => ((it | (it << 8)) >> shift) & 255).toList();
    final data = _concat([
      query,
      body,
      le32(ts),
      pad,
      unhex('00000000000001a0'),
    ]);
    final di = <int>[
      for (var i = 0; i < data.length; i += 4)
        ByteData.sublistView(data).getInt32(i, Endian.big),
    ];
    for (var i = 0; i < 112; i++) {
      final x = di[i + 1], y = di[i + 14];
      di.add(
        _i32(
          di[i] +
              di[i + 9] +
              (rotl(x, 14) ^ rotl(x, 25) ^ _ushr(x, 3)) +
              (rotl(y, 13) ^ rotl(y, 15) ^ _ushr(y, 10)),
        ),
      );
    }
    final initial = const [
      0x7aba4fc8,
      0x67166507,
      0x6403fa00,
      0x340f512f,
      984304912,
      3005047866,
      2874125293,
      2152413264,
    ].map(_i32).map((it) => ror(it, count)).toList();
    final chosen = mobileV5
        ? const [96, 1, 3, 4, 0, 6, 5, 2, 0, 7, 7]
        : const [
            [101, 5, 7, 6, 3, 2, 1, 0, 5, 4, 3],
            [96, 0, 6, 7, 5, 3, 2, 1, 5, 4, 4],
            [96, 7, 6, 2, 1, 4, 0, 5, 4, 3, 5],
            [99, 3, 6, 2, 4, 5, 1, 0, 0, 7, 6],
            [96, 0, 5, 6, 7, 3, 1, 2, 5, 4, 4],
            [100, 2, 0, 3, 5, 4, 6, 7, 2, 1, 5],
          ][index];
    final d = List<int>.from(initial);
    for (var i = 0; i < chosen[0]; i++) {
      final base = _i32(ivV1 + i) & 0xffffffff;
      final n1 = _i32(
        ((_u32v(d[chosen[3]]) ^ _u32v(d[chosen[4]])) & _u32v(d[chosen[1]])) ^
            _u32v(d[chosen[3]]),
      );
      final n2 = _i32(
        rotl(d[chosen[1]], 26) ^ rotl(d[chosen[1]], 21) ^ rotl(d[chosen[1]], 7),
      );
      final n4 = _i32(di[base & 127] + n1 + n2 + tt[base & 63] + d[chosen[5]]);
      final n5 = _i32(
        rotl(d[chosen[2]], 30) ^
            rotl(d[chosen[2]], 19) ^
            rotl(d[chosen[2]], 10),
      );
      final n6 = _i32(
        (_u32v(d[chosen[2]]) & _u32v(d[chosen[6]])) |
            ((_u32v(d[chosen[2]]) | _u32v(d[chosen[6]])) & _u32v(d[chosen[7]])),
      );
      final old = d[chosen[9]];
      d.insert(0, d.removeAt(7));
      d[chosen[10]] = _i32(n5 + n6 + n4);
      d[chosen[8]] = _i32(old + n4);
    }
    final ret = _concat([
      for (var i = 0; i < 8; i++) be32(_i32(d[i] + initial[i])),
    ]);
    final folded = Uint8List.fromList([
      for (var i = 0; i < 16; i++) ret[i] ^ ret[16 + i],
    ]);
    return _concat([
      folded,
      le32(_i32(_sumMd5(folded) | (mobileV5 ? 0x20 : 0))),
    ]);
  }

  String gorgon(String query, List<int>? body, int ts, int randomValue) {
    final input = _concat([
      _md5(utf8.encode(query)).sublist(0, 4),
      body == null ? List<int>.filled(4, 0) : _md5(body).sublist(0, 4),
      List<int>.filled(4, 0),
      le32(67503104),
      be32(ts),
    ]);
    final key = <int>[
      0x4a,
      0x40,
      0x16,
      _ushr(randomValue, 8) & 255,
      0x47,
      0x6c,
      1,
      randomValue & 255,
    ];
    final s = List<int>.generate(256, (i) => i);
    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j + s[i] + key[i % 8]) & 255;
      s[i] = s[j];
    }
    j = 0;
    final out = Uint8List(input.length);
    for (var n = 0; n < input.length; n++) {
      final i = n + 1;
      j = (j + s[i]) & 255;
      final y = s[j & 255];
      s[i] = y;
      out[n] = input[n] ^ s[(y + y) & 255];
    }
    for (var i = 0; i < out.length; i++) {
      final value = (_ushr(out[i], 4) | (out[i] << 4)) & 255;
      final next = out[(i + 1) % out.length];
      out[i] = (~(reverseBits(next ^ value) ^ 20)) & 255;
    }
    return hex(
      _concat([
        unhex('8404'),
        [randomValue & 255, _ushr(randomValue, 8) & 255, 0x40, 1],
        out,
      ]),
    );
  }

  String _secDeviceToken() {
    if (processNonce.length == 25 && processNonce.startsWith('A')) {
      return processNonce;
    }
    final head = processNonce.substring(
      0,
      processNonce.length < 24 ? processNonce.length : 24,
    );
    return 'A${head.padRight(24, 'A')}';
  }

  Uint8List _deviceProto(Map<String, String> who, int nowMs) {
    final secToken = _secDeviceToken();
    return proto([
      [1, 1, 'sint'],
      [2, 2, 'sint'],
      [3, '8662'],
      [4, who['device_id'] ?? ''],
      [5, secToken],
      [6, '!noperm!'],
      [7, -888888, 'sint'],
      [8, -888888, 'sint'],
      [9, 3, 'sint'],
      [10, -888888, 'sint'],
      [11, '!notset!'],
      [12, 'Asia/Shanghai,8'],
      [13, 'zh_CN'],
      [14, 4, 'sint'],
      [16, 0.0, 'float'],
      [17, 0.0, 'float'],
      [18, 0.0, 'float'],
      [19, 0.0, 'float'],
      [20, 0.0, 'float'],
      [21, 0.0, 'float'],
      [22, who['os_version'] ?? ''],
      [23, 41, 'sint'],
      [24, 36, 'sint'],
      [25, processStarted, 'sint'],
      [26, processStarted, 'sint'],
      [27, processStarted, 'sint'],
      [28, nowMs, 'sint'],
      [29, -1, 'sint'],
      [30, who['device_type'] ?? ''],
      [31, who['device_brand'] ?? 'HONOR'],
      [32, who['device_type'] ?? ''],
      [33, who['device_type'] ?? ''],
      [34, who['device_brand'] ?? 'HONOR'],
      [35, who['device_brand'] ?? 'HONOR'],
      [36, who['device_brand'] ?? 'HONOR'],
      [38, 31, 'sint'],
    ]);
  }

  Uint8List _xmxor(List<int> data, List<int> key) {
    final encoded = List<int>.filled(data.length, 0);
    for (var i = 0; i < data.length; i++) {
      final at = (i * 4) & 28;
      final d0 = key[at], d1 = key[at + 1], v = data[i];
      var d2 = (((v << 4) | _ushr(v, 4)) & 255) + d0;
      d2 = (~d2) ^ d1;
      d2 = (((d2 & 255) << 3) | ((d2 & 255) >> 5)) & 255;
      d2 = (d2 + d1) & 255;
      d2 = (d2 ^ d0) & 255;
      encoded[data.length - i - 1] = (~d2) & 255;
    }
    final last = encoded.last ^ encoded[encoded.length - 2];
    final first = encoded[0];
    encoded[0] = ((~last) + first) & 255;
    encoded[1] = ((encoded[0] ^ encoded.last ^ 254) + encoded[1]) & 255;
    encoded[2] =
        (encoded[2] +
            ((last - first) ^
                (((encoded[1] << 3) | _ushr(encoded[1], 5)) & 255) ^
                2)) &
        255;
    for (var i = 0; i < encoded.length - 4; i++) {
      final temp =
          (((encoded[i + 2] << 3) | _ushr(encoded[i + 2], 5)) & 255) ^
          encoded[i + 1] ^
          (i + 3);
      encoded[i + 3] = ((~temp) + encoded[i + 3]) & 255;
    }
    encoded[encoded.length - 1] = encoded.last ^ encoded[encoded.length - 2];
    encoded[0] =
        ((encoded[0] ^ encoded[1]) +
            encoded.skip(1).fold<int>(0, (a, b) => a + b)) &
        255;
    return Uint8List.fromList(encoded);
  }

  Uint8List _queryOf(String url) {
    final at = url.indexOf('?');
    return utf8.encode(at < 0 ? url : url.substring(at + 1));
  }

  /// v04.10.03 medusa envelope (mobileV5). Device identity must match the
  /// registered values written into the request query.
  String medusa(String url, List<int>? body, int ts, Map<String, String> who) {
    final query = _sm3(_queryOf(url));
    final f13 = hashF13(
      query,
      body == null ? List<int>.filled(16, 0) : _md5(body),
      ts,
    );
    final flags = unhex('4480000000000000');
    final version = who['version_name'] ?? '';
    final did = who['device_id'] ?? '';
    final secToken = _secDeviceToken();
    final nowMs = clockMillis();
    final deviceInfo = _deviceProto(who, nowMs);
    final envLaunch = (random() * 21).floor() + 100;
    final envPid = (random() * 2000).floor() + 10001;
    final envSub13 = proto([
      [1, ts, 'sint'],
      [2, -2, 'sint'],
      [4, 200, 'sint'],
    ]);
    final env = proto([
      [1, envLaunch, 'sint'],
      [2, 247235599, 'sint'],
      [3, 247235596, 'sint'],
      [5, 7, 'sint'],
      [6, 'v04.10.03.04-bugfix'],
      [7, envPid, 'sint'],
      [8, who['channel'] ?? ''],
      [12, deviceInfo, 'bytes'],
      [13, envSub13, 'bytes'],
      [14, version],
    ]);
    final nested = proto([
      [1, 305, 'sint'],
      [2, 4, 'sint'],
      [3, 694367, 'sint'],
      [5, 1621072674, 'sint'],
    ]);
    final message = proto([
      [1, unhex(playbackV5MagicHex), 'bytes'],
      [2, 5, 'sint'],
      [3, rand() & 0xffffffff, 'sint'],
      [4, '8662'],
      [5, did],
      [6, playbackV5License],
      [7, version],
      [8, 'v04.10.03-ml-android'],
      [9, 0x040a0300, 'sint'],
      [10, flags, 'bytes'],
      [12, ts, 'sint'],
      [13, f13, 'bytes'],
      [14, query.sublist(0, 6), 'bytes'],
      [15, nested, 'bytes'],
      [16, secToken],
      [17, ts, 'sint'],
      [20, 'none'],
      [21, 312, 'sint'],
      [23, env, 'bytes'],
      [
        24,
        '{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}',
      ],
    ]);
    final nonce = rand();
    final key = unhex(playbackV5SignKeyHex);
    final hash = _sm3(_concat([key, le32(nonce), key]));
    final high = _ushr(nonce, 16) & 255;
    final seed = le32(
      _inv32(((high << 11) | _ushr(nonce, 24)) ^ _ushr(high, 5) ^ high),
    );
    final transformed = _concat([flags, _xmxor(message, hash)]).reversed
        .toList();
    for (var i = 0; i < transformed.length; i++) {
      transformed[i] ^= seed[(~i) & 3];
    }
    final check = 0x18000001 | ((query[0] & 63) << 14) | ((f13[0] & 63) << 8);
    final packed = _concat([
      [0xca],
      le32(rand()),
      le32(check),
      transformed,
      [_ushr(nonce, 16) & 255, _ushr(nonce, 24) & 255],
    ]);
    final encrypted = PlaybackAesV3(
      _md5(key.sublist(0, 16)),
      ts,
      v5: true,
    ).encrypt(packed, _md5(key.sublist(16, 32)));
    final prefix = _concat([le32(5), unhex(playbackV5MagicHex)]);
    final tsBytes = le32(ts);
    for (var i = 0; i < prefix.length; i++) {
      prefix[i] ^= tsBytes[i & 3];
    }
    return base64.encode(
      _concat([
        prefix,
        [nonce & 255, _ushr(nonce, 8) & 255, 0, 1],
        encrypted,
      ]),
    );
  }

  String helios(int ts) {
    final random = rand();
    final ascii = utf8.encode(
      hex(_md5(_concat([le32(random), utf8.encode('8662')]))),
    );
    final words = List<int>.generate(4, (i) => _i64(ascii, i * 8));
    final table = <int>[words[0]];
    var b0 = words.removeAt(0);
    var b8 = words.removeAt(0);
    for (var i = 0; i < 34; i++) {
      var x8 = (_rotr64(b8, 8) + b0) ^ i;
      words.add(x8);
      x8 ^= _rotr64(b0, 61);
      table.add(x8);
      b0 = x8;
      b8 = words.removeAt(0);
    }
    final license = mobileV5 ? playbackV5License : '1588093228';
    final text = utf8.encode('$ts-$license-8662');
    final padding = 16 - text.length % 16;
    final data = _concat([text, List<int>.filled(padding, padding)]);
    var output = le32(random);
    for (var at = 0; at < data.length; at += 16) {
      var a = _i64(data, at);
      var b = _i64(data, at + 8);
      for (var i = 0; i < 34; i++) {
        b = table[i] ^ (a + _rotr64(b, 8));
        a = b ^ _rotr64(a, 61);
      }
      output = _concat([output, _le64(a), _le64(b)]);
    }
    return base64.encode(output);
  }

  /// v5 player/v1 POST signing. body must already be gzip-compressed; the
  /// caller is responsible for Content-Encoding. Only branch 0 is emitted by
  /// rolling _rticket up to 1024 times.
  PlaybackRequest signPlayback(
    String base,
    Map<String, String> values, {
    List<int>? body,
    int? nowMillis,
  }) {
    final now = nowMillis ?? clockMillis();
    final ts = now ~/ 1000;
    for (var offset = 0; offset < 1024; offset++) {
      final ticket = now + offset;
      final query = _encode({...values, '_rticket': '$ticket'});
      if (branch(query, body, ts) != 0) continue;
      final url = '$base?$query';
      final headers = <String, String>{
        'User-Agent': playerUserAgent,
        'Accept': accept,
        'x-ss-req-ticket': '$ticket',
        'sdk-version': '2',
        'x-xs-from-web': '0',
        'x-khronos': '$ts',
        'x-ladon': base64.encode(be32(ts)),
        'x-argus': base64.encode(le32(ts)),
        'x-gorgon': gorgon(query, body, ts, (random() * 65536).floor()),
        'x-helios': helios(ts),
        'x-medusa': medusa(url, body, ts, mobileV5 ? values : device),
      };
      if (mobileV5) {
        headers.removeWhere(
          (k, _) => !{'x-khronos', 'x-helios', 'x-medusa'}.contains(k),
        );
      }
      if (body != null) {
        headers['Content-Type'] = 'application/json; charset=utf-8';
        headers['x-ss-stub'] = hex(_md5(body)).toUpperCase();
      }
      return PlaybackRequest(url, headers, body);
    }
    throw StateError('无法生成播放签名');
  }

  /// v5 video_tab GET signing: empty-body MD5 and only three headers.
  PlaybackRequest signPlaybackGet(
    String base,
    Map<String, String> values, {
    int? nowMillis,
  }) {
    final now = nowMillis ?? clockMillis();
    final ts = now ~/ 1000;
    final empty = <int>[];
    for (var offset = 0; offset < 1024; offset++) {
      final ticket = now + offset;
      final query = _encode({...values, '_rticket': '$ticket'});
      if (branch(query, empty, ts) != 0) continue;
      final url = '$base?$query';
      return PlaybackRequest(url, {
        'x-khronos': '$ts',
        'x-helios': helios(ts),
        'x-medusa': medusa(url, empty, ts, values),
      }, null);
    }
    throw StateError('无法生成播放签名');
  }
}

String _encode(Map<String, String> values) => values.entries
    .map((e) => '${_encodePart(e.key)}=${_encodePart(e.value)}')
    .join('&');

String _encodePart(String value) => utf8.encode(value).map((b) {
  final safe =
      (b >= 65 && b <= 90) ||
      (b >= 97 && b <= 122) ||
      (b >= 48 && b <= 57) ||
      [45, 46, 95, 126, 42].contains(b);
  return safe
      ? String.fromCharCode(b)
      : '%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}';
}).join();
