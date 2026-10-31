import 'dart:async';

import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_app/platform/runtime.dart';

class FakeCatalog implements CatalogRepository {
  String? lastQuery, lastGenre, lastTheme, lastSort;
  int browseCalls = 0;
  bool fail = false;
  static const demo = Drama(
    id: '123',
    title: '山海之间',
    intro: '一段关于相遇的故事',
    episodeCount: 3,
  );
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) async {
    browseCalls++;
    lastGenre = genre;
    lastSort = sort;
    lastTheme = theme;
    if (fail) throw const CatalogError('上游暂时不可用');
    return cursor == null
        ? const CatalogPage([demo], nextCursor: '18')
        : const CatalogPage([
            Drama(id: '124', title: '第二个故事', episodeCount: 2),
          ]);
  }

  @override
  Future<CatalogPage> search(String query, {String? cursor}) async {
    lastQuery = query;
    return const CatalogPage([
      Drama(id: '125', title: '搜索命中', episodeCount: 2),
    ]);
  }

  @override
  Future<DramaDetail> detail(String id) async {
    if (detailFail) throw const CatalogError('上游暂时不可用');
    return DramaDetail(
      Drama(
        id: demo.id,
        title: demo.title,
        intro: demo.intro,
        episodeCount: episodes.length,
      ),
      episodes,
    );
  }

  /// Tests that ask 「what does this series have online now」 replace this list;
  /// the default is the three-episode demo shelf every other suite reads.
  List<Episode> episodes = const [
    Episode(vid: '11', index: 1),
    Episode(vid: '12', index: 2),
    Episode(vid: '13', index: 3),
  ];
  bool detailFail = false;
  @override
  Future<List<CatalogFilter>> themes(String genre) async => const [
    CatalogFilter('玄幻', 'cate_7'),
  ];
}

class FakeRuntime implements ConfigurableRuntime {
  @override
  AppSettings settings = const AppSettings(themeMode: 'light');
  @override
  SessionCredentials credentials = const SessionCredentials();
  @override
  String deviceId = '1234567890123456';
  @override
  String? settingsWarning;
  final changes = StreamController<AppSettings>.broadcast();
  int saves = 0, signRefreshes = 0, deviceRotations = 0, clears = 0;
  @override
  Stream<AppSettings> get settingsChanges => changes.stream;
  @override
  Future<void> saveSettings(
    AppSettings value, {
    SessionCredentials? credentials,
  }) async {
    value.validate();
    settings = value;
    if (credentials != null) this.credentials = credentials;
    saves++;
    changes.add(value);
  }

  @override
  Future<void> refreshSigning() async {
    signRefreshes++;
  }

  @override
  Future<void> rotateDeviceIdentity() async {
    deviceRotations++;
    deviceId = '2234567890123456';
  }

  @override
  /// Not `final`: a test can hand the runtime a new catalog object to stand in
  /// for the viewer pointing the app at a different upstream.
  FakeCatalog catalog;
  FakeRuntime([FakeCatalog? catalog]) : catalog = catalog ?? FakeCatalog();
  @override
  PlaybackJob prepare(
    String vid, {
    String quality = 'best',
    void Function(PreparationProgress)? onProgress,
    bool background = false,
  }) => throw UnimplementedError();
  @override
  Future<int> cacheBytes() async => 1024;
  @override
  Future<void> clearCache() async {
    clears++;
  }

  @override
  Future<void> evict(String vid, {String quality = 'best'}) async {}
  @override
  Future<void> dispose() async {
    if (!changes.isClosed) await changes.close();
  }
}
