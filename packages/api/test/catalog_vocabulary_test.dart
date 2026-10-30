import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:test/test.dart';

import 'catalog_retry_test.dart' show ScriptedAdapter, response, page;

/// The panel `landpage/v` publishes per genre. Item names and the `cate_*`
/// theme ids are the sampled values (docs/evidence/ranking-fields/README.md
/// §2); the other ids are shaped like the samples without claiming to be them,
/// because the captures kept row labels and counts, not every item id. One row
/// is deliberately un-mappable so the drop rule is pinned, not assumed.
Map<String, dynamic> panel({
  String artStyleRowType = '',
  bool withComic = true,
}) => {
  'code': 0,
  'data': {
    'selector_rows': [
      {
        'type': 'category_dim_genre',
        'row_name': '全部体裁',
        'items': [
          {'show_name': '漫剧', 'selector_item_id': 'comic_series'},
        ],
      },
      {
        'type': 'category_dim_theme',
        'row_name': '全部主题',
        'selection_type': 1,
        'items': [
          {'show_name': '悬疑', 'selector_item_id': 'cate_165'},
          {'show_name': '玄幻', 'selector_item_id': 'cate_1019'},
        ],
      },
      {
        'row_name': '全部设定',
        'selection_type': 2,
        'items': [
          {'show_name': '穿越', 'selector_item_id': 'cate_2001'},
        ],
      },
      {
        'row_name': '全部背景',
        'items': [
          {'show_name': '古代', 'selector_item_id': 'cate_3001'},
        ],
      },
      {
        'row_name': '全部受众',
        'items': [
          {'show_name': '男频', 'selector_item_id': '1'},
          {'show_name': '女频', 'selector_item_id': '0'},
        ],
      },
      {
        'row_name': '上架时间',
        'items': [
          {'show_name': '近7天', 'selector_item_id': 'days_7'},
        ],
      },
      {
        'row_name': '全部推荐',
        'items': [
          {'show_name': '最新上架', 'selector_item_id': 'online_time'},
        ],
      },
      {
        'row_name': '剧情简介',
        'type': 'synopsis',
        'items': [
          {'show_name': '无 this row cannot be sent', 'selector_item_id': 'x'},
        ],
      },
      if (withComic) ...[
        {
          'type': artStyleRowType,
          'row_name': '全部画风',
          'items': [
            {'show_name': '2D', 'selector_item_id': 'cate_9001'},
          ],
        },
        {
          'row_name': '全部状态',
          'items': [
            {'show_name': '完结', 'selector_item_id': 'creation_status_1'},
          ],
        },
      ],
    ],
  },
};

CatalogClient clientWith(ScriptedAdapter adapter, {DateTime Function()? now}) {
  final dio = Dio()..httpClientAdapter = adapter;
  addTearDown(dio.close);
  return CatalogClient(dio: dio, deviceId: '1234567890123456', now: now);
}

void main() {
  test(
    'every published dimension is read back, keyed by what the body can send',
    () async {
      final adapter = ScriptedAdapter(
        (_, _) async =>
            response(panel(artStyleRowType: 'category_dim_art_style')),
      );
      final client = clientWith(adapter);
      final dims = await client.filterRows('comic_series');
      expect(dims.map((d) => d.key), [
        categoryThemeKey,
        'category_dim_role',
        'category_dim_epoch',
        'gender',
        'online_time',
        'category_dim_art_style',
        'creation_status',
      ]);
      expect(dims.map((d) => d.label), [
        '全部主题',
        '全部设定',
        '全部背景',
        '全部受众',
        '上架时间',
        '全部画风',
        '全部状态',
      ]);
      expect(dims.first.items.map((f) => (f.name, f.id)), [
        ('悬疑', 'cate_165'),
        ('玄幻', 'cate_1019'),
      ]);
      // 单选/多选 is upstream's answer, not a front-end guess: the panel sends it.
      expect(dims.first.selectionType, 1);
      expect(dims[1].selectionType, 2);
      // 体裁 and 推荐 are the L1/L3 layers, 剧情简介 has no request key: none of
      // them belong in the drawer, so all three are dropped.
      expect(
        dims.any((d) => d.key.contains('genre') || d.key == 'synopsis'),
        isFalse,
      );
    },
  );

  test('a row named only in Chinese still lands on its request key', () async {
    final adapter = ScriptedAdapter(
      (_, _) async => response(panel(artStyleRowType: 'art')),
    );
    final client = clientWith(adapter);
    final dims = await client.filterRows('comic_series');
    expect(dims.map((d) => d.key), contains('category_dim_art_style'));
  });

  test(
    '真人剧 draws four sections because upstream publishes four, not a stub',
    () async {
      final adapter = ScriptedAdapter(
        (_, _) async => response(panel(withComic: false)),
      );
      final client = clientWith(adapter);
      final dims = await client.filterRows('short_play');
      expect(dims.map((d) => d.key), [
        categoryThemeKey,
        'category_dim_role',
        'category_dim_epoch',
        'gender',
        'online_time',
      ]);
      expect(dims.any((d) => d.key == 'creation_status'), isFalse);
      // The old single-row read still answers only 主题, so the current two-row
      // interface keeps working while the drawer is built on filterRows().
      expect(await client.themes('short_play'), hasLength(2));
    },
  );

  test('a panel that comes back with no rows keeps the last real one', () async {
    var clock = DateTime.utc(2026, 10, 30);
    var full = true;
    final adapter = ScriptedAdapter(
      (_, _) async => response(
        full
            ? panel()
            : {
                'code': 0,
                'data': {'selector_rows': []},
              },
      ),
    );
    final client = clientWith(adapter, now: () => clock);
    final first = await client.filterRows('comic_series');
    full = false;
    clock = clock.add(const Duration(hours: 7));
    expect(await client.filterRows('comic_series'), first);
    expect(adapter.requests, hasLength(2));
    // A genre that was never answered well has nothing to fall back to, and the
    // empty panel is then the truth: no row is drawn rather than a borrowed one.
    expect(await client.filterRows('ai_series'), isEmpty);
  });

  test(
    'a failed panel still surfaces as an error the page can retry',
    () async {
      var clock = DateTime.utc(2026, 10, 30);
      final adapter = ScriptedAdapter(
        (_, _) async => response({'code': 123, 'message': '暂时不可用'}),
      );
      final client = clientWith(adapter, now: () => clock);
      await expectLater(
        client.filterRows('comic_series'),
        throwsA(isA<CatalogError>()),
      );
    },
  );

  test('browseFiltered fills the keys that were always sent empty', () async {
    final adapter = ScriptedAdapter((_, _) async => response(page));
    final client = clientWith(adapter);
    await client.browseFiltered(
      CatalogQuery(
        genre: 'comic_series',
        sort: 'hot_score',
        dims: const {
          categoryThemeKey: ['cate_165'],
          'category_dim_role': ['cate_2001'],
          'category_dim_epoch': ['cate_3001'],
          'category_dim_art_style': ['cate_9001'],
          'creation_status': ['creation_status_1'],
          'gender': ['0'],
          'online_time': ['days_7'],
        },
        cursor: '18',
        seen: const ['999'],
      ),
    );
    final select =
        adapter.bodies.single['select_items'] as Map<String, dynamic>;
    expect(select.keys.toSet(), {..._allDimKeys, 'genre', 'sort'});
    expect(select['category_dim_art_style'], ['cate_9001']);
    expect(select['creation_status'], ['creation_status_1']);
    expect(select['gender'], ['0']);
    expect(select['online_time'], ['days_7']);
    expect(select['category_dim_role'], ['cate_2001']);
    expect(select['genre'], ['comic_series']);
    expect(select['sort'], ['hot_score']);
    expect(adapter.bodies.single['offset'], 18);
    expect(adapter.bodies.single['filter_ids'], '999');
  });

  test('browseFiltered answers every dimension once: chosen filled, unchosen empty', () async {
    final adapter = ScriptedAdapter((_, _) async => response(page));
    final client = clientWith(adapter);
    await client.browseFiltered(
      CatalogQuery(
        genre: 'comic_series',
        sort: 'hot_collect',
        dims: const {
          categoryThemeKey: ['cate_165'],
          'category_dim_art_style': ['cate_9001'],
        },
      ),
    );
    final select =
        adapter.bodies.single['select_items'] as Map<String, dynamic>;
    // 不限 is an empty array, not an absent key: upstream only accepts the whole
    // row set, so every catalogDimKeys entry is present exactly once.
    expect(select.keys.toSet(), {...catalogDimKeys, 'genre', 'sort'});
    for (final key in catalogDimKeys) {
      expect(select[key], isA<List>(), reason: key);
      expect(
        select[key],
        key == categoryThemeKey || key == 'category_dim_art_style'
            ? isNotEmpty
            : isEmpty,
        reason: key,
      );
    }
    expect(select['category_dim_theme'], ['cate_165']);
    expect(select['category_dim_art_style'], ['cate_9001']);
    expect(select['sort'], ['hot_collect']);
  });

  test('the theme row browse(theme:) writes is the row browseFiltered writes', () async {
    final adapter = ScriptedAdapter((_, _) async => response(page));
    final client = clientWith(adapter);
    await client.browse(genre: 'comic_series', theme: 'cate_165');
    await client.browseFiltered(
      CatalogQuery(
        genre: 'comic_series',
        dims: const {
          categoryThemeKey: ['cate_165'],
        },
      ),
    );
    final l2 = adapter.bodies[0]['select_items'] as Map<String, dynamic>;
    final l2p = adapter.bodies[1]['select_items'] as Map<String, dynamic>;
    // L2′ is built on top of L2; if they landed on different keys the two rows
    // would silently diverge, so pin that both fill the one shared key and
    // leave every other dimension empty.
    for (final select in [l2, l2p]) {
      expect(select[categoryThemeKey], ['cate_165']);
      expect(catalogDimKeys.where((k) => (select[k] as List).isNotEmpty), [
        categoryThemeKey,
      ]);
    }
  });

  test(
    'catalogDimKeysByGenre agrees with what the parser yields for a full panel',
    () async {
      final adapter = ScriptedAdapter(
        (_, body) async => response(
          body['req_scene'] == 'comic_series'
              ? panel(artStyleRowType: 'category_dim_art_style')
              : panel(withComic: false),
        ),
      );
      final client = clientWith(adapter);
      for (final entry in catalogDimKeysByGenre.entries) {
        final dims = await client.filterRows(entry.key);
        expect(
          dims.map((d) => d.key).toSet(),
          entry.value.toSet(),
          reason: entry.key,
        );
      }
    },
  );

  test(
    'a dimension the request cannot carry is refused before sending',
    () async {
      final adapter = ScriptedAdapter((_, _) async => response(page));
      final client = clientWith(adapter);
      await expectLater(
        client.browseFiltered(
          CatalogQuery(
            dims: const {
              'synopsis': ['x'],
            },
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(adapter.requests, isEmpty);
    },
  );

  test('the plain browse path still answers 主题 alone', () async {
    final adapter = ScriptedAdapter((_, _) async => response(page));
    final client = clientWith(adapter);
    await client.browse(genre: 'short_play', theme: 'cate_165');
    final select =
        adapter.bodies.single['select_items'] as Map<String, dynamic>;
    expect(select['category_dim_theme'], ['cate_165']);
    expect(select['category_dim_role'], isEmpty);
  });
}

const _allDimKeys = [
  categoryThemeKey,
  'category_dim_role',
  'category_dim_epoch',
  'category_dim_art_style',
  'creation_status',
  'gender',
  'online_time',
];
