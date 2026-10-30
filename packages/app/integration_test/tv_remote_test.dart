import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_api/hongguo_native_api.dart';
import 'package:hongguo_app/catalog/library_cache.dart';
import 'package:hongguo_app/settings/settings_store_native.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_app/features/tv/tv_library_page.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_tv/hongguo_tv.dart';
import 'package:media_kit/media_kit.dart' hide VideoTrack;
import 'package:video_player/video_player.dart';
import 'package:hongguo_app/playback/tv_video_view.dart';

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

class _Catalog implements CatalogRepository {
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

class TvPlaybackFixtureRuntime
    implements
        ConfigurableRuntime,
        LibraryCacheRuntime,
        LocalMediaRuntime,
        VideoQualityRuntime {
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
  final CatalogRepository catalog;
  final Dio dio;
  final Directory directory;
  late final MediaCache cache;
  final localRequests = <String>[];
  TvPlaybackFixtureRuntime(
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
  final prepared = <({String vid, String quality})>[];
  final qualityRequests = <String>[];
  @override
  Future<List<VideoQuality>> videoQualities(String vid) async {
    qualityRequests.add(vid);
    return const [
      VideoQuality('best', '自动'),
      VideoQuality('160p', '160p', width: 160, height: 288),
    ];
  }

  @override
  PlaybackJob prepare(
    String vid, {
    String quality = 'best',
    void Function(PreparationProgress)? onProgress,
    bool background = false,
  }) {
    prepared.add((vid: vid, quality: quality));
    return _Job(
      cache.prepare(
        vid,
        quality: quality,
        background: background,
        onProgress: (p) =>
            onProgress?.call(PreparationProgress(p.stage.name, p.fraction)),
      ),
      cache,
    );
  }

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

class _NavigationLog extends NavigatorObserver {
  final popped = <String?>[];
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popped.add(route.settings.name);
    super.didPop(route, previousRoute);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  testWidgets(
    'TV remote catalog -> detail -> real CENC -> playback -> seek -> return',
    (t) async {
      Future<void> remote(LogicalKeyboardKey key) async {
        if (!const bool.fromEnvironment('HONGGUO_SYSTEM_DPAD')) {
          await t.sendKeyEvent(key);
          return;
        }
        final code = switch (key) {
          LogicalKeyboardKey.arrowUp => 19,
          LogicalKeyboardKey.arrowDown => 20,
          LogicalKeyboardKey.arrowLeft => 21,
          LogicalKeyboardKey.arrowRight => 22,
          LogicalKeyboardKey.select => 23,
          LogicalKeyboardKey.escape => 4,
          _ => throw ArgumentError('Unmapped system key: $key'),
        };
        print('TV_SYSTEM_KEY=$code');
        await Future<void>.delayed(const Duration(milliseconds: 650));
        await t.pump();
        print('TV_FOCUS=${FocusManager.instance.primaryFocus}');
      }

      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
      ]);
      final asset = await rootBundle.load('assets/verification.cenc.mp4');
      final runtime = TvPlaybackFixtureRuntime(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        await Directory.systemTemp.createTemp('hongguo-tv-integration-'),
        episodes: 2,
        settings: const AppSettings(autoNext: false, prefetchEnabled: false),
      );
      final navigation = _NavigationLog();
      await t.pumpWidget(
        TvBackDispatcher(
          builder: (_, key) => MaterialApp(
            navigatorKey: key,
            navigatorObservers: [navigation],
            builder: (context, child) => TvEnvironment(
              enabled: true,
              child: TvNavigation(child: child!),
            ),
            home: TvLibraryPage(runtime: runtime),
          ),
        ),
      );
      await t.pumpAndSettle();
      // A native window can gain input focus after its first settled frame.
      for (
        var frame = 0;
        frame < 50 && FocusManager.instance.primaryFocus == null;
        frame++
      ) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'nav-0');
      await remote(LogicalKeyboardKey.arrowRight);
      await t.pumpAndSettle();
      for (
        var n = 0;
        n < 5 &&
            FocusManager.instance.primaryFocus?.debugLabel?.startsWith(
                  'tv-grid-',
                ) !=
                true;
        n++
      ) {
        await remote(LogicalKeyboardKey.arrowDown);
        await t.pumpAndSettle();
      }
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-grid-123');
      await remote(LogicalKeyboardKey.select);
      await t.pumpAndSettle();
      expect(find.text('▶ 开始观看'), findsOneWidget);
      await remote(LogicalKeyboardKey.select);
      for (
        var i = 0;
        i < 150 && find.byType(VideoPlayer).evaluate().isEmpty;
        i++
      ) {
        await t.pump(const Duration(milliseconds: 100));
      }
      // A single physical Back from plain video must pop ONLY the player.
      await remote(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(find.text('▶ 开始观看'), findsOneWidget);
      expect(navigation.popped, ['/tv/player']);
      print('TV_SCREENSHOT=back-to-detail');
      await t.pump(const Duration(milliseconds: 200));
      await remote(LogicalKeyboardKey.select);
      for (
        var i = 0;
        i < 150 && find.byType(VideoPlayer).evaluate().isEmpty;
        i++
      ) {
        await t.pump(const Duration(milliseconds: 100));
      }
      final surface = t.state(find.byType(TvPlayerSurface));
      expect(surface.mounted, isTrue);
      for (var i = 0; i < 150; i++) {
        await t.pump(const Duration(milliseconds: 100));
        final tv = t.widget<TvPlayerSurface>(find.byType(TvPlayerSurface));
        if (!tv.busy && tv.duration > Duration.zero) break;
      }
      final tv = t.widget<TvPlayerSurface>(find.byType(TvPlayerSurface));
      expect(tv.error, isNull);
      expect(tv.busy, isFalse);
      expect(tv.duration, greaterThan(Duration.zero));
      final player = t.widget<TvVideoView>(find.byType(TvVideoView)).controller;
      expect(player.video!.value.isInitialized, isTrue);
      expect(player.video!.viewType, VideoViewType.platformView);
      for (
        var i = 0;
        i < 60 && find.byType(AndroidViewSurface).evaluate().isEmpty;
        i++
      ) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.byType(AndroidViewSurface),
        findsWidgets,
        reason:
            'A playing timeline must expose the native Android video surface',
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await t.pump();
      await player.pause();
      await t.pump();
      print('TV_SCREENSHOT=player-frame');
      await t.pump(const Duration(milliseconds: 200));
      await remote(LogicalKeyboardKey.select);
      expect(player.playing, isTrue);
      await remote(LogicalKeyboardKey.select);
      expect(player.playing, isFalse);
      await remote(LogicalKeyboardKey.escape);
      await remote(LogicalKeyboardKey.arrowRight);
      await t.pump();
      expect(find.textContaining('预览'), findsOneWidget);
      await remote(LogicalKeyboardKey.select);
      for (var i = 0; i < 30; i++) {
        await t.pump(const Duration(milliseconds: 100));
        if (player.position > const Duration(seconds: 1)) break;
      }
      expect(player.position, greaterThan(const Duration(seconds: 1)));
      await remote(LogicalKeyboardKey.arrowUp);
      await t.pump();
      expect(find.text('选集'), findsOneWidget);
      // Move from play past the disabled previous button to next, then switch.
      await remote(LogicalKeyboardKey.arrowRight);
      await remote(LogicalKeyboardKey.select);
      for (var i = 0; i < 100; i++) {
        await t.pump(const Duration(milliseconds: 100));
        final view = t.widget<TvPlayerSurface>(find.byType(TvPlayerSurface));
        if (!view.busy && view.episode == 1) break;
      }
      final switched = t.widget<TvPlayerSurface>(find.byType(TvPlayerSurface));
      expect(switched.episode, 1);
      expect(switched.error, isNull);
      expect(switched.busy, isFalse);
      for (
        var i = 0;
        i < 60 && find.byType(AndroidViewSurface).evaluate().isEmpty;
        i++
      ) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(AndroidViewSurface), findsWidgets);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await t.pump();
      print('TV_SCREENSHOT=player-next-episode');
      await t.pump(const Duration(milliseconds: 200));
      await remote(LogicalKeyboardKey.arrowUp);
      expect(find.text('选集'), findsOneWidget);
      await remote(LogicalKeyboardKey.escape);
      await t.pump();
      await remote(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('▶ 开始观看'), findsOneWidget);
      expect(navigation.popped, ['/tv/player', '/tv/player']);
      await remote(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byType(TvLibraryPage), findsOneWidget);
      expect(navigation.popped, ['/tv/player', '/tv/player', '/tv/detail/123']);
      print(
        'TV_BACK_NATIVE_PASS one_back_one_route=true detail_before_catalog=true',
      );
      print(
        'TV_NATIVE_PASS duration_ms=${tv.duration.inMilliseconds} backend=android_exoplayer remote_seek=true next_episode=true remote_pause_resume=true platform_surface_visible=true',
      );
      await t.pumpWidget(const SizedBox());
      await t.pump();
      await runtime.dispose();
    },
  );
}
