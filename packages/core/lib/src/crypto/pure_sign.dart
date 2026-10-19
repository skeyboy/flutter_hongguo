// Port of hongguo-web PureSign. See NOTICE.md for provenance.
// Algorithm methods deliberately retain upstream names to ease byte-level audit.
// ignore_for_file: non_constant_identifier_names, unnecessary_parenthesis, curly_braces_in_flow_control_structures
import 'dart:convert';
import 'dart:typed_data';

import 'bytes.dart';

int _i32(dynamic value) => (value as num).truncate().toSigned(32);
int _u32(dynamic value) => (value as num).truncate().toUnsigned(32);
int _not(dynamic value) => (~_i32(value)).toSigned(32);
int _bit(String op, dynamic left, dynamic right) {
  final a = _i32(left), b = _i32(right);
  return switch (op) {
    '&' => a & b,
    '|' => a | b,
    '^' => a ^ b,
    '<<' => (a << (b & 31)).toSigned(32),
    '>>' => a >> (b & 31),
    '>>>' => a.toUnsigned(32) >> (b & 31),
    _ => throw ArgumentError(op),
  };
}

Uint8List _bytes(dynamic value, [String encoding = 'utf8']) {
  if (value is String) {
    return encoding == 'base64'
        ? decodeBase64(value)
        : Uint8List.fromList(utf8.encode(value));
  }
  return Uint8List.fromList(List<int>.from(value as Iterable));
}

Uint8List _concat(Iterable<dynamic> parts) => Uint8List.fromList([
  for (final part in parts) ...List<int>.from(part as Iterable),
]);
List<dynamic> _slice(dynamic bytes, int from, [int? to]) =>
    (bytes as List).sublist(from, to);
dynamic _fill(dynamic values, dynamic value) {
  values.fillRange(0, values.length, value);
  return values;
}

Uint8List _secureBytes(int n) => secureBytes(n);
int rotl(int x, int n) {
  final k = n & 31;
  return ((x << k) | (x.toUnsigned(32) >> ((32 - k) & 31))).toSigned(32);
}

int ror(int x, int n) {
  final k = n & 31;
  return ((x.toUnsigned(32) >> k) | (x << ((32 - k) & 31))).toSigned(32);
}

int rotl8(int x) => ((x << 4) | (x.toUnsigned(32) >> 4)) & 255;
int rotl8_3(int x) => ((x << 3) | (x.toUnsigned(32) >> 5)) & 255;
int reverseBits(int value) {
  var result = 0;
  for (var i = 0; i < 8; i++) result = (result << 1) | ((value >> i) & 1);
  return result;
}

int readLe32(dynamic b, int off) =>
    ByteData.sublistView(_bytes(b)).getInt32(off, Endian.little);
int readBe32(dynamic b, int off) =>
    ByteData.sublistView(_bytes(b)).getInt32(off, Endian.big);
void putLe32(dynamic b, int off, int value) {
  for (var i = 0; i < 4; i++) b[off + i] = (value >> (8 * i)) & 255;
}

void putBe32(dynamic b, int off, int value) {
  for (var i = 0; i < 4; i++) b[off + i] = (value >> (24 - 8 * i)) & 255;
}

Uint8List le32(int value) {
  final b = Uint8List(4);
  putLe32(b, 0, value);
  return b;
}

Uint8List be32(int value) {
  final b = Uint8List(4);
  putBe32(b, 0, value);
  return b;
}

BigInt readU64Le(List<int> b, int off) {
  var value = BigInt.zero;
  for (var i = 7; i >= 0; i--) value = (value << 8) | BigInt.from(b[off + i]);
  return value.toUnsigned(64);
}

void putU64Le(List<int> b, int off, BigInt value) {
  for (var i = 0; i < 8; i++)
    b[off + i] = ((value >> (8 * i)) & BigInt.from(255)).toInt();
}

BigInt rotr64(BigInt value, int n) {
  final v = value.toUnsigned(64), k = n & 63;
  return k == 0 ? v : ((v >> k) | (v << (64 - k))).toUnsigned(64);
}

List<dynamic> sliceBytes(dynamic b, int from, int to) => _slice(b, from, to);
Uint8List xorBytes(dynamic a, dynamic b) {
  final out = _bytes(a);
  for (var i = 0; i < out.length; i++) out[i] ^= b[i % b.length] as int;
  return out;
}

String b64(dynamic value) => base64Encode(List<int>.from(value as Iterable));
Uint8List varint(BigInt value) {
  if (value.isNegative) throw ArgumentError('Negative varint');
  final out = <int>[];
  while (value > BigInt.from(127)) {
    out.add(((value & BigInt.from(127)) | BigInt.from(128)).toInt());
    value >>= 7;
  }
  out.add(value.toInt());
  return Uint8List.fromList(out);
}

BigInt zigzag(BigInt value) =>
    value.isNegative ? (-value) * BigInt.two - BigInt.one : value * BigInt.two;
Uint8List protoField(int tag, dynamic value, String type) {
  if (value == null || (type == 'string' && value == '')) return Uint8List(0);
  Uint8List head, body;
  if (type == 'bytes' || type == 'message' || type == 'string') {
    body = type == 'string' ? _bytes('$value') : _bytes(value);
    head = _concat([
      varint((BigInt.from(tag) << 3) | BigInt.two),
      varint(BigInt.from(body.length)),
    ]);
  } else if (type == 'float') {
    body = Uint8List(4);
    ByteData.sublistView(body)
        .setFloat32(0, (value as num).toDouble(), Endian.little);
    head = varint((BigInt.from(tag) << 3) | BigInt.from(5));
  } else {
    final v = BigInt.from(value as num);
    head = varint(BigInt.from(tag) << 3);
    body = varint(type == 'sint' ? zigzag(v) : v);
  }
  return _concat([head, body]);
}

Uint8List proto(List<dynamic> fields) => _concat([
  for (final f in fields)
    protoField(f[0] as int, f[1], f.length > 2 ? f[2] as String : 'string'),
]);
dynamic BRANCH2_SV = [
  2813263392,
  1900671446,
  1206176263,
  3920990055,
  2478384350,
  3323252981,
  951050479,
  2998644083,
  3796124867,
  2637884571,
  3749394404,
  3635506496,
  4172034488,
  1991878923,
  836252654,
  2503986788,
  892704164,
  1175044411,
  915558408,
  2355956005,
  1576386935,
  486274347,
  2320476144,
  290235230,
  2173958532,
  2054850355,
  829076693,
  1008783305,
  2799191123,
  974671884,
  2039399546,
  2544331560,
  1724186518,
  1366385731,
  231930939,
  3043585447,
  3152755397,
  1548997124,
  3542485198,
  1920580076,
  4095250127,
  4158100443,
  858571921,
  2876681749,
  2615928615,
  413143940,
  1542060199,
  1603315540,
  968254400,
  912735363,
  2090005780,
  2642253015,
  3806910890,
  1602133673,
  2059224401,
  1453196762,
  1084380722,
  1039509925,
  3132325248,
  1161987804,
  1063079544,
  64468829,
  2986232567,
  2779457187,
];
dynamic BRANCH2_ORDERS = unhex(
  ("0f0704000908030a060b050d0e010c020f05080c0009020103070e060b0a0d04060500070c000a04080f010b0d09020e060b02050403080101070a000d0c090e0d070e0f0b0208030c0509010004060a0d0902060f0b0a040807000c0503010e0c090f07060f030e020d0405010b0a000c050a090e0802040407030f01060b000b0f0408020a0700090d06010e03050c0b060a0508020c03070f0e090d0001040906080f050800040a0b030d01020c0e090d0c0604070a03030f00080105020e01000d0f090a0b0e0402080703060c0501080a0c0f0905060b000304020e070d04080f000c0f0e0d0a01060207090503040205080d0b0a0606000e0f070c09030a08040f000b01060d0c0709030e05020a070b050f00020e0108030d0c0609040d070f08050f06040b0a0e0c090002030d0c020704010b0e0e08060f09050003"),
);
dynamic SBOX = _bytes(
  "+n0Ia5xZs0sEXznQOEqRmQBnpiCf9U2Ccybu3xhmgzOAAxn72f6uqqmwUsYL83klTni0NqxdGieeiNu9PGPsSRXBMB/cuFbUbM3KCUPINaPvHvSW0vwOcnuUhNHqRVpiAj/TEoE0K91+5ijypUYTATsh9mE3KSoN7Yyvv51cuyR2D3XkU4nhmI2xmmVwT1RMWKtub4sjxAcRDLrPoKSO2AU9FLLadMPX577Wf95IFj6FkKFVt3dCIsmGUC4X+WQxLJvxbRxEaOPpqJOXyzJX6+Vxaq3AzMfF/WAdoi1Hp+JRaV56zgpBtpWP97mH4DoGEIq1+FvV8LyS/3wvwugbQOwb2r26mJEMsiuDQTRn+wrYdrVGBVlhI3WQhyrjUBVMrLF5667llUcEaPCGPVGLD8qO5LlO8hKCvA7V9+8oJc9bXelqVQLhM76T5/WtnT45JKji+hdX0HoNCDDWuKON/QeaxB5uImSX0h2wv0VmP2zd2yeApxHcpsVS+MC2yFwAc2B7oBkTqsk1SEvTpM2fmfMQREBUfin0Bh+iq6EvPPavhWI2IX9e3yAas7Tm/3KEj2UmlFp36kN4x0rMLBRrxuh0U/zUHM4xcAMYjJY4MonxOl/X+alpt2M3WMI7w3HLnpIBigtNiJu7T21v4P6lSd5WFgntnMEt7oF92XzRLkJbTcGmXepE/UVOG6E/0YnhfS+q26utWcuxzpooyeD2cDlK1/8w9d28VzsRjbLuALbmGlp8+d7EzS6Au7lMpZ+ECMZvQmzwJ+eLOpxR+2chdUExp8ogQyq3v9l68rX4jCwjg0+PYKAEEzcU4wHFY2ZcdIHfWL1okD3SszT0GZMyKdZJrg1L2AeerB4tC0C4crp2EHGo5FYdSP7lwkeR2ocmnR+Ia8CYviUJlzOjhRZef9xuVOn3qcjow3fQgivsAmKKkg4+sA8F8/GWeDiGNhg8JM8KtFPMYWWkx5TVFX5t73kiNRJqjlIGVXtGZFCV4gzt0xcDopuZ6xz8r9Rzafpf9ywev8jh8592gHFIqpStZPuJxmDDMrNN0uBE3V+oscdoIzTJbRJ/t+sVvqnReJOgDJKk10fjisJwqyZBmnmn2BSFj8BvVtCMEbkuPOKdzw7eA11GPs04Qw8zWtkaZWwiO/wwpojqN6K0jY5RnNZA7vn4hPSul+nKCkVnVwQvg1zVxcSCtqORmB9KrJaBbssbCQivGJVJfVTt+hYxOtq4ZvWl8f4QAQZ0zGPffCgl9s6yT4vlvIdpu4YhBwA25wtQWZsc6GJYGWHyvSdeuh3mmUI9DSq13Fsp8C1MU3tqc04/df9LoTUXVXI5INOw/e8C7Hd+5CvbkMEFnnrUUmskEw==",
  "base64",
);
dynamic aesSrc(dynamic data, dynamic idx) {
  return ((idx < data.length) ? _bit("&", data[idx], 255) : 0);
}

dynamic aesPut(dynamic out, dynamic idx, dynamic value) {
  if (((idx >= 0) && (idx < out.length))) out[idx] = _bit("&", value, 255);
}

dynamic aesMatrix(dynamic bytes) {
  dynamic rows = List<dynamic>.filled(4, null);
  for (dynamic i = 0; (i < 4); i++) {
    rows[i] = List<dynamic>.filled(4, null);
    for (dynamic j = 0; (j < 4); j++)
      rows[i][j] = _bit("&", bytes[((i * 4) + j)], 255);
  }
  return rows;
}

dynamic aesFlat(dynamic rows) {
  dynamic b = Uint8List(16);
  for (dynamic i = 0; (i < 4); i++) {
    for (dynamic j = 0; (j < 4); j++)
      b[((i * 4) + j)] = _bit("&", rows[i][j], 255);
  }
  return b;
}

dynamic aesXt(dynamic x) {
  return _bit(
    "&",
    _bit("^", _bit("<<", x, 1), ((_bit("&", x, 128) != 0) ? 27 : 0)),
    255,
  );
}

dynamic aesMix(dynamic rows) {
  for (dynamic i = 0; (i < 4); i++) {
    dynamic t = _bit(
      "^",
      _bit("^", _bit("^", rows[0][i], rows[1][i]), rows[2][i]),
      rows[3][i],
    );
    dynamic u = rows[0][i];
    rows[0][i] = _bit(
      '^',
      rows[0][i],
      _bit("^", t, aesXt(_bit("^", rows[0][i], rows[1][i]))),
    );
    rows[1][i] = _bit(
      '^',
      rows[1][i],
      _bit("^", t, aesXt(_bit("^", rows[1][i], rows[2][i]))),
    );
    rows[2][i] = _bit(
      '^',
      rows[2][i],
      _bit("^", t, aesXt(_bit("^", rows[2][i], rows[3][i]))),
    );
    rows[3][i] = _bit(
      '^',
      rows[3][i],
      _bit("^", t, aesXt(_bit("^", rows[3][i], u))),
    );
  }
}

class AesV3 {
  late dynamic wordSize, box, con2, order, keys;
  AesV3(dynamic key, dynamic khronos) {
    wordSize = _bit("&", khronos, 3);
    box = sliceBytes(SBOX, (wordSize * 256), ((wordSize + 1) * 256));
    dynamic con2Table = [
      [1, 0, 2, 3],
      [2, 0, 3, 1],
      [0, 1, 3, 2],
      [1, 0, 2, 3],
    ];
    dynamic orderTable = [
      [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
      [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
      [0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15],
      [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
    ];
    con2 = con2Table[wordSize];
    order = orderTable[wordSize];
    dynamic init = [3389152732, 2185086278, 3376547203, 3264750175][wordSize];
    dynamic initial = Uint8List(16);
    for (dynamic i = 0; (i < 4); i++) putLe32(initial, (i * 4), init);
    dynamic mk = xorBytes(initial, key);
    dynamic expanded = _concat([mk, Uint8List(32)]);
    dynamic rounds = 8;
    for (dynamic i = 4; (i < 12); i++) {
      dynamic at = (4 * (i - 1));
      dynamic a = _bit("&", expanded[at], 255);
      dynamic b = _bit("&", expanded[(at + 1)], 255);
      dynamic c = _bit("&", expanded[(at + 2)], 255);
      dynamic d = _bit("&", expanded[(at + 3)], 255);
      if ((_bit("&", i, 3) == 0)) {
        dynamic t = _bit(
          "&",
          _bit(
            "^",
            _bit(">>>", init, _bit("&", rounds, 24)),
            _bit("&", box[b], 255),
          ),
          255,
        );
        b = _bit("&", box[c], 255);
        c = _bit("&", box[d], 255);
        d = _bit("&", box[a], 255);
        a = t;
      }
      rounds += 2;
      expanded[(at + 4)] = _bit(
        "&",
        _bit("^", a, _bit("&", expanded[(at - 12)], 255)),
        255,
      );
      expanded[(at + 5)] = _bit(
        "&",
        _bit("^", b, _bit("&", expanded[(at - 11)], 255)),
        255,
      );
      expanded[(at + 6)] = _bit(
        "&",
        _bit("^", c, _bit("&", expanded[(at - 10)], 255)),
        255,
      );
      expanded[(at + 7)] = _bit(
        "&",
        _bit("^", d, _bit("&", expanded[(at - 9)], 255)),
        255,
      );
    }
    keys = List<dynamic>.filled(12, null);
    for (dynamic i = 0; (i < 12); i++) {
      keys[i] = List<dynamic>.filled(4, null);
      for (dynamic j = 0; (j < 4); j++)
        keys[i][j] = _bit("&", expanded[((i * 4) + j)], 255);
    }
  }
  dynamic add(dynamic rows, dynamic key) {
    for (dynamic i = 0; (i < 4); i++) {
      for (dynamic j = 0; (j < 4); j++)
        rows[i][j] = _bit('^', rows[i][j], key[i][j]);
    }
  }

  dynamic addCon(dynamic rows, dynamic ks) {
    for (dynamic i = 0; (i < 4); i++) {
      for (dynamic j = 0; (j < 4); j++)
        rows[i][j] = _bit('^', rows[i][j], ks[i][con2[j]]);
    }
  }

  dynamic sub(dynamic rows) {
    for (dynamic i = 0; (i < 4); i++) {
      for (dynamic j = 0; (j < 4); j++)
        rows[i][j] = _bit("&", box[rows[i][j]], 255);
    }
    dynamic old = List<dynamic>.filled(4, null);
    for (dynamic i = 0; (i < 4); i++) old[i] = _slice(rows[i], 0);
    for (dynamic i = 0; (i < 4); i++) rows[i] = old[con2[i]];
  }

  dynamic shift(dynamic rows) {
    dynamic b = aesFlat(rows);
    for (dynamic i = 0; (i < 16); i++)
      rows[_i32((i / 4))][(i % 4)] = _bit("&", b[order[i]], 255);
  }

  dynamic shiftCon(dynamic rows) {
    dynamic old = List<dynamic>.filled(4, null);
    for (dynamic i = 0; (i < 4); i++) old[i] = _slice(rows[i], 0);
    for (dynamic i = 0; (i < 4); i++) {
      for (dynamic j = 0; (j < 4); j++) rows[i][j] = old[i][con2[j]];
    }
  }

  dynamic block(dynamic value) {
    dynamic rows = aesMatrix(value);
    dynamic k0 = subKeys(0);
    addCon(rows, k0);
    for (dynamic i = 1; (i < 3); i++) {
      sub(rows);
      shift(rows);
      if ((i == 1)) {
        shiftCon(rows);
        aesMix(rows);
      }
      addCon(rows, subKeys((i * 4)));
    }
    add(rows, subKeys(4));
    return aesFlat(rows);
  }

  dynamic subKeys(dynamic from) {
    dynamic out = List<dynamic>.filled(4, null);
    for (dynamic i = 0; (i < 4); i++) out[i] = _slice(keys[(from + i)], 0, 4);
    return out;
  }

  dynamic encrypt(dynamic data, dynamic iv) {
    dynamic plaintext = Uint8List(32);
    for (dynamic i = 0; (i < 31); i++) {
      dynamic at = (i * 8);
      dynamic n0 = _bit("&", _bit(">>", aesSrc(data, at), 4), 2);
      dynamic n1 = _bit("|", n0, _bit("&", aesSrc(data, (at + 1)), 64));
      dynamic n2 = _bit(
        "|",
        n1,
        _bit("&", _bit(">>", aesSrc(data, (at + 2)), 2), 1),
      );
      dynamic n3 = _bit(
        "|",
        n2,
        _bit("&", _bit("<<", aesSrc(data, (at + 3)), 3), 128),
      );
      dynamic n4 = _bit(
        "|",
        n3,
        _bit("&", _bit(">>", aesSrc(data, (at + 4)), 1), 4),
      );
      dynamic n5 = _bit(
        "|",
        n4,
        _bit("&", _bit("<<", aesSrc(data, (at + 5)), 3), 16),
      );
      dynamic n6 = _bit(
        "|",
        n5,
        _bit("&", _bit("<<", aesSrc(data, (at + 6)), 5), 32),
      );
      plaintext[i] = _bit(
        "&",
        _bit("|", n6, _bit("&", _bit(">>", aesSrc(data, (at + 7)), 4), 8)),
        255,
      );
    }
    plaintext[31] = 1;
    dynamic blocks = [];
    dynamic previous = _bytes(iv);
    for (dynamic i = 0; (i < plaintext.length); i += 16) {
      dynamic value = block(
        xorBytes(sliceBytes(plaintext, i, (i + 16)), previous),
      );
      blocks.add(value);
      previous = value;
    }
    dynamic key = _concat([...blocks]);
    dynamic out = _bytes(data);
    for (dynamic i = 0; (i < 31); i++) {
      dynamic at = (i * 8);
      dynamic k = _bit("&", key[i], 255);
      aesPut(
        out,
        at,
        _bit(
          "|",
          _bit("&", aesSrc(out, at), 223),
          _bit("&", _bit("<<", k, 4), 32),
        ),
      );
      aesPut(
        out,
        (at + 1),
        _bit("|", _bit("&", aesSrc(out, (at + 1)), 191), _bit("&", k, 64)),
      );
      aesPut(
        out,
        (at + 2),
        _bit(
          "|",
          _bit("&", aesSrc(out, (at + 2)), 251),
          _bit("&", _bit("<<", k, 2), 4),
        ),
      );
      aesPut(
        out,
        (at + 3),
        _bit(
          "|",
          _bit("&", aesSrc(out, (at + 3)), 239),
          _bit("&", _bit(">>", k, 3), 16),
        ),
      );
      aesPut(
        out,
        (at + 4),
        _bit("|", _bit("&", aesSrc(out, (at + 4)), 247), _bit("&", (k + k), 8)),
      );
      aesPut(
        out,
        (at + 5),
        _bit(
          "|",
          _bit("&", aesSrc(out, (at + 5)), 253),
          _bit("&", _bit(">>", k, 3), 2),
        ),
      );
      aesPut(
        out,
        (at + 6),
        _bit(
          "|",
          _bit("&", aesSrc(out, (at + 6)), 254),
          _bit("&", _bit(">>", k, 5), 1),
        ),
      );
      aesPut(
        out,
        (at + 7),
        _bit(
          "|",
          _bit("&", aesSrc(out, (at + 7)), 127),
          _bit("&", _bit("<<", k, 4), 128),
        ),
      );
    }
    return _concat([sliceBytes(key, (key.length - 1), key.length), out]);
  }
}

dynamic MEDUSA_SIGN_KEY = unhex(
  "8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eaef71cb691f7aa8aa2f5",
);
dynamic MEDUSA_AES_KEY = unhex("f1593376766ea98d34f31b057a9d5be4");
dynamic MEDUSA_AES_IV = unhex("1fe109a4125283f418de9e051a969e12");
dynamic MEDUSA_MAGIC16 = unhex("f7e85ffad7d7dc3bd62ac87057cf6118");
dynamic MEDUSA_MAGIC8 = unhex("4001000000000000");

class PureSign {
  final int Function() clockMillis;
  final Uint8List Function(int) entropy;
  late final String PROCESS_NONCE;
  late final int PROCESS_STARTED;
  PureSign({int Function()? clockMillis, Uint8List Function(int)? entropy})
    : clockMillis =
          clockMillis ?? (() => DateTime.now().millisecondsSinceEpoch),
      entropy = entropy ?? _secureBytes {
    PROCESS_NONCE = base64UrlEncode(this.entropy(18)).replaceAll('=', '');
    PROCESS_STARTED = this.clockMillis();
  }
  Uint8List randomBytes(int n) => entropy(n);
  int rndInt(int n) {
    // Rejection sampling: no modulo bias for non-power-of-two bounds.
    final ceiling = 0x100000000 - (0x100000000 % n);
    while (true) {
      final value = ByteData.sublistView(entropy(4)).getUint32(0);
      if (value < ceiling) return value % n;
    }
  }

  int rndInt32() => ByteData.sublistView(entropy(4)).getInt32(0);
  Map<String, String> sign(String url, Uint8List? body, [int? khronos]) {
    final ts = khronos ?? clockMillis() ~/ 1000;
    final query = _queryOf(url) as String;
    return {
      'x-gorgon': _xGorgon(query, body, ts, rndInt(65536)) as String,
      'x-khronos': '$ts',
      'x-ladon': b64(be32(ts)),
      'x-argus': b64(le32(ts)),
      'x-helios': _heliosWith(ts, rndInt32()),
      'x-medusa': _buildMedusa(
        url,
        body,
        ts,
        _paramOf(query, 'device_id', '0'),
        _paramOf(query, 'version_name', '7.1.3.32'),
      ) as String,
    };
  }

  String _heliosWith(int khronos, int random) {
    final ascii = _bytes(hex(md5(_concat([le32(random), _bytes('8662')]))));
    final words = List<BigInt>.generate(4, (i) => readU64Le(ascii, i * 8));
    final queue = [words[2], words[3]];
    var b0 = words[0];
    var b8 = words[1];
    final table = List<BigInt>.filled(35, BigInt.zero)..[0] = words[0];
    for (var i = 0; i < 34; i++) {
      var x8 = (rotr64(b8, 8) + b0).toUnsigned(64);
      x8 = (x8 ^ BigInt.from(i)).toUnsigned(64);
      queue.add(x8);
      x8 = (x8 ^ rotr64(b0, 61)).toUnsigned(64);
      table[i + 1] = x8;
      b0 = x8;
      b8 = queue.removeAt(0);
    }
    final tb = _bytes('$khronos-1588093228-8662');
    final pad = Uint8List(((tb.length + 16) ~/ 16) * 16)
      ..fillRange(0, ((tb.length + 16) ~/ 16) * 16, 16 - tb.length % 16)
      ..setRange(0, tb.length, tb);
    final output = <List<int>>[le32(random)];
    for (var at = 0; at < pad.length; at += 16) {
      var a = readU64Le(pad, at);
      var b = readU64Le(pad, at + 8);
      for (var i = 0; i < 34; i++) {
        b = (table[i] ^ (a + rotr64(b, 8)).toUnsigned(64)).toUnsigned(64);
        a = (b ^ rotr64(a, 61)).toUnsigned(64);
      }
      final block = Uint8List(16);
      putU64Le(block, 0, a);
      putU64Le(block, 8, b);
      output.add(block);
    }
    return b64(_concat(output));
  }

  dynamic _getIv(dynamic iv, dynamic data) {
    dynamic value = iv;
    for (dynamic i = 0; (i < data.length); i++) {
      dynamic d = _bit("&", data[i], 255);
      if ((_bit("&", i, 1) == 0)) {
        value = _i32(
          _bit(
            "^",
            _bit(
              "^",
              _bit("^", _bit(">>>", value, 4), value),
              _bit("<<", value, 6),
            ),
            d,
          ),
        );
      } else {
        value = _not(
          _bit(
            "^",
            _bit("^", _bit(">>>", value, 7), value),
            _bit("|", d, _bit("<<", value, 12)),
          ),
        );
      }
    }
    return value;
  }

  dynamic _sumMd5(dynamic data) {
    dynamic check = 539100192;
    for (dynamic i = 0; (i < 12); i++) {
      dynamic temp = ((_bit("&", i, 1) == 0)
          ? _bit("^", _bit(">>>", check, 3), check)
          : _bit("^", _bit(">>>", check, 5), check));
      check = ((_bit("&", i, 1) == 0)
          ? _bit("^", _bit("&", data[i], 255), _bit("<<", check, 7))
          : _bit("|", _bit("&", data[i], 255), _bit("<<", check, 11)));
      if ((_bit("&", i, 1) != 0)) check = _not(check);
      check = _bit("^", check, temp);
    }
    return _i32(_bit("^", _bit("|", check, 4), 16777216));
  }

  dynamic _md5V3Step(
    dynamic kind,
    dynamic a,
    dynamic b,
    dynamic c,
    dynamic d,
    dynamic m,
    dynamic shift,
    dynamic constant,
  ) {
    dynamic f;
    if ((kind == 0))
      f = _bit("|", _bit("&", b, c), _bit("&", _not(b), d));
    else if ((kind == 1))
      f = _bit("|", _bit("&", b, d), _bit("&", c, _not(d)));
    else if ((kind == 2))
      f = _bit("^", _bit("^", b, c), d);
    else
      f = _bit("^", c, _bit("|", b, _not(d)));
    return _i32((b + rotl(_i32((((a + f) + m) + constant)), shift)));
  }

  dynamic _md5SumV3(
    dynamic message,
    dynamic countV2,
    dynamic orders,
    dynamic countV1,
  ) {
    dynamic sv = List<dynamic>.filled(BRANCH2_SV.length, null);
    for (dynamic i = 0; (i < sv.length); i++)
      sv[i] = ror(BRANCH2_SV[i], countV1);
    dynamic start = [
      ror(2044785403, countV2),
      ror(3367314800, countV2),
      ror(3955423437, countV2),
      ror(2081443219, countV2),
    ];
    dynamic endCount = _bit("&", (countV2 + 6), 255);
    dynamic end = [
      ror(431900774, endCount),
      ror(3898181300, endCount),
      ror(3785044590, endCount),
      ror(1909577684, endCount),
    ];
    dynamic m = List<dynamic>.filled(16, null);
    for (dynamic i = 0; (i < 16); i++) m[i] = readLe32(message, (i * 4));
    dynamic a = start[0];
    dynamic b = start[1];
    dynamic c = start[2];
    dynamic d = start[3];
    dynamic shifts0 = [
      7,
      12,
      17,
      22,
      7,
      12,
      17,
      22,
      7,
      12,
      17,
      22,
      7,
      12,
      17,
      22,
    ];
    dynamic shifts1 = [5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20];
    dynamic shifts2 = [
      4,
      11,
      16,
      23,
      4,
      11,
      16,
      23,
      4,
      11,
      16,
      23,
      4,
      11,
      16,
      23,
    ];
    dynamic shifts3 = [
      6,
      10,
      15,
      21,
      6,
      10,
      15,
      21,
      6,
      10,
      15,
      21,
      6,
      10,
      15,
      21,
    ];
    for (dynamic kind = 0; (kind < 4); kind++) {
      dynamic shifts = ((kind == 0)
          ? shifts0
          : ((kind == 1) ? shifts1 : ((kind == 2) ? shifts2 : shifts3)));
      dynamic offset = (kind * 16);
      for (dynamic i = 0; (i < 16); i++) {
        dynamic phase = _bit("&", i, 3);
        dynamic mm = m[_bit("&", orders[(offset + i)], 255)];
        dynamic cc = sv[(offset + i)];
        dynamic next;
        if ((phase == 0))
          next = _md5V3Step(kind, a, b, c, d, mm, shifts[i], cc);
        else if ((phase == 1))
          next = _md5V3Step(kind, d, a, b, c, mm, shifts[i], cc);
        else if ((phase == 2))
          next = _md5V3Step(kind, c, d, a, b, mm, shifts[i], cc);
        else
          next = _md5V3Step(kind, b, c, d, a, mm, shifts[i], cc);
        if ((phase == 0))
          a = next;
        else if ((phase == 1))
          d = next;
        else if ((phase == 2))
          c = next;
        else
          b = next;
      }
    }
    dynamic ret = Uint8List(16);
    putLe32(ret, 0, _bit("^", (start[0] + a), end[0]));
    putLe32(ret, 4, _bit("^", (start[1] + b), end[1]));
    putLe32(ret, 8, _bit("^", (start[2] + c), end[2]));
    putLe32(ret, 12, _bit("^", (start[3] + d), end[3]));
    return _concat([ret, le32(_sumMd5(ret))]);
  }

  dynamic _branch2F13(
    dynamic iv,
    dynamic querySm3,
    dynamic bodyMd5,
    dynamic tsBytes,
    dynamic khronos,
  ) {
    dynamic v = (_bit("&", iv, 13) * 86);
    dynamic ivV0 =
        (_bit("&", _bit(">>>", v, 15), 255) +
        _bit("&", _bit(">>>", v, 8), 255));
    dynamic n1 = [
      2306929307,
      3948190847,
      2961647323,
      3557602790,
      3908393444,
    ][ivV0];
    dynamic countV1 = _bit("&", ((n1 + khronos) + 1), 255);
    dynamic countV2 = _i32((n1 + khronos));
    dynamic shift = _bit("&", (countV2 + 5), 7);
    dynamic seed = [132, 150, 119, 157, 212, 21, 11, 248];
    dynamic pad = Uint8List(8);
    for (dynamic i = 0; (i < 8); i++)
      pad[i] = _bit(
        "&",
        _bit(">>", _bit("|", seed[i], _bit("<<", seed[i], 8)), shift),
        255,
      );
    dynamic input = _concat([
      querySm3,
      bodyMd5,
      tsBytes,
      pad,
      unhex("a0010000"),
    ]);
    dynamic from = _bit("<<", ivV0, 6);
    dynamic to = _bit("<<", (ivV0 + 1), 6);
    dynamic orders = sliceBytes(BRANCH2_ORDERS, from, to);
    return _md5SumV3(input, countV2, orders, countV1);
  }

  dynamic _hashF13(
    dynamic querySm3,
    dynamic bodyMd5,
    dynamic tsBytes,
    dynamic khronos,
  ) {
    dynamic iv = _getIv(_getIv(_getIv(539167016, querySm3), bodyMd5), tsBytes);
    dynamic low = _bit("&", iv, 15);
    dynamic ivV0 = _bit(">>", (low * 171), 9);
    dynamic branch = (low - (ivV0 * 3));
    if ((branch == 2))
      return _branch2F13(iv, querySm3, bodyMd5, tsBytes, khronos);
    if ((branch != 0)) {
      return _concat([
        sliceBytes(querySm3, 0, 16),
        bodyMd5,
        le32(_sumMd5(_concat([querySm3, bodyMd5]))),
      ]);
    }
    dynamic ivV1List = [
      3299313024,
      3015769401,
      3314308742,
      3383376807,
      4121406962,
      2520526545,
    ];
    dynamic ivV1 = _i32(ivV1List[ivV0]);
    dynamic countV1 = _bit("&", ((ivV1 + khronos) + 1), 255);
    dynamic countV2 = _i32((ivV1 + khronos));
    dynamic tt02 = [
      3954593711,
      128638146,
      3476129727,
      3759225087,
      1829502207,
      1513137086,
      3021657656,
      873991864,
      4063488879,
      2980414668,
      3435335111,
      1204935505,
      3579204574,
      1890078625,
      1464286226,
      4151247496,
      738688778,
      3658336976,
      4223168364,
      4257533696,
      1753874957,
      3866543782,
      2362848139,
      440175886,
      3437801579,
      1792077067,
      2689738519,
      3698437251,
      579197809,
      3585400230,
      1936688720,
      1700802668,
      1635574438,
      3827515774,
      172024131,
      1414414386,
      2296380202,
      1902910176,
      1279687304,
      95566771,
      3788552294,
      3131301048,
      2922607827,
      3275233872,
      386070363,
      4268598120,
      4038381384,
      1309670328,
      1923797261,
      650459709,
      4072464630,
      3025499521,
      1243971549,
      2352054946,
      2869640070,
      1029569300,
      1326462516,
      3548074711,
      1146027798,
      3943314385,
      1822977902,
      2640807,
      137919738,
      1605596550,
    ];
    dynamic tt = List<dynamic>.filled(tt02.length, null);
    for (dynamic i = 0; (i < tt.length); i++) tt[i] = ror(tt02[i], countV1);
    dynamic n0 = _bit("&", (countV2 + 2), 7);
    dynamic seed = [250, 69, 97, 215];
    dynamic pad = Uint8List(seed.length);
    for (dynamic i = 0; (i < seed.length); i++)
      pad[i] = _bit(
        "&",
        _bit(">>", _bit("|", seed[i], _bit("<<", seed[i], 8)), n0),
        255,
      );
    dynamic data = _concat([
      querySm3,
      bodyMd5,
      tsBytes,
      pad,
      unhex("00000000000001a0"),
    ]);
    dynamic di = _fill(
      List<dynamic>.filled((((data.length ~/ 4) + 112) + 16), null),
      0,
    );
    dynamic diLen = 0;
    for (dynamic i = 0; ((i + 3) < data.length); i += 4)
      di[diLen++] = readBe32(data, i);
    dynamic di0 = di[0];
    for (dynamic i = 0; (i < 112); i++) {
      dynamic di1 = di[(i + 1)];
      dynamic di14 = di[(i + 14)];
      dynamic r1 = _bit(
        "^",
        _bit("^", rotl(di1, 14), rotl(di1, 25)),
        _bit(">>>", di1, 3),
      );
      dynamic r2 = _bit(
        "^",
        _bit("^", rotl(di14, 13), rotl(di14, 15)),
        _bit(">>>", di14, 10),
      );
      di[diLen++] = _i32((((di0 + di[(i + 9)]) + r1) + r2));
    }
    dynamic initRaw = [
      2059030472,
      1729520903,
      1677982208,
      873419055,
      984304912,
      3005047866,
      2874125293,
      2152413264,
    ];
    dynamic init = List<dynamic>.filled(8, null);
    for (dynamic i = 0; (i < 8); i++)
      init[i] = ror(initRaw[i], _bit("&", countV2, 31));
    dynamic chosenTable = [
      [101, 5, 7, 6, 3, 2, 1, 0, 5, 4, 3],
      [96, 0, 6, 7, 5, 3, 2, 1, 5, 4, 4],
      [96, 7, 6, 2, 1, 4, 0, 5, 4, 3, 5],
      [99, 3, 6, 2, 4, 5, 1, 0, 0, 7, 6],
      [96, 0, 5, 6, 7, 3, 1, 2, 5, 4, 4],
      [100, 2, 0, 3, 5, 4, 6, 7, 2, 1, 5],
    ];
    dynamic chosen = chosenTable[ivV0];
    dynamic d = _slice(init, 0);
    for (dynamic i = 0; (i < chosen[0]); i++) {
      dynamic base = _i32((ivV1 + i));
      dynamic n0v = di[_bit("&", base, 127)];
      dynamic n1 = _bit(
        "^",
        _bit("&", _bit("^", d[chosen[3]], d[chosen[4]]), d[chosen[1]]),
        d[chosen[3]],
      );
      dynamic n2 = _bit(
        "^",
        _bit("^", rotl(d[chosen[1]], 26), rotl(d[chosen[1]], 21)),
        rotl(d[chosen[1]], 7),
      );
      dynamic n4 = _i32(
        ((((n0v + n1) + n2) + tt[_bit("&", base, 63)]) + d[chosen[5]]),
      );
      dynamic n5 = _bit(
        "^",
        _bit("^", rotl(d[chosen[2]], 30), rotl(d[chosen[2]], 19)),
        rotl(d[chosen[2]], 10),
      );
      dynamic n6 = _bit(
        "|",
        _bit("&", d[chosen[2]], d[chosen[6]]),
        _bit("&", _bit("|", d[chosen[2]], d[chosen[6]]), d[chosen[7]]),
      );
      dynamic n7 = _i32((n5 + n6));
      dynamic old = d[chosen[9]];
      dynamic last = d[(d.length - 1)];
      for (dynamic k = (d.length - 1); (k >= 1); k--) d[k] = d[(k - 1)];
      d[0] = last;
      d[chosen[10]] = _i32((n7 + n4));
      d[chosen[8]] = _i32((old + n4));
    }
    dynamic ret = Uint8List(32);
    for (dynamic i = 0; (i < 8); i++)
      putBe32(ret, (i * 4), _i32((d[i] + init[i])));
    for (dynamic i = 0; (i < 16); i++)
      ret[i] = _bit("^", ret[i], ret[(i + 16)]);
    return _concat([
      sliceBytes(ret, 0, 16),
      le32(_sumMd5(sliceBytes(ret, 0, 16))),
    ]);
  }

  dynamic _rc4Gorgon(dynamic data, dynamic key) {
    dynamic s = List<dynamic>.filled(256, null);
    for (dynamic i = 0; (i < 256); i++) s[i] = i;
    dynamic j = 0;
    for (dynamic i = 0; (i < 256); i++) {
      j = _bit("&", ((j + s[i]) + key[(i % key.length)]), 255);
      s[i] = s[j];
    }
    dynamic out = Uint8List(data.length);
    dynamic i = 0;
    j = 0;
    for (dynamic k = 0; (k < data.length); k++) {
      i += 1;
      dynamic x = s[i];
      j += x;
      dynamic y = s[_bit("&", j, 255)];
      s[i] = y;
      out[k] = _bit("^", data[k], s[_bit("&", (y + y), 255)]);
    }
    return out;
  }

  dynamic _xGorgon(
    dynamic query,
    dynamic body,
    dynamic timestamp,
    dynamic random,
  ) {
    dynamic q4 = sliceBytes(md5(_bytes(query, "utf8")), 0, 4);
    dynamic b4 = (((body != null) && (body.length > 0))
        ? sliceBytes(md5(body), 0, 4)
        : Uint8List(4));
    dynamic sdk = le32(67503104);
    dynamic input = _concat([q4, b4, Uint8List(4), sdk, be32(_i32(timestamp))]);
    dynamic key = [
      74,
      64,
      22,
      _bit("&", _bit(">>", random, 8), 255),
      71,
      108,
      1,
      _bit("&", random, 255),
    ];
    dynamic out = _rc4Gorgon(input, key);
    for (dynamic i = 0; (i < out.length); i++) {
      dynamic value = rotl8(_bit("&", out[i], 255));
      dynamic next = (((i + 1) < out.length)
          ? _bit("&", out[(i + 1)], 255)
          : _bit("&", out[0], 255));
      out[i] = _bit(
        "&",
        _not(
          _bit("^", reverseBits(_bit("&", _bit("^", next, value), 255)), 20),
        ),
        255,
      );
    }
    return hex(
      _concat([
        unhex("8404"),
        _bytes([
          _bit("&", random, 255),
          _bit("&", _bit(">>", random, 8), 255),
          64,
          1,
        ]),
        out,
      ]),
    );
  }

  dynamic _xmxor(dynamic data, dynamic key) {
    dynamic encoded = Uint8List(data.length);
    for (dynamic i = 0; (i < data.length); i++) {
      dynamic at = _bit("&", (i * 4), 28);
      dynamic d0 = _bit("&", key[at], 255);
      dynamic d1 = _bit("&", key[(at + 1)], 255);
      dynamic d2 = (rotl8(_bit("&", data[i], 255)) + d0);
      d2 = _bit("^", _not(d2), d1);
      d2 = rotl8_3(_bit("&", d2, 255));
      d2 = _bit("&", (d2 + d1), 255);
      d2 = _bit("&", _bit("^", d2, d0), 255);
      encoded[((data.length - i) - 1)] = _bit("&", _not(d2), 255);
    }
    dynamic last = _bit(
      "&",
      _bit("^", encoded[(encoded.length - 1)], encoded[(encoded.length - 2)]),
      255,
    );
    dynamic first = _bit("&", encoded[0], 255);
    encoded[0] = _bit("&", (_not(last) + first), 255);
    encoded[1] = _bit(
      "&",
      (_bit("^", _bit("^", encoded[0], encoded[(encoded.length - 1)]), 254) +
          encoded[1]),
      255,
    );
    encoded[2] = _bit(
      "&",
      (encoded[2] +
          _bit(
            "^",
            _bit("^", (last - first), rotl8_3(_bit("&", encoded[1], 255))),
            2,
          )),
      255,
    );
    for (dynamic i = 0; (i < (encoded.length - 4)); i++) {
      dynamic temp = _bit(
        "^",
        _bit("^", rotl8_3(_bit("&", encoded[(i + 2)], 255)), encoded[(i + 1)]),
        (i + 3),
      );
      encoded[(i + 3)] = _bit("&", (_not(temp) + encoded[(i + 3)]), 255);
    }
    encoded[(encoded.length - 1)] = _bit(
      "&",
      _bit("^", encoded[(encoded.length - 1)], encoded[(encoded.length - 2)]),
      255,
    );
    dynamic sum = 0;
    for (dynamic i = 0; (i < (encoded.length - 1)); i++)
      sum += _bit("&", encoded[(i + 1)], 255);
    encoded[0] = _bit("&", (_bit("^", encoded[0], encoded[1]) + sum), 255);
    return encoded;
  }

  dynamic _keyHash(dynamic signKey, dynamic random) {
    dynamic hash = sm3(_concat([signKey, le32(random), signKey]));
    dynamic d1 = _bit("&", _bit(">>", random, 16), 255);
    dynamic d2 = _bit(
      "^",
      _bit(
        "^",
        _bit("|", _bit("<<", d1, 11), _bit(">>>", random, 24)),
        _bit(">>", d1, 5),
      ),
      d1,
    );
    d2 = _not(d2);
    return [hash, le32(d2)];
  }

  dynamic _deviceProto(dynamic deviceId, dynamic version) {
    return proto([
      [1, 1, "sint"],
      [2, 2, "sint"],
      [3, "8662"],
      [4, deviceId],
      [5, PROCESS_NONCE],
      [6, "!noperm!"],
      [7, (-888888), "sint"],
      [8, (-888888), "sint"],
      [9, 3, "sint"],
      [10, (-888888), "sint"],
      [11, "!notset!"],
      [12, "Asia/Shanghai,8"],
      [13, "zh_CN"],
      [14, 4, "sint"],
      [16, 0, "float"],
      [17, 0, "float"],
      [18, 0, "float"],
      [19, 0, "float"],
      [20, 0, "float"],
      [21, 0, "float"],
      [22, "16"],
      [23, 41, "sint"],
      [24, 36, "sint"],
      [25, PROCESS_STARTED, "sint"],
      [26, PROCESS_STARTED, "sint"],
      [27, PROCESS_STARTED, "sint"],
      [28, PROCESS_STARTED, "sint"],
      [29, (-1), "sint"],
      [30, "25053RT47C"],
      [31, "Redmi"],
      [32, "25053RT47C"],
      [33, "25053RT47C"],
      [34, "Xiaomi"],
      [35, "Redmi"],
      [36, "Redmi"],
      [38, 31, "sint"],
    ]);
  }

  dynamic _buildMedusa(
    dynamic url,
    dynamic body,
    dynamic khronos,
    dynamic deviceId,
    dynamic version,
  ) {
    dynamic bodyMd5 = (((body != null) && (body.length > 0))
        ? md5(body)
        : Uint8List(16));
    dynamic query = _queryOf(url);
    dynamic querySm3 = sm3(_bytes(query, "utf8"));
    dynamic ts = le32(_i32(khronos));
    dynamic queryBodyTs = _hashF13(querySm3, bodyMd5, ts, khronos);
    dynamic messageRand = randomBytes(4);
    dynamic messageRandU = _u32(readLe32(messageRand, 0));
    dynamic envLaunch = (100 + rndInt(21));
    dynamic envPid = (10001 + rndInt(2000));
    dynamic env = proto([
      [1, envLaunch, "sint"],
      [2, 146331399, "sint"],
      [3, 146331396, "sint"],
      [5, 7, "sint"],
      [6, "v04.06.04.03-bugfix"],
      [7, envPid, "sint"],
      [12, _deviceProto(deviceId, version), "message"],
      [
        13,
        proto([
          [1, ((clockMillis() / 1000)).floor(), "sint"],
          [2, (-2), "sint"],
          [4, 200, "sint"],
        ]),
        "message",
      ],
      [14, version],
    ]);
    dynamic queryHash = sm3(
      _concat([_bytes(query, "utf8"), bodyMd5, _bytes("none", "utf8")]),
    );
    dynamic nested = proto([
      [1, 111, "sint"],
      [2, 10, "sint"],
      [3, 694367, "sint"],
      [5, 586952199, "sint"],
    ]);
    dynamic message = proto([
      [1, MEDUSA_MAGIC16, "bytes"],
      [2, 3, "sint"],
      [3, messageRandU, "sint"],
      [4, "8662"],
      [5, deviceId],
      [6, "1588093228"],
      [7, version],
      [8, "v04.06.04-ml-android"],
      [9, 67503104, "sint"],
      [10, MEDUSA_MAGIC8, "bytes"],
      [12, khronos, "sint"],
      [13, queryBodyTs, "bytes"],
      [14, sliceBytes(querySm3, 0, 6), "bytes"],
      [15, nested, "message"],
      [16, PROCESS_NONCE],
      [17, khronos, "sint"],
      [19, queryHash, "bytes"],
      [20, "none"],
      [21, 312, "sint"],
      [23, env, "message"],
      [
        24,
        ("{\"cmr\":16777216,\"cmr2\":16777216,\"un_h\":1879194040,\"vpn\":0,\"kd\":0,\"fkd\":3672518972,\"pd\":-1872573247,\"dyn\":\"\",\"do\":0,\"tk\":true}"),
      ],
    ]);
    dynamic random = rndInt32();
    dynamic hs = _keyHash(MEDUSA_SIGN_KEY, random);
    dynamic hash = hs[0];
    dynamic seed = hs[1];
    dynamic transformed = _xmxor(message, hash);
    transformed = _concat([MEDUSA_MAGIC8, transformed]);
    for (dynamic i = 0, j = (transformed.length - 1); (i < j); i++, j--) {
      dynamic t = transformed[i];
      transformed[i] = transformed[j];
      transformed[j] = t;
    }
    for (dynamic i = 0; (i < transformed.length); i++) {
      transformed[i] = _bit(
        "&",
        _bit("^", transformed[i], seed[_bit("&", _not(i), 3)]),
        255,
      );
    }
    dynamic check = _i32(
      _bit(
        "|",
        _bit("|", _bit("<<", _bit("&", querySm3[0], 63), 14), 402653185),
        _bit("<<", _bit("&", queryBodyTs[0], 63), 8),
      ),
    );
    dynamic xmRand = rndInt32();
    dynamic packed = _concat([
      _bytes([53]),
      le32(xmRand),
      le32(check),
      transformed,
      _bytes([
        _bit("&", _bit(">>", random, 16), 255),
        _bit("&", _bit(">>", random, 24), 255),
      ]),
    ]);
    dynamic encrypted = AesV3(
      MEDUSA_AES_KEY,
      khronos,
    ).encrypt(packed, MEDUSA_AES_IV);
    dynamic versionBytes = unhex("03000000f7e85ffad7d7dc3bd62ac87057cf6118");
    dynamic prefix = Uint8List(20);
    for (dynamic i = 0; (i < 20); i += 4) {
      putLe32(prefix, i, _bit("^", readLe32(versionBytes, i), _i32(khronos)));
    }
    return b64(
      _concat([
        prefix,
        _bytes([
          _bit("&", random, 255),
          _bit("&", _bit(">>", random, 8), 255),
          0,
          1,
        ]),
        encrypted,
      ]),
    );
  }

  int branchOf(String url, Uint8List? body, int khronos) {
    dynamic bodyMd5 = (((body != null) && (body.isNotEmpty))
        ? md5(body)
        : Uint8List(16));
    dynamic q = sm3(_bytes(_queryOf(url), "utf8"));
    dynamic iv = _getIv(
      _getIv(_getIv(539167016, q), bodyMd5),
      le32(_i32(khronos)),
    );
    dynamic low = _bit("&", iv, 15);
    return (low - (_bit(">>", (low * 171), 9) * 3));
  }

  dynamic _queryOf(dynamic url) {
    dynamic i = url.indexOf("?");
    return ((i < 0) ? "" : url.substring((i + 1)));
  }

  dynamic _paramOf(dynamic query, dynamic key, dynamic fallback) {
    for (final kv in query.split("&")) {
      dynamic eq = kv.indexOf("=");
      if ((eq <= 0)) continue;
      if ((kv.substring(0, eq) == key)) {
        dynamic v = kv.substring((eq + 1));
        if ((v.length > 0)) return v;
      }
    }
    return fallback;
  }
}
