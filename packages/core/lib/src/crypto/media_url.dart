import 'dart:convert';
import 'dart:typed_data';

import 'bytes.dart';

/// App 取址（签名 / 免签 POST）返回的 CDN 家族：链接只会落在这些域上。
///
/// 这是下载层的默认白名单，比官网层窄一档——签名接口没有理由给出别的域。
const appMediaDomains = ['qznovelvod.com', 'fqnovelvod.com', 'douyinvod.com'];

/// 官网直链会落到字节系其它 CDN（`/api/video/protected/fallback-play-info`
/// 与 player 页 ld+json 都可能指向它们），因此官网层要用这张更宽的表校验，
/// 下载层对「来自官网层的 track」也必须放行同一张表，否则直链会被判非法。
const webMediaDomains = [
  ...appMediaDomains,
  'bytecdn.cn',
  'bytecdn.com',
  'ibytedtos.com',
  'bdcgslb.com',
];

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
