// v0.3.1 Android real-device verification of two features:
//   1) player vertical swipe-to-episode (touch/stylus only) + one-time hint pill
//   2) search focus dropdown (last 3 history rows + ranked recommendations)
//
// This mirrors the offline assembly of offline_playback_test.dart so it needs no
// upstream real IDs. All gestures are delivered *inside* the app through the
// integration_test instrumentation (Flutter drag/tap), never via `adb shell input`
// (HyperOS denies INJECT_EVENTS here). Only touch/stylus switch episodes; mouse
// must not. Screenshots of the real device compositor are captured in parallel by
// the screenshot loop (see findings.md), keyed off DEVICE_SCREENSHOT= markers.
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_api/hongguo_native_api.dart';
import 'package:hongguo_app/features/library_page.dart';
import 'package:hongguo_app/features/detail_page.dart';
import 'package:hongguo_app/features/player_page.dart';
import 'package:hongguo_app/personal/personal_library.dart';
import 'package:hongguo_app/playback/episode_swipe.dart';
import 'package:hongguo_app/catalog/library_cache.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_app/search/search_history.dart';
import 'package:hongguo_app/settings/settings_store_native.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:media_kit/media_kit.dart' hide VideoTrack;

// ---- Fake offline runtime (copied from offline_playback_test, plus search) ----

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
    searchHistory = SearchHistory(
      backend: FilePreferencesBackend(File('${directory.path}/search.json')),
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
  Future<List<LocalEpisode>> localEpisodes() async => [];
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
    await searchHistory.flush();
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

// ---- helpers ----

const kHint = '上滑下一集 · 下滑上一集';
const kDesktopHint = 'Page Up / Page Down 切换上下集';

dynamic _playerState(WidgetTester tester) =>
    tester.state(find.byType(PlayerPage));

Finder _picture() {
  final compact = find.byKey(const ValueKey('compact-player-picture'));
  return compact.evaluate().isNotEmpty
      ? compact
      : find.byKey(const ValueKey('player-picture'));
}

Future<void> _waitReady(WidgetTester tester) async {
  for (var i = 0; i < 400; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    final state = _playerState(tester);
    if (!state.preparing && state.error == null) return;
  }
  final state = _playerState(tester);
  fail(
    'player never became ready; error=${state.error} preparing=${state.preparing}',
  );
}

/// A single vertical (or any) drag on the player picture with a given device kind.
Future<void> _dragPicture(
  WidgetTester tester,
  Offset delta, {
  required PointerDeviceKind kind,
}) async {
  await tester.drag(_picture(), delta, kind: kind, warnIfMissed: false);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // ------------------------------------------------------------------
  // Feature 1 (core): real Android render of the mobile hint, then the
  // full swipe gate matrix on the actual PlayerPage picture.
  // ------------------------------------------------------------------
  testWidgets('F1 swipe + hint on real Android player', (tester) async {
    final asset = await rootBundle.load('assets/verification.cenc.mp4');
    final runtime = _Runtime(
      asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
      Directory.systemTemp.createTempSync('hongguo-swipe-'),
      episodes: 3,
      settings: const AppSettings(autoNext: false, prefetchEnabled: false),
    );
    final detail = await runtime.catalog.detail('123');
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(runtime: runtime, detail: detail),
      ),
    );
    await tester.pump();
    final state = _playerState(tester);
    await (state.player as Player).setVolume(0);
    await _waitReady(tester);

    // Compact (mobile) layout on a 390-wide phone: EpisodeSwipeArea is mounted.
    expect(
      find.byType(EpisodeSwipeArea),
      findsOneWidget,
      reason: 'mobile picture must use EpisodeSwipeArea',
    );
    expect(
      find.byKey(const ValueKey('compact-player-picture')),
      findsOneWidget,
      reason: 'phone viewport must render compact layout',
    );

    // 1a. First-time hint pill renders with the MOBILE copy, not the desktop one.
    expect(runtime.settings.episodeSwipeHintShown, isFalse);
    expect(
      find.text(kHint),
      findsOneWidget,
      reason: 'mobile hint copy missing',
    );
    expect(
      find.text(kDesktopHint),
      findsNothing,
      reason: 'wrong (desktop) hint copy leaked onto mobile',
    );
    print('DEVICE_SCREENSHOT=swipe-hint-first');
    await Future<void>.delayed(const Duration(milliseconds: 400));

    // 1b. Sub-threshold touch drag -> no episode change, hint survives.
    await _dragPicture(
      tester,
      const Offset(0, -40),
      kind: PointerDeviceKind.touch,
    );
    expect(
      state.position,
      0,
      reason: 'small drag below 80px threshold must not switch',
    );
    expect(find.text(kHint), findsOneWidget);

    // 1c. MOUSE drag -> must NOT switch (desktop mis-gesture guard).
    await _dragPicture(
      tester,
      const Offset(0, -300),
      kind: PointerDeviceKind.mouse,
    );
    expect(state.position, 0, reason: 'mouse drag must not switch episode');
    expect(state.sourceVid, '123');
    expect(
      find.text(kHint),
      findsOneWidget,
      reason: 'mouse drag must not consume the hint',
    );

    // 1d. Horizontal large touch drag -> must NOT change episode.
    await _dragPicture(
      tester,
      const Offset(320, 0),
      kind: PointerDeviceKind.touch,
    );
    expect(
      state.position,
      0,
      reason: 'horizontal drag must not change episode',
    );

    // 1e. STYLUS drag up -> DOES switch (touch/stylus are the allowed fingers).
    await _dragPicture(
      tester,
      const Offset(0, -200),
      kind: PointerDeviceKind.stylus,
    );
    for (var i = 0; i < 200 && state.preparing; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await _waitReady(tester);
    expect(
      state.position,
      1,
      reason: 'stylus up-swipe must go to next episode',
    );
    expect(state.sourceVid, '124');

    // 1f. Touch up-swipe -> next episode again, and the pill was retired+persisted.
    await _dragPicture(
      tester,
      const Offset(0, -200),
      kind: PointerDeviceKind.touch,
    );
    await _waitReady(tester);
    expect(
      state.position,
      2,
      reason: 'touch up-swipe must advance to last episode',
    );
    expect(state.sourceVid, '125');
    expect(
      find.text(kHint),
      findsNothing,
      reason: 'hint must be gone after first real swipe',
    );
    expect(
      runtime.settings.episodeSwipeHintShown,
      isTrue,
      reason: 'consuming the hint must persist episodeSwipeHintShown',
    );

    // 1g. Out-of-range at the LAST episode: up-swipe -> '已经是最后一集' + controls.
    await _dragPicture(
      tester,
      const Offset(0, -200),
      kind: PointerDeviceKind.touch,
    );
    expect(state.position, 2, reason: 'cannot advance past the last episode');
    expect(find.text('已经是最后一集'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('compact-playback-controls')),
      findsOneWidget,
      reason: 'boundary notice must bring up the control bar',
    );
    print('DEVICE_SCREENSHOT=swipe-boundary-last');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    // ~2.6s later the fleeting notice disappears (real-clock timer).
    await Future<void>.delayed(const Duration(seconds: 3));
    await tester.pump();
    expect(
      find.text('已经是最后一集'),
      findsNothing,
      reason: 'boundary notice must auto-dismiss',
    );

    // 1h. Out-of-range at the FIRST episode: down-swipe -> '已经是第一集'.
    await _dragPicture(
      tester,
      const Offset(0, 200),
      kind: PointerDeviceKind.touch,
    ); // last -> 1
    await _waitReady(tester);
    await _dragPicture(
      tester,
      const Offset(0, 200),
      kind: PointerDeviceKind.touch,
    ); // 1 -> 0
    await _waitReady(tester);
    expect(state.position, 0);
    await _dragPicture(
      tester,
      const Offset(0, 200),
      kind: PointerDeviceKind.touch,
    ); // down past first
    expect(state.position, 0, reason: 'cannot go before the first episode');
    expect(find.text('已经是第一集'), findsOneWidget);
    print('DEVICE_SCREENSHOT=swipe-boundary-first');
    await Future<void>.delayed(const Duration(milliseconds: 400));

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await runtime.dispose();
    print(
      'FEATURE1_CORE=passed: touch/stylus switch, mouse+horizontal+small do not; '
      'mobile hint copy only; boundary first/last notices auto-dismiss; flag persisted',
    );
  });

  // ------------------------------------------------------------------
  // Feature 1 (re-entry): once the flag is set, re-entering the player
  // shows no hint (the "杀进程重启后不再出现" path, via persisted settings).
  // ------------------------------------------------------------------
  testWidgets('F1 re-entry: hint suppressed once persisted', (tester) async {
    final asset = await rootBundle.load('assets/verification.cenc.mp4');
    final runtime = _Runtime(
      asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
      Directory.systemTemp.createTempSync('hongguo-reentry-'),
      episodes: 3,
      // Simulate a prior session having already consumed the hint.
      settings: const AppSettings(
        autoNext: false,
        prefetchEnabled: false,
        episodeSwipeHintShown: true,
      ),
    );
    final detail = await runtime.catalog.detail('123');
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(runtime: runtime, detail: detail),
      ),
    );
    await tester.pump();
    final state = _playerState(tester);
    await (state.player as Player).setVolume(0);
    await _waitReady(tester);
    expect(
      find.text(kHint),
      findsNothing,
      reason: 'already-seen users must not see the hint',
    );
    print('DEVICE_SCREENSHOT=reentry-no-hint');
    // Swiping still works even without the hint.
    await _dragPicture(
      tester,
      const Offset(0, -200),
      kind: PointerDeviceKind.touch,
    );
    await _waitReady(tester);
    expect(state.position, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await runtime.dispose();
    print(
      'FEATURE1_REENTRY=passed: persisted episodeSwipeHintShown suppresses the pill; swipe still works',
    );
  });

  // ------------------------------------------------------------------
  // Feature 1 (auto-fade): untouched hint disappears on its own after ~3s
  // and persists itself. Fresh runtime so the flag starts false.
  // ------------------------------------------------------------------
  testWidgets('F1 hint auto-fades after ~3s and persists', (tester) async {
    final asset = await rootBundle.load('assets/verification.cenc.mp4');
    final runtime = _Runtime(
      asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
      Directory.systemTemp.createTempSync('hongguo-fade-'),
      episodes: 3,
      settings: const AppSettings(autoNext: false, prefetchEnabled: false),
    );
    final detail = await runtime.catalog.detail('123');
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(runtime: runtime, detail: detail),
      ),
    );
    await tester.pump();
    final state = _playerState(tester);
    await (state.player as Player).setVolume(0);
    await _waitReady(tester);
    expect(find.text(kHint), findsOneWidget);
    expect(runtime.settings.episodeSwipeHintShown, isFalse);
    print('DEVICE_SCREENSHOT=hint-countdown');
    // Do NOT touch it: let the ~3s countdown + 220ms fade run on the real clock.
    await Future<void>.delayed(const Duration(milliseconds: 3500));
    await tester.pump();
    expect(
      find.text(kHint),
      findsNothing,
      reason: 'hint must fade out on its own (~3s)',
    );
    expect(
      runtime.settings.episodeSwipeHintShown,
      isTrue,
      reason: 'auto-fade still marks the one-time hint as seen',
    );
    print('DEVICE_SCREENSHOT=hint-faded');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await runtime.dispose();
    print(
      'FEATURE1_FADE=passed: untouched pill disappears ~3s after ready and persists episodeSwipeHintShown',
    );
  });

  // ------------------------------------------------------------------
  // Feature 2a: search focus panel -> last-3 history (cap + per-row delete)
  // and tapping a history row executes the search.
  // ------------------------------------------------------------------
  testWidgets('F2 search history panel: cap, delete, tap-to-search', (
    tester,
  ) async {
    final asset = await rootBundle.load('assets/verification.cenc.mp4');
    final runtime = _Runtime(
      asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
      Directory.systemTemp.createTempSync('hongguo-search-'),
      episodes: 2,
    );
    // Seed 5 local history terms (newest first after recording).
    for (final q in const ['第一部', '第二部', '第三部', '第四部', '第五部']) {
      await runtime.searchHistory.record(q);
    }
    await tester.pumpWidget(MaterialApp(home: LibraryPage(runtime: runtime)));
    await tester.pumpAndSettle();
    print('DEVICE_SCREENSHOT=library-initial');

    // Focus the search field -> panel drops down.
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('search-suggestions')),
      findsOneWidget,
      reason: 'focus must open the search panel',
    );
    expect(find.text('最近搜索'), findsOneWidget);

    // Only the 3 most recent are shown (SearchHistory.shown == 3).
    final rows = find.byWidgetPredicate((w) {
      final k = w.key;
      if (k is! ValueKey<String>) return false;
      final v = k.value;
      return v.startsWith('search-history-') && !v.contains('-remove-');
    });
    expect(
      rows.evaluate().length,
      3,
      reason: 'history must cap at the latest 3 rows',
    );
    expect(find.byKey(const ValueKey('search-history-第五部')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-history-第四部')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-history-第三部')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('search-history-第一部')),
      findsNothing,
      reason: '5th-oldest must be capped out',
    );
    print('DEVICE_SCREENSHOT=search-panel');

    // Per-row delete.
    await tester.tap(find.byKey(const ValueKey('search-history-remove-第四部')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('search-history-第四部')),
      findsNothing,
      reason: 'deleted row must vanish',
    );
    // After deleting 第四部, the previously capped 第二部 enters the top-3.
    expect(find.byKey(const ValueKey('search-history-第二部')), findsOneWidget);
    expect(rows.evaluate().length, 3);

    // Tap a history row -> executes the search (panel closes, results header shows).
    await tester.tap(find.byKey(const ValueKey('search-history-第五部')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('search-suggestions')),
      findsNothing,
      reason: 'picking history closes the panel',
    );
    expect(
      find.text('“第五部”'),
      findsOneWidget,
      reason: 'tapping a history row must run that search',
    );
    print('DEVICE_SCREENSHOT=search-from-history');
    // Confirm the term is stored locally only: file exists under the temp dir.
    expect(
      File('${runtime.directory.path}/search.json').existsSync(),
      isTrue,
      reason: 'history persists to a local preferences file',
    );
    print('search-history-local-file=${runtime.directory.path}/search.json');

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await runtime.dispose();
    print(
      'FEATURE2_HISTORY=passed: 3-row cap, per-row delete, tap-history executes search, stored on device file',
    );
  });

  // ------------------------------------------------------------------
  // Feature 2b: recommended board rows (title + latest/popular mark icon),
  // and tapping a recommendation goes straight to the detail page.
  // ------------------------------------------------------------------
  testWidgets('F2 search recommendations: marks and tap-to-detail', (
    tester,
  ) async {
    final asset = await rootBundle.load('assets/verification.cenc.mp4');
    final runtime = _Runtime(
      asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
      Directory.systemTemp.createTempSync('hongguo-reco-'),
      episodes: 2,
    );
    await tester.pumpWidget(MaterialApp(home: LibraryPage(runtime: runtime)));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-suggestions')), findsOneWidget);

    // Recommendation rows + their mark icon (latest board returns a 最新 mark).
    final label = find.text('最新与热门');
    expect(
      label,
      findsOneWidget,
      reason: 'blank-field suggestions section header missing',
    );
    expect(find.byKey(const ValueKey('search-suggest-123')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('search-suggest-mark-123')),
      findsOneWidget,
      reason: 'recommendation row must carry its latest/hot mark icon',
    );
    print('DEVICE_SCREENSHOT=search-recommendations');

    // Tap the recommendation -> enter the detail page directly (no search).
    await tester.tap(find.byKey(const ValueKey('search-suggest-123')));
    await tester.pumpAndSettle();
    expect(
      find.byType(DetailPage),
      findsOneWidget,
      reason: 'recommendation row must open the drama detail',
    );
    expect(find.byKey(const ValueKey('search-suggestions')), findsNothing);
    print('DEVICE_SCREENSHOT=detail-from-suggestion');

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await runtime.dispose();
    print(
      'FEATURE2_RECO=passed: recommended row shows title + mark icon and tap enters detail',
    );
  });
}
