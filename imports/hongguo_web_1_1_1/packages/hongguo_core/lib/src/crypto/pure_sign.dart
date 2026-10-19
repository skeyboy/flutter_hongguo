// Ported from server/src/core/pure-sign.js. See THIRD_PARTY_NOTICES.md.
import 'dart:convert';
import 'dart:typed_data';
import 'bytes.dart';
import '../ports/runtime.dart';

BigInt uint64(BigInt x) => x.toUnsigned(64);

int rotl(int x, int n) {
  final k = n & 31;
  return i32((u32(x) << k) | shr32(x, 32 - k));
}

int ror(int x, int n) {
  final k = n & 31;
  return i32(shr32(x, k) | (u32(x) << ((32 - k) & 31)));
}

int rotl8(int x) => ((x << 4) | (x >> 4)) & 255;
int rotl8_3(int x) => ((x << 3) | (x >> 5)) & 255;
int reverseBits(int v) {
  var r = 0;
  for (var i = 0; i < 8; i++) {
    r = (r << 1) | ((v >> i) & 1);
  }
  return r;
}

int readLe32(List<int> b, int o) =>
    i32(ByteData.sublistView(bytes(b)).getUint32(o, Endian.little));
int readBe32(List<int> b, int o) =>
    i32(ByteData.sublistView(bytes(b)).getUint32(o));
void putLe32(List<int> b, int o, int v) {
  for (var i = 0; i < 4; i++) {
    b[o + i] = (v >> (i * 8)) & 255;
  }
}

void putBe32(List<int> b, int o, int v) {
  for (var i = 0; i < 4; i++) {
    b[o + i] = (v >> (24 - i * 8)) & 255;
  }
}

Uint8List le32(int v) {
  final b = Uint8List(4);
  putLe32(b, 0, v);
  return b;
}

Uint8List be32(int v) {
  final b = Uint8List(4);
  putBe32(b, 0, v);
  return b;
}

BigInt readU64Le(List<int> b, int o) {
  var v = BigInt.zero;
  for (var i = 7; i >= 0; i--) {
    v = (v << 8) | BigInt.from(b[o + i]);
  }
  return v.toUnsigned(64);
}

void putU64Le(List<int> b, int o, BigInt v) {
  for (var i = 0; i < 8; i++) {
    b[o + i] = ((v >> (i * 8)) & BigInt.from(255)).toInt();
  }
}

BigInt rotr64(BigInt x, int n) {
  final v = x.toUnsigned(64), k = n & 63;
  return ((v >> k) | (v << (64 - k))).toUnsigned(64);
}

Uint8List sliceBytes(List<int> b, int from, int to) =>
    bytes(b.sublist(from, to));
Uint8List xorBytes(List<int> a, List<int> b) =>
    bytes([for (var i = 0; i < a.length; i++) a[i] ^ b[i % b.length]]);
Uint8List md5(List<int> data) => md5Bytes(data);
Uint8List sm3(List<int> data) => sm3Bytes(data);
String b64(List<int> data) => base64Encode(data);
Uint8List varint(dynamic value) {
  var n = value is BigInt ? value : BigInt.from(value as int);
  if (n.isNegative) throw ArgumentError('negative varint');
  final out = <int>[];
  while (n > BigInt.from(127)) {
    out.add(((n & BigInt.from(127)) | BigInt.from(128)).toInt());
    n >>= 7;
  }
  out.add(n.toInt());
  return bytes(out);
}

BigInt zigzag(BigInt v) =>
    v.isNegative ? -v * BigInt.two - BigInt.one : v * BigInt.two;
Uint8List protoField(int tag, dynamic value, String type) {
  if (value == null || (type == 'string' && value == '')) return Uint8List(0);
  late List<int> body;
  late List<int> head;
  if (type == 'bytes' || type == 'message' || type == 'string') {
    body = type == 'string'
        ? utf8Bytes(value.toString())
        : List<int>.from(value);
    head = joinBytes([varint((tag << 3) | 2), varint(body.length)]);
  } else if (type == 'float') {
    final b = ByteData(4)
      ..setFloat32(0, (value as num).toDouble(), Endian.little);
    body = b.buffer.asUint8List();
    head = varint((tag << 3) | 5);
  } else {
    final v = BigInt.from(value as int);
    head = varint(tag << 3);
    body = varint(type == 'sint' ? zigzag(v) : v);
  }
  return joinBytes([head, body]);
}

Uint8List proto(List<List<dynamic>> fields) => joinBytes([
  for (final f in fields)
    protoField(f[0], f[1], f.length > 2 ? f[2] : 'string'),
]);

final SBOX = base64Decode(
  '+n0Ia5xZs0sEXznQOEqRmQBnpiCf9U2Ccybu3xhmgzOAAxn72f6uqqmwUsYL83klTni0NqxdGieeiNu9PGPsSRXBMB/cuFbUbM3KCUPINaPvHvSW0vwOcnuUhNHqRVpiAj/TEoE0K91+5ijypUYTATsh9mE3KSoN7Yyvv51cuyR2D3XkU4nhmI2xmmVwT1RMWKtub4sjxAcRDLrPoKSO2AU9FLLadMPX577Wf95IFj6FkKFVt3dCIsmGUC4X+WQxLJvxbRxEaOPpqJOXyzJX6+Vxaq3AzMfF/WAdoi1Hp+JRaV56zgpBtpWP97mH4DoGEIq1+FvV8LyS/3wvwugbQOwb2r26mJEMsiuDQTRn+wrYdrVGBVlhI3WQhyrjUBVMrLF5667llUcEaPCGPVGLD8qO5LlO8hKCvA7V9+8oJc9bXelqVQLhM76T5/WtnT45JKji+hdX0HoNCDDWuKON/QeaxB5uImSX0h2wv0VmP2zd2yeApxHcpsVS+MC2yFwAc2B7oBkTqsk1SEvTpM2fmfMQREBUfin0Bh+iq6EvPPavhWI2IX9e3yAas7Tm/3KEj2UmlFp36kN4x0rMLBRrxuh0U/zUHM4xcAMYjJY4MonxOl/X+alpt2M3WMI7w3HLnpIBigtNiJu7T21v4P6lSd5WFgntnMEt7oF92XzRLkJbTcGmXepE/UVOG6E/0YnhfS+q26utWcuxzpooyeD2cDlK1/8w9d28VzsRjbLuALbmGlp8+d7EzS6Au7lMpZ+ECMZvQmzwJ+eLOpxR+2chdUExp8ogQyq3v9l68rX4jCwjg0+PYKAEEzcU4wHFY2ZcdIHfWL1okD3SszT0GZMyKdZJrg1L2AeerB4tC0C4crp2EHGo5FYdSP7lwkeR2ocmnR+Ia8CYviUJlzOjhRZef9xuVOn3qcjow3fQgivsAmKKkg4+sA8F8/GWeDiGNhg8JM8KtFPMYWWkx5TVFX5t73kiNRJqjlIGVXtGZFCV4gzt0xcDopuZ6xz8r9Rzafpf9ywev8jh8592gHFIqpStZPuJxmDDMrNN0uBE3V+oscdoIzTJbRJ/t+sVvqnReJOgDJKk10fjisJwqyZBmnmn2BSFj8BvVtCMEbkuPOKdzw7eA11GPs04Qw8zWtkaZWwiO/wwpojqN6K0jY5RnNZA7vn4hPSul+nKCkVnVwQvg1zVxcSCtqORmB9KrJaBbssbCQivGJVJfVTt+hYxOtq4ZvWl8f4QAQZ0zGPffCgl9s6yT4vlvIdpu4YhBwA25wtQWZsc6GJYGWHyvSdeuh3mmUI9DSq13Fsp8C1MU3tqc04/df9LoTUXVXI5INOw/e8C7Hd+5CvbkMEFnnrUUmskEw==',
);

dynamic aesSrc(dynamic data, dynamic idx) {
  return idx < data.length ? (data[idx] & 0xff) : 0;
}

dynamic aesPut(dynamic out, dynamic idx, dynamic value) {
  if (idx >= 0 && idx < out.length) out[idx] = value & 0xff;
}

dynamic aesMatrix(dynamic bytes) {
  var rows = List<dynamic>.filled(4, null);
  for (var i = 0; i < 4; i++) {
    rows[i] = List<dynamic>.filled(4, null);
    for (var j = 0; j < 4; j++) rows[i][j] = bytes[i * 4 + j] & 0xff;
  }
  return rows;
}

dynamic aesFlat(dynamic rows) {
  var b = Uint8List(16);
  for (var i = 0; i < 4; i++) {
    for (var j = 0; j < 4; j++) b[i * 4 + j] = rows[i][j] & 0xff;
  }
  return b;
}

dynamic aesXt(dynamic x) {
  return ((x << 1) ^ ((x & 128) != 0 ? 0x1b : 0)) & 255;
}

dynamic aesMix(dynamic rows) {
  for (var i = 0; i < 4; i++) {
    var t = rows[0][i] ^ rows[1][i] ^ rows[2][i] ^ rows[3][i];
    var u = rows[0][i];
    rows[0][i] ^= t ^ aesXt(rows[0][i] ^ rows[1][i]);
    rows[1][i] ^= t ^ aesXt(rows[1][i] ^ rows[2][i]);
    rows[2][i] ^= t ^ aesXt(rows[2][i] ^ rows[3][i]);
    rows[3][i] ^= t ^ aesXt(rows[3][i] ^ u);
  }
}

class AesV3 {
  late int wordSize;
  late List<int> box;
  late List<int> con2;
  late List<int> order;
  late List<dynamic> keys;
  AesV3(dynamic key, dynamic khronos) {
    this.wordSize = khronos & 3;
    this.box = sliceBytes(SBOX, this.wordSize * 256, (this.wordSize + 1) * 256);
    var con2Table = [
      [1, 0, 2, 3],
      [2, 0, 3, 1],
      [0, 1, 3, 2],
      [1, 0, 2, 3],
    ];
    var orderTable = [
      [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
      [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
      [0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15],
      [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
    ];
    this.con2 = con2Table[this.wordSize];
    this.order = orderTable[this.wordSize];
    var init = [0xca025ddc, 0x823dc546, 0xc9420583, 0xc298225f][this.wordSize];
    var initial = Uint8List(16);
    for (var i = 0; i < 4; i++) putLe32(initial, i * 4, init);
    var mk = xorBytes(initial, key);
    var expanded = joinBytes([mk, Uint8List(32)]);
    var rounds = 8;
    for (var i = 4; i < 12; i++) {
      var at = 4 * (i - 1);
      var a = expanded[at] & 0xff;
      var b = expanded[at + 1] & 0xff;
      var c = expanded[at + 2] & 0xff;
      var d = expanded[at + 3] & 0xff;
      if ((i & 3) == 0) {
        var t = ((shr32(init, (rounds & 24))) ^ (this.box[b] & 0xff)) & 255;
        b = this.box[c] & 0xff;
        c = this.box[d] & 0xff;
        d = this.box[a] & 0xff;
        a = t;
      }
      rounds += 2;
      expanded[at + 4] = (a ^ (expanded[at - 12] & 0xff)) & 0xff;
      expanded[at + 5] = (b ^ (expanded[at - 11] & 0xff)) & 0xff;
      expanded[at + 6] = (c ^ (expanded[at - 10] & 0xff)) & 0xff;
      expanded[at + 7] = (d ^ (expanded[at - 9] & 0xff)) & 0xff;
    }
    this.keys = List<dynamic>.filled(12, null);
    for (var i = 0; i < 12; i++) {
      this.keys[i] = List<dynamic>.filled(4, null);
      for (var j = 0; j < 4; j++) this.keys[i][j] = expanded[i * 4 + j] & 0xff;
    }
  }

  dynamic add(dynamic rows, dynamic key) {
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) rows[i][j] ^= key[i][j];
    }
  }

  dynamic addCon(dynamic rows, dynamic ks) {
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) rows[i][j] ^= ks[i][this.con2[j]];
    }
  }

  dynamic sub(dynamic rows) {
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) rows[i][j] = this.box[rows[i][j]] & 0xff;
    }
    var old = List<dynamic>.filled(4, null);
    for (var i = 0; i < 4; i++) old[i] = rows[i].toList();
    for (var i = 0; i < 4; i++) rows[i] = old[this.con2[i]];
  }

  dynamic shift(dynamic rows) {
    var b = aesFlat(rows);
    for (var i = 0; i < 16; i++) rows[i ~/ 4][i % 4] = b[this.order[i]] & 0xff;
  }

  dynamic shiftCon(dynamic rows) {
    var old = List<dynamic>.filled(4, null);
    for (var i = 0; i < 4; i++) old[i] = rows[i].toList();
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) rows[i][j] = old[i][this.con2[j]];
    }
  }

  dynamic block(dynamic value) {
    var rows = aesMatrix(value);
    var k0 = this.subKeys(0);
    this.addCon(rows, k0);
    for (var i = 1; i < 3; i++) {
      this.sub(rows);
      this.shift(rows);
      if (i == 1) {
        this.shiftCon(rows);
        aesMix(rows);
      }
      this.addCon(rows, this.subKeys(i * 4));
    }
    this.add(rows, this.subKeys(4));
    return aesFlat(rows);
  }

  dynamic subKeys(dynamic from) {
    var out = List<dynamic>.filled(4, null);
    for (var i = 0; i < 4; i++) out[i] = this.keys[from + i].sublist(0, 4);
    return out;
  }

  dynamic encrypt(dynamic data, dynamic iv) {
    var plaintext = Uint8List(32);
    for (var i = 0; i < 31; i++) {
      var at = i * 8;
      var n0 = (aesSrc(data, at) >> 4) & 2;
      var n1 = n0 | (aesSrc(data, at + 1) & 64);
      var n2 = n1 | ((aesSrc(data, at + 2) >> 2) & 1);
      var n3 = n2 | ((aesSrc(data, at + 3) << 3) & 128);
      var n4 = n3 | ((aesSrc(data, at + 4) >> 1) & 4);
      var n5 = n4 | ((aesSrc(data, at + 5) << 3) & 16);
      var n6 = n5 | ((aesSrc(data, at + 6) << 5) & 32);
      plaintext[i] = (n6 | ((aesSrc(data, at + 7) >> 4) & 8)) & 0xff;
    }
    plaintext[31] = 1;
    var blocks = [];
    var previous = bytes(iv);
    for (var i = 0; i < plaintext.length; i += 16) {
      var value = this.block(
        xorBytes(sliceBytes(plaintext, i, i + 16), previous),
      );
      blocks.add(value);
      previous = value;
    }
    var key = joinBytes([...blocks]);
    var out = bytes(data);
    for (var i = 0; i < 31; i++) {
      var at = i * 8;
      var k = key[i] & 0xff;

      aesPut(out, at, (aesSrc(out, at) & 0xdf) | ((k << 4) & 32));
      aesPut(out, at + 1, (aesSrc(out, at + 1) & 0xbf) | (k & 64));
      aesPut(out, at + 2, (aesSrc(out, at + 2) & 0xfb) | ((k << 2) & 4));
      aesPut(out, at + 3, (aesSrc(out, at + 3) & 0xef) | ((k >> 3) & 16));
      aesPut(out, at + 4, (aesSrc(out, at + 4) & 0xf7) | ((k + k) & 8));
      aesPut(out, at + 5, (aesSrc(out, at + 5) & 0xfd) | ((k >> 3) & 2));
      aesPut(out, at + 6, (aesSrc(out, at + 6) & 0xfe) | ((k >> 5) & 1));
      aesPut(out, at + 7, (aesSrc(out, at + 7) & 0x7f) | ((k << 4) & 128));
    }
    return joinBytes([sliceBytes(key, key.length - 1, key.length), out]);
  }
}

class PureSign {
  final Clock clock;
  final RandomSource random;
  final String PROCESS_NONCE;
  final int PROCESS_STARTED;
  PureSign({
    Clock? clock,
    RandomSource? random,
    String? processNonce,
    int? processStarted,
  }) : this._(
         clock ?? const SystemClock(),
         random ?? SecureRandomSource(),
         processNonce,
         processStarted,
       );
  PureSign._(this.clock, this.random, String? nonce, int? started)
    : PROCESS_NONCE =
          nonce ?? base64UrlEncode(random.bytes(18)).replaceAll('=', ''),
      PROCESS_STARTED = started ?? clock.milliseconds;
  dynamic EMPTY = Uint8List(0);

  int getIv(int iv, List<int> data) {
    var value = iv;
    for (var i = 0; i < data.length; i++) {
      final d = data[i] & 255;
      value = i32(
        i.isEven
            ? shr32(value, 4) ^ value ^ (value << 6) ^ d
            : ~(shr32(value, 7) ^ value ^ (d | (value << 12))),
      );
    }
    return value;
  }

  dynamic sumMd5(dynamic data) {
    dynamic check = 0x20220420;
    for (var i = 0; i < 12; i++) {
      dynamic temp = (i & 1) == 0
          ? ((shr32(check, 3)) ^ check)
          : ((shr32(check, 5)) ^ check);
      check = (i & 1) == 0
          ? ((data[i] & 0xff) ^ (check << 7))
          : ((data[i] & 0xff) | (check << 11));
      if ((i & 1) != 0) check = ~check;
      check = check ^ temp;
    }
    return i32((check | 4) ^ 0x1000000);
  }

  dynamic BRANCH2_SV = [
    0xa7aefe20,
    0x7149f1d6,
    0x47e4ca07,
    0xe9b58f67,
    0x93b924de,
    0xc614d0f5,
    0x38afe0ef,
    0xb2bbad73,
    0xe24444c3,
    0x9d3aec9b,
    0xdf7b37e4,
    0xd8b16d40,
    0xf8ac31b8,
    0x76b9a90b,
    0x31d833ee,
    0x953fce64,
    0x353595a4,
    0x4609c13b,
    0x36925008,
    0x8c6d0925,
    0x5df5c177,
    0x1cfbf52b,
    0x8a4fa7f0,
    0x114ca35e,
    0x8193f984,
    0x7a7a8733,
    0x316ab4d5,
    0x3c20cfc9,
    0xa6d84453,
    0x3a18500c,
    0x798ec47a,
    0x97a76b28,
    0x66c4ff96,
    0x51716443,
    0x0dd2fc3b,
    0xb5696da7,
    0xbbeb3ac5,
    0x5c53d204,
    0xd32608ce,
    0x7279b9ec,
    0xf4188ecf,
    0xf7d793db,
    0x332cc491,
    0xab76ae15,
    0x9bebe727,
    0x18a01384,
    0x5be9f8a7,
    0x5f90a754,
    0x39b663c0,
    0x36673c83,
    0x7c92f514,
    0x9d7d94d7,
    0xe2e8d9aa,
    0x5f7e9ea9,
    0x7abd4551,
    0x569e05da,
    0x40a25632,
    0x3df5a9a5,
    0xbab37d80,
    0x454286dc,
    0x3f5d4e78,
    0x03d7b75d,
    0xb1fe4af7,
    0xa5ab26a3,
  ];

  dynamic BRANCH2_ORDERS = unhex(
    '0f0704000908030a060b050d0e010c02' +
        '0f05080c0009020103070e060b0a0d04' +
        '060500070c000a04080f010b0d09020e' +
        '060b02050403080101070a000d0c090e' +
        '0d070e0f0b0208030c0509010004060a' +
        '0d0902060f0b0a040807000c0503010e' +
        '0c090f07060f030e020d0405010b0a00' +
        '0c050a090e0802040407030f01060b00' +
        '0b0f0408020a0700090d06010e03050c' +
        '0b060a0508020c03070f0e090d000104' +
        '0906080f050800040a0b030d01020c0e' +
        '090d0c0604070a03030f00080105020e' +
        '01000d0f090a0b0e0402080703060c05' +
        '01080a0c0f0905060b000304020e070d' +
        '04080f000c0f0e0d0a01060207090503' +
        '040205080d0b0a0606000e0f070c0903' +
        '0a08040f000b01060d0c0709030e0502' +
        '0a070b050f00020e0108030d0c060904' +
        '0d070f08050f06040b0a0e0c09000203' +
        '0d0c020704010b0e0e08060f09050003',
  );

  dynamic md5V3Step(
    dynamic kind,
    dynamic a,
    dynamic b,
    dynamic c,
    dynamic d,
    dynamic m,
    dynamic shift,
    dynamic constant,
  ) {
    var f;
    if (kind == 0)
      f = (b & c) | (~b & d);
    else if (kind == 1)
      f = (b & d) | (c & ~d);
    else if (kind == 2)
      f = b ^ c ^ d;
    else
      f = c ^ (b | ~d);
    return i32(b + rotl(i32(a + f + m + constant), shift));
  }

  dynamic md5SumV3(
    dynamic message,
    dynamic countV2,
    dynamic orders,
    dynamic countV1,
  ) {
    dynamic sv = List<dynamic>.filled(BRANCH2_SV.length, null);
    for (var i = 0; i < sv.length; i++) sv[i] = ror(BRANCH2_SV[i], countV1);
    dynamic start = [
      ror(0x79e0f2fb, countV2),
      ror(0xc8b52570, countV2),
      ror(0xebc2f8cd, countV2),
      ror(0x7c104d93, countV2),
    ];
    dynamic endCount = (countV2 + 6) & 255;
    dynamic end = [
      ror(0x19be4866, endCount),
      ror(0xe85986b4, endCount),
      ror(0xe19b326e, endCount),
      ror(0x71d1d7d4, endCount),
    ];
    dynamic m = List<dynamic>.filled(16, null);
    for (var i = 0; i < 16; i++) m[i] = readLe32(message, i * 4);
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

    for (var kind = 0; kind < 4; kind++) {
      dynamic shifts = kind == 0
          ? shifts0
          : kind == 1
          ? shifts1
          : kind == 2
          ? shifts2
          : shifts3;
      dynamic offset = kind * 16;
      for (var i = 0; i < 16; i++) {
        dynamic phase = i & 3;
        dynamic mm = m[orders[offset + i] & 0xff];
        dynamic cc = sv[offset + i];
        var next;
        if (phase == 0)
          next = md5V3Step(kind, a, b, c, d, mm, shifts[i], cc);
        else if (phase == 1)
          next = md5V3Step(kind, d, a, b, c, mm, shifts[i], cc);
        else if (phase == 2)
          next = md5V3Step(kind, c, d, a, b, mm, shifts[i], cc);
        else
          next = md5V3Step(kind, b, c, d, a, mm, shifts[i], cc);
        if (phase == 0)
          a = next;
        else if (phase == 1)
          d = next;
        else if (phase == 2)
          c = next;
        else
          b = next;
      }
    }
    dynamic ret = Uint8List(16);
    putLe32(ret, 0, (start[0] + a) ^ end[0]);
    putLe32(ret, 4, (start[1] + b) ^ end[1]);
    putLe32(ret, 8, (start[2] + c) ^ end[2]);
    putLe32(ret, 12, (start[3] + d) ^ end[3]);
    return joinBytes([ret, le32(sumMd5(ret))]);
  }

  dynamic branch2F13(
    dynamic iv,
    dynamic querySm3,
    dynamic bodyMd5,
    dynamic tsBytes,
    dynamic khronos,
  ) {
    dynamic v = (iv & 13) * 86;
    dynamic ivV0 = ((shr32(v, 15)) & 255) + ((shr32(v, 8)) & 255);
    dynamic n1 = [
      0x8980f29b,
      0xeb549c7f,
      0xb08726db,
      0xd40cb5e6,
      0xe8f559e4,
    ][ivV0];
    dynamic countV1 = (n1 + khronos + 1) & 255;
    dynamic countV2 = i32(n1 + khronos);
    dynamic shift = (countV2 + 5) & 7;
    dynamic seed = [0x84, 0x96, 0x77, 0x9d, 0xd4, 0x15, 0x0b, 0xf8];
    dynamic pad = Uint8List(8);
    for (var i = 0; i < 8; i++)
      pad[i] = ((seed[i] | (seed[i] << 8)) >> shift) & 255;
    dynamic input = joinBytes([
      querySm3,
      bodyMd5,
      tsBytes,
      pad,
      unhex('a0010000'),
    ]);
    dynamic from = ivV0 << 6;
    dynamic to = (ivV0 + 1) << 6;
    dynamic orders = sliceBytes(BRANCH2_ORDERS, from, to);
    return md5SumV3(input, countV2, orders, countV1);
  }

  dynamic hashF13(
    dynamic querySm3,
    dynamic bodyMd5,
    dynamic tsBytes,
    dynamic khronos,
  ) {
    dynamic iv = getIv(getIv(getIv(0x20230928, querySm3), bodyMd5), tsBytes);
    dynamic low = iv & 15;
    dynamic ivV0 = (low * 171) >> 9;
    dynamic branch = low - ivV0 * 3;
    if (branch == 2) return branch2F13(iv, querySm3, bodyMd5, tsBytes, khronos);
    if (branch != 0) {
      return joinBytes([
        sliceBytes(querySm3, 0, 16),
        bodyMd5,
        le32(sumMd5(joinBytes([querySm3, bodyMd5]))),
      ]);
    }

    dynamic ivV1List = [
      0xc4a78580,
      0xb3c0fd39,
      0xc58c5686,
      0xc9aa3ba7,
      0xf5a7adf2,
      0x963c2ed1,
    ];
    dynamic ivV1 = i32(ivV1List[ivV0]);
    dynamic countV1 = (ivV1 + khronos + 1) & 255;
    dynamic countV2 = i32(ivV1 + khronos);
    dynamic tt02 = [
      0xebb64faf,
      0x07aadcc2,
      0xcf3187bf,
      0xe01138ff,
      0x6d0bfcff,
      0x5a30a3be,
      0xb41ad638,
      0x34180eb8,
      0xf233eb6f,
      0xb1a584cc,
      0xccc30dc7,
      0x47d1db51,
      0xd55653de,
      0x70a84fa1,
      0x57473c12,
      0xf76f0288,
      0x2c077f0a,
      0xda0dcad0,
      0xfbb86f6c,
      0xfdc4cf00,
      0x688a020d,
      0xe676c6a6,
      0x8cd6338b,
      0x1a3c8d0e,
      0xcce8b06b,
      0x6ad0ed0b,
      0xa0522717,
      0xdc71ac83,
      0x2285db71,
      0xd5b4dda6,
      0x736f8650,
      0x6560306c,
      0x617ce2a6,
      0xe423417e,
      0x0a40e143,
      0x544e4032,
      0x88dffb2a,
      0x716c1ae0,
      0x4c467a88,
      0x05b23bb3,
      0xe1d0b866,
      0xbaa3dcb8,
      0xae3374d3,
      0xc3381a50,
      0x1702f75b,
      0xfe6da368,
      0xf0b4cf48,
      0x4e0ffbb8,
      0x72aad10d,
      0x26c53a3d,
      0xf2bce0f6,
      0xb4557581,
      0x4a257fdd,
      0x8c3182a2,
      0xab0b3b86,
      0x3d5dfb14,
      0x4f103634,
      0xd37b52d7,
      0x444eff16,
      0xeb0a33d1,
      0x6ca86f6e,
      0x0284ba7,
      0x08387cfa,
      0x5fb37586,
    ];
    dynamic tt = List<dynamic>.filled(tt02.length, null);
    for (var i = 0; i < tt.length; i++) tt[i] = ror(tt02[i], countV1);
    dynamic n0 = (countV2 + 2) & 7;
    dynamic seed = [0xfa, 0x45, 0x61, 0xd7];

    dynamic pad = Uint8List(seed.length);
    for (var i = 0; i < seed.length; i++)
      pad[i] = ((seed[i] | (seed[i] << 8)) >> n0) & 255;
    dynamic data = joinBytes([
      querySm3,
      bodyMd5,
      tsBytes,
      pad,
      unhex('00000000000001a0'),
    ]);

    dynamic di = List<int>.filled((data.length ~/ 4) + 112 + 16, 0);
    dynamic diLen = 0;
    for (var i = 0; i + 3 < data.length; i += 4)
      di[diLen++] = readBe32(data, i);
    dynamic di0 = di[0];
    for (var i = 0; i < 112; i++) {
      dynamic di1 = di[i + 1];
      dynamic di14 = di[i + 14];
      dynamic r1 = rotl(di1, 14) ^ rotl(di1, 25) ^ (shr32(di1, 3));
      dynamic r2 = rotl(di14, 13) ^ rotl(di14, 15) ^ (shr32(di14, 10));
      di[diLen++] = i32(di0 + di[i + 9] + r1 + r2);
    }

    dynamic initRaw = [
      0x7aba4fc8,
      0x67166507,
      0x6403fa00,
      0x340f512f,
      984304912,
      3005047866,
      2874125293,
      2152413264,
    ];
    dynamic init = List<dynamic>.filled(8, null);
    for (var i = 0; i < 8; i++) init[i] = ror(initRaw[i], countV2 & 31);
    dynamic chosenTable = [
      [101, 5, 7, 6, 3, 2, 1, 0, 5, 4, 3],
      [96, 0, 6, 7, 5, 3, 2, 1, 5, 4, 4],
      [96, 7, 6, 2, 1, 4, 0, 5, 4, 3, 5],
      [99, 3, 6, 2, 4, 5, 1, 0, 0, 7, 6],
      [96, 0, 5, 6, 7, 3, 1, 2, 5, 4, 4],
      [100, 2, 0, 3, 5, 4, 6, 7, 2, 1, 5],
    ];
    dynamic chosen = chosenTable[ivV0];
    dynamic d = init.toList();
    for (var i = 0; i < chosen[0]; i++) {
      dynamic base = i32(ivV1 + i);
      dynamic n0v = di[base & 127];
      dynamic n1 =
          ((d[chosen[3]] ^ d[chosen[4]]) & d[chosen[1]]) ^ d[chosen[3]];
      dynamic n2 =
          rotl(d[chosen[1]], 26) ^
          rotl(d[chosen[1]], 21) ^
          rotl(d[chosen[1]], 7);
      dynamic n4 = i32(n0v + n1 + n2 + tt[base & 63] + d[chosen[5]]);
      dynamic n5 =
          rotl(d[chosen[2]], 30) ^
          rotl(d[chosen[2]], 19) ^
          rotl(d[chosen[2]], 10);
      dynamic n6 =
          (d[chosen[2]] & d[chosen[6]]) |
          ((d[chosen[2]] | d[chosen[6]]) & d[chosen[7]]);
      dynamic n7 = i32(n5 + n6);
      dynamic old = d[chosen[9]];

      dynamic last = d[d.length - 1];
      for (var k = d.length - 1; k >= 1; k--) d[k] = d[k - 1];
      d[0] = last;
      d[chosen[10]] = i32(n7 + n4);
      d[chosen[8]] = i32(old + n4);
    }
    dynamic ret = Uint8List(32);
    for (var i = 0; i < 8; i++) putBe32(ret, i * 4, i32(d[i] + init[i]));
    for (var i = 0; i < 16; i++) ret[i] = ret[i] ^ ret[i + 16];
    return joinBytes([
      sliceBytes(ret, 0, 16),
      le32(sumMd5(sliceBytes(ret, 0, 16))),
    ]);
  }

  dynamic rc4Gorgon(dynamic data, dynamic key) {
    dynamic s = List<dynamic>.filled(256, null);
    for (var i = 0; i < 256; i++) s[i] = i;
    dynamic j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j + s[i] + key[i % key.length]) & 255;
      s[i] = s[j];
    }
    dynamic out = Uint8List(data.length);
    dynamic i = 0;
    j = 0;
    for (var k = 0; k < data.length; k++) {
      i += 1;
      dynamic x = s[i];
      j += x;
      dynamic y = s[j & 255];
      s[i] = y;
      out[k] = data[k] ^ s[(y + y) & 255];
    }
    return out;
  }

  dynamic xGorgon(
    dynamic query,
    dynamic body,
    dynamic timestamp,
    dynamic random,
  ) {
    dynamic q4 = sliceBytes(md5(utf8Bytes(query)), 0, 4);
    dynamic b4 = body != null && body.length > 0
        ? sliceBytes(md5(body), 0, 4)
        : Uint8List(4);
    dynamic sdk = le32(67503104);
    dynamic input = joinBytes([
      q4,
      b4,
      Uint8List(4),
      sdk,
      be32(i32(timestamp)),
    ]);
    dynamic key = [
      0x4a,
      0x40,
      0x16,
      (random >> 8) & 255,
      0x47,
      0x6c,
      0x01,
      random & 255,
    ];
    dynamic out = rc4Gorgon(input, key);
    for (var i = 0; i < out.length; i++) {
      dynamic value = rotl8(out[i] & 0xff);
      dynamic next = i + 1 < out.length ? (out[i + 1] & 0xff) : (out[0] & 0xff);
      out[i] = (~(reverseBits((next ^ value) & 255) ^ 20)) & 255;
    }
    return hex(
      joinBytes([
        unhex('8404'),
        bytes([random & 255, (random >> 8) & 255, 0x40, 0x01]),
        out,
      ]),
    );
  }

  dynamic xmxor(dynamic data, dynamic key) {
    dynamic encoded = Uint8List(data.length);
    for (var i = 0; i < data.length; i++) {
      dynamic at = (i * 4) & 28;
      dynamic d0 = key[at] & 0xff;
      dynamic d1 = key[at + 1] & 0xff;
      dynamic d2 = (rotl8(data[i] & 0xff) + d0);
      d2 = (~d2) ^ d1;
      d2 = rotl8_3(d2 & 0xff);
      d2 = (d2 + d1) & 255;
      d2 = (d2 ^ d0) & 255;
      encoded[data.length - i - 1] = (~d2) & 255;
    }
    dynamic last =
        (encoded[encoded.length - 1] ^ encoded[encoded.length - 2]) & 255;
    dynamic first = encoded[0] & 0xff;
    encoded[0] = ((~last) + first) & 255;
    encoded[1] =
        ((encoded[0] ^ encoded[encoded.length - 1] ^ 254) + encoded[1]) & 255;
    encoded[2] =
        (encoded[2] + (((last - first) ^ rotl8_3(encoded[1] & 0xff)) ^ 2)) &
        255;
    for (var i = 0; i < encoded.length - 4; i++) {
      dynamic temp =
          (rotl8_3(encoded[i + 2] & 0xff) ^ encoded[i + 1] ^ (i + 3));
      encoded[i + 3] = ((~temp) + encoded[i + 3]) & 255;
    }
    encoded[encoded.length - 1] =
        (encoded[encoded.length - 1] ^ encoded[encoded.length - 2]) & 255;
    dynamic sum = 0;
    for (var i = 0; i < encoded.length - 1; i++) sum += encoded[i + 1] & 0xff;
    encoded[0] = ((encoded[0] ^ encoded[1]) + sum) & 255;
    return encoded;
  }

  dynamic keyHash(dynamic signKey, dynamic random) {
    dynamic hash = sm3(joinBytes([signKey, le32(random), signKey]));
    dynamic d1 = (random >> 16) & 255;
    dynamic d2 = (((d1 << 11) | (shr32(random, 24))) ^ (d1 >> 5) ^ d1);
    d2 = ~d2;
    return [hash, le32(d2)];
  }

  dynamic MEDUSA_SIGN_KEY = unhex(
    '8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eaef71cb691f7aa8aa2f5',
  );
  dynamic MEDUSA_AES_KEY = unhex('f1593376766ea98d34f31b057a9d5be4');
  dynamic MEDUSA_AES_IV = unhex('1fe109a4125283f418de9e051a969e12');
  dynamic MEDUSA_MAGIC16 = unhex('f7e85ffad7d7dc3bd62ac87057cf6118');
  dynamic MEDUSA_MAGIC8 = unhex('4001000000000000');

  Uint8List randomBytes(int n) => random.bytes(n);
  int rndInt(int n) => random.nextInt(n);
  int rndInt32() => readBe32(randomBytes(4), 0);
  dynamic deviceProto(dynamic deviceId, dynamic version) {
    return proto([
      [1, 1, 'sint'],
      [2, 2, 'sint'],
      [3, '8662'],
      [4, deviceId],
      [5, PROCESS_NONCE],
      [6, '!noperm!'],
      [7, -888888, 'sint'],
      [8, -888888, 'sint'],
      [9, 3, 'sint'],
      [10, -888888, 'sint'],
      [11, '!notset!'],
      [12, 'Asia/Shanghai,8'],
      [13, 'zh_CN'],
      [14, 4, 'sint'],
      [16, 0, 'float'],
      [17, 0, 'float'],
      [18, 0, 'float'],
      [19, 0, 'float'],
      [20, 0, 'float'],
      [21, 0, 'float'],
      [22, '16'],
      [23, 41, 'sint'],
      [24, 36, 'sint'],
      [25, PROCESS_STARTED, 'sint'],
      [26, PROCESS_STARTED, 'sint'],
      [27, PROCESS_STARTED, 'sint'],
      [28, PROCESS_STARTED, 'sint'],
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
  }

  dynamic buildMedusa(
    dynamic url,
    dynamic body,
    dynamic khronos,
    dynamic deviceId,
    dynamic version,
  ) {
    dynamic bodyMd5 = body != null && body.length > 0
        ? md5(body)
        : Uint8List(16);
    dynamic query = queryOf(url);
    dynamic querySm3 = sm3(utf8Bytes(query));
    dynamic ts = le32(i32(khronos));
    dynamic queryBodyTs = hashF13(querySm3, bodyMd5, ts, khronos);

    dynamic messageRand = randomBytes(4);
    dynamic messageRandU = u32(readLe32(messageRand, 0));
    dynamic envLaunch = 100 + rndInt(21);
    dynamic envPid = 10001 + rndInt(2000);
    dynamic env = proto([
      [1, envLaunch, 'sint'],
      [2, 146331399, 'sint'],
      [3, 146331396, 'sint'],
      [5, 7, 'sint'],
      [6, 'v04.06.04.03-bugfix'],
      [7, envPid, 'sint'],
      [12, deviceProto(deviceId, version), 'message'],
      [
        13,
        proto([
          [1, (clock.milliseconds ~/ 1000), 'sint'],
          [2, -2, 'sint'],
          [4, 200, 'sint'],
        ]),
        'message',
      ],
      [14, version],
    ]);
    dynamic queryHash = sm3(
      joinBytes([utf8Bytes(query), bodyMd5, utf8Bytes('none')]),
    );

    dynamic nested = proto([
      [1, 111, 'sint'],
      [2, 10, 'sint'],
      [3, 694367, 'sint'],
      [5, 586952199, 'sint'],
    ]);
    dynamic message = proto([
      [1, MEDUSA_MAGIC16, 'bytes'],
      [2, 3, 'sint'],
      [3, messageRandU, 'sint'],
      [4, '8662'],
      [5, deviceId],
      [6, '1588093228'],
      [7, version],
      [8, 'v04.06.04-ml-android'],
      [9, 67503104, 'sint'],
      [10, MEDUSA_MAGIC8, 'bytes'],
      [12, khronos, 'sint'],
      [13, queryBodyTs, 'bytes'],
      [14, sliceBytes(querySm3, 0, 6), 'bytes'],
      [15, nested, 'message'],
      [16, PROCESS_NONCE],
      [17, khronos, 'sint'],
      [19, queryHash, 'bytes'],
      [20, 'none'],
      [21, 312, 'sint'],
      [23, env, 'message'],
      [
        24,
        '{"cmr":16777216,"cmr2":16777216,"un_h":1879194040,"vpn":0,' +
            '"kd":0,"fkd":3672518972,"pd":-1872573247,"dyn":"",' +
            '"do":0,"tk":true}',
      ],
    ]);

    dynamic random = rndInt32();
    dynamic hs = keyHash(MEDUSA_SIGN_KEY, random);
    dynamic hash = hs[0];
    dynamic seed = hs[1];
    dynamic transformed = xmxor(message, hash);
    transformed = joinBytes([MEDUSA_MAGIC8, transformed]);

    for (var i = 0; i < transformed.length ~/ 2; i++) {
      final j = transformed.length - 1 - i;
      final t = transformed[i];
      transformed[i] = transformed[j];
      transformed[j] = t;
    }
    for (var i = 0; i < transformed.length; i++) {
      transformed[i] = (transformed[i] ^ seed[(~i) & 3]) & 0xff;
    }
    final check = i32(
      ((querySm3[0] & 63) << 14) | 0x18000001 | ((queryBodyTs[0] & 63) << 8),
    );
    dynamic xmRand = rndInt32();
    dynamic packed = joinBytes([
      bytes([0x35]),
      le32(xmRand),
      le32(check),
      transformed,
      bytes([(random >> 16) & 255, (random >> 24) & 255]),
    ]);
    dynamic encrypted = AesV3(
      MEDUSA_AES_KEY,
      khronos,
    ).encrypt(packed, MEDUSA_AES_IV);
    dynamic versionBytes = unhex('03000000f7e85ffad7d7dc3bd62ac87057cf6118');
    dynamic prefix = Uint8List(20);
    for (var i = 0; i < 20; i += 4) {
      putLe32(prefix, i, (readLe32(versionBytes, i) ^ (i32(khronos))));
    }
    return b64(
      joinBytes([
        prefix,
        bytes([random & 255, (random >> 8) & 255, 0, 1]),
        encrypted,
      ]),
    );
  }

  dynamic helios(dynamic khronos) {
    return heliosWith(khronos, rndInt32());
  }

  dynamic heliosWith(dynamic khronos, dynamic random) {
    dynamic digest = md5(joinBytes([le32(random), utf8Bytes('8662')]));
    final digestHex = hex(digest);
    dynamic ascii = utf8Bytes(digestHex);
    dynamic words = List<dynamic>.filled(4, null);
    for (var i = 0; i < 4; i++) words[i] = readU64Le(ascii, i * 8);

    dynamic queue = [words[2], words[3]];
    dynamic b0 = words[0];
    dynamic b8 = words[1];
    dynamic table = List<dynamic>.filled(35, null);
    table[0] = words[0];
    for (var i = 0; i < 34; i++) {
      dynamic x8 = uint64(rotr64(b8, 8) + b0);
      x8 = uint64(x8 ^ BigInt.from(i));
      queue.add(x8);
      x8 = uint64(x8 ^ rotr64(b0, 61));
      table[i + 1] = x8;
      b0 = x8;
      b8 = queue.removeAt(0);
    }
    dynamic text = khronos.toString() + '-1588093228-8662';
    dynamic tb = utf8Bytes(text);
    dynamic padLen = ((tb.length + 16) ~/ 16) * 16;
    dynamic pad = Uint8List(padLen);
    pad.fillRange(0, pad.length, (16 - ((tb.length as int) % 16)) & 255);
    pad.setRange(0, tb.length, tb);

    dynamic output = [];
    for (var at = 0; at < pad.length; at += 16) {
      dynamic a = readU64Le(pad, at);
      dynamic b = readU64Le(pad, at + 8);
      for (var i = 0; i < 34; i++) {
        b = uint64(table[i] ^ uint64(a + rotr64(b, 8)));
        a = uint64(b ^ rotr64(a, 61));
      }
      dynamic block = Uint8List(16);

      putU64Le(block, 0, a);
      putU64Le(block, 8, b);
      output.add(block);
    }
    dynamic all = [le32(random), ...output];
    return b64(joinBytes([...all]));
  }

  int branchOf(String url, List<int>? body, int khronos) {
    dynamic bodyMd5 = body != null && body.length > 0
        ? md5(body)
        : Uint8List(16);
    dynamic q = sm3(utf8Bytes(queryOf(url)));
    dynamic iv = getIv(
      getIv(getIv(0x20230928, q), bodyMd5),
      le32(i32(khronos)),
    );
    dynamic low = iv & 15;
    return low - (((low * 171) >> 9) * 3);
  }

  String queryOf(String url) {
    dynamic i = url.indexOf('?');
    return i < 0 ? '' : url.substring(i + 1);
  }

  Map<String, String> sign(String url, List<int>? body, [int? khronos]) {
    dynamic ts = (khronos == null) ? (clock.milliseconds ~/ 1000) : khronos;
    dynamic gorgonRandom = rndInt(65536);
    dynamic query = queryOf(url);
    final out = <String, String>{};
    out['x-gorgon'] = xGorgon(query, body, ts, gorgonRandom);
    out['x-khronos'] = ts.toString();
    out['x-ladon'] = b64(be32(i32(ts)));
    out['x-argus'] = b64(le32(i32(ts)));
    out['x-helios'] = helios(ts);
    out['x-medusa'] = buildMedusa(
      url,
      body,
      ts,
      paramOf(query, 'device_id', '0'),
      paramOf(query, 'version_name', '7.1.3.32'),
    );
    return out;
  }

  String paramOf(String query, String key, String fallback) {
    for (final kv in query.split('&')) {
      dynamic eq = kv.indexOf('=');
      if (eq <= 0) continue;
      if (kv.substring(0, eq) == key) {
        dynamic v = kv.substring(eq + 1);
        if (v.length > 0) return v;
      }
    }
    return fallback;
  }
}
