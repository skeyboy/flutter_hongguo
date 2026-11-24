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

/// 公网媒体 URL 判定：null 表示放行，否则返回便于诊断的中文拒绝原因。
///
/// 纯函数、无 IO 无 DNS：只挡字面量与凭据，DNS rebinding 靠逐跳校验兜底。
/// 与 [MediaUrlDecoder.checked] 的域名白名单完全独立，第三方源主机不固定。
String? isPublicMediaUrl(Uri url) {
  if (url.scheme != 'https') return '仅允许 HTTPS';
  if (url.userInfo.isNotEmpty) return 'URL 不得包含凭据';
  if (url.port != 443) return '端口必须为 443';
  final host = url.host;
  if (host.isEmpty) return 'host 不能为空';

  if (host.contains(':')) {
    final v6 = _parseIpv6Literal(host);
    if (v6 == null) return 'IPv6 地址格式无效';
    // mapped/兼容写法还原成 IPv4 再判，否则 ::ffff:127.0.0.1 会绕过私网检查。
    if (_isIpv4Mapped(v6) || _isIpv4Compatible(v6)) {
      return _rejectReasonForIpv4(v6.sublist(12));
    }
    return _rejectReasonForIpv6(v6);
  }

  final v4 = _parseIpv4Literal(host);
  if (v4 != null) return _rejectReasonForIpv4(v4);

  return _isPlausibleDnsName(host) ? null : 'host 格式无效';
}

/// 按 inet_aton 兼容语义还原 IPv4：1～4 段，段内支持十进制/八进制/十六进制，
/// 末段吃掉剩余位数（如 127.1 == 127.0.0.1、2130706433 == 127.0.0.1）。
List<int>? _parseIpv4Literal(String host) {
  final parts = host.split('.');
  if (parts.isEmpty || parts.length > 4) return null;
  final values = <int>[];
  for (final part in parts) {
    final value = _parseRadixNumber(part);
    if (value == null) return null;
    values.add(value);
  }
  final lastBits = 8 * (5 - parts.length);
  final maxLast = (1 << lastBits) - 1;
  for (var i = 0; i < values.length - 1; i++) {
    if (values[i] > 0xff) return null;
  }
  if (values.last > maxLast) return null;
  var address = values.last;
  for (var i = 0; i < values.length - 1; i++) {
    address |= values[i] << (lastBits + 8 * (values.length - 2 - i));
  }
  return [
    (address >> 24) & 0xff,
    (address >> 16) & 0xff,
    (address >> 8) & 0xff,
    address & 0xff,
  ];
}

int? _parseRadixNumber(String text) {
  if (text.isEmpty) return null;
  var radix = 10;
  var digits = text;
  if (digits.length > 2 &&
      digits[0] == '0' &&
      (digits[1] == 'x' || digits[1] == 'X')) {
    radix = 16;
    digits = digits.substring(2);
  } else if (digits.length > 1 && digits[0] == '0') {
    radix = 8; // 前导零在传统 IP 记法里是八进制
  }
  return int.tryParse(digits, radix: radix);
}

/// 解析不带方括号的 IPv6 字面量，返回 16 字节；支持 `::` 压缩与末尾内嵌 IPv4。
List<int>? _parseIpv6Literal(String host) {
  var text = host;
  final zone = text.indexOf('%');
  if (zone >= 0) text = text.substring(0, zone); // zone id 不参与地址判定
  final sides = text.split('::');
  if (sides.length > 2) return null;
  final head = sides[0].isEmpty ? <String>[] : sides[0].split(':');
  final tail = sides.length == 2 && sides[1].isNotEmpty
      ? sides[1].split(':')
      : <String>[];
  final groups = <int>[];
  if (!_appendIpv6Groups(head, groups)) return null;
  final gapAt = groups.length;
  if (!_appendIpv6Groups(tail, groups)) return null;
  final missing = 8 - groups.length;
  if (missing < 0) return null;
  if (sides.length == 2) {
    if (missing == 0) return null; // `::` 至少要压缩一段
    groups.insertAll(gapAt, List<int>.filled(missing, 0));
  } else if (missing != 0) {
    return null;
  }
  final bytes = <int>[];
  for (final group in groups) {
    bytes.add((group >> 8) & 0xff);
    bytes.add(group & 0xff);
  }
  return bytes;
}

bool _appendIpv6Groups(List<String> tokens, List<int> out) {
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    if (token.contains('.')) {
      if (i != tokens.length - 1) return false; // 内嵌 IPv4 只能出现在末尾
      final v4 = _parseIpv4Literal(token);
      if (v4 == null) return false;
      out.add((v4[0] << 8) | v4[1]);
      out.add((v4[2] << 8) | v4[3]);
      continue;
    }
    final value = int.tryParse(token, radix: 16);
    if (value == null || value > 0xffff) return false;
    out.add(value);
  }
  return true;
}

bool _isIpv4Mapped(List<int> b) {
  if (b.length != 16) return false;
  for (var i = 0; i < 10; i++) {
    if (b[i] != 0) return false;
  }
  return b[10] == 0xff && b[11] == 0xff;
}

bool _isIpv4Compatible(List<int> b) {
  for (var i = 0; i < 12; i++) {
    if (b[i] != 0) return false;
  }
  return true;
}

String? _rejectReasonForIpv4(List<int> b) {
  final a = b[0], c = b[1];
  if (a == 0) return '未指定地址';
  if (a == 10) return '私网地址';
  if (a == 127) return '回环地址';
  if (a == 169 && c == 254) return '链路本地地址';
  if (a == 172 && c >= 16 && c <= 31) return '私网地址';
  if (a == 192 && c == 168) return '私网地址';
  if (a == 198 && (c == 18 || c == 19)) return 'Fake-IP 地址';
  if (a == 100 && c >= 64 && c <= 127) return '运营商级 NAT 地址';
  if (a >= 224) return '多播/保留地址';
  return null;
}

String? _rejectReasonForIpv6(List<int> b) {
  if (b.every((x) => x == 0)) return '未指定地址';
  if (b.sublist(0, 15).every((x) => x == 0) && b[15] == 1) return '回环地址';
  if ((b[0] & 0xfe) == 0xfc) return 'IPv6 唯一本地地址'; // fc00::/7
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return 'IPv6 链路本地地址'; // fe80::/10
  if (b[0] == 0xff) return '多播地址'; // ff00::/8
  return null;
}

/// 域名只做基本形状检查：Uri 已拆掉凭据/端口/路径，这里挡住注入类字符即可。
bool _isPlausibleDnsName(String host) {
  if (host.isEmpty || host.length > 253 || host.startsWith('.')) return false;
  const forbidden = '/\\@%[]{}<>|"';
  for (final char in host.split('')) {
    if (char.trim().isEmpty || forbidden.contains(char)) return false;
  }
  return true;
}
