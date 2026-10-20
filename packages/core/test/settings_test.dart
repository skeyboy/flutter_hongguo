import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

void main() {
  test('3–5 episode window and native preferences round-trip', () {
    for (final count in [3, 4, 5]) {
      final value = const AppSettings().copyWith(
        prefetchEpisodes: count,
        themeMode: 'dark',
        autoLoadMore: false,
      );
      value.validate();
      expect(AppSettings.fromJson(value.toJson()).toJson(), value.toJson());
    }
    expect(
      () => const AppSettings(prefetchEpisodes: 6).validate(),
      throwsFormatException,
    );
  });
  test('untrusted hosts, header injection and invalid limits are rejected', () {
    for (final host in [
      'https://fqnovel.com',
      'a.fqnovel.com.evil.test',
      'user@fqnovel.com',
      'fqnovel.com:443',
      'fqnovel.com/path',
    ]) {
      expect(
        () => AppSettings(apiHost: host).validate(),
        throwsFormatException,
      );
    }
    expect(
      () =>
          const AppSettings(videoUserAgent: 'ok\r\nInjected: value').validate(),
      throwsFormatException,
    );
    expect(
      () => const AppSettings(concurrentPreparations: 0).validate(),
      throwsFormatException,
    );
    expect(
      () => const AppSettings(maxCacheMb: 1).validate(),
      throwsFormatException,
    );
    expect(
      () => const SessionCredentials(ttToken: 'x\nInjected: y').validate(),
      throwsFormatException,
    );
  });
  test('background capabilities are opt-in and survive copy and restart', () {
    final old = AppSettings.fromJson({'themeMode': 'dark'});
    expect(old.backgroundPlayback, isFalse);
    expect(old.backgroundDownloads, isFalse);
    expect(old.floatingPlayback, isFalse);
    expect(old.backgroundWifiOnly, isTrue);
    final settings = old.copyWith(
      backgroundPlayback: true,
      backgroundDownloads: true,
      floatingPlayback: true,
      backgroundWifiOnly: false,
    );
    settings.validate();
    final restored = AppSettings.fromJson(settings.toJson())
        .copyWith(prefetchEpisodes: 5);
    expect(restored.backgroundPlayback, isTrue);
    expect(restored.backgroundDownloads, isTrue);
    expect(restored.floatingPlayback, isTrue);
    expect(restored.backgroundWifiOnly, isFalse);
    expect(restored.protocolJson(), old.protocolJson());
  });
}
