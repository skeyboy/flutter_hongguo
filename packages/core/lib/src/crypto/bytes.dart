import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:pointycastle/export.dart' as pc;

Uint8List md5(List<int> bytes) =>
    Uint8List.fromList(hashes.md5.convert(bytes).bytes);
Uint8List sha512(List<int> bytes) =>
    Uint8List.fromList(hashes.sha512.convert(bytes).bytes);
Uint8List sm3(List<int> bytes) =>
    pc.SM3Digest().process(Uint8List.fromList(bytes));
String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
Uint8List unhex(String text) {
  if (text.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(text)) {
    throw const FormatException('Invalid hex');
  }
  return Uint8List.fromList(
    List.generate(
      text.length ~/ 2,
      (i) => int.parse(text.substring(i * 2, i * 2 + 2), radix: 16),
    ),
  );
}

/// Match Node Buffer's padded/unpadded and URL-safe base64 inputs.
Uint8List decodeBase64(String text) =>
    base64Decode(base64.normalize(text.trim()));

Uint8List aesCtr(Uint8List key, Uint8List counter, Uint8List input) {
  if (key.length != 16 || counter.length != 16) {
    throw ArgumentError('AES-128 requires a 16-byte key and counter');
  }
  final cipher = pc.SICStreamCipher(pc.AESEngine())
    ..init(true, pc.ParametersWithIV(pc.KeyParameter(key), counter));
  return cipher.process(input);
}

Uint8List aesCbcDecrypt(Uint8List key, Uint8List iv, Uint8List ciphertext) {
  if (key.length != 16 || iv.length != 16 || ciphertext.length % 16 != 0) {
    throw ArgumentError('Invalid AES-CBC key, IV, or block length');
  }
  final cipher = pc.CBCBlockCipher(pc.AESEngine())
    ..init(false, pc.ParametersWithIV(pc.KeyParameter(key), iv));
  final out = Uint8List(ciphertext.length);
  for (var at = 0; at < out.length; at += 16) {
    cipher.processBlock(ciphertext, at, out, at);
  }
  return out;
}

/// PKCS#7 CBC for the anonymous device-registration envelope, which Node's
/// `createCipheriv('aes-128-cbc', ...)` produces and the log endpoint unwraps.
Uint8List aesCbcEncryptPkcs7(Uint8List key, Uint8List iv, Uint8List plain) {
  if (key.length != 16 || iv.length != 16) {
    throw ArgumentError('AES-128-CBC requires a 16-byte key and IV');
  }
  final cipher =
      pc.PaddedBlockCipherImpl(
        pc.PKCS7Padding(),
        pc.CBCBlockCipher(pc.AESEngine()),
      )..init(
        true,
        pc.PaddedBlockCipherParameters(
          pc.ParametersWithIV(pc.KeyParameter(key), iv),
          null,
        ),
      );
  return cipher.process(plain);
}

/// The other half of the registration envelope: used by the oracle test to undo
/// its own ciphertext, because a gzipped byte stream is a property of whichever
/// zlib built this binary, while the plaintext inside it is the protocol.
Uint8List aesCbcDecryptPkcs7(
  Uint8List key,
  Uint8List iv,
  Uint8List ciphertext,
) {
  if (key.length != 16 || iv.length != 16 || ciphertext.isEmpty) {
    throw ArgumentError('AES-128-CBC requires a 16-byte key and IV');
  }
  if (ciphertext.length % 16 != 0) {
    throw const FormatException('AES-CBC ciphertext is not block aligned');
  }
  final cipher =
      pc.PaddedBlockCipherImpl(
        pc.PKCS7Padding(),
        pc.CBCBlockCipher(pc.AESEngine()),
      )..init(
        false,
        pc.PaddedBlockCipherParameters(
          pc.ParametersWithIV(pc.KeyParameter(key), iv),
          null,
        ),
      );
  return cipher.process(ciphertext);
}

final _secureRandom = Random.secure();
Uint8List secureBytes(int length) => Uint8List.fromList(
  List.generate(length, (_) => _secureRandom.nextInt(256)),
);
