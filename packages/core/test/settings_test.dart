import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

void main() {
  test('new profiles sign catalog requests while saved preferences remain explicit', () {
    expect(const AppSettings().signLists, isTrue);
    expect(AppSettings.fromJson({}).signLists, isTrue);
    expect(AppSettings.fromJson({'signLists': false}).signLists, isFalse);
  });
  test(
    'global catalog sort and TV page size migrate, persist and validate',
    () {
      final old = AppSettings.fromJson({});
      expect(old.catalogSort, 'hot_score');
      expect(old.tvPageSize, 30);
      final saved = old.copyWith(catalogSort: 'hot_collect', tvPageSize: 50);
      saved.validate();
      final restored = AppSettings.fromJson(saved.toJson());
      expect(restored.catalogSort, 'hot_collect');
      expect(restored.tvPageSize, 50);
      expect(saved.protocolJson(), old.protocolJson());
      expect(
        () => const AppSettings(catalogSort: 'unknown').validate(),
        throwsFormatException,
      );
      expect(
        () => const AppSettings(tvPageSize: 100).validate(),
        throwsFormatException,
      );
    },
  );
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
      () => const AppSettings(downloadConcurrent: 0).validate(),
      throwsFormatException,
    );
    expect(
      () => const AppSettings(downloadConcurrent: 6).validate(),
      throwsFormatException,
    );
    const clamped = AppSettings(downloadConcurrent: 5);
    expect(AppSettings.fromJson(clamped.toJson()).downloadConcurrent, 5);
    expect(clamped.protocolJson(), const AppSettings().protocolJson());
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
  test('old settings have no recommendation decisions; decisions persist outside protocol', () {
    final old = AppSettings.fromJson({});
    expect(old.backgroundPlaybackPrompted, isFalse);
    expect(old.floatingPlaybackPrompted, isFalse);
    expect(old.episodeSwipeHintShown, isFalse);
    final stored = old.copyWith(
      backgroundPlaybackPrompted: true,
      floatingPlaybackPrompted: true,
      episodeSwipeHintShown: true,
    );
    final reopened = AppSettings.fromJson(stored.toJson())
        .copyWith(themeMode: 'dark');
    expect(reopened.backgroundPlaybackPrompted, isTrue);
    expect(reopened.floatingPlaybackPrompted, isTrue);
    expect(reopened.episodeSwipeHintShown, isTrue);
    expect(reopened.protocolJson(), old.protocolJson());
  });
}
