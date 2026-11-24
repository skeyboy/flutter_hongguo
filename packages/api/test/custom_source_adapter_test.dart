import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart'
    show CustomSourceConfig, SourceSettings;
import 'package:test/test.dart';

/// 离线苹果 CMS：按请求回 fixture JSON，不碰真网。
/// 逐跳重定向测试也走这里——适配器必须自己校验 Location，不能依赖 Dio 跟随。
class _FakeAppleCms implements HttpClientAdapter {
  _FakeAppleCms({
    Map<String, dynamic>? payload,
    this.location,
    this.brokenJson = false,
    this.timeout = false,
    this.slow = false,
  }) : payload = payload ?? _payload();

  final Map<String, dynamic> payload;
  final String? location;
  final bool brokenJson;
  final bool timeout;
  final bool slow;

  final List<Uri> urls = [];
  final List<Map<String, String>> queryParameters = [];
  final List<Map<String, dynamic>> headers = [];
  final Completer<void> entered = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async {
    urls.add(options.uri);
    queryParameters.add(
      options.uri.queryParameters.map((key, value) => MapEntry(key, value)),
    );
    headers.add(Map<String, dynamic>.from(options.headers));
    if (!entered.isCompleted) entered.complete();

    if (timeout) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.receiveTimeout,
      );
    }
    if (slow) {
      // 真实网络里 Dio 会在令牌取消时结束等待；这里把 cancelFuture 当作闸门。
      await (cancelFuture ?? Future<void>.value());
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
      );
    }
    if (location != null && urls.length == 1) {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': [location!],
        },
      );
    }
    final text = brokenJson ? 'not-json' : jsonEncode(payload);
    return ResponseBody.fromString(
      text,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _uuid = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
const _apiUrl = 'https://cms.example.com';
const _videoBase = 'https://cdn.example.com/vod';

CustomSourceConfig _config({
  String uuid = _uuid,
  String name = '我的苹果源',
  String url = _apiUrl,
  bool enabled = true,
}) => CustomSourceConfig(uuid: uuid, name: name, url: url, enabled: enabled);

Map<String, dynamic> _item(
  int id, {
  String name = '测试短剧',
  String? playFrom,
  String? playUrl,
  Map<String, dynamic> extra = const {},
}) => {
  'vod_id': '$id',
  'vod_name': name,
  'vod_pic': 'https://img.example.com/$id.jpg',
  'vod_total': 2,
  'vod_content': '<p>简介</p>',
  'type_name': '逆袭',
  'vod_play_from': playFrom ?? '线路一\$\$\$线路二',
  'vod_play_url':
      playUrl ??
      '第1集\$$_videoBase/$id/1.mp4#第2集\$$_videoBase/$id/2.mp4\$\$\$'
          '第1集\$$_videoBase/$id/b1.mp4#第2集\$$_videoBase/$id/b2.mp4',
  ...extra,
};

Map<String, dynamic> _payload({
  int page = 1,
  int pagecount = 2,
  List<Map<String, dynamic>>? list,
  int code = 1,
}) => {
  'code': code,
  'page': page,
  'pagecount': pagecount,
  'total': 10,
  'class': [
    {'type_id': 1, 'type_name': '都市'},
    {'type_id': '2', 'type_name': '逆袭'},
    {'type_id': 'bad', 'type_name': '丢弃'},
  ],
  'list': list ?? [_item(101), _item(101), _item(102)],
};

({CustomSourceAdapter adapter, _FakeAppleCms fake}) _make({
  CustomSourceConfig? config,
  CustomSourceConfig? Function()? configOf,
  Map<String, dynamic>? payload,
  String? location,
  bool brokenJson = false,
  bool timeout = false,
  bool slow = false,
  CancelTokenRegistry? tokens,
}) {
  final initial = config ?? _config();
  final fake = _FakeAppleCms(
    payload: payload,
    location: location,
    brokenJson: brokenJson,
    timeout: timeout,
    slow: slow,
  );
  final adapter = CustomSourceAdapter(
    uuid: _uuid,
    dio: Dio()..httpClientAdapter = fake,
    configOf: configOf ?? () => initial,
    initial: initial,
    tokens: tokens,
  );
  addTearDown(() => adapter.dio.close(force: true));
  return (adapter: adapter, fake: fake);
}

void main() {
  group('配置校验（validate）', () {
    test('归一默认接口路径、去 hash 与 HTML 标签', () {
      final result = CustomSourceAdapter.validate(
        _config(
          name: '<b>我的苹果源</b>',
          url: 'https://cms.example.com/?ac=list#fragment',
        ),
      );
      expect(result.name, '我的苹果源');
      expect(result.uuid, _uuid);
      expect(
        result.url,
        'https://cms.example.com/api.php/provide/vod/?ac=list',
      );
    });

    test('拒绝私网/回环/Fake-IP/TEST-NET/十进制 IP/凭据/非 https', () {
      for (final url in [
        'https://127.0.0.1/api',
        'https://[::1]/api',
        'https://10.0.0.1/api',
        'https://192.168.1.1/api',
        'https://169.254.169.254/latest/meta-data',
        'https://198.18.0.1/api',
        'https://203.0.113.9/api',
        'https://2130706433/api',
        'https://0x7f000001/api',
        'https://user:pass@cms.example.com/api',
        'http://cms.example.com/api',
      ]) {
        expect(
          () => CustomSourceAdapter.validate(_config(url: url)),
          throwsA(isA<SourceRejected>()),
          reason: url,
        );
      }
    });

    test('拒绝坏 UUID 与坏名称', () {
      final badUuid = _config().copyWithUuid('not-a-uuid');
      expect(
        () => CustomSourceAdapter.validate(badUuid),
        throwsA(isA<SourceRejected>()),
      );
      for (final name in ['', 'x' * 41, '换行\n名称']) {
        expect(
          () => CustomSourceAdapter.validate(_config(name: name)),
          throwsA(isA<SourceRejected>()),
          reason: name,
        );
      }
    });
  });

  group('配置热变更', () {
    test('禁用、删除、改 URL 后旧实例拒绝请求', () async {
      CustomSourceConfig? current = _config();
      final fake = _FakeAppleCms();
      final adapter = CustomSourceAdapter(
        uuid: _uuid,
        dio: Dio()..httpClientAdapter = fake,
        configOf: () => current,
        initial: current,
      );
      addTearDown(() => adapter.dio.close(force: true));

      current = _config(enabled: false);
      await expectLater(
        adapter.browse(),
        throwsA(
          isA<SourceRejected>().having(
            (e) => e.message,
            'message',
            contains('已禁用、删除或配置已变更'),
          ),
        ),
      );
      current = null;
      await expectLater(adapter.search('短剧'), throwsA(isA<SourceRejected>()));
      current = _config(url: 'https://other.example.com');
      await expectLater(
        adapter.detail('custom:$_uuid:101'),
        throwsA(isA<SourceRejected>()),
      );
      expect(fake.urls, isEmpty);
    });

    test('label 跟随当前配置，删除后回退 initial', () {
      CustomSourceConfig? current = _config(name: '改名了');
      final (adapter: adapter, fake: _) = _make(configOf: () => current);
      expect(adapter.label, '改名了');
      current = null;
      expect(adapter.label, '我的苹果源');
      expect(adapter.id, 'custom:$_uuid');
      expect(adapter.kind, SourceKind.custom);
      expect(adapter.matches('custom:$_uuid:101:0:0'), isTrue);
      expect(adapter.matches('custom:other:101'), isFalse);
      expect(
        adapter.enabled(
          SourceSettings(customSources: [_config(enabled: true)]),
        ),
        isTrue,
      );
    });
  });

  group('目录与详情', () {
    test('browse 归一、去重、给分类与下一页，并固定 ac/at 参数', () async {
      final (adapter: adapter, fake: fake) = _make();
      final page = await adapter.browse(genre: '2', cursor: '1');
      expect(page.items.map((d) => d.id), [
        'custom:$_uuid:101',
        'custom:$_uuid:102',
      ]);
      expect(page.items.first.title, '测试短剧');
      expect(page.items.first.cover, 'https://img.example.com/101.jpg');
      expect(page.items.first.intro, '简介');
      expect(page.items.first.tagNames, ['逆袭']);
      expect(page.items.first.episodeCount, 2);
      expect(page.nextCursor, '2');
      expect(adapter.lastGenres.map((g) => g.id), ['1', '2']);
      expect(adapter.lastGenres.first.name, '都市');

      final query = fake.queryParameters.single;
      expect(query['ac'], 'detail');
      expect(query['at'], 'json');
      expect(query['pg'], '1');
      expect(query['t'], '2');
      final headers = fake.headers.single;
      expect(headers['Accept'], 'application/json');
      expect(headers['User-Agent'], 'Mozilla/5.0');
      expect(fake.urls.single.path, '/api.php/provide/vod/');
    });

    test('search 传 wd/pg，页码与关键词非法时拒绝', () async {
      final (adapter: adapter, fake: fake) = _make(payload: _payload(page: 3));
      final page = await adapter.search('逆袭', cursor: '3');
      expect(page.items, hasLength(2));
      expect(fake.queryParameters.single['wd'], '逆袭');
      expect(fake.queryParameters.single['pg'], '3');

      await expectLater(adapter.search(''), throwsA(isA<SourceRejected>()));
      await expectLater(
        adapter.search('x' * 201),
        throwsA(isA<SourceRejected>()),
      );
      await expectLater(
        adapter.browse(cursor: '100001'),
        throwsA(isA<SourceRejected>()),
      );
      await expectLater(
        adapter.browse(genre: 'abc'),
        throwsA(isA<SourceRejected>()),
      );
    });

    test('分页不一致与坏 JSON 都换成自有文案', () async {
      final (adapter: mismatch, fake: _) = _make(payload: _payload(page: 9));
      await expectLater(
        mismatch.browse(),
        throwsA(
          isA<SourceUnavailable>().having(
            (e) => e.message,
            'message',
            contains('页码不一致'),
          ),
        ),
      );

      final (adapter: broken, fake: _) = _make(brokenJson: true);
      await expectLater(
        broken.browse(),
        throwsA(
          isA<SourceUnavailable>().having(
            (e) => e.message,
            'message',
            contains('未返回有效 JSON'),
          ),
        ),
      );

      final (adapter: wrongShape, fake: _) = _make(payload: _payload(code: 0));
      await expectLater(
        wrongShape.browse(),
        throwsA(
          isA<SourceUnavailable>().having(
            (e) => e.message,
            'message',
            contains('苹果 CMS 数据无效'),
          ),
        ),
      );
    });

    test('detail 只展开 mp4 线路且集键按「第N集」归一', () async {
      final item = _item(
        101,
        playFrom: '高清\$\$\$备用',
        playUrl: '第01集\$$_videoBase/101/1.mp4#番外\$$_videoBase/101/x.mp4',
      );
      final (adapter: adapter, fake: fake) = _make(
        payload: _payload(list: [item]),
      );
      final detail = await adapter.detail('custom:$_uuid:101');
      expect(detail.drama.id, 'custom:$_uuid:101');
      expect(fake.queryParameters.single['ids'], '101');
      expect(detail.episodes.map((e) => e.vid), [
        'custom:$_uuid:101:0:0',
        'custom:$_uuid:101:0:1',
      ]);
      expect(detail.episodes.map((e) => e.index), [1, 2]);

      final lines = adapter.mediaLines(item);
      expect(lines.map((e) => e.key), ['number:1', '番外']);
      expect(lines.every((e) => e.format == VideoFormat.mp4), isTrue);
    });

    test('跨源 ID 与非法分段 ID 被拒', () async {
      final (adapter: adapter, fake: fake) = _make();
      await expectLater(
        adapter.detail('custom:other:101'),
        throwsA(isA<SourceRejected>()),
      );
      await expectLater(
        adapter.fetchTrack('custom:$_uuid:101:0'),
        throwsA(isA<SourceRejected>()),
      );
      expect(fake.urls, isEmpty);
    });
  });

  group('取址', () {
    test('mp4 主轨与多线路候选', () async {
      final (adapter: adapter, fake: fake) = _make(
        payload: _payload(list: [_item(101)]),
      );
      final track = await adapter.fetchTrack('custom:$_uuid:101:0:0');
      expect(track.url.toString(), '$_videoBase/101/1.mp4');
      expect(track.source, 'custom:$_uuid');
      expect(track.format, VideoFormat.mp4);
      expect(track.spadeA, isEmpty);
      expect(track.userAgent, 'Mozilla/5.0');
      expect(track.referer, 'https://cms.example.com/');
      expect(track.policy, isA<PublicWebPolicy>());
      expect((track.policy! as PublicWebPolicy).hosts, ['cdn.example.com']);
      expect(track.candidates, hasLength(1));
      expect(track.candidates!.single.url.toString(), '$_videoBase/101/b1.mp4');
      // 每次取址重新 detail，不复用上一次详情。
      expect(fake.urls, hasLength(1));
    });

    test('只有 m3u8 线路时早拒，不返回 HLS 轨', () async {
      final item = _item(
        101,
        playFrom: 'HLS',
        playUrl: '第1集\$$_videoBase/101/1.m3u8#第2集\$$_videoBase/101/2.m3u8',
      );
      final (adapter: adapter, fake: fake) = _make(
        payload: _payload(list: [item]),
      );
      await expectLater(
        adapter.detail('custom:$_uuid:101'),
        throwsA(
          isA<SourceUnavailable>().having(
            (e) => e.message,
            'message',
            allOf(contains('HLS'), contains('暂不支持')),
          ),
        ),
      );
      await expectLater(
        adapter.fetchTrack('custom:$_uuid:101:0:0'),
        throwsA(
          isA<SourceUnavailable>().having(
            (e) => e.message,
            'message',
            contains('暂不支持'),
          ),
        ),
      );
      expect(adapter.mediaLines(item).first.format, VideoFormat.hls);
      expect(fake.urls, hasLength(2));
    });

    test('付费/密码剧抛 SourceLocked 且不返回地址', () async {
      for (final extra in [
        {'vod_points_play': 1},
        {'vod_points': 2},
        {'vod_pwd_play': '1234'},
        {'locked': true},
      ]) {
        final (adapter: adapter, fake: fake) = _make(
          payload: _payload(list: [_item(101, extra: extra)]),
        );
        await expectLater(
          adapter.fetchTrack('custom:$_uuid:101:0:0'),
          throwsA(
            isA<SourceLocked>().having(
              (e) => e.message,
              'message',
              contains('需付费或密码'),
            ),
          ),
        );
        expect(fake.urls, hasLength(1));
      }
    });

    test('拿不到选中分集时给固定文案', () async {
      final (adapter: adapter, fake: _) = _make(
        payload: _payload(list: [_item(101)]),
      );
      await expectLater(
        adapter.fetchTrack('custom:$_uuid:101:9:9'),
        throwsA(
          isA<SourceUnavailable>().having(
            (e) => e.message,
            'message',
            contains('未找到可直接播放的分集'),
          ),
        ),
      );
    });
  });

  group('SSRF 与逐跳校验', () {
    test('请求阶段拒绝不安全配置地址，一个包都不发', () async {
      for (final url in [
        'https://127.0.0.1/api',
        'https://[::1]/api',
        'https://10.0.0.1/api',
        'https://198.18.0.1/api',
        'https://203.0.113.9/api',
        'https://2130706433/api',
        'https://user:pass@cms.example.com/api',
      ]) {
        final (adapter: adapter, fake: fake) = _make(config: _config(url: url));
        await expectLater(
          adapter.browse(),
          throwsA(isA<SourceRejected>()),
          reason: url,
        );
        expect(fake.urls, isEmpty, reason: url);
      }
    });

    test('重定向到私网在下一跳发包前拒绝', () async {
      final (adapter: adapter, fake: fake) = _make(
        location: 'http://127.0.0.1/inside',
      );
      await expectLater(
        adapter.browse(),
        throwsA(
          isA<SourceRejected>().having(
            (e) => e.message,
            'message',
            contains('来源配置'),
          ),
        ),
      );
      expect(fake.urls, hasLength(1));
      expect(fake.urls.single.host, 'cms.example.com');
    });

    test('重定向到 TEST-NET / 十进制回环同样拒绝', () async {
      for (final location in [
        'https://203.0.113.9/x',
        'https://2130706433/x',
      ]) {
        final (adapter: adapter, fake: fake) = _make(location: location);
        await expectLater(adapter.browse(), throwsA(isA<SourceRejected>()));
        expect(fake.urls, hasLength(1), reason: location);
      }
    });

    test('相对 Location 基于当前跳 resolve 后合法跟随', () async {
      final (adapter: adapter, fake: fake) = _make(
        location: '/api.php/provide/vod/?pg=2',
      );
      final page = await adapter.browse();
      expect(page.items, hasLength(2));
      expect(fake.urls, hasLength(2));
      expect(fake.urls.last.host, 'cms.example.com');
      expect(fake.urls.last.path, '/api.php/provide/vod/');
    });
  });

  group('超时、取消与测试连接', () {
    test('超时与网络失败只给固定文案', () async {
      final (adapter: timedOut, fake: _) = _make(timeout: true);
      await expectLater(
        timedOut.browse(),
        throwsA(
          isA<SourceUnavailable>().having(
            (e) => e.message,
            'message',
            contains('取消或超时'),
          ),
        ),
      );

      final (adapter: refused, fake: _) = _make(
        payload: _payload(),
        config: _config(url: 'https://cms.example.com'),
      );
      // 正常路径不应误报网络失败。
      expect((await refused.browse()).items, hasLength(2));
    });

    test('cancelRequests 撤销在途并释放令牌', () async {
      final registry = CancelTokenRegistry();
      final (adapter: adapter, fake: fake) = _make(
        slow: true,
        tokens: registry,
      );
      final pending = adapter.browse();
      await fake.entered.future;
      expect(registry.inFlightCount, 1);
      adapter.cancelRequests();
      await expectLater(
        pending,
        throwsA(
          isA<SourceUnavailable>().having(
            (e) => e.message,
            'message',
            contains('取消或超时'),
          ),
        ),
      );
      expect(registry.inFlightCount, 0);
    });

    test('test() 成功报条数与分类数，失败用自有文案', () async {
      final (adapter: ok, fake: _) = _make();
      final success = await ok.test();
      expect(success.ok, isTrue);
      expect(success.message, '连接成功，返回 3 条，2 个分类');

      final (adapter: failed, fake: _) = _make(brokenJson: true);
      final failure = await failed.test();
      expect(failure.ok, isFalse);
      expect(failure.message, contains('未返回有效 JSON'));

      // draft 模式允许保存前测试：禁用配置也照样可测。
      final (adapter: draft, fake: draftFake) = _make(
        config: _config(enabled: false),
      );
      expect((await draft.test()).ok, isTrue);
      expect(draftFake.urls, hasLength(1));
    });
  });
}

extension on CustomSourceConfig {
  CustomSourceConfig copyWithUuid(String value) =>
      CustomSourceConfig(uuid: value, name: name, url: url, enabled: enabled);
}
