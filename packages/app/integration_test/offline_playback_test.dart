import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_api/hongguo_native_api.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/catalog/library_cache.dart';
import 'package:hongguo_app/features/local_cache_page.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_app/features/player_page.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_app/settings/settings_store_native.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:media_kit/media_kit.dart' hide VideoTrack;

class _Adapter implements HttpClientAdapter {
  final Uint8List bytes;
  int downloads = 0;
  _Adapter(this.bytes);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    downloads++;
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
    implements ConfigurableRuntime, LibraryCacheRuntime, LocalMediaRuntime {
  @override
  late final LibraryCache libraryCache;
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
  late final MediaCache cache;
  _Runtime(
    Uint8List bytes,
    this.directory, {
    this.settings = const AppSettings(),
    int episodes = 1,
  }) : catalog = _Catalog(episodes),
       dio = Dio()..httpClientAdapter = _Adapter(bytes) {
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
  PlaybackJob prepareLocal(String vid, {String quality = 'best'}) =>
      _Job(cache.prepareCached(vid, quality: quality), cache);
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  testWidgets(
    'catalog → episode → streamed CENC → Dart decrypt → native local playback and seek',
    (tester) async {
      final asset = await rootBundle.load('assets/verification.cenc.mp4');
      final runtime = _Runtime(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        Directory.systemTemp.createTempSync('hongguo-player-'),
      );
      final captureKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: ProviderScope(
            overrides: [runtimeProvider.overrideWith((ref) async => runtime)],
            child: const HongguoApp(),
          ),
        ),
      );
      Future<void> capture(String name) async {
        final boundary =
            captureKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          '${runtime.directory.parent.path}/hongguo-$name-ui.png',
        );
        file.writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
        print('UI_ARTIFACT=${file.path}');
      }

      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.pumpAndSettle();
      await capture('library-pc');
      await tester.tap(find.byKey(const ValueKey('sticky-genre')));
      await tester.pumpAndSettle();
      await capture('horizontal-filters-pc');
      await tester.tap(find.text('收起筛选'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '设置'),
      );
      await tester.pumpAndSettle();
      await capture('settings-pc');
      await tester.tap(find.widgetWithText(ListTile, '发现'));
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpAndSettle();
      await capture('library-mobile');
      await tester.tap(find.byKey(const ValueKey('sticky-genre')));
      await tester.pumpAndSettle();
      await capture('horizontal-filters-mobile');
      await tester.tap(find.text('收起筛选'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '设置'),
      );
      await tester.pumpAndSettle();
      await capture('settings-mobile');
      final currentTheme = runtime.settings.themeMode;
      await tester.ensureVisible(
        find.text(
          currentTheme == 'light'
              ? '浅色'
              : currentTheme == 'dark'
              ? '深色'
              : '跟随系统',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(
          currentTheme == 'light'
              ? '浅色'
              : currentTheme == 'dark'
              ? '深色'
              : '跟随系统',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('深色').last);
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(NavigationBar))).brightness,
        Brightness.dark,
      );
      print(
        'THEME_ACCEPTANCE=selection applied dark immediately without pressing save',
      );
      await capture('theme-dark-mobile');

      await tester.tap(find.text('发现'));
      await tester.pumpAndSettle();
      await capture('library');
      await tester.ensureVisible(find.text('离线播放验证').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('离线播放验证').last);
      await tester.pumpAndSettle();
      await capture('detail');
      await tester.tap(find.text('开始观看'));
      for (
        var i = 0;
        i < 30 && find.byType(PlayerPage).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(PlayerPage), findsOneWidget);
      final dynamic state = tester.state(find.byType(PlayerPage));
      final player = state.player as Player;
      await player.setVolume(0);
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (player.state.duration > Duration.zero &&
            player.state.width == 160) {
          break;
        }
      }
      expect(player.state.width, 160);
      expect(player.state.height, 288);
      expect(player.state.duration.inMilliseconds, greaterThan(1000));
      final source = player.state.playlist.medias.single.uri;
      final local = source.startsWith('file:')
          ? File.fromUri(Uri.parse(source))
          : File(source);
      expect(local.existsSync(), isTrue);
      expect(local.path, startsWith(runtime.directory.path));
      expect(await runtime.cacheBytes(), greaterThan(0));
      expect(
        player.state.tracks.audio.where((t) => !['auto', 'no'].contains(t.id)),
        isNotEmpty,
      );
      await player.pause();
      await player.seek(const Duration(milliseconds: 700));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (player.state.position.inMilliseconds >= 500) break;
      }
      expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(500));
      print('PLAYER_STATE_ERROR=${state.error}');
      print('AUDIO_OUTPUT_WARNING=${state.audioNotice}');
      expect(find.text('暂时无法播放'), findsNothing);
      final frame = await player.screenshot(format: 'image/png');
      expect(frame, isNotNull);
      expect(frame!.length, greaterThan(100));
      final frameFile = File(
        '${runtime.directory.parent.path}/hongguo-native-frame.png',
      )..writeAsBytesSync(frame);
      print('NATIVE_FRAME_ARTIFACT=${frameFile.path}');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '设置'),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('本地缓存剧集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地缓存剧集'));
      await tester.pumpAndSettle();
      expect(find.byType(LocalCachePage), findsOneWidget);
      expect(find.byKey(const ValueKey('local-drama-123')), findsOneWidget);
      await capture('local-cache-mobile');
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.pumpAndSettle();
      await capture('local-cache-pc');
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local-drama-123')));
      await tester.pumpAndSettle();
      expect(find.byType(LocalEpisodesPage), findsOneWidget);
      await capture('local-episodes-mobile');
      final downloadsBefore =
          (runtime.dio.httpClientAdapter as _Adapter).downloads;
      await tester.tap(find.byTooltip('播放本地剧集'));
      for (
        var i = 0;
        i < 30 && find.byType(PlayerPage).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final dynamic localState = tester.state(find.byType(PlayerPage));
      final localPlayer = localState.player as Player;
      await localPlayer.setVolume(0);
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (!localState.preparing && localPlayer.state.width != null) break;
      }
      expect(localState.error, isNull);
      expect(localState.preparing, isFalse);
      expect(localPlayer.state.width, 160);
      expect(
        (runtime.dio.httpClientAdapter as _Adapter).downloads,
        downloadsBefore,
      );
      expect(localState.prefetch.ready, 0);
      await capture('local-player-mobile');
      print(
        'LOCAL_CACHE_ACCEPTANCE=listed named episode; decoded local MP4 without another request; no prefetch',
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(null);
      await runtime.dispose();
    },
  );
  testWidgets(
    'five future files stay ready and next episode reuses cache across layouts',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final asset = await rootBundle.load('assets/verification.cenc.mp4');
      final runtime = _Runtime(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        Directory.systemTemp.createTempSync('hongguo-prefetch-'),
        episodes: 6,
        settings: const AppSettings(prefetchEpisodes: 5, autoNext: false),
      );
      final detail = await runtime.catalog.detail('123');
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(runtime: runtime, detail: detail),
        ),
      );
      await tester.pump();
      final dynamic state = tester.state(find.byType(PlayerPage));
      final player = state.player as Player;
      await player.setVolume(0);
      for (var i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (state.prefetch.ready == 5 && !state.preparing) break;
      }
      expect(state.prefetch.ready, 5);
      expect((runtime.dio.httpClientAdapter as _Adapter).downloads, 6);
      await tester.tap(find.widgetWithText(FilledButton, '下一集'));
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (state.position == 1 && !state.preparing) break;
      }
      expect(state.position, 1);
      expect(state.preparing, isFalse);
      expect(state.sourceVid, '124');
      expect((runtime.dio.httpClientAdapter as _Adapter).downloads, 6);
      final handle = await player.handle;
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('第 2 集 · 选集'), findsOneWidget);
      expect(await player.handle, handle);
      await tester.tap(find.text('第 2 集 · 选集'));
      await tester.pumpAndSettle();
      expect(find.text('已缓存'), findsWidgets);
      await tester.tapAt(const Offset(10, 70));
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(null);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await runtime.dispose();
      print(
        'PREFETCH_ACCEPTANCE=5 ready; switching reused file without another download; player survived compact layout',
      );
    },
  );
  testWidgets(
    'macOS system session vault round-trip uses only a disposable test record',
    (tester) async {
      if (!Platform.isMacOS) return;
      final vault = SystemSessionVault();
      final key = 'hongguo.verify.${DateTime.now().microsecondsSinceEpoch}';
      try {
        await vault
            .write(key, 'synthetic-test-only')
            .timeout(const Duration(seconds: 20));
        expect(await vault.read(key), 'synthetic-test-only');
      } finally {
        await vault.delete(key);
      }
      expect(await vault.read(key), isNull);
    },
  );
}
