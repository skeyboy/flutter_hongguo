// Ported from the corresponding hongguo-web JS module; see root THIRD_PARTY_NOTICES.md.
import 'dart:convert';
import 'dart:typed_data';

class SpadeKey {
  final String? key;
  final int flag;
  const SpadeKey(this.key, this.flag);
}

class Spade {
  static bool isValidKey(String? key) =>
      key != null && RegExp(r'^[0-9a-f]{32}$').hasMatch(key);
  static String? unwrapV1(List<int> spade, [int flag = 0]) {
    final length = spade.length;
    if (length < 3) return null;
    final marker = spade[0] ^ spade[1] ^ spade[2];
    final typeLength = marker - 0x30;
    final count = length - marker + 0x2f;
    if (typeLength < 1 ||
        count < 1 ||
        1 + count > length ||
        length - typeLength - 2 < 0)
      return null;
    final type = [
      for (var i = 0; i < typeLength; i++)
        spade[length - typeLength - 1] ^
            spade[length - typeLength - 2] ^
            spade[length - typeLength + i],
    ];
    bool matches(String text) {
      for (var i = 0; i < typeLength; i++) {
        final b = i < text.length ? text.codeUnitAt(i) : 0;
        if (type[i] != b) return false;
        if (b == 0) return true;
      }
      return true;
    }

    if (matches('app_v2') || matches('web_v2')) return null;
    final dest = Uint8List.fromList(spade.sublist(1, 1 + count));
    var cur14 = 0x55, cur16 = 0xfa;
    for (var i = 0; i < count; i++) {
      final value = dest[i];
      var bits = i, pop = 0;
      while (bits > 0) {
        pop += bits & 1;
        bits >>= 1;
      }
      var b3 = value, b7 = cur14;
      if (i.isOdd) {
        b3 = cur16;
        b7 = value;
        cur16 = cur14;
      }
      dest[i] =
          ((flag != 0 ? pop + 0x15 : -0x15 - pop) + (cur16 ^ value)) & 255;
      cur14 = b7;
      cur16 = b3;
    }
    final first = dest[0];
    final skip = first >= 0x30 && first <= 0x39
        ? first - 0x30
        : first >= 0x61 && first <= 0x7a
        ? first - 0x57
        : -1;
    if (skip < 0 || count - skip < 2) return null;
    return latin1.decode(dest.sublist(1, count - skip));
  }

  static SpadeKey toKey(String value, [int flag = 0]) {
    try {
      final raw = base64Decode(base64.normalize(value));
      final key = unwrapV1(raw, flag);
      if (isValidKey(key)) return SpadeKey(key, flag);
      final alt = unwrapV1(raw, 1 - flag);
      if (isValidKey(alt)) return SpadeKey(alt, 1 - flag);
    } on FormatException {
      /* malformed base64 */
    }
    return SpadeKey(null, flag);
  }
}
