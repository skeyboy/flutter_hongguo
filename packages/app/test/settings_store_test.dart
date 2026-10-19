import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/platform/runtime_native.dart';
import 'package:hongguo_app/settings/settings_store.dart';
import 'package:hongguo_app/settings/settings_store_native.dart';

class MemoryPreferences implements PreferencesBackend {
  Map<String, dynamic>? data;
  bool fail = false;
  @override
  Future<Map<String, dynamic>?> read() async => data;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    if (fail) throw StateError('disk');
    data = Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
  }
}

class MemoryVault implements SessionVault {
  final data = <String, String>{};
  bool failRead = false, failWrite = false;
  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('locked');
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('vault');
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

void main() {
  late MemoryPreferences prefs;
  late MemoryVault vault;
  late SettingsStore store;
  setUp(() {
    prefs = MemoryPreferences();
    vault = MemoryVault();
    store = SettingsStore(
      backend: prefs,
      vault: vault,
      deviceId: '1234567890123456',
    );
  });
  test(
    'settings persist across restart; secrets never enter preference JSON',
    () async {
      await store.load();
      await store.save(
        store.settings.copyWith(prefetchEpisodes: 5, themeMode: 'dark'),
        session: const SessionCredentials(
          cookie: 'cookie-for-test',
          ttToken: 'token-for-test',
        ),
      );
      expect(jsonEncode(prefs.data), isNot(contains('cookie-for-test')));
      expect(jsonEncode(prefs.data), isNot(contains('token-for-test')));
      final restart = SettingsStore(
        backend: prefs,
        vault: vault,
        deviceId: '9999999999999999',
      );
      await restart.load();
      expect(restart.settings.prefetchEpisodes, 5);
      expect(restart.settings.themeMode, 'dark');
      expect(restart.credentials.cookie, 'cookie-for-test');
      expect(restart.deviceId, '1234567890123456');
    },
  );
  test(
    'failed vault write does not change settings or existing session',
    () async {
      await store.save(
        store.settings,
        session: const SessionCredentials(ttToken: 'old'),
      );
      final before = jsonEncode(prefs.data);
      vault.failWrite = true;
      await expectLater(
        store.save(
          store.settings.copyWith(prefetchEpisodes: 5),
          session: const SessionCredentials(ttToken: 'new'),
        ),
        throwsStateError,
      );
      expect(jsonEncode(prefs.data), before);
      expect(store.settings.prefetchEpisodes, 3);
      expect(store.credentials.ttToken, 'old');
    },
  );
  test(
    'failed preferences commit rolls back the newly created secret record',
    () async {
      await store.save(
        store.settings,
        session: const SessionCredentials(ttToken: 'old'),
      );
      final oldKeys = vault.data.keys.toList();
      prefs.fail = true;
      await expectLater(
        store.save(
          store.settings,
          session: const SessionCredentials(ttToken: 'new'),
        ),
        throwsStateError,
      );
      expect(vault.data.keys, oldKeys);
      expect(store.credentials.ttToken, 'old');
    },
  );
  test('locked vault permits preferences update without deleting the saved session', () async {
    await store.save(
      store.settings,
      session: const SessionCredentials(ttToken: 'old'),
    );
    vault.failRead = true;
    final restart = SettingsStore(
      backend: prefs,
      vault: vault,
      deviceId: store.deviceId,
    );
    await restart.load();
    expect(restart.warning, isNotNull);
    final ref = prefs.data!['sessionRef'];
    await restart.save(restart.settings.copyWith(autoLoadMore: false));
    expect(prefs.data!['sessionRef'], ref);
    await restart.save(restart.settings, session: const SessionCredentials());
    expect(prefs.data!['sessionRef'], isNull);
    expect(vault.data, isEmpty);
  });
  test(
    'malformed configuration fails safely; invalid host and CRLF never commit',
    () async {
      prefs.data = {
        'preferences': {'prefetchEpisodes': 100},
      };
      await store.load();
      expect(store.settings.prefetchEpisodes, 3);
      expect(store.warning, isNotNull);
      expect(
        () => store.save(
          store.settings.copyWith(apiHost: 'fqnovel.com.attacker.test'),
        ),
        throwsFormatException,
      );
      expect(
        () => store.save(
          store.settings,
          session: const SessionCredentials(cookie: 'a\r\nInjected: x'),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'native preference writer atomically replaces an existing JSON file',
    () async {
      final temp = Directory.systemTemp.createTempSync('hongguo-settings-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final backend = FilePreferencesBackend(
        File('${temp.path}/settings.json'),
      );
      await backend.write({'n': 1});
      await backend.write({'n': 2});
      expect((await backend.read())!['n'], 2);
      expect(temp.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    },
  );
  test(
    'native settings rebuild protocol and survive a real file restart',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'hongguo-settings-runtime-',
      );
      final backend = FilePreferencesBackend(
        File('${root.path}/settings.json'),
      );
      final nativeStore = SettingsStore(
        backend: backend,
        vault: vault,
        deviceId: '1234567890123456',
      );
      await nativeStore.load();
      final runtime = NativeRuntime(root, nativeStore);
      final events = <AppSettings>[];
      final subscription = runtime.settingsChanges.listen(events.add);
      final next = runtime.settings.copyWith(
        themeMode: 'dark',
        prefetchEnabled: false,
        prefetchEpisodes: 5,
        concurrentPreparations: 1,
        maxCacheFiles: 20,
        maxCacheMb: 256,
        autoNext: false,
        autoLoadMore: false,
        defaultQuality: '720p',
        timeoutSeconds: 25,
        signLists: true,
        catalogVersion: '7.2.2.33',
        catalogVersionCode: '72233',
      );
      await runtime.saveSettings(next);
      expect(events.last.themeMode, 'dark');
      expect((runtime.catalog as CatalogClient).protocol.timeoutSeconds, 25);
      expect((runtime.catalog as CatalogClient).signLists, isTrue);
      expect(
        (runtime.catalog as CatalogClient).protocol.catalogVersion,
        '7.2.2.33',
      );
      await subscription.cancel();
      await runtime.dispose();
      final restarted = SettingsStore(
        backend: backend,
        vault: vault,
        deviceId: '9999999999999999',
      );
      await restarted.load();
      expect(restarted.settings.toJson(), next.toJson());
      expect(restarted.deviceId, '1234567890123456');
      await root.delete(recursive: true);
    },
  );
}
