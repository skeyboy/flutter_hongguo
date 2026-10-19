import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as digest;
import 'package:pointycastle/export.dart';

Uint8List bytes(List<int> v) => Uint8List.fromList(v);
Uint8List unhex(String s) {
  if (s.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(s)) {
    throw FormatException('Invalid hexadecimal bytes');
  }
  return bytes([
    for (var i = 0; i < s.length; i += 2)
      int.parse(s.substring(i, i + 2), radix: 16),
  ]);
}

String hex(List<int> v) =>
    v.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
Uint8List joinBytes(Iterable<dynamic> parts) =>
    (BytesBuilder(copy: false)..addAllParts(parts)).takeBytes();

extension on BytesBuilder {
  void addAllParts(Iterable<dynamic> parts) {
    for (final p in parts) {
      add(List<int>.from(p));
    }
  }
}

Uint8List md5Bytes(List<int> v) => bytes(digest.md5.convert(v).bytes);
Uint8List sha512Bytes(List<int> v) => bytes(digest.sha512.convert(v).bytes);
Uint8List sm3Bytes(List<int> v) => SM3Digest().process(bytes(v));
Uint8List aesCtr(List<int> key, List<int> iv, List<int> input) {
  if (key.length != 16 || iv.length != 16)
    throw ArgumentError('AES-128 key/counter must have 16 bytes');
  return (SICStreamCipher(AESEngine())
        ..init(false, ParametersWithIV(KeyParameter(bytes(key)), bytes(iv))))
      .process(bytes(input));
}

Uint8List aesCbcDecrypt(List<int> key, List<int> iv, List<int> input) {
  if (input.length % 16 != 0)
    throw FormatException('CBC input is not block aligned');
  final cipher = CBCBlockCipher(AESEngine())
    ..init(false, ParametersWithIV(KeyParameter(bytes(key)), bytes(iv)));
  final out = Uint8List(input.length);
  final source = bytes(input);
  for (var p = 0; p < input.length; p += 16) {
    cipher.processBlock(source, p, out, p);
  }
  return out;
}

Uint8List utf8Bytes(String v) => bytes(utf8.encode(v));
int u32(int v) => v & 0xffffffff;
int i32(int v) => (v & 0x80000000) == 0 ? u32(v) : u32(v) - 0x100000000;
int shr32(int v, int n) => u32(v) >> (n & 31);
