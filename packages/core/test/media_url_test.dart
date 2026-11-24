import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

/// 取源分两层，白名单也必须分两张：官网直链会落到字节系其它 CDN，App 签名
/// 链接不会。下载层按 track 来源选表——收窄会误杀官网直链，放宽会替 App 层
/// 放行不该出现的域。
void main() {
  test('官网表是 App 表的超集，且多出来的正是页面直链的 CDN', () {
    expect(webMediaDomains, containsAll(appMediaDomains));
    for (final host in [
      'v3.bytecdn.cn',
      'v9.bytecdn.com',
      'p3.ibytedtos.com',
      'x.bdcgslb.com',
    ]) {
      expect(
        () => MediaUrlDecoder.checked('https://$host/v.mp4', webMediaDomains),
        returnsNormally,
        reason: host,
      );
      expect(
        () => MediaUrlDecoder.checked('https://$host/v.mp4', appMediaDomains),
        throwsFormatException,
        reason: host,
      );
    }
  });

  test('两张表都只认 HTTPS 且不允许带端口与凭据', () {
    for (final domains in [appMediaDomains, webMediaDomains]) {
      expect(
        () => MediaUrlDecoder.checked('http://v.qznovelvod.com/v.mp4', domains),
        throwsFormatException,
      );
      expect(
        () => MediaUrlDecoder.checked(
          'https://v.qznovelvod.com:8443/v.mp4',
          domains,
        ),
        throwsFormatException,
      );
      expect(
        () => MediaUrlDecoder.checked(
          'https://user@v.qznovelvod.com/v.mp4',
          domains,
        ),
        throwsFormatException,
      );
      expect(
        () => MediaUrlDecoder.checked('https://evil.example/v.mp4', domains),
        throwsFormatException,
      );
    }
  });

  test('子域命中而前缀伪装不命中', () {
    expect(
      MediaUrlDecoder.checked(
        'https://a.qznovelvod.com/v.mp4',
        appMediaDomains,
      ).host,
      'a.qznovelvod.com',
    );
    // 结尾拼接不算命中：qznovelvod.com.evil.example 是别人的域。
    expect(
      () => MediaUrlDecoder.checked(
        'https://qznovelvod.com.evil.example/v.mp4',
        appMediaDomains,
      ),
      throwsFormatException,
    );
  });
}
