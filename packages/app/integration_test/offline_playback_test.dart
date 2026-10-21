import 'package:hongguo_app/downloads/download_manager.dart';
import 'package:hongguo_app/platform/macos_window.dart';
import 'package:hongguo_app/features/downloads_page.dart';
import 'package:hongguo_app/navigation/app_navigation.dart';
import 'package:hongguo_app/features/library_page.dart';
import 'package:hongguo_app/features/detail_page.dart';
import 'package:hongguo_app/personal/personal_library.dart';

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
import 'package:hongguo_app/catalog/local_library.dart';
import 'package:hongguo_app/playback/local_playlist.dart';
import 'package:hongguo_app/playback/capability_preferences.dart';
import 'package:flutter/gestures.dart';
import 'package:hongguo_app/features/local_cache_page.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_app/features/player_page.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_app/platform/background/native_downloads.dart';
import 'package:hongguo_app/settings/settings_store.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:hongguo_app/settings/settings_store_native.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:media_kit/media_kit.dart' hide VideoTrack;

bool get _mobileDevice => Platform.isAndroid || Platform.isIOS;

Future<void> _resizeDesktop(WidgetTester tester, Size? size) async {
  if (_mobileDevice) {
    return;
  }
  await tester.binding.setSurfaceSize(size);
}

Future<void> _wakePlayerControls(WidgetTester tester) async {
  if (find.byKey(const ValueKey('player-exit')).evaluate().isEmpty) {
    final rect = tester.getRect(
      find.byKey(const ValueKey('compact-player-picture')),
    );
    await tester.tapAt(rect.center);
    await tester.pumpAndSettle();
  }
}

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

class _ManualRuntime extends _Runtime implements DownloadRuntime {
  @override
  late final DownloadManager downloads;
  _ManualRuntime(Uint8List bytes, Directory directory)
    : super(
        bytes,
        directory,
        episodes: 3,
        settings: const AppSettings(
          autoNext: false,
          prefetchEnabled: false,
          backgroundPlayback: true,
          backgroundPlaybackPrompted: true,
          floatingPlaybackPrompted: true,
        ),
      ) {
    final resolver = cache.resolve;
    cache.close();
    downloads = DownloadManager(
      backend: FilePreferencesBackend(File('${directory.path}/downloads.json')),
      settings: () => settings,
      files: localEpisodes,
      remember: libraryCache.rememberDetail,
      deleteFile: (vid, quality) => cache.evict(vid, quality: quality),
      prepare: (task, progress) => _Job(
        cache.prepare(
          task.episode.vid,
          quality: task.quality,
          background: true,
          onProgress: (p) => progress(
            PreparationProgress.bytes(
              p.stage.name,
              p.fraction,
              received: p.received,
              total: p.total,
            ),
          ),
        ),
        cache,
      ),
    );
    cache = MediaCache(
      directory: directory,
      dio: dio,
      resolve: resolver,
      retainFile: downloads.retains,
    );
  }
  @override
  Future<void> dispose() async {
    if (disposed) return;
    await downloads.shutdown();
    downloads.dispose();
    await super.dispose();
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

class _DownloadVault implements SessionVault {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
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
        if (_mobileDevice) {
          expect(
            boundary.size,
            tester.view.physicalSize / tester.view.devicePixelRatio,
            reason: 'Mobile UI must use actual device window dimensions',
          );
        }
        if (Platform.isAndroid) {
          // Capture native textures through the device compositor, not GPU readback.
          print('DEVICE_SCREENSHOT=$name');
          await Future<void>.delayed(const Duration(seconds: 1));
          return;
        }
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
      if (!_mobileDevice) {
        await _resizeDesktop(tester, const Size(1280, 900));
        await tester.pumpAndSettle();
        await capture('library-pc');
        await tester.tap(find.byKey(const ValueKey('sticky-genre')));
        await tester.pumpAndSettle();
        await capture('horizontal-filters-pc');
        await tester.tap(find.text('收起筛选'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '我的'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('my-settings')));
        await tester.pumpAndSettle();
        await capture('settings-pc');
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, '发现'));
        await tester.pumpAndSettle();
      } else {
        final view = tester.view;
        print(
          'REAL_MOBILE_VIEWPORT=platform=${Platform.operatingSystem}; physical=${view.physicalSize}; dpr=${view.devicePixelRatio}; surfaceOverride=none',
        );
      }
      await _resizeDesktop(tester, const Size(390, 844));
      await tester.pumpAndSettle();
      await capture('library-mobile');
      await tester.tap(find.byKey(const ValueKey('sticky-genre')));
      await tester.pumpAndSettle();
      await capture('horizontal-filters-mobile');
      await tester.tap(find.text('收起筛选'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '我的'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('my-settings')));
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
        Theme.of(tester.element(find.text('后台播放'))).brightness,
        Brightness.dark,
      );
      print(
        'THEME_ACCEPTANCE=selection applied dark immediately without pressing save',
      );
      await capture('theme-dark-mobile');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
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
      final pictureHandle = await player.handle;
      if (!_mobileDevice) {
        await _resizeDesktop(tester, const Size(1280, 900));
        await tester.pumpAndSettle();
        final pictureRect = tester.getRect(
          find.byKey(const ValueKey('player-picture')),
        );
        await capture('player-pc-picture');
        await _wakePlayerControls(tester);
        await tester.tap(find.byKey(const ValueKey('toggle-episodes')));
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byKey(const ValueKey('player-picture'))),
          pictureRect,
        );
        await capture('player-pc-overlay');
        await tester.tap(find.byTooltip('隐藏选集'));
        await tester.pumpAndSettle();
        await _resizeDesktop(tester, const Size(800, 600));
        await tester.pumpAndSettle();
        await _wakePlayerControls(tester);
        await tester.tap(find.byKey(const ValueKey('toggle-episodes')));
        await tester.pumpAndSettle();
        await capture('player-medium-overlay');
        await tester.tap(find.byTooltip('隐藏选集'));
        await tester.pumpAndSettle();
      }
      await _resizeDesktop(tester, const Size(390, 844));
      await tester.pumpAndSettle();
      if (find.byKey(const ValueKey('player-picture')).evaluate().isEmpty) {
        final compactPicture = tester.getRect(
          find.byKey(const ValueKey('compact-player-picture')),
        );
        await capture('player-mobile-controls');
        // Paused controls intentionally stay visible; exercise manual hide while playing.
        await player.setPlaylistMode(PlaylistMode.loop);
        await player.setRate(.25);
        await player.play();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(find.byTooltip('隐藏播放操作'));
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byKey(const ValueKey('compact-player-picture'))),
          compactPicture,
        );
        expect(
          find.byKey(const ValueKey('compact-playback-controls')),
          findsNothing,
        );
        await capture('player-mobile-picture');
        await _wakePlayerControls(tester);
        await tester.tap(find.byKey(const ValueKey('toggle-episodes')));
        await tester.pumpAndSettle();
        expect(find.text('选集'), findsOneWidget);
        await capture('player-mobile-episodes');
        if (Platform.isAndroid &&
            const bool.fromEnvironment('HONGGUO_DEVICE_GESTURES')) {
          print('MOBILE_BACK_WINDOW=bottom episode sheet open');
          await Future<void>.delayed(const Duration(seconds: 4));
          await tester.pumpAndSettle();
          expect(
            find.text('选集'),
            findsNothing,
            reason: 'Actual Android Back must dismiss the sheet',
          );
          print('MOBILE_BACK_ACCEPTANCE=system Back dismissed episode sheet');
        } else {
          await tester.tap(find.byTooltip('关闭选集'));
          await tester.pumpAndSettle();
        }
      } else {
        // A real tablet uses the wide overlay, without pretending to be a phone.
        final rect = tester.getRect(
          find.byKey(const ValueKey('player-picture')),
        );
        await _wakePlayerControls(tester);
        await tester.tap(find.byKey(const ValueKey('toggle-episodes')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('episode-panel')), findsOneWidget);
        expect(
          tester.getRect(find.byKey(const ValueKey('player-picture'))),
          rect,
        );
        await capture('player-tablet-overlay');
        await tester.tap(find.byTooltip('隐藏选集'));
        await tester.pumpAndSettle();
      }
      expect(await player.handle, pictureHandle);
      print(
        'OVERLAY_ACCEPTANCE=video rectangle stable; device-appropriate selector; player preserved; desktopResize=${!_mobileDevice}',
      );

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '我的'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('my-settings')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('本地缓存剧集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地缓存剧集'));
      await tester.pumpAndSettle();
      expect(find.byType(LocalCachePage), findsOneWidget);
      expect(find.byKey(const ValueKey('local-drama-123')), findsOneWidget);
      await capture('local-cache-mobile');
      if (!_mobileDevice) {
        await _resizeDesktop(tester, const Size(1280, 900));
        await tester.pumpAndSettle();
        await capture('local-cache-pc');
        await _resizeDesktop(tester, const Size(390, 844));
        await tester.pumpAndSettle();
      }
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
      await _resizeDesktop(tester, null);
      await runtime.dispose();
    },
  );
  testWidgets(
    'five future files stay ready and next episode reuses cache across layouts',
    (tester) async {
      await _resizeDesktop(tester, const Size(1280, 900));
      addTearDown(() => _resizeDesktop(tester, null));
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
      final originalHandle = await player.handle;
      if (_mobileDevice) {
        final compact = find
            .byKey(const ValueKey('player-picture'))
            .evaluate()
            .isEmpty;
        final picture = find.byKey(
          ValueKey(compact ? 'compact-player-picture' : 'player-picture'),
        );
        final rect = tester.getRect(picture);
        await _wakePlayerControls(tester);
        await tester.tap(find.byKey(const ValueKey('toggle-episodes')));
        await tester.pumpAndSettle();
        if (compact) {
          expect(find.text('选集'), findsOneWidget);
        } else {
          expect(find.byKey(const ValueKey('episode-panel')), findsOneWidget);
        }
        await tester.tap(find.widgetWithText(FilledButton, '下一集'));
        for (var i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (state.position == 1 && !state.preparing) break;
        }
        expect(state.position, 1);
        expect(state.sourceVid, '124');
        expect((runtime.dio.httpClientAdapter as _Adapter).downloads, 6);
        await tester.tap(find.byTooltip(compact ? '关闭选集' : '隐藏选集'));
        await tester.pumpAndSettle();
        expect(tester.getRect(picture), rect);
        expect(await player.handle, originalHandle);
      } else {
        final picture = find.byKey(const ValueKey('player-picture'));
        final pictureWidth = tester.getSize(picture).width;
        expect(find.byKey(const ValueKey('episode-panel')), findsNothing);
        await _wakePlayerControls(tester);
        await tester.tap(find.byKey(const ValueKey('toggle-episodes')));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('隐藏选集'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('episode-panel')), findsNothing);
        expect(tester.getSize(picture).width, pictureWidth);
        expect(await player.handle, originalHandle);
        await _wakePlayerControls(tester);
        await tester.tap(find.byKey(const ValueKey('toggle-episodes')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('episode-panel')), findsOneWidget);
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
        await _resizeDesktop(tester, const Size(800, 600));
        await tester.pumpAndSettle();
        final overlayPicture = tester.getRect(picture);
        await tester.tap(find.byTooltip('隐藏选集'));
        await tester.pumpAndSettle();
        expect(tester.getRect(picture), overlayPicture);
        expect(await player.handle, handle);
        expect((runtime.dio.httpClientAdapter as _Adapter).downloads, 6);
        await _resizeDesktop(tester, const Size(390, 844));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('第 2 集 · 选集'), findsOneWidget);
        expect(await player.handle, handle);
        await tester.tap(find.text('第 2 集 · 选集'));
        await tester.pumpAndSettle();
        expect(find.text('已缓存'), findsWidgets);
        await tester.tapAt(const Offset(10, 70));
        await tester.pumpAndSettle();
      }
      await _resizeDesktop(tester, null);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await runtime.dispose();
      print(
        'PREFETCH_ACCEPTANCE=5 ready; switching reused file without another download; player survived compact layout',
      );
    },
  );

  testWidgets(
    'cached episodes auto-next across local qualities; switch and final episode stop correctly',
    (tester) async {
      await _resizeDesktop(tester, const Size(1280, 900));
      addTearDown(() => _resizeDesktop(tester, null));
      final asset = await rootBundle.load('assets/verification.cenc.mp4');
      final runtime = _Runtime(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        Directory.systemTemp.createTempSync('hongguo-local-auto-'),
        episodes: 3,
        settings: const AppSettings(prefetchEnabled: false, autoNext: true),
      );
      final detail = await runtime.catalog.detail('123');
      await runtime.libraryCache.rememberDetail(detail);
      for (final pair in [('123', '720p'), ('124', 'best'), ('125', '720p')]) {
        final job = runtime.prepare(pair.$1, quality: pair.$2);
        await job.source;
        job.release();
      }
      final files = await runtime.localEpisodes();
      final queue = localPlaybackQueue(
        groupLocalEpisodes(files).single,
        files.firstWhere((e) => e.vid == '123'),
      );
      final downloads = (runtime.dio.httpClientAdapter as _Adapter).downloads;
      runtime.dio.close(
        force: true,
      ); // Every subsequent playback operation must remain offline.
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            runtime: runtime,
            detail: queue.detail,
            initialPosition: queue.initialPosition,
            cachedOnly: true,
            cachedQuality: '720p',
          ),
        ),
      );
      await tester.pump();
      final dynamic state = tester.state(find.byType(PlayerPage));
      final player = state.player as Player;
      await player.setVolume(0);
      Future<void> waitReady(int position) async {
        for (var i = 0; i < 150; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (state.position == position &&
              !state.preparing &&
              state.error == null &&
              player.state.duration > Duration.zero) {
            return;
          }
        }
        fail('Local episode $position did not become ready: ${state.error}');
      }

      await waitReady(0);
      await waitReady(1);
      print('LOCAL_AUTO_STAGE=second-ready');
      await player.pause().timeout(const Duration(seconds: 5));
      print('LOCAL_AUTO_STAGE=paused');
      await _wakePlayerControls(tester);
      await tester.tap(find.byKey(const ValueKey('toggle-episodes')));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      expect(state.quality, 'best');
      expect(state.prefetch.total, 0);
      print('LOCAL_AUTO_STAGE=panel-open');
      await tester.tap(find.byKey(const ValueKey('episode-auto-next')));
      await tester.pump();
      print('LOCAL_AUTO_STAGE=disabled');
      expect(runtime.settings.autoNext, isFalse);
      await player.seek(Duration.zero).timeout(const Duration(seconds: 5));
      print('LOCAL_AUTO_STAGE=seeked');
      await player.play().timeout(const Duration(seconds: 5));
      print('LOCAL_AUTO_STAGE=playing');
      for (var i = 0; i < 100 && !player.state.completed; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(player.state.completed, isTrue);
      expect(state.position, 1);
      expect(runtime.localRequests.length, 2);
      await tester.tap(find.byKey(const ValueKey('episode-auto-next')));
      await tester.pump();
      await waitReady(2);
      expect(runtime.settings.autoNext, isTrue);
      expect(state.quality, '720p');
      for (var i = 0; i < 100 && !player.state.completed; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(player.state.completed, isTrue);
      expect(state.position, 2);
      expect(runtime.localRequests, ['123:720p', '124:best', '125:720p']);
      expect((runtime.dio.httpClientAdapter as _Adapter).downloads, downloads);
      await _resizeDesktop(tester, const Size(390, 844));
      await tester.pump(const Duration(milliseconds: 300));
      if (find.byKey(const ValueKey('episode-auto-next')).evaluate().isEmpty) {
        await _wakePlayerControls(tester);
        await tester.tap(find.byKey(const ValueKey('toggle-episodes')));
        await tester.pumpAndSettle();
      }
      expect(find.text('连播'), findsOneWidget);
      final episodeSwitch = find.byKey(const ValueKey('episode-auto-next'));
      expect(
        tester
            .widget<Switch>(
              episodeSwitch.evaluate().isEmpty
                  ? find.byType(Switch)
                  : episodeSwitch,
            )
            .onChanged,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      await runtime.dispose();
      print(
        'LOCAL_AUTOPLAY=3 local episodes; 720p→best→720p; switch persisted; final episode stopped; no network',
      );
    },
  );

  testWidgets(
    'missing cached episode index stops autoplay; removed file never downloads',
    (tester) async {
      await _resizeDesktop(tester, const Size(1280, 900));
      addTearDown(() => _resizeDesktop(tester, null));
      final asset = await rootBundle.load('assets/verification.cenc.mp4');
      final runtime = _Runtime(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        Directory.systemTemp.createTempSync('hongguo-local-gap-'),
        episodes: 3,
        settings: const AppSettings(prefetchEnabled: false, autoNext: true),
      );
      await runtime.libraryCache.rememberDetail(
        await runtime.catalog.detail('123'),
      );
      for (final vid in ['123', '125']) {
        final job = runtime.prepare(vid);
        await job.source;
        job.release();
      }
      final files = await runtime.localEpisodes();
      final queue = localPlaybackQueue(
        groupLocalEpisodes(files).single,
        files.firstWhere((e) => e.vid == '123'),
      );
      final downloads = (runtime.dio.httpClientAdapter as _Adapter).downloads;
      runtime.dio.close(force: true);
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            runtime: runtime,
            detail: queue.detail,
            cachedOnly: true,
          ),
        ),
      );
      await tester.pump();
      final dynamic state = tester.state(find.byType(PlayerPage));
      final player = state.player as Player;
      await player.setVolume(0);
      for (var i = 0; i < 150 && state.playbackNotice == null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(state.position, 0);
      expect(state.playbackNotice, contains('第 2 集尚未缓存'));
      expect(runtime.localRequests, ['123:best']);
      await runtime.evict('125');
      await _wakePlayerControls(tester);
      await tester.tap(find.byKey(const ValueKey('toggle-episodes')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '下一集'));
      for (var i = 0; i < 100 && state.error == null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(state.error, isNotNull);
      expect((runtime.dio.httpClientAdapter as _Adapter).downloads, downloads);
      expect(runtime.localRequests, ['123:best']);
      expect((await runtime.cache.entries()).every((e) => !e.inUse), isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await runtime.dispose();
      print(
        'LOCAL_AUTOPLAY_GAP=stopped at missing index; removed file failed offline without download; pins released',
      );
    },
  );

  testWidgets(
    'mac picture in picture continues episodes without closing the small window',
    (tester) async {
      if (!Platform.isMacOS) return;
      await windowManager.ensureInitialized();
      await windowManager.setSize(const Size(1100, 760));
      await windowManager.show();
      await windowManager.focus();
      final asset = await rootBundle.load('assets/verification.cenc.mp4');
      final runtime = _Runtime(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        Directory.systemTemp.createTempSync('hongguo-pip-next-'),
        episodes: 3,
        settings: const AppSettings(
          autoNext: true,
          floatingPlayback: true,
          prefetchEnabled: false,
        ),
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
      var completedEpisodes = 0;
      final completed =
          state.platformPlayback.onExternalCompleted as VoidCallback?;
      state.platformPlayback.onExternalCompleted = () {
        completedEpisodes++;
        completed?.call();
      };
      try {
        for (var i = 0; i < 150 && state.preparing; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(state.error, isNull);
        await player.setVolume(0);
        await player.setRate(.5);
        await player.seek(Duration.zero);
        await player.play();
        for (var i = 0; i < 30 && !player.state.playing; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        Object? failure;
        final entering = state.platformPlayback
            .enter(player, player.state.playlist.medias.single.uri)
            .catchError((Object e) {
              failure = e;
            });
        for (
          var i = 0;
          i < 100 && !state.platformPlayback.floating.value && failure == null;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await entering;
        expect(failure, isNull);
        expect(state.platformPlayback.platformPip.value, isTrue);
        print('MAC_PIP_STAGE=entered');
        await MacWindow.invoke('hide');
        for (
          var i = 0;
          i < 150 && (state.position < 1 || state.preparing);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(state.error, isNull);
        expect(state.position, 1);
        expect(state.platformPlayback.platformPip.value, isTrue);
        expect(player.state.playing, isFalse);
        for (
          var i = 0;
          i < 150 && (state.position < 2 || state.preparing);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(state.error, isNull);
        expect(state.position, 2);
        expect(state.platformPlayback.platformPip.value, isTrue);
        expect(player.state.playing, isFalse);
        for (
          var i = 0;
          i < 40 &&
              ((state.platformPlayback.externalPosition?.inMilliseconds ?? 0) ==
                      0 ||
                  state.platformPlayback.externalPlaying != true);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(state.platformPlayback.externalPlaying, isTrue);
        for (var i = 0; i < 70 && completedEpisodes < 3; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(completedEpisodes, 3);
        expect(state.platformPlayback.externalPlaying, isFalse);
        expect(
          state.platformPlayback.externalPosition.inMilliseconds,
          greaterThan(0),
        );
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(state.position, 2);
        expect(state.platformPlayback.floating.value, isTrue);
        await MacWindow.invoke('show');
        final exit = state.platformPlayback.exit(player);
        for (var i = 0; i < 60 && state.platformPlayback.floating.value; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await exit;
        expect(state.position, 2);
        print(
          'MAC_PIP_AUTONEXT=three local files played in one native PiP session while main window hidden; last episode stopped; main player stayed paused',
        );
      } finally {
        await MacWindow.invoke('show');
        await tester.pumpWidget(const SizedBox());
        await state.platformUpdates;
        await tester.pumpAndSettle();
        await runtime.dispose();
      }
    },
  );

  testWidgets(
    'desktop picture in picture restores playback and occlusion does not pause',
    (tester) async {
      if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) return;
      await _resizeDesktop(tester, const Size(1280, 900));
      addTearDown(() => _resizeDesktop(tester, null));
      final asset = await rootBundle.load('assets/verification.cenc.mp4');
      final runtime = _Runtime(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        Directory.systemTemp.createTempSync('hongguo-platform-'),
        settings: AppSettings(
          prefetchEnabled: false,
          autoNext: false,
          floatingPlayback: !Platform.isMacOS,
          backgroundPlayback: false,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            runtime: runtime,
            detail: await runtime.catalog.detail('123'),
          ),
        ),
      );
      await tester.pump();
      final dynamic state = tester.state(find.byType(PlayerPage));
      final player = state.player as Player;
      await player.setVolume(0);
      for (var i = 0; i < 150 && state.preparing; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await state.platformUpdates;
      await windowManager.ensureInitialized();
      if (Platform.isMacOS) await windowManager.setSize(const Size(1100, 760));
      await windowManager.show();
      await windowManager.focus();
      final original = await windowManager.getBounds();
      final originalTop = await windowManager.isAlwaysOnTop();
      final handle = await player.handle;
      try {
        await _wakePlayerControls(tester);
        await player.setRate(.25);
        await player.setPlaylistMode(PlaylistMode.loop);
        await player.seek(Duration.zero);
        await player.play();
        for (var i = 0; i < 30 && !player.state.playing; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(player.state.playing, isTrue);
        expect(find.byKey(const ValueKey('enter-pip')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('enter-pip')));
        for (
          var i = 0;
          i < 100 && !state.platformPlayback.floating.value;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await windowManager.show();
        await windowManager.focus();
        await tester.pump();
        expect(runtime.settings.floatingPlayback, isTrue);
        expect(state.platformPlayback.floating.value, isTrue);
        if (Platform.isMacOS) {
          expect(state.platformPlayback.platformPip.value, isTrue);
          expect(player.state.playing, isFalse);
          expect(find.byKey(const ValueKey('restore-pip')), findsOneWidget);
          final unchanged = await windowManager.getBounds();
          expect(unchanged.width, closeTo(original.width, 3));
          for (
            var i = 0;
            i < 40 &&
                (state.platformPlayback.externalPosition?.inMilliseconds ??
                        0) ==
                    0;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(state.platformPlayback.externalPlaying, isTrue);
          expect(state.platformPlayback.externalPosition, isNotNull);
          expect(
            state.platformPlayback.externalPosition.inMilliseconds,
            greaterThan(0),
          );
          await tester.tap(find.byKey(const ValueKey('restore-pip')));
        } else {
          expect(await windowManager.isAlwaysOnTop(), isTrue);
          final mini = await windowManager.getBounds();
          expect(mini.width, lessThanOrEqualTo(525));
          await tester.tap(find.byTooltip('退出悬浮播放'));
        }
        for (var i = 0; i < 100 && state.platformPlayback.floating.value; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(state.platformPlayback.floating.value, isFalse);
        for (var i = 0; i < 30 && !player.state.playing; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(player.state.playing, isTrue);
        expect(player.state.rate, .25);
        final restored = await windowManager.getBounds();
        expect(restored.width, closeTo(original.width, 3));
        expect(restored.height, closeTo(original.height, 3));
        expect(await windowManager.isAlwaysOnTop(), originalTop);
        expect(await player.handle, handle);
        await player.seek(Duration.zero);
        await player.play();
        state.didChangeAppLifecycleState(AppLifecycleState.paused);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(player.state.playing, isTrue);
        state.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await runtime.saveSettings(
          runtime.settings.copyWith(backgroundPlayback: false),
        );
        await tester.pump();
        state.didChangeAppLifecycleState(AppLifecycleState.paused);
        await tester.pump(const Duration(milliseconds: 200));
        expect(player.state.playing, isTrue);
        await windowManager.minimize();
        await tester.pump(const Duration(milliseconds: 800));
        expect(player.state.playing, isTrue);
        await windowManager.restore();
        await windowManager.show();
        await windowManager.focus();
        await player.pause();
        state.didChangeAppLifecycleState(AppLifecycleState.hidden);
        state.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(player.state.playing, isFalse);
        state.didChangeAppLifecycleState(AppLifecycleState.resumed);
        print(
          'BACKGROUND_DESKTOP=native PiP restored on Mac; same player; real minimization continues; manual pause retained',
        );
      } finally {
        await state.platformPlayback.exit(player);
        await tester.pumpWidget(const SizedBox());
        await state.platformUpdates;
        await tester.pumpAndSettle();
        await runtime.dispose();
      }
    },
  );

  testWidgets(
    'native background transport downloads private ciphertext and stores key only in vault',
    (tester) async {
      final asset = await rootBundle.load('assets/verification.cenc.mp4');
      final bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = server.listen((request) async {
        request.response.contentLength = bytes.length;
        if (const bool.fromEnvironment('HONGGUO_TEST_BACKGROUND')) {
          print('NATIVE_DOWNLOAD_BACKGROUND_WINDOW=request started');
          final chunkSize = (bytes.length / 8).ceil();
          for (var start = 0; start < bytes.length; start += chunkSize) {
            final end = (start + chunkSize).clamp(0, bytes.length);
            request.response.add(bytes.sublist(start, end));
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 600));
          }
        } else {
          request.response.add(bytes);
        }
        await request.response.close();
      });
      final root = await getApplicationSupportDirectory();
      final vid = '9${DateTime.now().microsecondsSinceEpoch}';
      final target = File(
        '${root.path}/media-cache/${vid}_best.mp4.100.0.part',
      );
      final vault = _DownloadVault();
      final dio = Dio();
      final downloads = NativeDownloads(
        () => const AppSettings(
          backgroundDownloads: true,
          backgroundWifiOnly: false,
        ),
        dio,
        vault: vault,
      );
      try {
        await downloads
            .download(
              vid,
              'best',
              VideoTrack(
                url: Uri.parse('http://127.0.0.1:${server.port}/fixture'),
                spadeA: 'synthetic-secret-for-downloader-test',
                definition: 'test',
                size: bytes.length,
              ),
              target.path,
              CancelToken(),
              (_, _) {},
            )
            .timeout(const Duration(seconds: 45));
        expect(await target.readAsBytes(), bytes);
        final journal = File('${root.path}/download-journal/${vid}_best.json');
        expect(await journal.exists(), isTrue);
        expect(
          await journal.readAsString(),
          isNot(contains('synthetic-secret-for-downloader-test')),
        );
        expect(
          vault.values.values.single,
          'synthetic-secret-for-downloader-test',
        );
        await downloads.finish(vid, 'best');
        expect(vault.values, isEmpty);
        expect(await journal.exists(), isFalse);
        print(
          'NATIVE_BACKGROUND_DOWNLOAD=native transport completed; bytes matched; journal contained only key reference',
        );
      } finally {
        await downloads.cancel();
        await downloads.finish(vid, 'best');
        if (await target.exists()) await target.delete();
        dio.close(force: true);
        await requests.cancel();
        await server.close(force: true);
      }
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
  testWidgets('background preparation follows platform playback policy', (
    tester,
  ) async {
    final asset = await rootBundle.load('assets/verification.cenc.mp4');
    final runtime = _Runtime(
      asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
      Directory.systemTemp.createTempSync('hongguo-hidden-prepare-'),
      settings: const AppSettings(
        backgroundDownloads: true,
        backgroundPlayback: false,
        prefetchEnabled: false,
        autoNext: false,
      ),
    );
    final gate = Completer<void>();
    (runtime.dio.httpClientAdapter as _Adapter).gate = gate;
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          runtime: runtime,
          detail: await runtime.catalog.detail('123'),
        ),
      ),
    );
    await tester.pump();
    final dynamic state = tester.state(find.byType(PlayerPage));
    final player = state.player as Player;
    try {
      expect(state.preparing, isTrue);
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      gate.complete();
      for (var i = 0; i < 150 && state.preparing; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(state.error, isNull);
      expect(state.preparing, isFalse);
      expect(player.state.playlist.medias, hasLength(1));
      expect(await runtime.cacheBytes(), greaterThan(0));
      expect(
        player.state.playing,
        _mobileDevice ? isFalse : isTrue,
        reason: 'Mobile honors opt-in; desktop continues under occlusion',
      );
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(player.state.playing, !_mobileDevice);
      print(
        'BACKGROUND_PREPARATION=mobile opt-in and desktop continuous playback policy honored; lifecycle simulated',
      );
    } finally {
      if (!gate.isCompleted) gate.complete();
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await runtime.dispose();
    }
  });

  testWidgets('mobile system media and picture-in-picture smoke', (
    tester,
  ) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    final asset = await rootBundle.load('assets/verification.cenc.mp4');
    final runtime = _Runtime(
      asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
      Directory.systemTemp.createTempSync('hongguo-mobile-system-'),
      settings: const AppSettings(
        prefetchEnabled: false,
        autoNext: false,
        backgroundPlayback: true,
        floatingPlayback: true,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          runtime: runtime,
          detail: await runtime.catalog.detail('123'),
        ),
      ),
    );
    await tester.pump();
    final dynamic state = tester.state(find.byType(PlayerPage));
    final player = state.player as Player;
    try {
      for (var i = 0; i < 200 && state.preparing; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await state.platformUpdates;
      expect(state.error, isNull);
      expect(
        state.playbackNotice,
        isNull,
        reason: 'System media handler must initialize without fallback',
      );
      await player.setPlaylistMode(PlaylistMode.loop);
      await player.seek(Duration.zero);
      await player.play();
      print(
        'MOBILE_MEDIA_READY=system handler configured; platform=${Platform.operatingSystem}; audioWarning=${state.audioNotice}',
      );
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 300));
      expect(player.state.playing, isTrue);
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      print(
        'MOBILE_BACKGROUND_WINDOW=ready for external Home/resume verification',
      );
      await Future<void>.delayed(const Duration(seconds: 8));
      expect(player.state.playing, isTrue);
      print(
        'MOBILE_BACKGROUND_AFTER=playing=${player.state.playing}; position=${player.state.position.inMilliseconds}',
      );
      final source = player.state.playlist.medias.single.uri;
      Object? pipError;
      var pipDone = false;
      final entering =
          state.platformPlayback.enter(player, source) as Future<void>;
      unawaited(
        entering
            .then((_) {
              pipDone = true;
            })
            .catchError((Object e) {
              pipError = e;
              pipDone = true;
            }),
      );
      for (var i = 0; i < 120 && !pipDone; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        pipDone,
        isTrue,
        reason: 'PiP transition must complete or report unsupported',
      );
      if (pipError != null) {
        print('MOBILE_PIP_UNAVAILABLE=$pipError');
        if (Platform.isAndroid) fail('Android device PiP failed: $pipError');
      } else {
        expect(state.platformPlayback.floating.value, isTrue);
        print('MOBILE_PIP_ACTIVE=system picture-in-picture entered');
        await Future<void>.delayed(const Duration(seconds: 2));
        if (Platform.isAndroid) {
          expect(
            player.state.playing,
            isTrue,
            reason: 'System PiP must keep playing rather than only showing a frozen window',
          );
        }
        await state.platformPlayback.exit(player);
        for (var i = 0; i < 80 && state.platformPlayback.floating.value; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(state.platformPlayback.floating.value, isFalse);
        print('MOBILE_PIP_RESTORED=system picture-in-picture exited');
      }
      await runtime.saveSettings(
        runtime.settings.copyWith(backgroundPlayback: false),
      );
      await tester.pump();
      await state.platformUpdates;
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 300));
      expect(player.state.playing, isFalse);
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    } finally {
      await state.platformPlayback.exit(player);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await runtime.dispose();
    }
  });
  testWidgets(
    'manual download from detail survives navigation and plays offline from My',
    (tester) async {
      final asset = await rootBundle.load('assets/verification.cenc.mp4');
      final runtime = _ManualRuntime(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        Directory.systemTemp.createTempSync('hongguo-manual-download-'),
      );
      await runtime.downloads.load();
      final detail = await runtime.catalog.detail('123');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [runtimeProvider.overrideWith((_) async => runtime)],
          child: const HongguoApp(),
        ),
      );
      await tester.pumpAndSettle();
      if (!_mobileDevice) {
        await windowManager.ensureInitialized();
        await windowManager.show();
        await windowManager.focus();
      }
      try {
        await tester.tap(find.text('离线播放验证').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('download-drama')),
        );
        await tester.tap(find.byKey(const ValueKey('download-drama')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('download-episode-0')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('confirm-download')));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        for (var i = 0; i < 150 && runtime.downloads.readyCount == 0; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(runtime.downloads.readyCount, 1);
        final stored = jsonDecode(
          await File('${runtime.directory.path}/downloads.json').readAsString(),
        ) as Map;
        expect((stored['tasks'] as List).single['phase'], 'ready');
        await tester.tap(
          find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '我的'),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('my-downloads')));
        await tester.tap(find.byKey(const ValueKey('my-downloads')));
        await tester.pumpAndSettle();
        expect(find.byType(DownloadsPage), findsOneWidget);
        await tester.tap(find.byTooltip('离线观看'));
        await tester.pumpAndSettle();
        final dynamic state = tester.state(find.byType(PlayerPage));
        final player = state.player as Player;
        await player.setVolume(0);
        for (
          var i = 0;
          i < 150 && (state.preparing || player.state.width == null);
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(state.error, isNull);
        expect(
          (tester.widget(find.byType(PlayerPage)) as PlayerPage).cachedOnly,
          isTrue,
        );
        expect(
          runtime.localRequests,
          contains('${detail.episodes.first.vid}:best'),
        );
        expect(player.state.width, 160);
        await player.pause();
        await tester.pump(const Duration(milliseconds: 200));
        await expectLater(
          runtime.downloads.remove('${detail.episodes.first.vid}_best'),
          throwsStateError,
        );
        await tester.tap(find.byKey(const ValueKey('player-exit')));
        await tester.pumpAndSettle();
        for (
          var i = 0;
          i < 50 && (await runtime.localEpisodes()).any((e) => e.inUse);
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await runtime.clearCache();
        expect(
          (await runtime.localEpisodes()).length,
          1,
          reason: 'Manual file survives ordinary cache cleanup after player releases it',
        );
        print(
          'MANUAL_DOWNLOAD_ACCEPTANCE=platform=${Platform.operatingSystem}; detail selection -> persisted ready -> My -> offline texture; preserved after cache cleanup',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await runtime.dispose();
      }
    },
  );

  testWidgets(
    'PC/mobile routed playback restores progress and returns without losing catalog',
    (tester) async {
      final asset = await rootBundle.load('assets/verification.cenc.mp4');
      final runtime = _Runtime(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        Directory.systemTemp.createTempSync('hongguo-routed-'),
        episodes: 3,
        settings: const AppSettings(
          backgroundPlayback: true,
          autoNext: false,
          prefetchEnabled: false,
          backgroundPlaybackPrompted: true,
          floatingPlaybackPrompted: true,
        ),
      );
      final detail = await runtime.catalog.detail('123');
      await runtime.personalLibrary.record(
        WatchRecord(
          drama: detail.drama,
          vid: detail.episodes[1].vid,
          episode: detail.episodes[1].index,
          positionMs: 700,
          durationMs: 2000,
          updated: DateTime.now(),
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [runtimeProvider.overrideWith((_) async => runtime)],
          child: const HongguoApp(),
        ),
      );
      await tester.pumpAndSettle();
      if (!_mobileDevice) {
        await windowManager.ensureInitialized();
        await windowManager.show();
        await windowManager.focus();
      }
      final catalogState = tester.state(find.byType(LibraryPage));
      final router = AppNavigation.maybeOf(
        tester.element(find.byType(LibraryPage)),
      )!.router;
      try {
        await tester.tap(find.text('离线播放验证').last);
        await tester.pumpAndSettle();
        expect(router.current.name, AppScreen.detail.routeName);
        expect(find.byType(DetailPage), findsOneWidget);
        expect(find.text('继续观看'), findsOneWidget);
        await tester.tap(find.text('继续观看'));
        await tester.pumpAndSettle();
        expect(router.current.name, AppScreen.player.routeName);
        final dynamic state = tester.state(find.byType(PlayerPage));
        final player = state.player as Player;
        await player.setVolume(0);
        for (var i = 0; i < 150 && state.preparing; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(state.error, isNull);
        expect(state.position, 1);
        for (
          var i = 0;
          i < 40 && player.state.position.inMilliseconds < 600;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(600));
        await player.pause();
        await tester.pump(const Duration(milliseconds: 200));
        await runtime.personalLibrary.flush();
        print(
          'ROUTED_PLAYBACK_ACCEPTANCE=platform=${Platform.operatingSystem}; route=${router.current.name}; episode=2; savedMs=${runtime.personalLibrary.episodeFor(detail.drama.id, detail.episodes[1].vid)?.positionMs}',
        );
        await tester.tap(find.byKey(const ValueKey('player-exit')));
        await tester.pumpAndSettle();
        expect(router.current.name, AppScreen.detail.routeName);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(router.current.name, 'Catalog');
        expect(tester.state(find.byType(LibraryPage)), same(catalogState));
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await runtime.dispose();
      }
    },
  );

  testWidgets(
    'personal library records real playback and resumes exact episode',
    (tester) async {
      final asset = await rootBundle.load('assets/verification.cenc.mp4');
      final runtime = _Runtime(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        Directory.systemTemp.createTempSync('hongguo-personal-'),
        episodes: 3,
        settings: const AppSettings(
          backgroundPlayback: true,
          autoNext: false,
          prefetchEnabled: false,
          backgroundPlaybackPrompted: true,
          floatingPlaybackPrompted: true,
        ),
      );
      final detail = await runtime.catalog.detail('123');
      final library = personalLibraryFor(runtime);
      await library.toggleFavorite(detail.drama);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PlayerPage(
                      runtime: runtime,
                      detail: detail,
                      initialPosition: 1,
                      initialOffset: const Duration(milliseconds: 700),
                    ),
                  ),
                ),
                child: const Text('open saved episode'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open saved episode'));
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(PlayerPage));
      final player = state.player as Player;
      for (var i = 0; i < 150 && state.preparing; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(state.error, isNull);
      expect(state.position, 1);
      for (
        var i = 0;
        i < 40 && player.state.position.inMilliseconds < 600;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(600));
      await player.pause();
      await tester.pump(const Duration(milliseconds: 200));
      await library.flush();
      expect(library.history.single.vid, detail.episodes[1].vid);
      expect(library.history.single.positionMs, greaterThanOrEqualTo(600));
      expect(library.favorites.single.id, detail.drama.id);
      final restored = PersonalLibrary(
        backend: FilePreferencesBackend(
          File('${runtime.directory.path}/personal.json'),
        ),
      );
      await restored.load();
      expect(restored.history.single.vid, detail.episodes[1].vid);
      expect(restored.favorites.single.id, detail.drama.id);
      restored.dispose();
      print(
        'PERSONAL_HISTORY_NATIVE=episode=2; savedMs=${library.history.single.positionMs}; favorite retained',
      );
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 100));
      await library.flush();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await runtime.dispose();
    },
  );

  testWidgets(
    'mac window close hides without stopping and immersive chrome restores',
    (tester) async {
      if (!Platform.isMacOS) return;
      await windowManager.ensureInitialized();
      await windowManager.show();
      await windowManager.focus();
      const channel = MethodChannel('hongguo/macos-window');
      Future<Map<dynamic, dynamic>> windowState() async =>
          (await channel.invokeMapMethod('state'))!;
      final initial = await windowState();
      expect(initial['titleHidden'], isTrue);
      expect(initial['closeHidden'], isTrue);
      expect(initial['fullSizeContent'], isTrue);
      expect(initial['statusItem'], isTrue);
      expect(initial['statusClickRestores'], isFalse);
      expect(
        (initial['menu'] as List)
            .where((item) => item.toString().isNotEmpty)
            .length,
        5,
      );
      final asset = await rootBundle.load('assets/verification.cenc.mp4');
      final runtime = _Runtime(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        Directory.systemTemp.createTempSync('hongguo-window-'),
        settings: const AppSettings(autoNext: false, prefetchEnabled: false),
      );
      final detail = await runtime.catalog.detail('123');
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [macPlaybackRoutes],
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('open mac player'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        PlayerPage(runtime: runtime, detail: detail),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open mac player'));
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(PlayerPage));
      final player = state.player as Player;
      try {
        for (var i = 0; i < 150 && state.preparing; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await player.setVolume(0);
        await player.setRate(.25);
        await player.setPlaylistMode(PlaylistMode.loop);
        await player.play();
        await tester.pump(const Duration(milliseconds: 200));
        var native = await windowState();
        expect(native['immersive'], isTrue);
        expect(native['titleHidden'], isTrue);
        expect(native['fullSizeContent'], isTrue);
        expect(native['closeHidden'], isTrue);
        expect(
          (native['contentHeight'] as num).toDouble(),
          closeTo((native['frameHeight'] as num).toDouble(), 2),
        );
        final handle = await player.handle;
        await _wakePlayerControls(tester);
        await tester.tap(find.byKey(const ValueKey('toggle-window-topmost')));
        for (var i = 0; i < 30 && state.pinUpdating; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(state.windowPinned, isTrue);
        expect((await windowState())['topmost'], isTrue);
        expect(await windowManager.isAlwaysOnTop(), isTrue);
        await state.platformPlayback.setDesktopFullscreen(true);
        expect((await windowState())['topmost'], isFalse);
        await state.platformPlayback.setDesktopFullscreen(false);
        expect((await windowState())['topmost'], isTrue);
        await player.seek(Duration.zero);
        await player.play();
        await _wakePlayerControls(tester);
        await tester.tap(find.byKey(const ValueKey('enter-pip')));
        for (
          var i = 0;
          i < 100 && !state.platformPlayback.platformPip.value;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(state.platformPlayback.platformPip.value, isTrue);
        expect((await windowState())['topmost'], isFalse);
        await state.platformPlayback.exit(player);
        expect((await windowState())['topmost'], isTrue);
        await windowManager.close();
        await tester.pump(const Duration(milliseconds: 700));
        expect((await windowState())['visible'], isFalse);
        expect((await windowState())['statusClickRestores'], isTrue);
        expect(player.state.playing, isTrue);
        await channel.invokeMethod('show');
        await tester.pump(const Duration(milliseconds: 300));
        expect((await windowState())['visible'], isTrue);
        expect((await windowState())['statusClickRestores'], isFalse);
        expect(await player.handle, handle);
        await _wakePlayerControls(tester);
        await tester.tap(find.byTooltip('播放速度'));
        await tester.pumpAndSettle();
        expect((await windowState())['immersive'], isTrue);
        await tester.tap(find.text('0.5×'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('toggle-episodes')));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('播放设置'));
        await tester.pumpAndSettle();
        expect((await windowState())['immersive'], isFalse);
        expect((await windowState())['topmost'], initial['topmost']);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect((await windowState())['immersive'], isTrue);
        expect((await windowState())['topmost'], isTrue);
        expect(await player.handle, handle);
        await _wakePlayerControls(tester);
        await tester.tap(find.byKey(const ValueKey('toggle-window-topmost')));
        for (var i = 0; i < 30 && state.pinUpdating; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(state.windowPinned, isFalse);
        expect((await windowState())['topmost'], initial['topmost']);
        await tester.tap(find.byKey(const ValueKey('toggle-window-topmost')));
        for (var i = 0; i < 30 && state.pinUpdating; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(state.windowPinned, isTrue);
        await tester.tap(find.byKey(const ValueKey('player-exit')));
        await tester.pumpAndSettle();
        native = await windowState();
        expect(native['immersive'], isFalse);
        expect(native['topmost'], initial['topmost']);
        expect(native['titleHidden'], initial['titleHidden']);
        expect(native['closeHidden'], initial['closeHidden']);
        print(
          'MAC_WINDOW_ACCEPTANCE=pin sets native floating level; fullscreen and PiP suspend/restore pin; settings and route exit restore level; real close hides; native status menu exists; restore retains player; full-size playback; route exit keeps native titlebar hidden',
        );
      } finally {
        await channel.invokeMethod('show');
        await tester.pumpWidget(const SizedBox());
        await state.platformUpdates;
        await tester.pumpAndSettle();
        await runtime.dispose();
      }
    },
  );

  testWidgets(
    'immersive player hides all chrome and restores exit using actual platform input',
    (tester) async {
      final asset = await rootBundle.load('assets/verification.cenc.mp4');
      final runtime = _Runtime(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        Directory.systemTemp.createTempSync('hongguo-immersive-'),
        settings: AppSettings(
          backgroundPlayback: !_mobileDevice,
          autoNext: false,
          prefetchEnabled: false,
          backgroundPlaybackPrompted: true,
          floatingPlaybackPrompted: true,
        ),
      );
      final detail = await runtime.catalog.detail('123');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        PlayerPage(runtime: runtime, detail: detail),
                  ),
                ),
                child: const Text('open immersive'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open immersive'));
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(PlayerPage));
      final player = state.player as Player;
      try {
        if (!_mobileDevice) {
          await windowManager.ensureInitialized();
          await windowManager.show();
          await windowManager.focus();
        }
        await player.setVolume(0);
        for (var i = 0; i < 150 && state.preparing; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(state.error, isNull);
        await player.setRate(
          .25,
        ); // Keep the short fixture playing through the idle interval.
        await player.setPlaylistMode(PlaylistMode.loop);
        await player.seek(Duration.zero);
        await player.play();
        await tester.pump(const Duration(milliseconds: 200));
        final handle = await player.handle;
        final picture = find.byKey(const ValueKey('compact-player-picture'));
        final rect = tester.getRect(picture);
        expect(
          rect.size,
          tester.view.physicalSize / tester.view.devicePixelRatio,
        );
        expect(find.byType(AppBar), findsNothing);
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        print(
          'IMMERSIVE_IDLE=visible=${state.compactControls.currentState.visible}; playing=${player.state.playing}; parentPlaying=${state.playing}; background=${state.appBackground}; busy=${state.compactControls.currentState.widget.busy}; keyboard=${state.compactControls.currentState.keyboardFocus}',
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const ValueKey('player-exit')), findsNothing);
        expect(
          find.byKey(const ValueKey('compact-playback-controls')),
          findsNothing,
        );
        if (Platform.isAndroid) {
          print('DEVICE_SCREENSHOT=immersive-hidden');
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        if (_mobileDevice) {
          await tester.tapAt(rect.center);
        } else {
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: const Offset(-1, -1));
          await mouse.moveTo(rect.center);
          await mouse.moveTo(rect.center + const Offset(5, 0));
          await mouse.removePointer();
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('player-exit')), findsOneWidget);
        expect(tester.getRect(picture), rect);
        expect(await player.handle, handle);
        if (Platform.isAndroid) {
          print('DEVICE_SCREENSHOT=immersive-visible');
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        await player.pause();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('player-exit')), findsOneWidget);
        await tester.tap(find.byTooltip('全屏'));
        for (var i = 0; i < 40 && !state.fullscreen; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(state.fullscreen, isTrue);
        if (!_mobileDevice) {
          for (var i = 0; i < 40 && !await windowManager.isFullScreen(); i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(await windowManager.isFullScreen(), isTrue);
        }
        await tester.pump(const Duration(milliseconds: 500));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        for (var i = 0; i < 40 && state.fullscreen; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(state.fullscreen, isFalse);
        if (!_mobileDevice) {
          for (var i = 0; i < 40 && await windowManager.isFullScreen(); i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(await windowManager.isFullScreen(), isFalse);
        }
        if (Platform.isMacOS) await state.platformPlayback.fullscreenUpdates;
        expect(await player.handle, handle);
        await tester.tap(find.byKey(const ValueKey('player-exit')));
        for (
          var i = 0;
          i < 40 && find.byType(PlayerPage).evaluate().isNotEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(find.byType(PlayerPage), findsNothing);
        print(
          'IMMERSIVE_ACCEPTANCE=real viewport; no AppBar; all chrome hidden; platform reveal; pause keeps exit; fullscreen preserves player; exit returns',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await state.platformUpdates;
        await tester.pumpAndSettle();
        await runtime.dispose();
      }
    },
  );

  testWidgets(
    'mobile return recommendations are durable, separated and respect hardware capability',
    (tester) async {
      if (!_mobileDevice) return;
      final asset = await rootBundle.load('assets/verification.cenc.mp4');
      var clock = DateTime(2026, 10, 20);
      final policy = PlaybackReturnRecommendations(now: () => clock);
      final runtime = _Runtime(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        Directory.systemTemp.createTempSync('hongguo-recommend-'),
        settings: const AppSettings(prefetchEnabled: false, autoNext: false),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            runtime: runtime,
            detail: await runtime.catalog.detail('123'),
            returnRecommendations: policy,
          ),
        ),
      );
      await tester.pump();
      final dynamic state = tester.state(find.byType(PlayerPage));
      final player = state.player as Player;
      Future<void> returned() async {
        state.didChangeAppLifecycleState(AppLifecycleState.paused);
        state.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
      }

      try {
        await player.setVolume(0);
        for (var i = 0; i < 150 && state.preparing; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await player.play();
        await tester.pump(const Duration(milliseconds: 200));
        await returned();
        expect(find.text('试试后台播放？'), findsOneWidget);
        expect(find.text('试试悬浮播放？'), findsNothing);
        await tester.tap(find.text('暂不开启'));
        await tester.pumpAndSettle();
        expect(runtime.settings.backgroundPlaybackPrompted, isTrue);
        expect(runtime.settings.backgroundPlayback, isFalse);
        await returned();
        expect(find.byType(AlertDialog), findsNothing);
        clock = clock.add(const Duration(seconds: 61));
        await returned();
        final supported =
            await state.platformPlayback.supportsFloating() as bool;
        if (supported) {
          expect(find.text('试试悬浮播放？'), findsOneWidget);
          await tester.tap(find.text('开启并生效'));
          await tester.pumpAndSettle();
          expect(runtime.settings.floatingPlayback, isTrue);
          expect(runtime.settings.floatingPlaybackPrompted, isTrue);
          expect(state.platformPlayback.floating.value, isFalse);
        } else {
          expect(find.byType(AlertDialog), findsNothing);
          expect(runtime.settings.floatingPlaybackPrompted, isFalse);
        }
        expect(player.state.playing, isFalse);
        print(
          'RETURN_PROMPT_ACCEPTANCE=first return offers background; decline remembered; cooldown; next return offers only supported PiP; lifecycle simulated',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await state.platformUpdates;
        await tester.pumpAndSettle();
        await runtime.dispose();
      }
    },
  );
}
