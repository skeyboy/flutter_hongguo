// D-pad reachability for the business pages a TV has to drive without touch:
// 我的 (收藏/历史), 本地缓存 (剧目网格与分集文件) and the TV detail page's
// episode grid. These pages are shared with the phone and desktop builds, so
// the assertions pin the `TvEnvironment` branch rather than the Android flavor.
//
// Controls are exercised through the real key path — a `select` event travelling
// `TvNavigation` -> `TvFocusable` — because `tester.tap` would pass even with the
// remote left holding a focus nobody can see.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_tv/hongguo_tv.dart';
import 'package:hongguo_app/catalog/library_cache.dart';
import 'package:hongguo_app/features/detail_page.dart';
import 'package:hongguo_app/features/local_cache_page.dart';
import 'package:hongguo_app/features/my_page.dart';
import 'package:hongguo_app/features/tv/tv_detail_page.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_app/personal/personal_library.dart';
import 'package:hongguo_app/widgets/drama_card.dart';

import 'fakes.dart';

class _EmptyCatalog extends FakeCatalog {
  @override
  Future<DramaDetail> detail(String id) async =>
      const DramaDetail(FakeCatalog.demo, []);
}

/// Cached files the cache page can list and delete, so the TV branch is tested
/// against the runtime shape the tv flavor actually hands it.
class _CacheRuntime extends FakeRuntime
    implements LocalMediaRuntime, LibraryCacheRuntime {
  @override
  final LibraryCache libraryCache = LibraryCache();
  final files = <LocalEpisode>[];
  @override
  Future<List<LocalEpisode>> localEpisodes() async => List.of(files);
  @override
  PlaybackJob prepareLocal(String vid, {String quality = 'best'}) =>
      throw UnimplementedError();
  @override
  Future<void> evict(String vid, {String quality = 'best'}) async {
    files.removeWhere((e) => e.vid == vid && !e.inUse);
  }
}

/// The app root in the tv flavor: `TvEnvironment` carries the decision and
/// `TvNavigation` is the single key handler, so a page gets the same focus walk
/// it has on the emulator.
Widget _tv(Widget child) => MaterialApp(
  theme: ThemeData(colorScheme: const ColorScheme.dark()),
  builder: (context, inner) =>
      TvEnvironment(enabled: true, child: TvNavigation(child: inner!)),
  home: child,
);

/// The node a named `TvFocusable` walks with. The lookup goes through the
/// widget's `label` rather than the node's debug label, because a page may hand
/// `TvFocusable` a node with a stable id (`tv-detail-play`, which the shipped
/// catalog test pins) and then the two names differ.
List<String> _targets(WidgetTester tester) => tester
    .widgetList<TvFocusable>(find.byType(TvFocusable))
    .map((w) => w.label)
    .toList();

FocusNode? _nodeByLabel(WidgetTester tester, String needle) {
  final candidates = tester.widgetList<TvFocusable>(
    find.byWidgetPredicate((w) => w is TvFocusable && w.label.contains(needle)),
  );
  if (candidates.isEmpty) return null;
  FocusNode? node;
  void scan(Element element) {
    if (node != null) return;
    final widget = element.widget;
    if (widget is Focus && widget.focusNode != null) node = widget.focusNode;
    element.visitChildren(scan);
  }

  tester.element(find.byWidget(candidates.first)).visitChildren(scan);
  return node;
}

String? _focus() => FocusManager.instance.primaryFocus?.debugLabel;

Future<void> _activate(WidgetTester tester, String label) async {
  final node = _nodeByLabel(tester, label);
  expect(
    node,
    isNotNull,
    reason: 'no remote target labelled $label; tree has ${_targets(tester)}',
  );
  node!.requestFocus();
  await tester.pumpAndSettle();
  await tester.sendKeyEvent(LogicalKeyboardKey.select);
  await tester.pumpAndSettle();
}

Future<void> _useTvView(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1920, 1080));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

const _threeEpisodes = DramaDetail(FakeCatalog.demo, [
  Episode(vid: '11', index: 1),
  Episode(vid: '12', index: 2),
  Episode(vid: '13', index: 3),
]);

LocalEpisode _file(String vid, int day) => LocalEpisode(
  vid: vid,
  quality: 'best',
  bytes: 2048,
  modified: DateTime(2026, 10, day),
  inUse: false,
  detail: _threeEpisodes,
);

void main() {
  group('我的', () {
    testWidgets(
      'renders the library as remote targets and opens the TV detail',
      (tester) async {
        await _useTvView(tester);
        final runtime = FakeRuntime();
        final library = personalLibraryFor(runtime);
        await library.toggleFavorite(FakeCatalog.demo);
        await tester.pumpWidget(_tv(MyPage(runtime: runtime)));
        await tester.pumpAndSettle();
        // The page opens on 观看历史; the remote has to be able to switch shelves.
        await _activate(tester, '收藏');

        expect(_nodeByLabel(tester, '收藏'), isNotNull);
        expect(_nodeByLabel(tester, '观看历史'), isNotNull);
        expect(_nodeByLabel(tester, '设置'), isNotNull);
        expect(_nodeByLabel(tester, '山海之间'), isNotNull);
        // Touch-only chrome of the phone layout must not survive on TV: an
        // IconButton or InkWell leaves the remote holding an invisible focus.
        expect(find.byType(IconButton), findsNothing);
        expect(find.byType(InkWell), findsNothing);

        await _activate(tester, '山海之间');
        expect(find.byType(TvDetailPage), findsOneWidget);
        expect(find.byType(DetailPage), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('取消收藏 is its own target and opens nothing', (tester) async {
      await _useTvView(tester);
      final runtime = FakeRuntime();
      final library = personalLibraryFor(runtime);
      await library.toggleFavorite(FakeCatalog.demo);
      await tester.pumpWidget(_tv(MyPage(runtime: runtime)));
      await tester.pumpAndSettle();
      await _activate(tester, '收藏');

      await _activate(tester, '取消收藏');
      expect(library.favorites, isEmpty);
      expect(find.byType(TvDetailPage), findsNothing);
    });

    testWidgets('a cache shortcut with no destination stays out of the walk', (
      tester,
    ) async {
      await _useTvView(tester);
      // FakeRuntime is not a LocalMediaRuntime, so the count reads 当前不可用.
      await tester.pumpWidget(_tv(MyPage(runtime: FakeRuntime())));
      await tester.pumpAndSettle();

      expect(find.text('当前不可用'), findsOneWidget);
      expect(_nodeByLabel(tester, '本地缓存')!.skipTraversal, isTrue);
    });

    testWidgets('history rows keep the resume position and gain a remove key', (
      tester,
    ) async {
      await _useTvView(tester);
      final runtime = FakeRuntime();
      await personalLibraryFor(runtime).record(
        WatchRecord(
          drama: FakeCatalog.demo,
          vid: '11',
          episode: 1,
          positionMs: 42000,
          durationMs: 120000,
          updated: DateTime.now(),
        ),
      );
      await tester.pumpWidget(_tv(MyPage(runtime: runtime)));
      await tester.pumpAndSettle();

      expect(find.textContaining('观看至 0:42'), findsOneWidget);
      expect(_nodeByLabel(tester, '山海之间 继续观看'), isNotNull);
      expect(_nodeByLabel(tester, '移除历史'), isNotNull);
    });

    testWidgets('the phone layout is untouched', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final runtime = FakeRuntime();
      await personalLibraryFor(runtime).toggleFavorite(FakeCatalog.demo);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, inner) =>
              TvEnvironment(enabled: false, child: inner!),
          home: MyPage(runtime: runtime),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏').first);
      await tester.pumpAndSettle();

      expect(find.byType(IconButton), findsWidgets);
      expect(find.byType(ListTile), findsOneWidget);
      expect(find.byType(TvFocusable), findsNothing);
    });
  });

  group('本地缓存', () {
    Future<void> openGrid(WidgetTester tester, _CacheRuntime runtime) async {
      await _useTvView(tester);
      runtime.files.addAll([_file('11', 1), _file('12', 2)]);
      await tester.pumpWidget(_tv(LocalCachePage(runtime: runtime)));
      await tester.pumpAndSettle();
      await _activate(tester, '山海之间');
    }

    testWidgets('the drama grid is a ring that opens the episode page', (
      tester,
    ) async {
      final runtime = _CacheRuntime();
      await _useTvView(tester);
      runtime.files.addAll([_file('11', 1), _file('12', 2)]);
      await tester.pumpWidget(_tv(LocalCachePage(runtime: runtime)));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('local-drama-tv-123')), findsOneWidget);
      expect(find.byType(DramaCard), findsNothing);
      expect(_nodeByLabel(tester, '刷新缓存列表'), isNotNull);
      expect(_nodeByLabel(tester, '补全剧目信息'), isNotNull);

      await _activate(tester, '山海之间');
      expect(find.byType(LocalEpisodesPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('each cached file gets a play and a delete target', (
      tester,
    ) async {
      final runtime = _CacheRuntime();
      await openGrid(tester, runtime);

      expect(find.byType(ListTile), findsNothing);
      expect(_nodeByLabel(tester, '播放'), isNotNull);
      expect(_nodeByLabel(tester, '删除缓存'), isNotNull);
    });

    testWidgets('删除 answers its confirmation with the remote alone', (
      tester,
    ) async {
      final runtime = _CacheRuntime();
      await _useTvView(tester);
      runtime.files.add(_file('11', 1));
      await tester.pumpWidget(_tv(LocalCachePage(runtime: runtime)));
      await tester.pumpAndSettle();
      await _activate(tester, '山海之间');
      await _activate(tester, '删除缓存');

      expect(find.text('删除本地剧集？'), findsOneWidget);
      // The ring starts on 取消, so a stray confirm key cannot delete anything,
      // and the destructive action is one step to the right.
      expect(_focus(), '取消');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(_focus(), '删除');

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(runtime.files, isEmpty);
      expect(find.text('删除本地剧集？'), findsNothing);
    });

    testWidgets('the phone grid keeps the tappable card', (tester) async {
      final runtime = _CacheRuntime();
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      runtime.files.add(_file('11', 1));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, inner) =>
              TvEnvironment(enabled: false, child: inner!),
          home: LocalCachePage(runtime: runtime),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DramaCard), findsOneWidget);
      expect(find.byType(TvFocusable), findsNothing);
    });
  });

  group('TV 详情', () {
    testWidgets('marks and reveals the episode this device left off on', (
      tester,
    ) async {
      await _useTvView(tester);
      final runtime = FakeRuntime();
      await personalLibraryFor(runtime).record(
        WatchRecord(
          drama: FakeCatalog.demo,
          vid: '12',
          episode: 2,
          positionMs: 1000,
          durationMs: 120000,
          updated: DateTime.now(),
        ),
      );
      await tester.pumpWidget(
        _tv(TvDetailPage(runtime: runtime, initial: FakeCatalog.demo)),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('已定位到上次观看的第 2 集'), findsOneWidget);
      final cell = tester.widget<TvFocusable>(
        find.byKey(const ValueKey('episode-pager-tv-cell-1')),
      );
      expect(cell.selected, isTrue);
      expect(_nodeByLabel(tester, '返回目录'), isNotNull);
      // The unreachable AppBar arrow is gone: the route has one back target the
      // ring can hold.
      expect(find.byType(AppBar), findsNothing);
    });

    testWidgets('no watch record leaves every cell unmarked', (tester) async {
      await _useTvView(tester);
      await tester.pumpWidget(
        _tv(TvDetailPage(runtime: FakeRuntime(), initial: FakeCatalog.demo)),
      );
      await tester.pumpAndSettle();

      final cells = tester
          .widgetList<TvFocusable>(find.byType(TvFocusable))
          .where((w) => w.label.startsWith('第 '))
          .toList();
      expect(cells, hasLength(3));
      expect(cells.every((w) => !w.selected), isTrue);
      expect(find.textContaining('已定位到'), findsNothing);
    });

    testWidgets('an empty episode list offers a retry, not a dead button', (
      tester,
    ) async {
      await _useTvView(tester);
      await tester.pumpWidget(
        _tv(
          TvDetailPage(
            runtime: FakeRuntime(_EmptyCatalog()),
            initial: FakeCatalog.demo,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('▶ 开始观看'), findsNothing);
      expect(find.textContaining('暂无可播放的分集'), findsOneWidget);
      expect(_nodeByLabel(tester, '刷新分集'), isNotNull);
      expect(_focus(), contains('刷新分集'));
    });

    testWidgets('the remote walks from the action line into the grid', (
      tester,
    ) async {
      await _useTvView(tester);
      await tester.pumpWidget(
        _tv(TvDetailPage(runtime: FakeRuntime(), initial: FakeCatalog.demo)),
      );
      await tester.pumpAndSettle();
      expect(_focus(), 'tv-detail-play');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      // The node ids are the pager's own (`episode-cell-N`), which is what
      // `episode_pager_tv_page_test` reads too; the ring's label is `第 1 集`.
      expect(_focus(), 'episode-cell-0');
    });
  });
}
