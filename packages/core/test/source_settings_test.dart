import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

const _uuid = '123e4567-e89b-42d3-a456-426614174000';

void main() {
  test('内置源默认值严格对齐参考语义', () {
    const settings = SourceSettings();
    expect(settings.isEnabled('hongguo'), isTrue);
    expect(settings.isEnabled('xifan'), isTrue);
    expect(settings.isEnabled('hema'), isTrue);
    expect(settings.isEnabled('reelshort'), isFalse);
    expect(settings.isEnabled('dramabox'), isFalse);
    expect(settings.isEnabled('unknown'), isFalse);
    settings.validate();
    expect(settings.builtin['hongguo'], isTrue);
  });

  test('hongguo 不可关闭，validate 强制写回 true', () {
    final settings = SourceSettings.fromJson({
      'builtin': {'hongguo': false, 'xifan': false},
    });
    settings.validate();
    expect(settings.builtin['hongguo'], isTrue);
    expect(settings.isEnabled('hongguo'), isTrue);
    expect(settings.isEnabled('xifan'), isFalse);

    // 即使是 const 构造的不可变 map，isEnabled 也保证恒开。
    const immutable = SourceSettings(builtin: {'hongguo': false});
    immutable.validate();
    expect(immutable.isEnabled('hongguo'), isTrue);
  });

  test('自定义源按 uuid 路由，合法配置通过校验', () {
    final settings = SourceSettings(
      customSources: [
        CustomSourceConfig(
          uuid: _uuid,
          name: '我的源',
          url: 'https://cdn.example.com/v.mp4',
          enabled: true,
        ),
      ],
    );
    settings.validate();
    expect(settings.isEnabled('custom:$_uuid'), isTrue);
    expect(settings.isEnabled('custom:missing'), isFalse);
  });

  test('validate 拒绝坏 UUID 与私网/带凭据地址', () {
    SourceSettings badUuid({required String uuid}) => SourceSettings(
      customSources: [
        CustomSourceConfig(
          uuid: uuid,
          name: '源',
          url: 'https://cdn.example.com/v.mp4',
        ),
      ],
    );
    for (final uuid in ['not-a-uuid', '123e4567-e89b-12d3-a456-426614174000']) {
      expect(() => badUuid(uuid: uuid).validate(), throwsFormatException);
    }
    SourceSettings badUrl(String url) => SourceSettings(
      customSources: [CustomSourceConfig(uuid: _uuid, name: '源', url: url)],
    );
    for (final url in [
      'http://cdn.example.com/v.mp4',
      'https://user:pass@cdn.example.com/v.mp4',
      'https://127.0.0.1/v.mp4',
      'https://192.168.1.1/v.mp4',
      'https://169.254.169.254/latest/meta-data',
      'https://198.18.0.1/v.mp4',
      'https://0x7f000001/v.mp4',
      'https://[::ffff:127.0.0.1]/v.mp4',
    ]) {
      expect(() => badUrl(url).validate(), throwsFormatException, reason: url);
    }
    expect(
      () => badUrl('https://cdn.example.com/${'x' * 2000}').validate(),
      throwsFormatException,
    );
    expect(
      () => SourceSettings(
        customSources: [
          CustomSourceConfig(
            uuid: _uuid,
            name: '',
            url: 'https://cdn.example.com/v.mp4',
          ),
        ],
      ).validate(),
      throwsFormatException,
    );
  });

  test('toJson/fromJson 往返，且坏类型回退默认值', () {
    final original = SourceSettings.fromJson({});
    original.customSources.add(
      CustomSourceConfig(
        uuid: _uuid,
        name: '我的源',
        url: 'https://cdn.example.com/v.mp4',
        enabled: true,
      ),
    );
    original.builtin['xifan'] = false;
    final restored = SourceSettings.fromJson(original.toJson());
    expect(restored.toJson(), original.toJson());
    expect(restored.isEnabled('xifan'), isFalse);
    expect(restored.isEnabled('custom:$_uuid'), isTrue);

    final fallback = SourceSettings.fromJson({
      'builtin': 'not-a-map',
      'customSources': 'not-a-list',
    });
    expect(fallback.toJson(), const SourceSettings().toJson());
  });

  test('AppSettings 纳入 sources，老 JSON 仍能回退且 copyWith 支持覆盖', () {
    expect(AppSettings.fromJson({}).sources, isA<SourceSettings>());
    final configured = AppSettings.fromJson({}).copyWith(
      sources: SourceSettings(
        customSources: [
          CustomSourceConfig(
            uuid: _uuid,
            name: '我的源',
            url: 'https://cdn.example.com/v.mp4',
            enabled: true,
          ),
        ],
      ),
    );
    configured.validate();
    expect(
      AppSettings.fromJson(configured.toJson()).sources.toJson(),
      configured.sources.toJson(),
    );
    expect(
      AppSettings.fromJson({'sources': 42}).sources.toJson(),
      const SourceSettings().toJson(),
    );
  });
}
