/// v0.3.1 macOS desktop acceptance for the episode-swipe hint, pointer-kind
/// filtering, edge toasts and the search suggestion panel.
///
/// Verification-only fixture: assembled like the offline playback test with a
/// fake runtime, driven with in-app events only (no synthetic OS clicks).
/// Screenshots and stage markers are written under --dart-define
/// HONGGUO_WATCH_DIR so an external `screencapture -l` watcher can grab real
/// window frames while stable states are on screen.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_api/hongguo_native_api.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/catalog/library_cache.dart';
import 'package:hongguo_app/features/detail_page.dart';
import 'package:hongguo_app/features/library_page.dart';
import 'package:hongguo_app/features/player_page.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_app/personal/personal_library.dart';
import 'package:hongguo_app/platform/macos_window.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_app/search/search_history.dart';
import 'package:hongguo_app/settings/settings_store_native.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' hide VideoTrack;
import 'package:window_manager/window_manager.dart';
import 'package:hongguo_core/hongguo_core.dart';

const desktopHint = 'Page Up / Page Down 切换上下集';
const mobileHint = '上滑下一集 · 下滑上一集';

// The macOS Runner is sandboxed, so the handshake lives in the app container's
// own temp dir (what Directory.systemTemp resolves to inside the app).
Directory get _watch =>
    Directory('${Directory.systemTemp.path}/hongguo-verify-watch');

File _watchFile(String name) => File('${_watch.path}/$name');

void _stage(String name) {
  _watchFile('stage').writeAsStringSync('$name\n', flush: true);
  print('STAGE=$name');
}

Future<void> _hold(String name, {int ms = 800}) async {
  _stage(name);
  await Future<void>.delayed(Duration(milliseconds: ms));
}

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

class _Catalog implements CatalogRepository {
  final int count;
  _Catalog([this.count = 3]);
  static const drama = Drama(id: '123', title: '离线播放验证', episodeCount: 3);
  static const latest = Drama(id: '9001', title: '桌面搜索最新剧', episodeCount: 1);
  static const popular = Drama(id: '9002', title: '桌面搜索热门剧', episodeCount: 1);
  static final byId = {
    for (final d in [drama, latest, popular]) d.id: d,
  };
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) async => switch (sort) {
    'online_time' => const CatalogPage([latest]),
    'hot_score' => const CatalogPage([popular, drama]),
    _ => const CatalogPage([drama]),
  };
  @override
  Future<CatalogPage> search(String query, {String? cursor}) async =>
      const CatalogPage([drama]);
  @override
  Future<DramaDetail> detail(String id) async {
    final drama = byId[id] ?? _Catalog.drama;
    if (id == '123') {
      return DramaDetail(
        drama,
        List.generate(count, (i) => Episode(vid: '${123 + i}', index: i + 1)),
      );
    }
    return DramaDetail(drama, [Episode(vid: '${id}1', index: 1)]);
  }

  @override
  Future<List<CatalogFilter>> themes(String genre) async => [];
}

class _Runtime
    implements
        ConfigurableRuntime,
        LibraryCacheRuntime,
        LocalMediaRuntime,
        PersonalLibraryRuntime,
        SearchHistoryRuntime {
  @override
  late final LibraryCache libraryCache;
  @override
  late final PersonalLibrary personalLibrary;
  @override
  late final SearchHistory searchHistory;
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
    int episodes = 3,
  }) : catalog = _Catalog(episodes),
       dio = Dio()..httpClientAdapter = _Adapter(bytes) {
    personalLibrary = PersonalLibrary(
      backend: FilePreferencesBackend(File('${directory.path}/personal.json')),
    );
    libraryCache = LibraryCache(
      backend: FilePreferencesBackend(File('${directory.path}/library.json')),
    );
    searchHistory = SearchHistory(
      backend: FilePreferencesBackend(
        File('${directory.path}/search-history.json'),
      ),
    );
    cache = MediaCache(
      directory: directory,
      dio: dio,
      maxConcurrent: settings.concurrentPreparations,
      resolve: (_, _) async => VideoTrack(
        url: Uri.parse('https://a.qznovelvod.com/offline.mp4'),
        spadeA: 'c3BhZGUtdGVzdC1rZXk=',
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
  Future<List<LocalEpisode>> localEpisodes() async => const [];
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
    await searchHistory.flush();
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

Future<Uint8List> _loadAsset() async {
  final asset = await rootBundle.load('assets/verification.cenc.mp4');
  return asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes);
}

Future<void> _capture(GlobalKey key, String name) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('${_watch.path}/goldens/$name.png');
  await file.create(recursive: true);
  await file.writeAsBytes(data!.buffer.asUint8List(), flush: true);
  image.dispose();
  print('GOLDEN=${file.path}');
}

Future<void> _waitEpisode(
  WidgetTester tester,
  dynamic state,
  Player player,
  int position,
) async {
  for (var i = 0; i < 250; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (state.position == position &&
        !state.preparing &&
        state.error == null &&
        player.state.duration > Duration.zero) {
      return;
    }
  }
  fail('Episode $position never became ready (error=${state.error})');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  setUpAll(() {
    _watch.createSync(recursive: true);
    try {
      _watchFile('stage').deleteSync();
    } on FileSystemException {
      // nothing to clear
    }
    _watchFile('app-pid.txt').writeAsStringSync('$pid\n', flush: true);
    print('HONGGUO_TEST_PID=$pid');
    print('HONGGUO_WATCH_DIR=${_watch.path}');
  });

  testWidgets(
    'macOS player: desktop hint copy, pointer-kind filtering, edge toasts, one-time hint',
    (tester) async {
      final runtime = _Runtime(
        await _loadAsset(),
        Directory.systemTemp.createTempSync('hongguo-desktop-swipe-'),
        episodes: 3,
        settings: const AppSettings(
          autoNext: false,
          prefetchEnabled: false,
          backgroundPlaybackPrompted: true,
          floatingPlaybackPrompted: true,
        ),
      );
      final detail = await runtime.catalog.detail('123');
      final captureKey = GlobalKey();
      await windowManager.ensureInitialized();
      await windowManager.show();
      await windowManager.focus();
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            navigatorObservers: [macPlaybackRoutes],
            home: PlayerPage(runtime: runtime, detail: detail),
          ),
        ),
      );
      await tester.pump();
      final dynamic state = tester.state(find.byType(PlayerPage));
      final player = state.player as Player;
      await player.setVolume(0);
      await player.setPlaylistMode(PlaylistMode.loop);
      for (var i = 0; i < 250; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (!state.preparing &&
            state.error == null &&
            player.state.width == 160) {
          break;
        }
      }
      expect(state.error, isNull);
      expect(state.preparing, isFalse);

      // 1. First entry shows the desktop copy of the one-time hint pill.
      expect(find.text(desktopHint), findsOneWidget);
      expect(find.text(mobileHint), findsNothing);
      await _capture(captureKey, 'desktop-hint-pill');
      await _hold('hint-pill');
      await player.play();
      // The pill fades out on its own and the consumption is persisted.
      await Future<void>.delayed(const Duration(milliseconds: 3600));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(desktopHint), findsNothing);
      expect(runtime.settings.episodeSwipeHintShown, isTrue);
      await _hold('hint-consumed');

      // Controls auto-hide while playing; the next assertions prove the wake.
      for (var attempt = 0; attempt < 10; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await tester.pump();
        if (find
            .byKey(const ValueKey('compact-playback-controls'))
            .evaluate()
            .isEmpty) {
          break;
        }
      }
      final picture = find.byKey(const ValueKey('player-picture'));
      final rect = tester.getRect(picture);
      final before = state.position as int;
      final beforeVid = state.sourceVid as String;

      // 2a. A mouse drag over the picture must not switch episodes.
      await tester.drag(
        picture,
        const Offset(0, -300),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(state.position, before);
      expect(state.sourceVid, beforeVid);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: rect.center);
      await mouse.down(rect.center);
      await tester.pump(const Duration(milliseconds: 20));
      await mouse.moveTo(rect.center + const Offset(0, -300));
      await tester.pump(const Duration(milliseconds: 20));
      await mouse.moveTo(rect.center + const Offset(0, -350));
      await tester.pump(const Duration(milliseconds: 20));
      await mouse.up();
      await mouse.removePointer();
      await tester.pump();
      expect(state.position, before);
      expect(state.sourceVid, beforeVid);

      // 2b. A scroll wheel event must not switch episodes either.
      await tester.sendEventToBinding(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: rect.center,
          scrollDelta: const Offset(0, -400),
        ),
      );
      await tester.pump();
      expect(state.position, before);
      expect(state.sourceVid, beforeVid);
      await _capture(captureKey, 'desktop-after-mouse-and-wheel');
      await _hold('mouse-wheel-ignored');

      // 3. Keyboard stepping still works (the unchanged _step path).
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await _waitEpisode(tester, state, player, before + 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await _waitEpisode(tester, state, player, before);
      expect(state.sourceVid, beforeVid);

      // 4. Touch drag is the accepted pointer kind: it must switch episodes.
      await tester.drag(picture, const Offset(0, -300));
      await _waitEpisode(tester, state, player, before + 1);
      expect(state.sourceVid, '${int.parse(beforeVid) + 1}');
      await tester.drag(picture, const Offset(0, 300));
      await _waitEpisode(tester, state, player, before);

      // 5. Past the first episode the toast names the edge and wakes the chrome.
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await _waitEpisode(tester, state, player, 0);
      for (var attempt = 0; attempt < 12; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await tester.pump();
        if (find
            .byKey(const ValueKey('compact-playback-controls'))
            .evaluate()
            .isEmpty) {
          break;
        }
      }
      expect(
        find.byKey(const ValueKey('compact-playback-controls')),
        findsNothing,
        reason:
            'Idle desktop playback hides the chrome before the boundary press',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('已经是第一集'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('compact-playback-controls')),
        findsOneWidget,
        reason: 'The boundary notice summons the control bar',
      );
      await _capture(captureKey, 'desktop-edge-first-toast');
      await _hold('edge-first-toast');
      await Future<void>.delayed(const Duration(milliseconds: 3000));
      await tester.pump();
      expect(find.text('已经是第一集'), findsNothing);
      expect(state.position, 0);

      // 6. Past the last episode shows the matching notice, also non-silent.
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await _waitEpisode(tester, state, player, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await _waitEpisode(tester, state, player, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('已经是最后一集'), findsOneWidget);
      expect(state.position, 2);
      await _capture(captureKey, 'desktop-edge-last-toast');
      await _hold('edge-last-toast');

      // 7. A second visit to the player must not replay the consumed hint.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 300));
      final detail2 = await runtime.catalog.detail('123');
      final captureKey2 = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey2,
          child: MaterialApp(
            navigatorObservers: [macPlaybackRoutes],
            home: PlayerPage(runtime: runtime, detail: detail2),
          ),
        ),
      );
      await tester.pump();
      final dynamic state2 = tester.state(find.byType(PlayerPage));
      final player2 = state2.player as Player;
      await player2.setVolume(0);
      for (var i = 0; i < 250; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (!state2.preparing &&
            state2.error == null &&
            player2.state.width == 160) {
          break;
        }
      }
      expect(state2.error, isNull);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text(desktopHint), findsNothing);
      expect(find.text(mobileHint), findsNothing);
      await _capture(captureKey2, 'desktop-reentry-no-hint');
      await _hold('reentry-no-hint');
      await player2.pause();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await state2.platformUpdates;
      await runtime.dispose();
      print(
        'DESKTOP_SWIPE_ACCEPTANCE=desktop hint copy; mouse drag and wheel keep the episode; keys and touch switch; both edge toasts shown then retired; hint consumed once and not replayed',
      );
    },
  );

  testWidgets('macOS search box focus opens the desktop suggestion panel', (
    tester,
  ) async {
    final runtime = _Runtime(
      await _loadAsset(),
      Directory.systemTemp.createTempSync('hongguo-desktop-search-'),
      settings: const AppSettings(
        autoNext: false,
        prefetchEnabled: false,
        backgroundPlaybackPrompted: true,
        floatingPlaybackPrompted: true,
      ),
    );
    for (final query in ['q1', 'q2', 'q3', 'q4']) {
      await runtime.searchHistory.record(query);
    }
    await runtime.searchHistory.flush();
    final captureKey = GlobalKey();
    await windowManager.ensureInitialized();
    await windowManager.show();
    await windowManager.focus();
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: ProviderScope(
          overrides: [runtimeProvider.overrideWith((_) async => runtime)],
          child: const HongguoApp(),
        ),
      ),
    );
    for (
      var i = 0;
      i < 150 && find.byType(LibraryPage).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(LibraryPage), findsOneWidget);
    await tester.pumpAndSettle();
    await _capture(captureKey, 'desktop-home');
    await _hold('desktop-home');

    Future<int> historyRowCount() async => find
        .byWidgetPredicate(
          (widget) =>
              widget is ListTile &&
              widget.key is ValueKey<String> &&
              (widget.key as ValueKey<String>).value.startsWith(
                'search-history-',
              ) &&
              !(widget.key as ValueKey<String>).value.contains('-remove-'),
        )
        .evaluate()
        .length;

    // Focusing the search box opens the dropdown panel on the desktop too.
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('search-suggestions')),
      findsOneWidget,
      reason: 'The suggestion panel must open from a focus on macOS',
    );
    expect(find.text('最近搜索'), findsOneWidget);
    expect(
      await historyRowCount(),
      3,
      reason: 'Only the newest three queries are shown',
    );
    expect(find.byKey(const ValueKey('search-history-q4')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-history-q3')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-history-q2')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-history-q1')), findsNothing);
    expect(find.text('最新与热门'), findsOneWidget);
    expect(find.byKey(const ValueKey('search-suggest-9001')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-suggest-9002')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('search-suggest-mark-9001')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('search-suggest-mark-9002')),
      findsOneWidget,
    );
    await _capture(captureKey, 'desktop-search-panel');
    await _hold('search-panel-open');

    // Per-row deletion works.
    await tester.tap(find.byKey(const ValueKey('search-history-remove-q4')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-history-q4')), findsNothing);
    expect(await historyRowCount(), 2);
    expect(find.byKey(const ValueKey('search-suggestions')), findsOneWidget);
    await _capture(captureKey, 'desktop-search-history-deleted');

    // Tapping a history row runs the search.
    await tester.tap(find.byKey(const ValueKey('search-history-q3')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('search-suggestions')),
      findsNothing,
      reason: 'Executing a search dismisses the panel',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'q3',
    );
    expect(find.text('搜索结果'), findsOneWidget);
    await _capture(captureKey, 'desktop-search-from-history');
    await _hold('search-from-history');

    // Tapping a ranked suggestion row opens its detail page directly.
    await tester.tap(find.text('清除搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-suggestions')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search-suggest-9002')));
    await tester.pumpAndSettle();
    expect(find.byType(DetailPage), findsOneWidget);
    expect(find.text('桌面搜索热门剧'), findsOneWidget);
    await _capture(captureKey, 'desktop-detail-from-suggestion');
    await _hold('detail-from-suggestion');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(DetailPage), findsNothing);
    expect(find.byType(LibraryPage), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await runtime.dispose();
    print(
      'DESKTOP_SEARCH_ACCEPTANCE=focus opens panel on macOS; 3-row history cap; per-row delete; history row executes search; suggestion row opens detail',
    );
  });
}
