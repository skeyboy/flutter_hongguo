import 'package:hongguo_app/personal/personal_library.dart';

import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_api/hongguo_native_api.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/catalog/library_cache.dart';
import 'package:hongguo_app/search/search_history.dart';
import 'package:flutter/gestures.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_app/features/player_page.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_app/settings/settings_store_native.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:media_kit/media_kit.dart' hide VideoTrack;

class _Adapter implements HttpClientAdapter {
  final Uint8List bytes;
  Completer<void>? gate;
  int downloads = 0;
  _Adapter(this.bytes);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    downloads++;
    await gate?.future;
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        Headers.contentLengthHeader: ['${bytes.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Catalog implements CatalogRepository, RankCatalogRepository {
  final int count;
  _Catalog([this.count = 1]);
  static const drama = Drama(id: '123', title: '离线播放验证', episodeCount: 1);
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) async => const CatalogPage([drama]);
  @override
  Future<CatalogPage> rank({
    String board = 'recommend',
    String? cursor,
  }) async => const CatalogPage([drama]);
  @override
  Future<CatalogPage> search(String query, {String? cursor}) async =>
      const CatalogPage([drama]);
  @override
  Future<DramaDetail> detail(String id) async => DramaDetail(
    drama,
    List.generate(count, (i) => Episode(vid: '${123 + i}', index: i + 1)),
  );
  @override
  Future<List<CatalogFilter>> themes(String genre) async => [];
}

class _Runtime
    implements
        ConfigurableRuntime,
        LibraryCacheRuntime,
        LocalMediaRuntime,
        PersonalLibraryRuntime {
  @override
  late final LibraryCache libraryCache;
  @override
  late final PersonalLibrary personalLibrary;
  @override
  AppSettings settings;
  @override
  final credentials = const SessionCredentials();
  @override
  String get deviceId => '1234567890123456';
  @override
  String? get settingsWarning => null;
  final events = StreamController<AppSettings>.broadcast();
  bool disposed = false;
  @override
  Stream<AppSettings> get settingsChanges => events.stream;
  @override
  Future<void> saveSettings(
    AppSettings value, {
    SessionCredentials? credentials,
  }) async {
    settings = value;
    events.add(value);
  }

  @override
  Future<void> refreshSigning() async {}
  @override
  Future<void> rotateDeviceIdentity() async {}

  @override
  final _Catalog catalog;
  final Dio dio;
  final Directory directory;
  late MediaCache cache;
  final localRequests = <String>[];
  _Runtime(
    Uint8List bytes,
    this.directory, {
    this.settings = const AppSettings(),
    int episodes = 1,
  }) : catalog = _Catalog(episodes),
       dio = Dio()..httpClientAdapter = _Adapter(bytes) {
    personalLibrary = PersonalLibrary(
      backend: FilePreferencesBackend(File('${directory.path}/personal.json')),
    );
    libraryCache = LibraryCache(
      backend: FilePreferencesBackend(File('${directory.path}/library.json')),
    );
    final spade = base64Encode(
      unhex(
        '93bc1df253ba1bf7618b19c448b806f64d810afc45b715fe5eb925f26cbf12f541ba098282',
      ),
    );
    cache = MediaCache(
      directory: directory,
      dio: dio,
      maxConcurrent: settings.concurrentPreparations,
      resolve: (_, _) async => VideoTrack(
        url: Uri.parse('https://a.qznovelvod.com/offline.mp4'),
        spadeA: spade,
        definition: 'test',
        size: bytes.length,
      ),
    );
  }
  @override
  PlaybackJob prepare(
    String vid, {
    String quality = 'best',
    void Function(PreparationProgress)? onProgress,
    bool background = false,
  }) => _Job(
    cache.prepare(
      vid,
      quality: quality,
      background: background,
      onProgress: (p) =>
          onProgress?.call(PreparationProgress(p.stage.name, p.fraction)),
    ),
    cache,
  );
  @override
  PlaybackJob prepareLocal(String vid, {String quality = 'best'}) {
    localRequests.add('$vid:$quality');
    return _Job(cache.prepareCached(vid, quality: quality), cache);
  }

  @override
  Future<List<LocalEpisode>> localEpisodes() async {
    return Future.wait(
      (await cache.entries()).map(
        (e) async => LocalEpisode(
          vid: e.vid,
          quality: e.quality,
          bytes: e.bytes,
          modified: e.modified,
          inUse: e.inUse,
          detail: await libraryCache.detailForVideo(e.vid),
        ),
      ),
    );
  }

  @override
  Future<int> cacheBytes() => cache.cacheBytes();
  @override
  Future<void> clearCache() => cache.clear();
  @override
  Future<void> evict(String vid, {String quality = 'best'}) =>
      cache.evict(vid, quality: quality);
  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await personalLibrary.flush();
    personalLibrary.dispose();
    cache.close();
    dio.close(force: true);
    await events.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

class _Job implements PlaybackJob {
  final MediaPreparation lease;
  final MediaCache cache;
  _Job(this.lease, this.cache);
  @override
  Future<String> get source => lease.result.then((p) => File(p).uri.toString());
  @override
  void cancel() => lease.cancel();
  @override
  void release() => cache.release(lease);
}

/// iOS 端 v0.3.1 竖滑切集功能验证夹具（需真机/模拟器与宿主机截图握手，不进 CI）。
///
/// 全部输入走应用内通道：`drag(kind: PointerDeviceKind.touch|mouse|trackpad)`、
/// `tap`。截图通过 gate 目录与宿主机上的 `xcrun simctl io ... screenshot` 握手。

const _mobileHint = '上滑下一集 · 下滑上一集';
const _desktopHintPrefix = 'Page Up';

Directory? _gateDir;

/// 同一容器可能留着上一轮的握手文件，必须清空，否则截图会串轮。
void _openGate() {
  final gate = Directory('${Directory.systemTemp.path}/iosgate')
    ..createSync(recursive: true);
  for (final entry in gate.listSync()) {
    entry.deleteSync(recursive: true);
  }
  _gateDir = gate;
  print('GATE_DIR=${gate.path}');
}

/// 宿主机轮询到 .ready 后写 .shot，测试再继续；截图失败绝不被断言掩盖。
Future<void> deviceShot(String name, {required WidgetTester tester}) async {
  final gate = _gateDir!;
  final ready = File('${gate.path}/$name.ready');
  final shot = File('${gate.path}/$name.png');
  final done = File('${gate.path}/$name.shot');
  ready.writeAsStringSync(DateTime.now().toIso8601String());
  print('SCREENSHOT_REQUEST=$name dir=${gate.path}');
  for (var i = 0; i < 120 && !done.existsSync(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (!done.existsSync()) {
    print('SCREENSHOT_TIMEOUT=$name');
    return;
  }
  print(
    'SCREENSHOT_TAKEN=$name host=${shot.existsSync() ? shot.path : 'MISSING'}',
  );
}

int _positionOf(WidgetTester tester) {
  final dynamic state = tester.state(find.byType(PlayerPage));
  return state.position as int;
}

bool _preparing(WidgetTester tester) {
  final dynamic state = tester.state(find.byType(PlayerPage));
  return state.preparing as bool;
}

Future<void> _waitPicture(WidgetTester tester) async {
  final dynamic state = tester.state(find.byType(PlayerPage));
  final player = state.player as Player;
  for (var i = 0; i < 300; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (!(_preparing(tester)) &&
        player.state.duration > Duration.zero &&
        player.state.width == 160) {
      return;
    }
  }
  fail('视频在 30s 内未就绪：state=${state.error} notice=${state.playbackNotice}');
}

Future<void> _wakeControls(WidgetTester tester) async {
  if (find.byKey(const ValueKey('player-exit')).evaluate().isEmpty) {
    final rect = tester.getRect(
      find.byKey(const ValueKey('compact-player-picture')),
    );
    await tester.tapAt(rect.center);
    await tester.pumpAndSettle();
  }
}

Finder _watchButton() => find.byWidgetPredicate(
  (widget) =>
      widget is Text && const ['开始观看', '继续观看', '重新观看'].contains(widget.data),
);

/// 从列表进详情再进播放页；已在详情页时直接按当前 CTA 文案进入。
Future<void> _openPlayer(WidgetTester tester) async {
  if (_watchButton().evaluate().isEmpty) {
    await tester.ensureVisible(find.text(_Catalog.drama.title).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(_Catalog.drama.title).last);
    await tester.pumpAndSettle();
  }
  expect(_watchButton(), findsWidgets, reason: '详情页应出现观看按钮');
  await tester.ensureVisible(_watchButton().first);
  await tester.pumpAndSettle();
  print('PLAYER_CTA=${_watchButton().evaluate().first.widget}');
  await tester.tap(_watchButton().first);
  for (var i = 0; i < 60 && find.byType(PlayerPage).evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(find.byType(PlayerPage), findsOneWidget);
  final dynamic state = tester.state(find.byType(PlayerPage));
  await (state.player as Player).setVolume(0);
  await _waitPicture(tester);
}

class _BoardsCatalog implements CatalogRepository, RankCatalogRepository {
  static const newest = [
    Drama(id: 'n1', title: '新剧一', episodeCount: 2),
    Drama(id: 'n2', title: '新剧二', episodeCount: 4),
  ];
  static const hot = [
    Drama(id: 'h1', title: '热门一', episodeCount: 9),
    Drama(id: 'n1', title: '新剧一', episodeCount: 2),
  ];
  static const feed = [
    Drama(id: 'f1', title: '信息流剧', episodeCount: 3),
    Drama(id: 'n1', title: '新剧一', episodeCount: 2),
    Drama(id: 'h1', title: '热门一', episodeCount: 9),
  ];
  String? lastQuery;
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) async => CatalogPage(switch (sort) {
    'online_time' => newest,
    'hot_score' => hot,
    _ => feed,
  });
  @override
  Future<CatalogPage> rank({
    String board = 'recommend',
    String? cursor,
  }) async => const CatalogPage(feed);
  @override
  Future<CatalogPage> search(String query, {String? cursor}) async {
    lastQuery = query;
    return const CatalogPage(feed);
  }

  @override
  Future<DramaDetail> detail(String id) async => DramaDetail(
    const Drama(id: 'n1', title: '新剧一', episodeCount: 2),
    const [Episode(vid: '901', index: 1), Episode(vid: '902', index: 2)],
  );
  @override
  Future<List<CatalogFilter>> themes(String genre) async => [];
}

class _SearchRuntime implements ConfigurableRuntime, SearchHistoryRuntime {
  _SearchRuntime(this.catalog, this.searchHistory);
  @override
  AppSettings settings = const AppSettings(themeMode: 'light');
  @override
  final SessionCredentials credentials = const SessionCredentials();
  @override
  String get deviceId => '1234567890123456';
  @override
  String? get settingsWarning => null;
  @override
  final _BoardsCatalog catalog;
  @override
  final SearchHistory searchHistory;
  final _changes = StreamController<AppSettings>.broadcast();
  @override
  Stream<AppSettings> get settingsChanges => _changes.stream;
  @override
  Future<void> saveSettings(
    AppSettings value, {
    SessionCredentials? credentials,
  }) async {
    settings = value;
    _changes.add(value);
  }

  @override
  Future<void> refreshSigning() async {}
  @override
  Future<void> rotateDeviceIdentity() async {}
  @override
  PlaybackJob prepare(
    String vid, {
    String quality = 'best',
    void Function(PreparationProgress)? onProgress,
    bool background = false,
  }) => throw UnimplementedError();
  @override
  Future<int> cacheBytes() async => 0;
  @override
  Future<void> clearCache() async {}
  @override
  Future<void> evict(String vid, {String quality = 'best'}) async {}
  @override
  Future<void> dispose() async {
    await searchHistory.flush();
    if (!_changes.isClosed) await _changes.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  testWidgets('iOS 播放页竖滑切集：触摸生效、鼠标不生效、一次性提示', (tester) async {
    final asset = await rootBundle.load('assets/verification.cenc.mp4');
    final directory = Directory.systemTemp.createTempSync('hongguo-ios-swipe-');
    _openGate();
    final runtime = _Runtime(
      asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
      directory,
      episodes: 4,
      settings: const AppSettings(
        autoNext: false,
        prefetchEnabled: false,
        backgroundPlayback: true,
        backgroundPlaybackPrompted: true,
        floatingPlaybackPrompted: true,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [runtimeProvider.overrideWith((ref) async => runtime)],
        child: const HongguoApp(),
      ),
    );
    await tester.pumpAndSettle();
    print(
      'IOS_VIEWPORT=platform=${Platform.operatingSystem} physical=${tester.view.physicalSize} dpr=${tester.view.devicePixelRatio}',
    );
    final view = tester.view;
    expect(
      view.physicalSize.width / view.devicePixelRatio,
      lessThan(720),
      reason: 'iPhone 应命中手机（compact）布局',
    );

    await _openPlayer(tester);

    // 1. 首次进入：手机文案出现，且绝不出现桌面 Page Up/Page Down 文案。
    expect(find.text(_mobileHint), findsOneWidget);
    expect(find.textContaining(_desktopHintPrefix), findsNothing);
    await deviceShot('01-hint-mobile', tester: tester);

    // 2. 约 3 秒淡出，并写入 episodeSwipeHintShown。
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.text(_mobileHint), findsOneWidget, reason: '3s 内提示仍在');
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(_mobileHint), findsNothing);
    expect(runtime.settings.episodeSwipeHintShown, isTrue);
    print(
      'HINT_CONSUMED=episodeSwipeHintShown=${runtime.settings.episodeSwipeHintShown}',
    );

    // 3. 鼠标 / 触控板拖拽不得切集。
    final picture = find.byKey(const ValueKey('compact-player-picture'));
    await tester.drag(
      picture,
      const Offset(0, -240),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(_positionOf(tester), 0, reason: '鼠标拖拽不应切集');
    await tester.drag(
      picture,
      const Offset(0, -240),
      kind: PointerDeviceKind.trackpad,
    );
    await tester.pumpAndSettle();
    expect(_positionOf(tester), 0, reason: '触控板拖拽不应切集');

    // 4. 触摸上滑 = 下一集。
    await tester.drag(
      picture,
      const Offset(0, -240),
      kind: PointerDeviceKind.touch,
    );
    await _waitPicture(tester);
    expect(_positionOf(tester), 1);
    await _wakeControls(tester);
    expect(find.text('第 2 集 · 选集'), findsWidgets);
    await deviceShot('02-after-swipe-up', tester: tester);

    // 5. 触摸下滑 = 上一集。
    await tester.drag(
      picture,
      const Offset(0, 240),
      kind: PointerDeviceKind.touch,
    );
    await _waitPicture(tester);
    expect(_positionOf(tester), 0);
    await _wakeControls(tester);
    expect(find.text('第 1 集 · 选集'), findsWidgets);

    // 6. 越界：最后一集继续上滑。
    for (var i = 0; i < 3; i++) {
      await tester.drag(
        picture,
        const Offset(0, -240),
        kind: PointerDeviceKind.touch,
      );
      await _waitPicture(tester);
    }
    expect(_positionOf(tester), 3);
    await tester.drag(
      picture,
      const Offset(0, -240),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已经是最后一集'), findsOneWidget);
    expect(_positionOf(tester), 3);
    expect(
      find.byKey(const ValueKey('player-exit')),
      findsWidgets,
      reason: '越界提示应唤出控制条',
    );
    await deviceShot('03-last-episode-notice', tester: tester);

    // 7. 越界：第一集继续下滑。
    for (var i = 0; i < 3; i++) {
      await tester.drag(
        picture,
        const Offset(0, 240),
        kind: PointerDeviceKind.touch,
      );
      await _waitPicture(tester);
    }
    expect(_positionOf(tester), 0);
    await tester.drag(
      picture,
      const Offset(0, 240),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已经是第一集'), findsOneWidget);
    await deviceShot('04-first-episode-notice', tester: tester);

    // 8. 退出后重进：提示不再出现。
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    if (find.byType(PlayerPage).evaluate().isNotEmpty) {
      await tester.tap(find.byType(BackButton).last);
      await tester.pumpAndSettle();
    }
    await _openPlayer(tester);
    expect(find.text(_mobileHint), findsNothing);
    expect(find.textContaining(_desktopHintPrefix), findsNothing);
    await deviceShot('05-reenter-no-hint', tester: tester);
    print('IOS_SWIPE_ACCEPTANCE=all eight checkpoints passed');

    await runtime.dispose();
  });

  testWidgets('iOS 搜索框聚焦：最近三条历史 + 榜单推荐位', (tester) async {
    final directory = Directory.systemTemp.createTempSync(
      'hongguo-ios-search-',
    );
    _openGate();
    final historyFile = File('${directory.path}/search-history.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'version': 1,
          'queries': ['甲剧', '乙剧', '丙剧', '丁剧', '戊剧'],
        }),
      );
    final runtime = _SearchRuntime(
      _BoardsCatalog(),
      SearchHistory(backend: FilePreferencesBackend(historyFile)),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [runtimeProvider.overrideWith((ref) async => runtime)],
        child: const HongguoApp(),
      ),
    );
    await tester.pumpAndSettle();

    final field = find.byType(TextField).first;
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.tap(field);
    await tester.pumpAndSettle();

    // 面板出现，历史只给最近 3 条。
    expect(find.byKey(const ValueKey('search-suggestions')), findsOneWidget);
    expect(find.text('最近搜索'), findsOneWidget);
    expect(find.byKey(const ValueKey('search-history-甲剧')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-history-乙剧')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-history-丙剧')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-history-丁剧')), findsNothing);
    expect(find.byKey(const ValueKey('search-history-戊剧')), findsNothing);
    // 榜单推荐位：标题 + 最新/热度图标。
    expect(find.text('最新与热门'), findsOneWidget);
    expect(find.byKey(const ValueKey('search-suggest-n1')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-suggest-h1')), findsOneWidget);
    expect(find.byIcon(Icons.fiber_new_rounded), findsWidgets);
    expect(find.byIcon(Icons.local_fire_department_rounded), findsWidgets);
    await deviceShot('10-search-panel', tester: tester);

    // 逐条删除生效。
    await tester.tap(find.byKey(const ValueKey('search-history-remove-丙剧')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-history-丙剧')), findsNothing);
    expect(find.byKey(const ValueKey('search-history-甲剧')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-suggestions')), findsOneWidget);
    await deviceShot('11-search-history-removed', tester: tester);

    // 点历史 = 执行搜索。
    final before = runtime.catalog.lastQuery;
    await tester.tap(find.byKey(const ValueKey('search-history-乙剧')));
    await tester.pumpAndSettle();
    expect(runtime.catalog.lastQuery, '乙剧');
    expect(runtime.catalog.lastQuery, isNot(before));
    expect(find.byKey(const ValueKey('search-suggestions')), findsNothing);
    expect(find.text('“乙剧”'), findsWidgets);
    await deviceShot('12-search-from-history', tester: tester);

    // 点推荐行 = 直接进详情页（不搜索）。
    await tester.ensureVisible(find.byType(TextField).first);
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-suggestions')), findsOneWidget);
    final queryBefore = runtime.catalog.lastQuery;
    await tester.tap(find.byKey(const ValueKey('search-suggest-h1')));
    await tester.pumpAndSettle();
    expect(runtime.catalog.lastQuery, queryBefore, reason: '推荐行不应触发搜索');
    expect(find.text('选择剧集'), findsOneWidget);
    await deviceShot('13-detail-from-suggestion', tester: tester);
    print(
      'IOS_SEARCH_ACCEPTANCE=panel + 3-row cap + delete + history search + detail',
    );

    await runtime.dispose();
  });
}
