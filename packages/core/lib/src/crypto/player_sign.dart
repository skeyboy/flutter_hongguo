// Legacy single-episode player signer for `/novel/player/video_model/v1/`,
// ported from hongguo-android `api/core/PlayerSign.java` (GPL-3.0-only; itself
// synced from LiuWQ0809/hongguo-android commit 3eaf813, which credits
// Xanerix/guoapp ad8dc125). Emits x-gorgon / x-argus / x-ladon plus the
// x-khronos / x-ss-req-ticket / x-ss-stub companions.
//
// This family is independent of both the account signer and the v5 playback
// signer: different gorgon layout, its own argus transform and AES envelope,
// and a self-contained ladon cipher. Never mix the three.
//
// Ported byte-for-byte against PlayerSignTest.java's pinned vectors
// (test/player_sign_test.dart). The 11-byte nonce is injectable so the vectors
// stay reproducible; production callers get secure randomness.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'bytes.dart' show aesCbcEncryptNoPadding, hex, md5, sm3, unhex;

class LegacyPlayerSign {
  LegacyPlayerSign._();

  /// Full header set for one legacy single-episode request.
  ///
  /// `nowMillis` is the wall clock; `nonce` overrides the random 11 bytes so
  /// the pinned vectors replay exactly. `deviceId` must be 1-30 digits, same
  /// gate as upstream.
  static Map<String, String> headers({
    required String query,
    required List<int> body,
    required int nowMillis,
    required String deviceId,
    List<int>? nonce,
  }) {
    if (!RegExp(r'^[0-9]{1,30}$').hasMatch(deviceId)) {
      throw ArgumentError.value(deviceId, 'deviceId', 'must be 1-30 digits');
    }
    final timestamp = nowMillis ~/ 1000;
    final nonceBytes = Uint8List.fromList(
      nonce ?? List.generate(11, (_) => Random.secure().nextInt(256)),
    );
    if (nonceBytes.length != 11) {
      throw ArgumentError.value(nonceBytes, 'nonce', 'must be 11 bytes');
    }
    return {
      'x-khronos': '$timestamp',
      'x-ss-req-ticket': '$nowMillis',
      'x-ss-stub': hex(md5(body)).toUpperCase(),
      'x-gorgon': gorgon(query, body, timestamp),
      'x-argus': argus(query, body, timestamp, deviceId, nonceBytes),
      'x-ladon': ladon(timestamp, Uint8List.fromList(nonceBytes.sublist(2, 6))),
    };
  }

  /// x-gorgon over the raw query bytes and the uncompressed body.
  static String gorgon(String query, List<int> body, int timestamp) {
    final data = Uint8List(20);
    final queryHash = md5(utf8Bytes(query));
    final bodyHash = md5(body);
    data.setRange(0, 4, queryHash);
    data.setRange(4, 8, bodyHash);
    data.setRange(12, 16, [0, 6, 11, 28]);
    // Java ByteBuffer default order is big endian.
    ByteData.sublistView(data, 16, 20).setInt32(0, timestamp, Endian.big);
    final key = unhex('44b9b9d9a4aef9fca493aa757ca3c2c4a496938f');
    for (var i = 0; i < data.length; i++) {
      data[i] ^= key[i];
    }
    for (var i = 0; i < data.length; i++) {
      final current = data[i] & 0xff;
      var mixed = ((current << 4) | (current >> 4)) & 0xff;
      mixed ^= data[(i + 1) % data.length] & 0xff;
      // Integer.reverse(mixed) >>> 24 on a byte-sized value is the bit
      // reversal of that byte's 8 bits.
      data[i] = (_reverseBits8(mixed) ^ 255 ^ data.length) & 0xff;
    }
    return hex(_join([unhex('8404401c0000'), data]));
  }

  /// x-ladon over the timestamp seconds and the 4 nonce bytes 2..6.
  static String ladon(int timestamp, Uint8List prefix) {
    final digest = Uint8List.fromList(
      utf8Bytes(hex(md5(_join([prefix, utf8Bytes('8662')])))),
    );
    final view = ByteData.sublistView(digest);
    var left = view.getInt64(0, Endian.little);
    var right = view.getInt64(8, Endian.little);
    final queue = List<int>.filled(36, 0);
    final keys = List<int>.filled(34, 0);
    queue[0] = view.getInt64(16, Endian.little);
    queue[1] = view.getInt64(24, Endian.little);
    for (var i = 0; i < keys.length; i++) {
      keys[i] = left;
      final mixed = (_rotr64(right, 8) + left) ^ i;
      queue[i + 2] = mixed;
      left = mixed ^ _rotl64(left, 3);
      right = queue[i];
    }
    final data = _pad(
      Uint8List.fromList(utf8Bytes('$timestamp-1611921764-8662')),
    );
    final buffer = ByteData.sublistView(data);
    for (var offset = 0; offset < data.length; offset += 16) {
      left = buffer.getInt64(offset, Endian.little);
      right = buffer.getInt64(offset + 8, Endian.little);
      for (final key in keys) {
        right = key ^ (left + _rotr64(right, 8));
        left = right ^ _rotl64(left, 3);
      }
      buffer.setInt64(offset, left, Endian.little);
      buffer.setInt64(offset + 8, right, Endian.little);
    }
    return base64Encode(_join([prefix, data]));
  }

  /// x-argus: proto message → 72-round transform → xor/reverse → AES-CBC.
  static String argus(
    String query,
    List<int> body,
    int timestamp,
    String deviceId,
    Uint8List nonce,
  ) {
    final key = unhex(
      'ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c',
    );
    final xorKey = unhex('d04ffdffd04ffdff');
    final message = _argusMessage(query, body, timestamp, deviceId, nonce);
    var data = _argusTransform(message, key);
    for (var i = 0; i < data.length; i++) {
      data[i] ^= xorKey[i % xorKey.length];
    }
    data = _join([xorKey, data]);
    for (var l = 0, r = data.length - 1; l < r; l++, r--) {
      final swap = data[l];
      data[l] = data[r];
      data[r] = swap;
    }
    final container = _pad(
      _join([unhex('a6e783ee7001100918'), data, unhex('567b')]),
    );
    final cipher = aesCbcEncryptNoPadding(
      md5(key.sublist(0, 16)),
      md5(key.sublist(16, 32)),
      container,
    );
    return base64Encode(_join([unhex('3ccc'), cipher]));
  }

  static Uint8List _argusMessage(
    String query,
    List<int> body,
    int timestamp,
    String deviceId,
    Uint8List nonce,
  ) {
    final bodyHash = sm3(md5(body));
    final queryHash = sm3(utf8Bytes(query));
    final nonceInt =
        ByteData.sublistView(nonce).getInt32(6, Endian.little) & 0x7fffffff;
    final counters = _join([
      _number(1, 1),
      _number(2, 1),
      _number(3, 1),
      _number(7, 3348294860),
    ]);
    final environment = _join([
      _text(1, '25053RT47C'),
      _text(2, '16'),
      _text(3, 'update_64'),
      _number(4, 2147483648),
    ]);
    return _join([
      _number(1, 0x20200929 * 2),
      _number(2, 2),
      _number(3, nonceInt),
      _text(4, '8662'),
      _text(5, deviceId),
      _text(6, '1611921764'),
      _text(7, '7.3.5.32'),
      _text(8, 'v04.07.01-ml-android'),
      _number(9, 135135744),
      _field(10, Uint8List(8)),
      _number(11, 0),
      _number(12, timestamp * 2),
      _field(13, Uint8List.fromList(bodyHash.sublist(0, 6))),
      _field(14, Uint8List.fromList(queryHash.sublist(0, 6))),
      _field(15, counters),
      _field(16, Uint8List(0)),
      _text(20, 'none'),
      _number(21, 738),
      _field(23, environment),
      _number(25, 2),
    ]);
  }

  static Uint8List _argusTransform(Uint8List message, Uint8List key) {
    final seed = _join([key, unhex('3ccc567b'), key]);
    final derived = sm3(seed);
    final derivedView = ByteData.sublistView(derived);
    final rounds = List<int>.filled(72, 0);
    for (var i = 0; i < 4; i++) {
      rounds[i] = derivedView.getInt64(i * 8, Endian.little);
    }
    for (var i = 4; i < rounds.length; i++) {
      var mixed = _rotr64(rounds[i - 1], 3) ^ rounds[i - 3];
      mixed ^= _rotr64(mixed, 1);
      rounds[i] = ~rounds[i - 4] ^ mixed ^ _tapBit((i - 4) % 62) ^ 3;
    }
    final data = _pad(message);
    final buffer = ByteData.sublistView(data);
    for (var offset = 0; offset < data.length; offset += 16) {
      var left = buffer.getInt64(offset, Endian.little);
      var right = buffer.getInt64(offset + 8, Endian.little);
      for (final round in rounds) {
        final next =
            left ^
            (_rotl64(right, 1) & _rotl64(right, 8)) ^
            _rotl64(right, 2) ^
            round;
        left = right;
        right = next;
      }
      buffer.setInt64(offset, left, Endian.little);
      buffer.setInt64(offset + 8, right, Endian.little);
    }
    return data;
  }

  // ---- helpers -----------------------------------------------------------

  /// Bit `k` (0..61) of the 64-bit round constant 0x3dc94c3a046d678b. The
  /// full literal cannot exist in JS-compiled Dart, so it is split into two
  /// 32-bit halves that are both exact.
  static int _tapBit(int k) {
    const hi = 0x3dc94c3a; // bits 32..63
    const lo = 0x046d678b; // bits 0..31
    return k >= 32 ? (hi >> (k - 32)) & 1 : (lo >> k) & 1;
  }

  static Uint8List utf8Bytes(String value) =>
      Uint8List.fromList(utf8.encode(value));

  static int _reverseBits8(int value) {
    var out = 0;
    for (var bit = 0; bit < 8; bit++) {
      if ((value >> bit) & 1 != 0) out |= 1 << (7 - bit);
    }
    return out;
  }

  static Uint8List _join(Iterable<List<int>> parts) {
    final out = BytesBuilder();
    for (final part in parts) {
      out.add(part);
    }
    return out.toBytes();
  }

  static Uint8List _varint(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'varint requires >= 0');
    }
    final out = BytesBuilder();
    // Division instead of shifts: the JS oracle compiles this library and
    // `>>` would truncate through int32 on values past 2^31.
    while (value > 127) {
      out.addByte((value & 127) | 128);
      value = value ~/ 128;
    }
    out.addByte(value);
    return out.toBytes();
  }

  /// Java `number(field, value)` writes `field * 8` then the raw varint.
  static Uint8List _number(int field, int value) =>
      _join([_varint(field * 8), _varint(value)]);

  /// Java `field(field, bytes)` writes `field * 8 + 2`, the length, the bytes.
  static Uint8List _field(int field, List<int> value) =>
      _join([_varint(field * 8 + 2), _varint(value.length), value]);

  static Uint8List _text(int field, String value) =>
      _field(field, utf8Bytes(value));

  /// Java `pad`: append `n` bytes of value `n` where n = 16 - len % 16, so
  /// short inputs always grow (1..16 bytes), never stay put.
  static Uint8List _pad(Uint8List data) {
    final n = 16 - data.length % 16;
    return Uint8List.fromList([...data, ...List.filled(n, n)]);
  }

  static int _rotr64(int value, int n) {
    final k = n & 63;
    if (k == 0) return value;
    // Mask the arithmetic-shift result: sign-extension bits would otherwise
    // leak into the rotated-in region.
    final lowMask = (1 << (64 - k)) - 1;
    return ((value >> k) & lowMask) | (value << (64 - k));
  }

  static int _rotl64(int value, int n) {
    final k = n & 63;
    if (k == 0) return value;
    return _rotr64(value, 64 - k);
  }
}
