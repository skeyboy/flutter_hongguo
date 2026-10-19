import 'dart:convert';
import 'dart:typed_data';

import 'bytes.dart';

class MediaUrlDecoder {
  static final _constants = unhex(
    '4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524'
    'f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58',
  );

  static String decrypt(String encoded, Uint8List seed) {
    final raw = decodeBase64(encoded);
    if (raw.length < 5 || raw[0] != 0xa8 || raw[2] != 1 || raw[3] != 0) {
      throw const FormatException('Invalid encrypted URL header');
    }
    final length = ((raw.length - 4) ~/ 16) * 16;
    if (length == 0) throw const FormatException('Encrypted URL has no blocks');
    final digest = sha512([...sha512(seed), ..._constants]);
    final plain = aesCbcDecrypt(
      Uint8List.sublistView(digest, 0, 16),
      Uint8List.sublistView(digest, 16, 32),
      Uint8List.sublistView(raw, 4, 4 + length),
    );
    var end = plain.length;
    final pad = plain[end - 1];
    if (pad >= 1 && pad <= 16 && pad <= end) end -= pad;
    while (end > 0 && plain[end - 1] == 0) {
      end--;
    }
    return utf8.decode(plain.sublist(0, end));
  }

  static Uri checked(String value, List<String> domains) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        !domains.any((d) => uri.host == d || uri.host.endsWith('.$d'))) {
      throw const FormatException('Unsupported upstream URL');
    }
    return uri;
  }
}
