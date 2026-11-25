import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

void main() {
  test('默认路由顺序与现状一致', () {
    final routes = playbackRoutes(
      webFirst: true,
      set: PlaybackRouteSet.current,
    );
    expect(routes.map((r) => r.id).toList(), [
      PlaybackRouteId.webPublic,
      PlaybackRouteId.appMultiV1,
      PlaybackRouteId.legacyPreload,
    ]);
  });

  test('app-first 只把官网层移到末尾，不改动 App 层相对顺序', () {
    final routes = playbackRoutes(
      webFirst: false,
      set: PlaybackRouteSet.current,
    );
    expect(routes.map((r) => r.id).toList(), [
      PlaybackRouteId.appMultiV1,
      PlaybackRouteId.legacyPreload,
      PlaybackRouteId.webPublic,
    ]);
  });

  test('扩展路由集包含 v5、老单集与换主机，且只暴露路由 ID', () {
    final routes = playbackRoutes(
      webFirst: true,
      set: PlaybackRouteSet.extended,
    );
    expect(routes, hasLength(8));
    expect(
      routes.map((r) => r.id).toList(),
      containsAll(<PlaybackRouteId>[
        PlaybackRouteId.appVideoTabV5,
        PlaybackRouteId.appPlayerV5,
        PlaybackRouteId.appSingleV1,
        PlaybackRouteId.appMultiV1Hl,
        PlaybackRouteId.webAnonymous,
      ]),
    );
    final alt = routes.singleWhere((r) => r.id == PlaybackRouteId.appMultiV1Hl);
    expect(alt.host, 'api5-normal-hl.fqnovel.com');
    expect(routes.every((r) => r.toString() == r.id.label), isTrue);
  });

  test('换主机会重新签名，绝不复用旧签名头', () {
    final builder = VideoRequestBuilder(
      clockMillis: () => 1700000000123,
      deviceFactory: () => const {'ac': 'wifi'},
    );
    const device = PlaybackDevice(
      deviceId: '7661622467441478681',
      iid: '1234567890',
      cdid: 'cdid',
    );
    final primary = builder.build('7661622467441478682', device: device);
    final alternate = builder.build(
      '7661622467441478682',
      device: device,
      host: 'api5-normal-hl.fqnovel.com',
    );
    expect(primary.url, isNot(alternate.url));
    expect(alternate.url, contains('api5-normal-hl.fqnovel.com'));
    expect(primary.headers['x-gorgon'], isNot(alternate.headers['x-gorgon']));
    expect(primary.body, equals(alternate.body));
    expect(
      () => builder.build(
        '7661622467441478682',
        device: device,
        host: 'evil.example.com',
      ),
      throwsArgumentError,
    );
  });

  test('老配置缺协议开关时全部回退到当前行为', () {
    final settings = AppSettings.fromJson({'apiHost': 'api5-test.fqnovel.com'});
    expect(settings.detailSourceOrder, DetailSourceOrder.webFirst);
    expect(settings.identityPolicy, PlaybackIdentityPolicy.freshPerAsk);
    expect(settings.playbackRouteSet, PlaybackRouteSet.current);
    final roundTrip = AppSettings.fromJson(settings.toJson());
    expect(roundTrip.detailSourceOrder, DetailSourceOrder.webFirst);
    expect(
      AppSettings.fromJson({
        ...settings.toJson(),
        'detailSourceOrder': 'appFirst',
        'playbackRouteSet': 'extended',
        'identityPolicy': 'reuseOnSuccess',
      }).playbackRouteSet,
      PlaybackRouteSet.extended,
    );
  });
}
