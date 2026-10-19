import 'dart:convert';
import 'dart:typed_data';

import 'crypto/bytes.dart';
import 'crypto/pure_sign.dart';
import 'crypto/spade.dart';

/// Tiny offline probe used by the Flutter host; all inputs are synthetic.
Map<String, bool> runCoreDiagnostics() {
  var state = 42;
  Uint8List entropy(int n) => Uint8List.fromList(
    List.generate(n, (_) {
      state = (state * 1664525 + 1013904223).toUnsigned(32);
      return state >> 24;
    }),
  );
  final signer = PureSign(clockMillis: () => 1700000000123, entropy: entropy);
  final headers = signer.sign(
    "https://example.invalid/novel/player/multi_video_model/v1/?device_id=7661622467441478681&version_name=7.1.3.32&query=%E7%8E%84%E5%B9%BB%21%2A%28%29&_rticket=1700000000123",
    null,
    1700000000,
  );
  final names = headers.keys.toList()..sort();
  final digest = hex(
    md5(utf8.encode(names.map((k) => '$k=${headers[k]}').join('&'))),
  );
  return {
    'MD5': hex(md5(utf8.encode('abc'))) == '900150983cd24fb0d6963f7d28e17f72',
    'SM3':
        hex(sm3(utf8.encode('abc'))) ==
        '66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0',
    'Spade v1':
        Spade.unwrapV1(
          unhex(
            "93bc1df253ba1bf7618b19c448b806f64d810afc45b715fe5eb925f26cbf12f541ba098282",
          ),
        ) ==
        "287216bfa89e662a0f748120c305e199",
    'Six-header Node parity': digest == "f3ef18a1e0e6604a2e6e472bb168f64e",
    'Timestamp endian encoding':
        ByteData.sublistView(decodeBase64(headers['x-ladon']!)).getUint32(0) ==
            1700000000 &&
        ByteData.sublistView(decodeBase64(headers['x-argus']!))
                .getUint32(0, Endian.little) ==
            1700000000,
  };
}
