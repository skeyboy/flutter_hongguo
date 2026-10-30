// Read-only live sample for the detail-page 相关推荐 redesign
// (docs/design/video-detail-redesign.md §4). Prints vocabulary hit rates, title
// similarity and per-dimension recall/precision only: no URLs, headers, signed
// parameters, media keys or response bodies are ever written.
//
// The questions, in the order the design needs them:
//   A. 关联到「题材」：只在全部主题一行里找同名（现状）/ 主题∪设定 / 主题∪设定∪背景
//      三种口径各命中几行；命中词在这一页的出现频次（泛词没有区分力）。
//   B. 关联到「标题」：标题字二元组相似度能不能在本页里找出同系列条目。
//   C. 按 selector_item_id 筛，上游 honor 不 honor：返回条目自己带这个词的比例，
//      以及和热门榜的重合度（重合高说明「同题材」其实又是一次热门榜）。
//   D. 跨体裁 id：短剧卡上的叙事词（剧情/反转）只在漫剧/AI 剧词表里发布时，拿那个
//      cate id 去筛短剧还能不能出内容。
//   E. 关联到「标题」的可证形式：面板词直接作为子串出现在标题里，用它筛出来的返回集
//      有多少标题也带这个词（不依赖卡片标签的精度指标）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';

const genres = ['short_play', 'comic_series', 'ai_series'];

/// Content dimensions a 同题材 request may be answered with, most specific
/// first. 背景（都市/现代/古代）几乎每行都有，只当最后的兜底。
const dimPriority = [
  'category_dim_role',
  categoryThemeKey,
  'category_dim_epoch',
];

Future<T> _tries<T>(String label, Future<T> Function() body) async {
  Object? last;
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      return await body();
    } on Object catch (e) {
      last = e;
      stderr.writeln('$label 第 ${attempt + 1} 次失败：$e');
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
  }
  throw StateError('$label 三次都失败：$last');
}

/// 中文短剧标题没有词切分，这里用字二元组的 Jaccard：同一套路（重生/闪婚/赘婿）会共享
/// 连续二字，不相关的大多只剩一两个字重叠。
Set<String> _bigrams(String title) {
  final chars = title
      .replaceAll(RegExp(r'[，。！？、：；·—…\-%（）()\s\d]+'), '')
      .split('');
  final set = <String>{};
  for (var i = 0; i + 1 < chars.length; i++) {
    set.add('${chars[i]}${chars[i + 1]}');
  }
  return set;
}

double _jaccard(Set<String> a, Set<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  return a.intersection(b).length / a.union(b).length.toDouble();
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) throw ArgumentError('Pass an output JSON path.');
  final out = File(args.first).absolute;
  await out.parent.create(recursive: true);
  final rest = args.where((a) => !a.startsWith('--')).skip(1).toList();
  final genre = rest.isNotEmpty ? rest.first : 'short_play';
  if (!genres.contains(genre)) throw ArgumentError('Unknown genre $genre');

  final catalog = CatalogClient(
    dio: Dio(BaseOptions(connectTimeout: const Duration(seconds: 15))),
    deviceId: newCatalogDeviceId(),
  );

  // ---- A. 词表 -------------------------------------------------------------
  final vocab = <String, List<CatalogDim>>{};
  for (final g in genres) {
    vocab[g] = await _tries('filterRows($g)', () => catalog.filterRows(g));
  }

  /// per genre: '<dimKey>|<name>' -> selector_item_id
  final byName = <String, Map<String, String>>{
    for (final g in genres)
      g: {
        for (final row in vocab[g]!)
          for (final item in row.items)
            '${row.key}|${item.name.trim()}': item.id,
      },
  };
  String? idFor(String g, String dim, String name) => byName[g]?['$dim|$name'];

  final page = await _tries(
    'browse($genre)',
    () => catalog.browse(genre: genre),
  );
  final rows = page.items.where((d) => d.id.isNotEmpty).take(18).toList();
  final n = rows.length;

  // 每个词在这一页出现几次：越接近 1 越有区分力，越接近 n 越是泛词
  final df = <String, int>{};
  for (final d in rows) {
    for (final tag in d.tagNames.toSet()) {
      df[tag] = (df[tag] ?? 0) + 1;
    }
  }

  List<String> hitsIn(String g, List<String> dims, List<String> tags) => [
    for (final tag in tags)
      if (dims.any((dim) => idFor(g, dim, tag) != null)) tag,
  ];

  /// 在给定维度里挑「最具体」的一个词：先按维度优先级，再按页内频次小者。
  Map<String, Object?>? pick(String g, List<String> dims, List<String> tags) {
    Map<String, Object?>? best;
    for (final tag in tags) {
      for (final dim in dims) {
        final id = idFor(g, dim, tag);
        if (id == null) continue;
        final rank = dims.indexOf(dim);
        final f = df[tag] ?? n;
        if (best == null ||
            rank < (best['dimRank'] as int) ||
            (rank == (best['dimRank'] as int) && f < (best['df'] as int))) {
          best = {'tag': tag, 'dim': dim, 'dimRank': rank, 'id': id, 'df': f};
        }
      }
    }
    return best;
  }

  final perRow = <Map<String, Object?>>[];
  for (final d in rows) {
    final themeOnly = hitsIn(genre, const [categoryThemeKey], d.tagNames);
    final roleTheme = hitsIn(genre, const [
      'category_dim_role',
      categoryThemeKey,
    ], d.tagNames);
    final allThree = hitsIn(genre, dimPriority, d.tagNames);
    // 这个词别的体裁才发布（本体裁词表里没有同名项）
    final elsewhere = <Map<String, String>>[];
    for (final tag in d.tagNames) {
      if (allThree.contains(tag)) continue;
      for (final other in genres.where((g) => g != genre)) {
        for (final dim in dimPriority) {
          final id = idFor(other, dim, tag);
          if (id != null) {
            elsewhere.add({'tag': tag, 'id': id, 'under': other, 'dim': dim});
          }
        }
      }
    }
    perRow.add({
      'id': d.id,
      'title': d.title,
      'tags': d.tagNames,
      'themeOnly': themeOnly,
      'roleOrTheme': roleTheme,
      'anyDim': allThree,
      'pick': pick(genre, dimPriority, d.tagNames),
      // 有区分力的命中：页内出现不超过 1/3
      'specificPick': roleTheme.isEmpty
          ? null
          : pick(genre, const [
              'category_dim_role',
              categoryThemeKey,
            ], roleTheme.where((t) => (df[t] ?? n) * 3 <= n).toList()),
      'onlyOtherGenre': elsewhere.isEmpty ? null : elsewhere.first,
    });
  }
  int countWhere(bool Function(Map<String, Object?>) test) =>
      perRow.where(test).length;

  final hitRates = {
    'denominator': n,
    'themeOnly_current': countWhere((r) => (r['themeOnly'] as List).isNotEmpty),
    'roleOrTheme': countWhere((r) => (r['roleOrTheme'] as List).isNotEmpty),
    'anyOfThreeDims': countWhere((r) => (r['anyDim'] as List).isNotEmpty),
    'specificNotGeneric': countWhere((r) => r['specificPick'] != null),
    'onlyReachableViaOtherGenre': countWhere(
      (r) => r['onlyOtherGenre'] != null,
    ),
    'noTagAtAll': countWhere((r) => (r['tags'] as List).isEmpty),
  };

  // ---- B. 标题关联 ---------------------------------------------------------
  final seedRow = perRow.first;
  final seedBigrams = _bigrams(seedRow['title'] as String);
  final titleMatches = <Map<String, Object?>>[];
  for (final other in perRow.skip(1)) {
    final score = _jaccard(seedBigrams, _bigrams(other['title'] as String));
    titleMatches.add({
      'title': other['title'],
      'score': double.parse((score * 100).toStringAsFixed(1)),
      'sharesTag': (other['tags'] as List).any(
        (t) => (seedRow['tags'] as List).contains(t),
      ),
    });
  }
  titleMatches.sort(
    (a, b) => (b['score'] as double).compareTo(a['score'] as double),
  );
  final strong = titleMatches
      .where((m) => (m['score'] as double) >= 25)
      .toList();
  final titleStats = {
    'seedTitle': seedRow['title'],
    'seedTags': seedRow['tags'],
    'compared': titleMatches.length,
    'atLeast25pct': strong.length,
    'atLeast25pctAndSharesTag': strong
        .where((m) => m['sharesTag'] == true)
        .length,
    'top6': titleMatches.take(6).toList(),
  };

  // ---- C/D. 维度筛选实测 ---------------------------------------------------
  // 每个 label 拿到的 id 集合留在内存里做集合相等对照，不写进证据文件。
  final idSets = <String, Set<String>>{};
  final pool = <String, Drama>{};
  Future<Map<String, Object?>> probe(
    String label,
    Map<String, List<String>> dims,
  ) async {
    final word = dims.values.expand((e) => e).firstOrNull ?? '';
    try {
      final got = await _tries(
        'browseFiltered($label)',
        () => catalog.browseFiltered(
          CatalogQuery(genre: genre, sort: 'online_time', dims: dims),
        ),
      );
      final ids = got.items.map((d) => d.id).toSet();
      idSets[label] = ids;
      for (final d in got.items) {
        pool.putIfAbsent(d.id, () => d);
      }
      final self = got.items.where((d) => d.tagNames.contains(word)).length;
      final hot = await _tries(
        'browse(hot)',
        () => catalog.browse(genre: genre, sort: 'hot_score'),
      );
      final newest = await _tries(
        'browse(online_time)',
        () => catalog.browse(genre: genre, sort: 'online_time'),
      );
      return {
        'label': label,
        'dims': dims,
        'returned': got.items.length,
        // 卡片自带词永远不等于面板词（docs/evidence/related-dramas 量的就是这件事），
        // 所以这个比例只用来暴露指标本身不可信，不用来判筛选是否生效。
        'selfReportedPct': got.items.isEmpty
            ? null
            : double.parse((self * 100 / got.items.length).toStringAsFixed(1)),
        // 标题里带这个词的比例：不依赖卡片标签的精度指标，只有请求确实按词筛才可能高。
        'titlesContainWordPct': got.items.isEmpty
            ? null
            : double.parse(
                (got.items.where((d) => d.title.contains(word)).length *
                        100 /
                        got.items.length)
                    .toStringAsFixed(1),
              ),
        'overlapWithHot': ids
            .intersection(hot.items.map((d) => d.id).toSet())
            .length,
        'overlapWithNewest': ids
            .intersection(newest.items.map((d) => d.id).toSet())
            .length,
        'titles': got.items.map((d) => d.title).take(6).toList(),
      };
    } on Object catch (e) {
      return {'label': label, 'dims': dims, 'error': '$e'};
    }
  }

  final probes = <Map<String, Object?>>[
    // 对照：不带任何维度，同一 sort——重合度基线
    await probe('对照：同 sort 不带维度', const {}),
  ];
  Map<String, Object?>? pickOf(String key) =>
      perRow.map((r) => r[key]).whereType<Map<String, Object?>>().firstOrNull;
  final specific = pickOf('specificPick');
  if (specific != null) {
    probes.add(
      await probe('有区分力的维度命中', {
        specific['dim'] as String: [specific['id'] as String],
      }),
    );
  }
  final cross = perRow
      .map((r) => r['onlyOtherGenre'])
      .whereType<Map<String, Object?>>()
      .firstOrNull;
  if (cross != null) {
    probes.add(
      await probe('跨体裁 id（只在别的体裁词表里发布）', {
        cross['dim'] as String: [cross['id'] as String],
      }),
    );
  }
  final anyDim = pickOf('pick');
  if (anyDim != null && (anyDim['df'] as int) > 1) {
    probes.add(
      await probe('泛词维度命中（df=${anyDim['df']}）', {
        anyDim['dim'] as String: [anyDim['id'] as String],
      }),
    );
  }

  // 决定性对照：同一维度换两个值。若两个返回集合完全相同，说明上游根本没吃这一维；
  // 若互不相同且都不同于对照，说明筛选生效，selfReportedPct=0 只是卡片词不等于面板词。
  final themeRow = (vocab[genre] ?? const <CatalogDim>[]).firstWhere(
    (row) => row.key == categoryThemeKey,
    orElse: () => const CatalogDim(key: '', label: ''),
  );
  final twoThemeValues = themeRow.items.take(2).map((e) => e.id).toList();
  for (final id in twoThemeValues) {
    final name = themeRow.items.firstWhere((e) => e.id == id).name.trim();
    probes.add(
      await probe('同维度换值：主题·$name', {
        categoryThemeKey: [id],
      }),
    );
  }
  // 标题相关在单页测不出来（17 条彼此不相关），在多页合并的候选池上重测。
  final seedBigramsAll = _bigrams(seedRow['title'] as String);
  final pooledMatches = <Map<String, Object?>>[];
  for (final entry in pool.entries) {
    if (entry.key == seedRow['id']) continue;
    final score = _jaccard(seedBigramsAll, _bigrams(entry.value.title));
    pooledMatches.add({
      'title': entry.value.title,
      'score': double.parse((score * 100).toStringAsFixed(1)),
      'tags': entry.value.tagNames,
    });
  }
  pooledMatches.sort(
    (a, b) => (b['score'] as double).compareTo(a['score'] as double),
  );
  final pooled25 = pooledMatches
      .where((m) => (m['score'] as double) >= 25)
      .toList();
  final pooledStats = {
    'poolSize': pool.length,
    'compared': pooledMatches.length,
    'atLeast25pct': pooled25.length,
    'atLeast15pct': pooledMatches
        .where((m) => (m['score'] as double) >= 15)
        .length,
    'top8': pooledMatches.take(8).toList(),
  };

  // ---- E. 「关联到标题」：面板词直接出现在标题里 ---------------------------
  // 二元组相似度已经否证了「按标题字面找同系列」这条路，剩下的唯一可证形式是：
  // 词表里的词本身就是标题的一个片段（《总裁的小娇妻》含「总裁」）。这样一次
  // select_items 请求同时服务「同题材」和「同标题关键词」，口径仍然只是请求要了什么。
  final panelWords = <String, ({String dim, String id})>{};
  for (final row in vocab[genre] ?? const <CatalogDim>[]) {
    if (!dimPriority.contains(row.key)) continue;
    for (final item in row.items) {
      final name = item.name.trim();
      // 单字无法安全地做子串匹配；「7天内上新」这类时间词也不是内容词。
      if (name.length < 2 || RegExp(r'天|年').hasMatch(name)) continue;
      panelWords.putIfAbsent(name, () => (dim: row.key, id: item.id));
    }
  }
  List<String> wordsIn(String text) => [
    for (final e in panelWords.entries)
      if (text.contains(e.key)) e.key,
  ];
  final titleWordRows = [
    for (final r in perRow)
      {'title': r['title'], 'wordsInTitle': wordsIn(r['title'] as String)},
  ];
  final seedTitleWords = wordsIn(seedRow['title'] as String);
  final recallPerWord = <Map<String, Object?>>[
    for (final w in seedTitleWords)
      {
        'word': w,
        'dim': panelWords[w]!.dim,
        'id': panelWords[w]!.id,
        'df': df[w] ?? 0,
        'poolCandidatesWithSameWord': pool.entries
            .where((e) => e.key != seedRow['id'] && e.value.title.contains(w))
            .length,
      },
  ];
  final titleWordStats = {
    'panelWordCount': panelWords.length,
    'denominator': n,
    'rowsWithAtLeastOneWordInTitle': titleWordRows
        .where((r) => (r['wordsInTitle'] as List).isNotEmpty)
        .length,
    'seedTitle': seedRow['title'],
    'seedTitleWords': seedTitleWords,
    'recallPerSeedWord': recallPerWord,
    'rows': titleWordRows,
  };
  // 用标题词筛一次，看返回的标题里有多少真的带这个词——这个精度指标不依赖卡片自带标签。
  final titleWordProbe = seedTitleWords.isEmpty
      ? null
      : await probe('标题词：${seedTitleWords.first}', {
          panelWords[seedTitleWords.first]!.dim: [
            panelWords[seedTitleWords.first]!.id,
          ],
        });
  if (titleWordProbe != null) probes.add(titleWordProbe);

  // 集合对照押到最后：每个 label 拿到的 id 集合只留在内存里比对，不写盘。
  final equality = <String, Object?>{};
  final labels = idSets.keys.toList();
  for (var i = 0; i < labels.length; i++) {
    for (var j = i + 1; j < labels.length; j++) {
      final a = idSets[labels[i]]!, b = idSets[labels[j]]!;
      final inter = a.intersection(b).length;
      equality['${labels[i]} ⟷ ${labels[j]}'] = {
        'identical': a.length == b.length && inter == a.length,
        'shared': inter,
        'sizes': [a.length, b.length],
      };
    }
  }

  final report = <String, Object?>{
    'at': DateTime.now().toIso8601String(),
    'note':
        'vocabulary hit rates, title similarity, per-dimension recall and '
        'precision only; no urls, headers, signed parameters, media keys or bodies',
    'genre': genre,
    'publishedRows': {
      for (final g in genres)
        g: [
          for (final row in vocab[g]!)
            {
              'key': row.key,
              'label': row.label,
              'count': row.items.length,
              // id 一起写盘：两次捕获的同一词若 id 变了，就是上游重新发布过词表。
              'items': row.items
                  .map((e) => '${e.name.trim()}|${e.id}')
                  .take(50)
                  .toList(),
            },
        ],
    },
    'hitRates': hitRates,
    'titleRelatedness': titleStats,
    'pooledTitleRelatedness': pooledStats,
    'titleWordRelatedness': titleWordStats,
    'dimFilterProbes': probes,
    'idSetEquality': equality,
    'rows': perRow,
  };
  out.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );

  stdout.writeln(
    jsonEncode({
      'genre': genre,
      'hitRates': hitRates,
      'title': {
        'seed': titleStats['seedTitle'],
        'singlePageAtLeast25pct': titleStats['atLeast25pct'],
        'poolSize': pooledStats['poolSize'],
        'pooledAtLeast25pct': pooledStats['atLeast25pct'],
        'pooledAtLeast15pct': pooledStats['atLeast15pct'],
      },
      'titleWords': {
        'panelWordCount': titleWordStats['panelWordCount'],
        'rowsWithWordInTitle':
            '${titleWordStats['rowsWithAtLeastOneWordInTitle']}/${titleWordStats['denominator']}',
        'seedWords': seedTitleWords,
        'sameWordPoolHits': [
          for (final r in recallPerWord)
            '${r['word']}×${r['poolCandidatesWithSameWord']}',
        ],
      },
      'probes': [
        for (final p in probes)
          {
            'label': p['label'],
            'dims': p['dims'],
            'returned': p['returned'],
            'selfPct': p['selfReportedPct'],
            'titlePct': p['titlesContainWordPct'],
            'ovHot': p['overlapWithHot'],
            'ovNew': p['overlapWithNewest'],
            if (p['error'] != null) 'error': p['error'],
          },
      ],
      'identicalPairs': [
        for (final e in equality.entries)
          if ((e.value as Map)['identical'] == true) e.key,
      ],
    }),
  );
}
