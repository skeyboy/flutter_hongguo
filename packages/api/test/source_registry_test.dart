import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_api/src/catalog.dart';
import 'package:hongguo_api/src/source_adapter.dart';
import 'package:hongguo_api/src/source_registry.dart';
import 'package:hongguo_api/src/video_model_client.dart';
import 'package:test/test.dart';

/// 测试替身：只关心路由用到的 id / matches / enabled。
class FakeAdapter implements SourceAdapter {
  FakeAdapter(
    this.id, {
    this.enabledFlag = true,
    bool Function(String)? matches,
  }) : _matches = matches ?? ((_) => true);

  final bool Function(String) _matches;
  final bool enabledFlag;

  @override
  final String id;

  @override
  String get label => id;

  @override
  SourceKind get kind => SourceKind.custom;

  @override
  bool matches(String mediaId) => _matches(mediaId);

  @override
  bool enabled(SourceSettings settings) => enabledFlag;

  @override
  Future<CatalogPage> browse({
    String genre = '',
    String? cursor,
    String? sort,
  }) async => CatalogPage(const []);

  @override
  Future<CatalogPage> search(String query, {String? cursor}) async =>
      CatalogPage(const []);

  @override
  Future<DramaDetail> detail(String seriesId) async =>
      DramaDetail(Drama(id: seriesId, title: ''), const []);

  @override
  Future<VideoTrack> fetchTrack(String mediaId, {String quality = 'best'}) =>
      throw UnimplementedError();
}

void main() {
  const settings = SourceSettings();
  final hongguo = FakeAdapter(
    'hongguo',
    matches: (id) => RegExp(r'^\d{1,30}$').hasMatch(id),
  );
  final xifan = FakeAdapter('xifan', matches: (id) => id.startsWith('xifan:'));

  group('forId 路由', () {
    test('按 matches 命中第一个适配器', () {
      final registry = SourceRegistry([(s) => hongguo, (s) => xifan], settings);
      expect(registry.forId('123'), same(hongguo));
      expect(registry.forId('xifan:a:b'), same(xifan));
    });

    test('未命中返回 null（由门面兜底）', () {
      final registry = SourceRegistry([(s) => hongguo], settings);
      expect(registry.forId('hema:42'), isNull);
    });
  });

  group('enabled 过滤', () {
    final disabled = FakeAdapter(
      'xifan',
      enabledFlag: false,
      matches: (id) => id.startsWith('xifan:'),
    );

    test('enabled 列表剔除禁用源且顺序稳定', () {
      final registry = SourceRegistry([
        (s) => hongguo,
        (s) => disabled,
        (s) => xifan,
      ], settings);
      expect(registry.enabled.map((a) => a.id), ['hongguo', 'xifan']);
    });

    test('forId 跳过禁用源继续找下一个', () {
      final registry = SourceRegistry([
        (s) => disabled,
        (s) => xifan,
      ], settings);
      expect(registry.forId('xifan:a:b'), same(xifan));
    });
  });

  group('sourceOf 兜底', () {
    test('无适配器命中时退回通用前缀判定', () {
      final registry = SourceRegistry(const [], settings);
      expect(registry.sourceOf('123'), 'hongguo');
      expect(registry.sourceOf('hema:42'), 'hema');
      expect(registry.sourceOf('unknown:x'), 'hongguo');
    });

    test('命中 custom 适配器时返回完整 custom:{uuid}', () {
      const uuid = '550e8400-e29b-41d4-a716-446655440000';
      final custom = FakeAdapter(
        'custom:$uuid',
        matches: (id) => id.startsWith('custom:$uuid:'),
      );
      final registry = SourceRegistry([(s) => custom], settings);
      expect(registry.sourceOf('custom:$uuid:vod:1:2'), 'custom:$uuid');
    });
  });

  group('custom 工厂动态生成', () {
    test('每次查找都重新调用工厂，配置变更即时生效', () {
      var currentId = 'custom:11111111-1111-4111-8111-111111111111';
      final registry = SourceRegistry([
        (s) => FakeAdapter(
          currentId,
          matches: (id) => id.startsWith('$currentId:'),
        ),
      ], settings);

      final firstId = currentId;
      expect(registry.forId('$firstId:vod:1')?.id, firstId);

      currentId = 'custom:22222222-2222-4222-8222-222222222222';
      expect(registry.forId('$currentId:vod:1')?.id, currentId);
      expect(registry.forId('$firstId:vod:1'), isNull);
    });

    test('expansive 工厂按配置展开多个适配器（P3 自定义源）', () {
      const a = 'custom:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const b = 'custom:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
      final enabledConfigs = [a, b];
      final registry = SourceRegistry(
        [],
        settings,
        expansiveFactories: [
          (s) => [
            for (final id in enabledConfigs)
              FakeAdapter(id, matches: (media) => media.startsWith('$id:')),
          ],
        ],
      );

      expect(registry.enabled.map((e) => e.id), [a, b]);
      expect(registry.forId('$a:vod:1:2')?.id, a);
      expect(registry.forId('$b:vod:1:2')?.id, b);
      expect(registry.sourceOf('$a:vod:1:2'), a);

      // 配置变更（移除一个源）后重新求值即生效。
      enabledConfigs.remove(b);
      expect(registry.enabled.map((e) => e.id), [a]);
      expect(registry.forId('$b:vod:1'), isNull);
    });
  });
}
