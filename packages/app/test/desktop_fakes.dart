import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'fakes.dart';

/// The runtime the mouse family is tested against: the whole `selector_rows`
/// panel, a filtered browse that records the query it was given, and a 赛道 tree
/// whose default board is not the one the drill asks for.
///
/// It lives here rather than in one test file because every desktop promise is
/// spelled against these same keys -- 排序, 更多筛选, the capped 主题 row and the
/// hover preview -- and a second copy would be a second vocabulary to keep honest.
class DesktopCatalog extends FakeCatalog
    implements FilteredCatalogRepository, RankCatalogRepository {
  final filtered = <CatalogQuery>[];
  final rankRequests = <(String track, String? board)>[];

  @override
  Future<List<CatalogDim>> filterRows(String genre) async => [
    CatalogDim(
      key: categoryThemeKey,
      label: catalogDimRowNames[categoryThemeKey]!,
      items: themeItems,
    ),
    const CatalogDim(
      key: 'category_dim_role',
      label: '设定',
      items: [CatalogFilter('穿越', 'role_1'), CatalogFilter('重生', 'role_2')],
    ),
    const CatalogDim(
      key: 'gender',
      label: '受众',
      items: [CatalogFilter('男频', 'gender_1')],
    ),
  ];

  /// Twelve of them, so the row has to give its tail to 更多 ▾ rather than ask a
  /// pointer to slide a list sideways.
  static const themeItems = [
    CatalogFilter('玄幻', 'cate_7'),
    CatalogFilter('都市', 'cate_8'),
    CatalogFilter('悬疑', 'cate_9'),
    CatalogFilter('古风', 'cate_10'),
    CatalogFilter('甜宠', 'cate_11'),
    CatalogFilter('复仇', 'cate_12'),
    CatalogFilter('萌宝', 'cate_13'),
    CatalogFilter('年代', 'cate_14'),
    CatalogFilter('商战', 'cate_15'),
    CatalogFilter('战神', 'cate_16'),
    CatalogFilter('赘婿', 'cate_17'),
    CatalogFilter('神豪', 'cate_18'),
  ];

  @override
  Future<CatalogPage> browseFiltered(CatalogQuery query) async {
    filtered.add(query);
    lastGenre = query.genre;
    lastSort = query.sort;
    return cursorPage(query.cursor);
  }

  CatalogPage cursorPage(String? cursor) => cursor == null
      ? CatalogPage([FakeCatalog.demo], nextCursor: '18')
      : const CatalogPage([Drama(id: '124', title: '第二个故事', episodeCount: 2)]);

  @override
  Future<RankPage> rankBoard({
    String track = rankSeedTrack,
    String? board,
    String? cursor,
  }) async {
    rankRequests.add((track, board));
    return const RankPage(
      tracks: [
        RankTrack('human', '真人剧', [
          RankBoard('human_hot_play', '热播榜'),
          // 上游这次默认的是新剧榜：所以那次 热播榜 请求是下钻自己命名的，不是
          // 顺着默认榜躺出来的。
          RankBoard('human_new', '新剧榜', selected: true),
        ]),
        RankTrack('comic_series_rank', '漫剧', [
          RankBoard('comic_series_hot_play', '热播榜'),
        ]),
        RankTrack('actor', '演员', []),
      ],
    );
  }
}

/// A 词表 that answers the drawer without a row the page is documented to offer
/// -- the 「词表缺行」 state, where nothing may be invented.
class UnfilteredCatalog extends DesktopCatalog {
  @override
  Future<List<CatalogDim>> filterRows(String genre) async => const [];
}

/// The card the hover preview reads: upstream's genre words live in
/// `category_schema`, which `Drama.tagNames` is made of.
class TaggedCatalog extends DesktopCatalog {
  final List<String> tags;
  TaggedCatalog(this.tags);

  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) async {
    lastGenre = genre;
    lastSort = sort;
    lastTheme = theme;
    browseCalls++;
    return CatalogPage([
      Drama(
        id: 'tagged',
        title: '剧名',
        intro: '一段关于相遇的故事',
        episodeCount: 12,
        tagNames: tags,
      ),
    ], nextCursor: '18');
  }
}

/// The app on a Mac-sized surface.
///
/// `desktopHost` is read from the platform, and `flutter_test`'s default is
/// android -- so overriding it is the whole of "pretend to be a desktop", and it
/// has to be undone inside the test body, not only in a tear-down.
Future<DesktopCatalog> mount(WidgetTester tester, FakeCatalog catalog) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  await tester.binding.setSurfaceSize(const Size(1440, 960));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final runtime = FakeRuntime(catalog)
    ..settings = const AppSettings(autoLoadMore: false);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [runtimeProvider.overrideWith((ref) async => runtime)],
      child: const HongguoApp(),
    ),
  );
  await tester.pumpAndSettle();
  return catalog as DesktopCatalog;
}

/// A pointer that arrives and stays: what `MouseRegion` calls a hover, and the
/// only way the mouse family's preview is supposed to open.
Future<void> hover(WidgetTester tester, Finder target) async {
  final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await pointer.addPointer(location: Offset.zero);
  addTearDown(pointer.removePointer);
  await pointer.moveTo(tester.getCenter(target));
  await tester.pump();
}

Future<void> openSort(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('sort-menu')));
  await tester.pumpAndSettle();
}

/// The one gesture 排序 offers on this family: open the dropdown, choose a 档.
/// A test that wants the promise 「换排序不换页」 asks for it this way rather than
/// hunting for a chip that only the touch family has.
Future<void> sortTo(WidgetTester tester, String sortKey) async {
  await openSort(tester);
  await tester.tap(find.byKey(ValueKey('sort-$sortKey')));
  await tester.pumpAndSettle();
}
