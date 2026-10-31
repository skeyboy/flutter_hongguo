import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/catalog/library_cache.dart';
import 'package:hongguo_app/features/detail_page.dart';
import 'package:hongguo_app/features/library_page.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_app/navigation/catalog_theme_handoff.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'fakes.dart';

/// The detail page under test reads two things the discover page also reads:
/// the drama's own 题材 words and this 类型's 主题 panel. This fake answers both
/// with one word on the panel ('玄幻' → `cate_7`) and one word that is not
/// ('穿越'), which is the pair §3.3 of the design is about.
class TaggedDetailCatalog extends FakeCatalog {
  TaggedDetailCatalog({
    this.tags = const ['玄幻', '穿越'],
    this.panelFailure,
    required this.detailId,
  });

  final List<String> tags;
  final Object? panelFailure;

  /// The recommendation loader is device-wide and caches by drama id, so each
  /// test gets its own: a shared id would let one test read another's answer.
  final String detailId;

  /// Which 类型's panel each page asked for -- the mapping has to follow the
  /// discover page, not a hard-coded type.
  final themesGenres = <String>[];

  /// Every `theme` a browse request carried, in order. The discover page and
  /// the recommendation block share one fake, so only the sequence tells which
  /// of the two asked for `cate_7`.
  final themeRequests = <String?>[];

  /// Every browse request as (类型, 主题). 「同题材 · X」 claims the request was
  /// filtered by that 题材, so the pair has to be one the upstream actually
  /// publishes: an id from this 类型's panel, sent with this 类型.
  final browseRequests = <({String genre, String? theme})>[];

  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) async {
    themeRequests.add(theme);
    browseRequests.add((genre: genre, theme: theme));
    return super.browse(
      genre: genre,
      sort: sort,
      theme: theme,
      cursor: cursor,
      seen: seen,
    );
  }

  @override
  Future<DramaDetail> detail(String id) async => DramaDetail(
    Drama(
      id: detailId,
      title: '山海之间',
      intro: '一段关于相遇的故事',
      episodeCount: 3,
      tagNames: tags,
    ),
    const [
      Episode(vid: '11', index: 1),
      Episode(vid: '12', index: 2),
      Episode(vid: '13', index: 3),
    ],
  );

  @override
  Future<List<CatalogFilter>> themes(String genre) async {
    themesGenres.add(genre);
    if (panelFailure != null) throw panelFailure!;
    return super.themes(genre);
  }
}

/// The handoff is device-wide like the recommendation loader, so an ask left
/// behind by a test cannot be allowed to fire in the next one.
void _resetHandoff() {
  catalogThemeHandoff.take();
  catalogThemeHandoff.genre = 'short_play';
}

Future<TaggedDetailCatalog> _mount(
  WidgetTester tester,
  TaggedDetailCatalog catalog,
) async {
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final runtime = FakeRuntime(catalog)
    ..settings = const AppSettings(autoLoadMore: false);
  addTearDown(runtime.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [runtimeProvider.overrideWith((_) async => runtime)],
      child: const HongguoApp(),
    ),
  );
  await tester.pumpAndSettle();
  return catalog;
}

Future<void> _openDetail(WidgetTester tester) async {
  await tester.tap(find.text('山海之间').last);
  await tester.pumpAndSettle();
  expect(find.byType(DetailPage), findsOneWidget);
}

/// Chips the *discover page* left behind are still in the tree under the pushed
/// detail page, so every count here is taken inside that route.
Finder _chipsInDetail = find.descendant(
  of: find.byType(DetailPage),
  matching: find.byType(ActionChip),
);

/// 推荐块排在折叠线以下时根本还没建，所以先滚到那一行标题，读数才算验过它。
Future<void> _revealBlock(WidgetTester tester, String title) async {
  await tester.scrollUntilVisible(
    find.text(title),
    300,
    scrollable: find
        .descendant(
          of: find.byType(DetailPage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

void main() {
  tearDown(_resetHandoff);

  testWidgets('面板有的词是一枚入口，面板没有的词只是文本', (tester) async {
    await _mount(tester, TaggedDetailCatalog(detailId: 'tag-row-1'));
    await _openDetail(tester);
    expect(
      find.byKey(const ValueKey('detail-tag-entry-cate_7')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('detail-tag-plain-穿越')), findsOneWidget);
    expect(_chipsInDetail, findsOneWidget);
  });

  testWidgets('点入口 pop 回发现页，主题行当场选上这一个', (tester) async {
    final catalog = await _mount(
      tester,
      TaggedDetailCatalog(detailId: 'tag-row-2'),
    );
    await _openDetail(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('detail-tag-entry-cate_7')),
    );
    await tester.tap(find.byKey(const ValueKey('detail-tag-entry-cate_7')));
    await tester.pumpAndSettle();
    expect(find.byType(DetailPage), findsNothing);
    expect(find.byType(LibraryPage), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('theme-rail-cate_7')))
          .selected,
      isTrue,
    );
    expect(catalog.lastTheme, 'cate_7');
    expect(find.textContaining('带着「玄幻」回到主题行'), findsOneWidget);
  });

  testWidgets('词表没回 = 这一页一个入口都不画', (tester) async {
    await _mount(
      tester,
      TaggedDetailCatalog(
        detailId: 'tag-row-3',
        panelFailure: const CatalogError('词表没回'),
      ),
    );
    await _openDetail(tester);
    expect(find.byKey(const ValueKey('detail-tag-plain-玄幻')), findsOneWidget);
    expect(_chipsInDetail, findsNothing);
  });

  testWidgets('标签映射的是发现页正在用的那一型的词表', (tester) async {
    final catalog = await _mount(
      tester,
      TaggedDetailCatalog(detailId: 'tag-row-4'),
    );
    await tester.tap(
      find.byKey(const ValueKey('filter-genre-discover-comic_series')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await _openDetail(tester);
    expect(catalog.themesGenres, contains('comic_series'));
  });

  testWidgets('详情合并后仍带着题材词，推荐块才敢叫「同题材 · X」', (tester) async {
    final catalog = await _mount(
      tester,
      TaggedDetailCatalog(detailId: 'tag-row-5'),
    );
    await _openDetail(tester);
    await _revealBlock(tester, '同题材 · 玄幻');
    expect(catalog.themeRequests, contains('cate_7'));
    expect(find.text('同题材 · 玄幻'), findsOneWidget);
  });

  testWidgets('换了一型之后，标签和推荐块读的是同一张面板', (tester) async {
    final catalog = await _mount(
      tester,
      TaggedDetailCatalog(detailId: 'tag-row-6'),
    );
    await tester.tap(
      find.byKey(const ValueKey('filter-genre-discover-comic_series')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await _openDetail(tester);
    await _revealBlock(tester, '同题材 · 玄幻');
    // 块名说「这次 browse 按该题材筛」，那一次请求就得带着这一型和这一行的 id：
    // 拿 comic_series 面板查到的 id 去筛 short_play 的列表，名字与请求对不上。
    expect(
      catalog.browseRequests,
      contains((genre: 'comic_series', theme: 'cate_7')),
    );
    expect(
      catalog.browseRequests.any(
        (r) => r.theme == 'cate_7' && r.genre != 'comic_series',
      ),
      isFalse,
    );
  });

  test('离线快照把题材词一起存下来', () async {
    final cache = LibraryCache();
    await cache.rememberDetail(
      DramaDetail(
        const Drama(id: 'cached', title: '山海之间', tagNames: ['玄幻', '穿越']),
        const [Episode(vid: 'v1', index: 1)],
      ),
    );
    expect((await cache.readDetail('cached'))!.drama.tagNames, ['玄幻', '穿越']);
  });
}
