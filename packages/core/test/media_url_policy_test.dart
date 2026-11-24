import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

/// 公网判定只挡字面量与凭据：等价变形（十进制/八进制/十六进制/IPv4-mapped）
/// 必须还原后再判，否则 SSRF 校验可以被一行写法绕过。
void main() {
  test('非 HTTPS、凭据与非 443 端口拒绝', () {
    expect(isPublicMediaUrl(Uri.parse('http://example.com/v.mp4')), isNotNull);
    expect(
      isPublicMediaUrl(Uri.parse('https://user:pass@example.com/v.mp4')),
      isNotNull,
    );
    expect(
      isPublicMediaUrl(Uri.parse('https://example.com:8443/v.mp4')),
      isNotNull,
    );
    expect(
      isPublicMediaUrl(Uri.parse('https://example.com:443/v.mp4')),
      isNull,
    );
  });

  test('回环、私网、链路本地、多播与未指定地址拒绝', () {
    for (final url in [
      'https://127.0.0.1/v.mp4',
      'https://[::1]/v.mp4',
      'https://10.0.0.1/v.mp4',
      'https://172.16.0.1/v.mp4',
      'https://192.168.1.1/v.mp4',
      'https://169.254.169.254/latest/meta-data',
      'https://224.0.0.1/v.mp4',
      'https://0.0.0.0/v.mp4',
      'https://[fc00::1]/v.mp4',
      'https://[fe80::1]/v.mp4',
      'https://[ff02::1]/v.mp4',
      'https://[::]/v.mp4',
    ]) {
      expect(isPublicMediaUrl(Uri.parse(url)), isNotNull, reason: url);
    }
  });

  test('Fake-IP 与降级 IP 写法还原后拒绝', () {
    for (final url in [
      'https://198.18.0.1/v.mp4',
      'https://198.19.255.255/v.mp4',
      'https://2130706433/v.mp4', // 十进制 127.0.0.1
      'https://0x7f000001/v.mp4', // 十六进制 127.0.0.1
      'https://0177.0.0.1/v.mp4', // 八进制 127.0.0.1
      'https://127.1/v.mp4', // inet_aton 缩写
      'https://3232235777/v.mp4', // 十进制 192.168.1.1
      'https://[::ffff:127.0.0.1]/v.mp4',
      'https://[::ffff:7f00:1]/v.mp4', // 十六进制 IPv4-mapped
      'https://[::ffff:a9fe:a9fe]/v.mp4', // 链路本地 via mapped
    ]) {
      expect(isPublicMediaUrl(Uri.parse(url)), isNotNull, reason: url);
    }
  });

  test('合法公网域名与公网 IP 放行', () {
    for (final url in [
      'https://cdn.example.com/v.mp4',
      'https://qznovelvod.com/v.mp4',
      'https://8.8.8.8/v.mp4',
      'https://[2001:4860:4860::8888]/v.mp4',
    ]) {
      expect(isPublicMediaUrl(Uri.parse(url)), isNull, reason: url);
    }
  });

  test('拒绝原因可读且非 IO 异常', () {
    final reason = isPublicMediaUrl(Uri.parse('https://127.0.0.1/v.mp4'));
    expect(reason, isA<String>());
    expect(reason, isNotEmpty);
  });
}
