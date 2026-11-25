import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_api/src/media_url_policy.dart';
import 'package:test/test.dart';

void main() {
  group('DomainAllowlistPolicy 保持红果原行为', () {
    const policy = DomainAllowlistPolicy(appMediaDomains);

    test('域名表内与子域放行，返回解析后的 Uri', () {
      expect(
        checkMediaUrl('https://qznovelvod.com/v.mp4', policy).host,
        'qznovelvod.com',
      );
      expect(
        checkMediaUrl('https://cdn.qznovelvod.com/v.mp4', policy).host,
        'cdn.qznovelvod.com',
      );
    });

    test('非白名单域名抛 FormatException，文案与 MediaUrlDecoder.checked 一致', () {
      const url = 'https://evil.com/v.mp4';
      String? original;
      try {
        MediaUrlDecoder.checked(url, appMediaDomains);
      } on FormatException catch (e) {
        original = e.message;
      }
      expect(original, isNotNull);
      expect(
        () => checkMediaUrl(url, policy),
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', original),
        ),
      );
    });
  });

  group('PublicWebPolicy hosts 后缀校验', () {
    const policy = PublicWebPolicy(hosts: ['xifan.tv']);

    test('精确 host 与点边界子域放行', () {
      expect(checkMediaUrl('https://xifan.tv/v.mp4', policy).host, 'xifan.tv');
      expect(
        checkMediaUrl('https://cdn.xifan.tv/v.mp4', policy).host,
        'cdn.xifan.tv',
      );
    });

    test('不同域与后缀伪装域拒绝', () {
      expect(
        () => checkMediaUrl('https://evil.com/v.mp4', policy),
        throwsFormatException,
      );
      expect(
        () => checkMediaUrl('https://xifan.tv.evil.com/v.mp4', policy),
        throwsFormatException,
      );
    });

    test('hosts 为 null 时只做公网校验', () {
      const open = PublicWebPolicy();
      expect(
        checkMediaUrl('https://cdn.example.com/v.mp4', open).host,
        'cdn.example.com',
      );
      expect(
        () => checkMediaUrl('https://127.0.0.1/v.mp4', open),
        throwsFormatException,
      );
    });
  });

  group('checkMediaUrl 先过 isPublicMediaUrl', () {
    test('私网 / 回环 / 凭据 / 十进制 IP 一律拒绝', () {
      for (final url in [
        'https://127.0.0.1/v.mp4',
        'https://[::1]/v.mp4',
        'https://user:pass@example.com/v.mp4',
        'https://2130706433/v.mp4',
      ]) {
        expect(
          () => checkMediaUrl(url, const PublicWebPolicy()),
          throwsFormatException,
          reason: '$url 应被公网判定拒绝',
        );
      }
    });

    test('即使域名表写了私网 host，公网判定仍先拦截', () {
      const policy = DomainAllowlistPolicy(['127.0.0.1']);
      expect(
        () => checkMediaUrl('https://127.0.0.1/v.mp4', policy),
        throwsFormatException,
      );
    });
  });
}
