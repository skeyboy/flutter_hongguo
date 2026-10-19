import 'dart:convert';
import 'dart:typed_data';

import 'bytes.dart';

/// Explicit result: v2 or malformed input cannot silently become an AES key.
class SpadeKey {
  final String hex;
  final int flag;
  const SpadeKey(this.hex, this.flag);
  Uint8List get bytes => unhex(hex);
}

class Spade {
  static bool isValidKey(String? key) =>
      key != null && RegExp(r'^[0-9a-f]{32}$').hasMatch(key);

  static int _popcount(int value) {
    var v = value.toUnsigned(32), count = 0;
    while (v != 0) {
      count += v & 1;
      v >>= 1;
    }
    return count;
  }

  static String? unwrapV1(Uint8List spade, [int flag = 0]) {
    if (flag != 0 && flag != 1) throw ArgumentError.value(flag, 'flag');
    final length = spade.length;
    if (length < 3) return null;
    final b = (spade[0] ^ spade[1] ^ spade[2]) & 255;
    final typeLength = b - 0x30, count = length - b + 0x2f;
    if (typeLength < 1 ||
        count < 1 ||
        count + 1 > length ||
        length - typeLength - 2 < 0) {
      return null;
    }
    final type = Uint8List(typeLength);
    final a = spade[length - typeLength - 2];
    final c = spade[length - typeLength - 1];
    for (var i = 0; i < typeLength; i++) {
      type[i] = a ^ c ^ spade[length - typeLength + i];
    }
    bool matches(String expected) {
      for (var i = 0; i < type.length; i++) {
        final v = i < expected.length ? expected.codeUnitAt(i) : 0;
        if (type[i] != v) return false;
        if (v == 0) return true;
      }
      return true;
    }

    if (matches('app_v2') || matches('web_v2')) return null;
    final dest = Uint8List.fromList(spade.sublist(1, 1 + count));
    var cur14 = 0x55, cur16 = 0xfa;
    for (var i = 0; i < count; i++) {
      final value = dest[i];
      var b3 = value, b7 = cur14;
      if (i.isOdd) {
        b3 = cur16;
        b7 = value;
        cur16 = cur14;
      }
      final shift = flag == 1 ? _popcount(i) + 0x15 : -0x15 - _popcount(i);
      dest[i] = (shift + (cur16 ^ value)) & 255;
      cur14 = b7;
      cur16 = b3;
    }
    final first = dest[0];
    final trim = first >= 0x30 && first <= 0x39
        ? first - 0x30
        : first >= 0x61 && first <= 0x7a
        ? first - 0x57
        : -1;
    if (trim < 0 || count - trim < 2) return null;
    return latin1.decode(dest.sublist(1, count - trim));
  }

  static SpadeKey? decode(String encoded, [int flag = 0]) {
    Uint8List raw;
    try {
      raw = decodeBase64(encoded);
    } on FormatException {
      return null;
    }
    for (final f in [flag, 1 - flag]) {
      final key = unwrapV1(raw, f);
      if (isValidKey(key)) return SpadeKey(key!, f);
    }
    return null;
  }
}
