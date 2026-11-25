// Pure Dart port of hongguo-android account/protocol/Signer.kt (GPL-3.0-only),
// adapted from tsukiyo-zero/hongguoTV 34c7930 and drpys 22261ad. No Flutter or
// dart:io dependency: it can run in the CLI, desktop and web oracles alike.
//
// Only branch 0 is emitted, matching the Kotlin implementation. Do not route
// these headers through PureSign: the two families share constants but not
// byte layouts.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'account_sign_constants.dart';
import 'bytes.dart';
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
Uint8List _hex(String value) => unhex(value);
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

/// Protocol-specific AES-like transform. Not standard AES and not interchangeable
/// with `AesV3` in `pure_sign.dart`.
class AccountAesV3 {
  AccountAesV3(this.key, this.timestamp) {
    final decoded = decodeBase64(accountSboxBase64);
    final word = timestamp & 3;
    _box = List<int>.from(decoded.sublist(word * 256, (word + 1) * 256));
    _con = const [
      [1, 0, 2, 3],
      [2, 0, 3, 1],
      [0, 1, 3, 2],
      [1, 0, 2, 3],
    ][word];
    _order = const [
      [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
      [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
      [0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15],
      [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
    ][word];
    final initial = const [
      0xca025ddc,
      0x823dc546,
      0xc9420583,
      0xc298225f,
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
        // Kotlin uses Int.shr (arithmetic), not ushr, on a negative seed.
        final t = (((initial >> (rounds & 24)) ^ _box[b]) & 255);
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
    final plaintext = List<int>.filled(32, 0);
    for (var i = 0; i < 31; i++) {
      final at = i * 8;
      plaintext[i] =
          (((source[at] >> 4) & 2) |
          (source[at + 1] & 64) |
          ((source[at + 2] >> 2) & 1) |
          ((source[at + 3] << 3) & 128) |
          ((source[at + 4] >> 1) & 4) |
          ((source[at + 5] << 3) & 16) |
          ((source[at + 6] << 5) & 32) |
          ((source[at + 7] >> 4) & 8));
    }
    plaintext[31] = 1;
    final first = _block(xorBytes(plaintext.sublist(0, 16), iv));
    final key = _concat([
      first,
      _block(xorBytes(plaintext.sublist(16, 32), first)),
    ]);
    final out = Uint8List.fromList(source);
    for (var i = 0; i < 31; i++) {
      final at = i * 8;
      final k = key[i];
      out[at] = (out[at] & 0xdf) | ((k << 4) & 32);
      out[at + 1] = (out[at + 1] & 0xbf) | (k & 64);
      out[at + 2] = (out[at + 2] & 0xfb) | ((k << 2) & 4);
      out[at + 3] = (out[at + 3] & 0xef) | ((k >> 3) & 16);
      out[at + 4] = (out[at + 4] & 0xf7) | ((k + k) & 8);
      out[at + 5] = (out[at + 5] & 0xfd) | ((k >> 3) & 2);
      out[at + 6] = (out[at + 6] & 0xfe) | ((k >> 5) & 1);
      out[at + 7] = (out[at + 7] & 0x7f) | ((k << 4) & 128);
    }
    return Uint8List.fromList([key.last, ...out]);
  }
}

/// The signed request family used by the account and v5 playback endpoints.
class AccountSigner {
  AccountSigner({int Function()? clockMillis, Map<String, String>? device})
    : clockMillis =
          clockMillis ?? (() => DateTime.now().millisecondsSinceEpoch),
      device = device ?? Map<String, String>.from(defaultDevice);

  static const videoUserAgent =
      'com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; '
      'Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 '
      'QuicVersion:c67e9834 2025-09-08)';
  static const appUserAgent =
      'com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; '
      'Build/BP2A.250605.031.A3)';

  static const defaultDevice = <String, String>{
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
  int _seed = 12345;

  /// Deterministic LCG shared by [rand] and [random], as in the Kotlin test.
  void reseed(int seed) => _seed = seed & 0xffffffff;
  double _nextDouble() {
    _seed = (_seed * 1664525 + 1013904223) & 0xffffffff;
    return _seed / 4294967296.0;
  }

  double random() => _nextDouble();
  int rand() => (random() * 4294967296).floor().toSigned(32);

  int branch(String query, List<int>? body, int ts) {
    final digest = _iv(
      _sm3(utf8.encode(query)),
      body == null ? List<int>.filled(16, 0) : _md5(body),
      ts,
    );
    return (_u32v(digest) & 15) % 3;
  }

  Uint8List hashF13(List<int> query, List<int> body, int ts) {
    final low = _u32v(_iv(query, body, ts)) & 15;
    if (low % 3 != 0) throw StateError('Unsupported hash branch');
    final index = low ~/ 3;
    final ivV1 = const [
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
      _hex('00000000000001a0'),
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
    final chosen = const [
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
    return _concat([folded, le32(_sumMd5(folded))]);
  }

  String gorgon(String query, List<int>? body, int ts, int random) {
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
      _ushr(random, 8) & 255,
      0x47,
      0x6c,
      1,
      random & 255,
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
      final value = ((_ushr(out[i], 4)) | (out[i] << 4)) & 255;
      final next = out[(i + 1) % out.length];
      out[i] = (~(reverseBits(next ^ value) ^ 20)) & 255;
    }
    return hex(
      _concat([
        _hex('8404'),
        [random & 255, _ushr(random, 8) & 255, 0x40, 1],
        out,
      ]),
    );
  }

  Uint8List _deviceProto() => proto([
    [1, 1, 'sint'],
    [2, 2, 'sint'],
    [3, '8662'],
    [4, device['device_id'] ?? ''],
    [5, 'Ai6svO3PyrwDOUSmO6ZcResxu'],
    [6, '!noperm!'],
    [7, -888888, 'sint'],
    [8, -888888, 'sint'],
    [9, 3, 'sint'],
    [10, -888888, 'sint'],
    [11, '!notset!'],
    [12, 'Asia/Shanghai,8'],
    [13, 'zh_CN'],
    [14, 4, 'sint'],
    [16, 255.24993896484375, 'float'],
    [17, 35.58599090576172, 'float'],
    [18, 3.467449188232422, 'float'],
    [19, 3.467449188232422, 'float'],
    [20, 255.1754913330078, 'float'],
    [21, 42.17544174194336, 'float'],
    [22, '16'],
    [23, 41, 'sint'],
    [24, 36, 'sint'],
    [25, 1728388016635, 'sint'],
    [26, 1728388016635, 'sint'],
    [27, 1728388016635, 'sint'],
    [28, 1728388016637, 'sint'],
    [29, -1, 'sint'],
    [30, '25053RT47C'],
    [31, 'Redmi'],
    [32, '25053RT47C'],
    [33, '25053RT47C'],
    [34, 'Xiaomi'],
    [35, 'Redmi'],
    [36, 'Redmi'],
    [38, 31, 'sint'],
  ]);

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

  String medusa(String url, List<int>? body, int ts) {
    final bodyMd5 = body == null ? List<int>.filled(16, 0) : _md5(body);
    final query = _queryOf(url);
    final querySm3 = _sm3(query);
    final queryBodyTs = hashF13(querySm3, bodyMd5, ts);
    final nested = proto([
      [1, 111, 'sint'],
      [2, 10, 'sint'],
      [3, 694367, 'sint'],
      [5, 586952199, 'sint'],
    ]);
    final messageRand = _u32v(rand());
    final envLaunch = (random() * 21).floor() + 100;
    final envPid = (random() * 2000).floor() + 10001;
    final version = device['version_name'] ?? '';
    final env = proto([
      [1, envLaunch, 'sint'],
      [2, 146331399, 'sint'],
      [3, 146331396, 'sint'],
      [5, 7, 'sint'],
      [6, 'v04.06.04.03-bugfix'],
      [7, envPid, 'sint'],
      [12, _deviceProto(), 'bytes'],
      [
        13,
        proto([
          [1, clockMillis() ~/ 1000, 'sint'],
          [2, -2, 'sint'],
          [4, 200, 'sint'],
        ]),
        'bytes',
      ],
      [14, version],
    ]);
    final queryHash = _sm3(_concat([query, bodyMd5, utf8.encode('none')]));
    final message = proto([
      [1, _hex('f7e85ffad7d7dc3bd62ac87057cf6118'), 'bytes'],
      [2, 3, 'sint'],
      [3, messageRand, 'sint'],
      [4, '8662'],
      [5, device['device_id'] ?? ''],
      [6, '1588093228'],
      [7, version],
      [8, 'v04.06.04-ml-android'],
      [9, 67503104, 'sint'],
      [10, _hex('4001000000000000'), 'bytes'],
      [12, ts, 'sint'],
      [13, queryBodyTs, 'bytes'],
      [14, querySm3.sublist(0, 6), 'bytes'],
      [15, nested, 'bytes'],
      [16, 'AXYQOS6n2m60x1fVZHIrH3iol'],
      [17, ts, 'sint'],
      [19, queryHash, 'bytes'],
      [20, 'none'],
      [21, 312, 'sint'],
      [23, env, 'bytes'],
      [
        24,
        '{"cmr":16777216,"cmr2":16777216,"un_h":1879194040,"vpn":0,"kd":0,'
            '"fkd":3672518972,"pd":-1872573247,"dyn":"","do":0,"tk":true}',
      ],
    ]);
    final r = rand();
    final signKey = _hex(
      '8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eaef71cb691f7aa8aa2f5',
    );
    final hash = _sm3(_concat([signKey, le32(r), signKey]));
    final d1 = _ushr(r, 16) & 255;
    final seed = le32(_inv32(((d1 << 11) | _ushr(r, 24)) ^ _ushr(d1, 5) ^ d1));
    final transformed = _concat([
      _hex('4001000000000000'),
      _xmxor(message, hash),
    ]).reversed.toList();
    for (var i = 0; i < transformed.length; i++) {
      transformed[i] ^= seed[(~i) & 3];
    }
    final check =
        ((querySm3[0] & 63) << 14) | 0x18000001 | ((queryBodyTs[0] & 63) << 8);
    final packed = _concat([
      [0x35],
      le32(rand()),
      le32(check),
      transformed,
      [_ushr(r, 16) & 255, _ushr(r, 24) & 255],
    ]);
    final encrypted = AccountAesV3(
      _hex('f1593376766ea98d34f31b057a9d5be4'),
      ts,
    ).encrypt(packed, _hex('1fe109a4125283f418de9e051a969e12'));
    final versionBytes = _hex('03000000f7e85ffad7d7dc3bd62ac87057cf6118');
    final prefix = _concat([
      for (var i = 0; i < 20; i += 4)
        le32(
          _i32(
            ByteData.sublistView(versionBytes).getInt32(i, Endian.little) ^ ts,
          ),
        ),
    ]);
    return base64.encode(
      _concat([
        prefix,
        [r & 255, _ushr(r, 8) & 255, 0, 1],
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
    final text = utf8.encode('$ts-1588093228-8662');
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

  /// The only signing entry point callers should use. [values] are the URL
  /// query parameters in insertion order; the ticket is rolled until branch 0.
  AccountRequest sign(
    String base,
    Map<String, String> values, {
    List<int>? body,
  }) {
    final now = clockMillis();
    final ts = now ~/ 1000;
    for (var offset = 0; offset < 128; offset++) {
      final ticket = now + offset;
      final query = encodeAccountQuery({
        ...values,
        'ts': '$ts',
        '_rticket': '$ticket',
      });
      if (branch(query, body, ts) != 0) continue;
      final url = '$base?$query';
      final gorgonRandom = (random() * 65536).floor();
      final headers = <String, String>{
        'User-Agent': body == null ? appUserAgent : videoUserAgent,
        'Accept': 'application/json; charset=utf-8,application/x-protobuf',
        'x-ss-req-ticket': '$ticket',
        'x-tt-request-tag': 't=0;n=0',
        'sdk-version': '2',
        'passport-sdk-version': '50561',
        'x-xs-from-web': '0',
        'x-khronos': '$ts',
        'x-ladon': base64.encode(be32(ts)),
        'x-argus': base64.encode(le32(ts)),
        'x-gorgon': gorgon(query, body, ts, gorgonRandom),
        'x-helios': helios(ts),
        'x-medusa': medusa(url, body, ts),
        'x-tt-dt': '',
      };
      if (body != null) {
        headers['Content-Type'] = 'application/json; charset=UTF-8';
        headers['x-vc-bdturing-sdk-version'] = '3.7.2.cn';
        headers['x-ss-stub'] = hex(_md5(body)).toUpperCase();
      }
      return AccountRequest(url, headers, body);
    }
    throw StateError('无法生成请求签名');
  }
}

class AccountRequest {
  const AccountRequest(this.url, this.headers, this.body);
  final String url;
  final Map<String, String> headers;
  final List<int>? body;
}

/// Java URLEncoder's safe set after its `+ -> %20` and `%7E -> ~` fixups.
String encodeAccountQuery(Map<String, String> values) => values.entries
    .map((e) => '${encodeAccountPart(e.key)}=${encodeAccountPart(e.value)}')
    .join('&');

String encodeAccountPart(String value) => utf8.encode(value).map((b) {
  final safe =
      (b >= 65 && b <= 90) ||
      (b >= 97 && b <= 122) ||
      (b >= 48 && b <= 57) ||
      [45, 46, 95, 126, 42].contains(b);
  return safe
      ? String.fromCharCode(b)
      : '%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}';
}).join();
