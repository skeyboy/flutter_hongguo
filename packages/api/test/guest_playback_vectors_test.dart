// Pinned vectors translated verbatim from hongguo-android
// app/src/test/java/com/hongguo/api/service/PublicEpisodeSourceTest.java
// (GPL-3.0-only). The parser must reproduce pageTrack's gate exactly before
// the web-anonymous route is wired in.
import 'package:hongguo_api/src/web_source.dart';
import 'package:test/test.dart';

const series = '7000000000000000001';
const first = '7000000000000000002';
const second = '7000000000000000003';

String page(String vid, int accessible, {bool seo = false}) {
  final metadata = seo
      ? ',"publicVideoSeo":{"available":true,"seriesId":"$series",'
            '"itemId":"$vid","durationSeconds":125.14,"width":360,"height":640}'
      : '';
  return '<script>_ROUTER_DATA = {"loaderData":{"player_(series_id)/(vid)/page":'
      '{"isSuccess":true,"series_id":"$series","vid":"$vid",'
      '"req":{"pcLoginRequired":false,"pcAuthenticatedPlayback":false},'
      '"seriesDetail":{"series_id":$series,"vid_list":[$first,$second],'
      '"accessible_episode_cnt":$accessible}$metadata}}};</script>';
}

void main() {
  group('parseGuestPlayerPage — pinned Android pageTrack vectors', () {
    test('访客首集带 SEO 元数据：duration 125.14 / 网页 360P', () {
      final info = parseGuestPlayerPage(
        page(first, 1, seo: true),
        series,
        first,
      );
      expect(info, isNotNull);
      expect(info!.seriesId, series);
      expect(info.vid, first);
      expect(info.publicDurationSeconds, 125.14);
      expect(info.definition, '网页 360P');
    });

    test('第二集不在访客覆盖内、无 SEO：duration 0 / 网页片源', () {
      final info = parseGuestPlayerPage(page(second, 2), series, second);
      expect(info, isNotNull);
      expect(info!.publicDurationSeconds, 0.0);
      expect(info.definition, '网页片源');
    });

    test('需要登录 / 需要鉴权 / 权限字段改名：一律拒绝', () {
      final valid = page(second, 2, seo: true);
      final rejected = <String>[
        page(second, 1),
        valid.replaceAll('"pcLoginRequired":false', '"pcLoginRequired":true'),
        valid.replaceAll(
          '"pcAuthenticatedPlayback":false',
          '"pcAuthenticatedPlayback":true',
        ),
        valid.replaceAll('pcLoginRequired', 'noPermissionFlag'),
      ];
      for (final html in rejected) {
        expect(
          parseGuestPlayerPage(html, series, second),
          isNull,
          reason: html.substring(0, html.length < 60 ? html.length : 60),
        );
      }
    });

    test('身份不符 / 路由标记缺失：拒绝', () {
      final valid = page(second, 2, seo: true);
      final rejected = <String>[
        page(first, 2), // 首集的页面拿来取第二集
        valid.replaceAll('"seriesId":"$series', '"seriesId":"$first'),
        valid.replaceAll('<script>', '<div>'),
      ];
      for (final html in rejected) {
        expect(parseGuestPlayerPage(html, series, second), isNull);
      }
    });

    test('SEO 元数据与请求分集不符：拒绝，绝不取推荐位的时长', () {
      final html = page(
        first,
        1,
        seo: true,
      ).replaceAll('"itemId":"$first"', '"itemId":"$second"');
      expect(parseGuestPlayerPage(html, series, first), isNull);
    });
  });
}
