import 'dart:convert';
import '../crypto/bytes.dart';

const mediaDomains = [
  'qznovelvod.com',
  'fqnovelvod.com',
  'douyinvod.com',
  'idouyinvod.com',
];

String encodeQueryComponent(String raw) => utf8
    .encode(raw)
    .map(
      (b) =>
          (b >= 65 && b <= 90) ||
              (b >= 97 && b <= 122) ||
              (b >= 48 && b <= 57) ||
              [45, 95, 46, 126].contains(b)
          ? String.fromCharCode(b)
          : '%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}',
    )
    .join();
String orderedQuery(Map<String, String> values) => values.entries
    .map(
      (e) => '${encodeQueryComponent(e.key)}=${encodeQueryComponent(e.value)}',
    )
    .join('&');
String cleanUrl(String value) => value
    .replaceAll(r'\/', '/')
    .replaceAll(r'\u0026', '&')
    .replaceAll('&amp;', '&');
Uri checkedUrl(String value, List<String> domains) {
  final uri = Uri.parse(cleanUrl(value));
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443 ||
      !domains.any((d) => uri.host == d || uri.host.endsWith('.$d'))) {
    throw FormatException('URL must be HTTPS on an allowed host');
  }
  return uri;
}

String decryptSpadeUrl(String value, List<int> seed) {
  final raw = base64Decode(base64.normalize(value));
  if (raw.length < 20 || raw[0] != 0xa8 || raw[2] != 1 || raw[3] != 0)
    throw FormatException('Invalid spade URL header');
  final count = ((raw.length - 4) ~/ 16) * 16;
  final constants = unhex(
    '4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58',
  );
  final hash = sha512Bytes(joinBytes([sha512Bytes(seed), constants]));
  final plain = aesCbcDecrypt(
    hash.sublist(0, 16),
    hash.sublist(16, 32),
    raw.sublist(4, 4 + count),
  );
  var end = plain.length;
  final pad = plain.last;
  if (pad >= 1 && pad <= 16 && pad <= end) end -= pad;
  while (end > 0 && plain[end - 1] == 0) {
    end--;
  }
  return utf8.decode(plain.sublist(0, end));
}

Map<String, dynamic> asObject(dynamic value) {
  if (value is String) {
    try {
      value = jsonDecode(value);
    } on FormatException {
      return {};
    }
  }
  return value is Map ? Map<String, dynamic>.from(value) : {};
}

String parseFallback(dynamic value) {
  if (value is List) return value.isEmpty ? '' : value.first.toString();
  if (value is String) {
    final obj = asObject(value);
    return obj['fallback_api']?.toString() ?? value;
  }
  return asObject(value)['fallback_api']?.toString() ?? '';
}
