import 'package:hongguo_api/hongguo_api.dart';

import '../platform/runtime_contract.dart';

/// One page of recommendations plus the relation that produced it.
///
/// [relation] is either 同题材 (the browse call was filtered by that theme) or
/// 平台热门 (the call asked for `sort=hot_score`) — each label claims exactly
/// what its request asked for, the same rule as `search_suggestions.dart:15-17`.
/// There is no trustworthy `published_at`/`score` on list rows, so this type
/// deliberately carries no 最新/热度 mark or ordering hint
/// (docs/design/2026-10-22-detail-page-and-download-policy.md §3.1).
class RelatedDramas {
  final String relation;
  final String themeName;
  final List<Drama> items;
  const RelatedDramas({
    this.relation = '同题材',
    this.themeName = '',
    this.items = const [],
  });

  const RelatedDramas.hot({this.items = const []})
    : relation = '平台热门',
      themeName = '';
}

/// Reads recommendations for a detail page through the catalog.
///
/// The drama's upstream genre names are mapped onto the theme panel
/// (`catalog.themes`, already memory-cached 6h by the client) and the first
/// matching theme seeds one browse page; a row with no genre name on the panel
/// falls back to the `hot_score` board. The current drama is always excluded by
/// id. Results stay in memory with a short freshness window and are never
/// written to LibraryCache — a stale row on a detail page would lie about what
/// is related today (same policy as search_suggestions.dart). Failures or an
/// empty upstream page return empty [RelatedDramas.items] so the UI simply
/// omits the block instead of showing an error or placeholder.
class RelatedDramaLoader {
  RelatedDramaLoader({DateTime Function()? now}) : now = now ?? DateTime.now;

  static const limit = 12;
  static const fresh = Duration(minutes: 10);

  final DateTime Function() now;
  final _saved = <String, ({DateTime at, RelatedDramas value})>{};
  final _pending = <String, Future<RelatedDramas>>{};

  /// Concurrent calls for the same drama share one flight, like the
  /// suggestion boards; in-flight merge lives here, throttling stays in the
  /// 260ms queue inside CatalogClient.
  Future<RelatedDramas> load(
    AppRuntime runtime,
    DramaDetail current, {
    String genre = 'short_play',
  }) {
    final id = current.drama.id;
    if (id.isEmpty) return Future.value(const RelatedDramas());
    final key = '$genre:$id';
    final cached = _saved[key];
    if (cached != null && now().difference(cached.at) < fresh) {
      return Future.value(cached.value);
    }
    return _pending[key] ??= _start(runtime.catalog, current.drama, key, genre);
  }

  Future<RelatedDramas> _start(
    CatalogRepository catalog,
    Drama current,
    String key,
    String genre,
  ) async {
    try {
      final value = await _read(catalog, current, genre);
      if (value.items.isNotEmpty) _saved[key] = (at: now(), value: value);
      return value;
    } on Object catch (_) {
      return const RelatedDramas();
    } finally {
      _pending.remove(key);
    }
  }

  Future<RelatedDramas> _read(
    CatalogRepository catalog,
    Drama current,
    String genre,
  ) async {
    CatalogFilter? theme;
    if (current.tagNames.isNotEmpty) {
      final themes = await catalog.themes(genre);
      for (final tag in current.tagNames) {
        for (final filter in themes) {
          if (filter.name.trim() == tag) {
            theme = filter;
            break;
          }
        }
        if (theme != null) break;
      }
    }
    // A live sample of page one mapped only 1 of 12 rows to a theme name
    // (docs/evidence/related-dramas/live-sample.json), so a row whose genre
    // words are not on the panel falls back to the board the upstream itself
    // ranks, rather than leaving the block out most of the time.
    final page = theme == null
        ? await catalog.browse(genre: genre, sort: 'hot_score')
        : await catalog.browse(genre: genre, theme: theme.id);
    final seen = <String>{current.id};
    final items = <Drama>[];
    for (final drama in page.items) {
      if (drama.id.isEmpty || !seen.add(drama.id)) continue;
      items.add(drama);
      if (items.length >= RelatedDramaLoader.limit) break;
    }
    if (items.isEmpty) return const RelatedDramas();
    return theme == null
        ? RelatedDramas.hot(items: List.unmodifiable(items))
        : RelatedDramas(themeName: theme.name, items: List.unmodifiable(items));
  }
}

/// Process-wide loader: recommendations are device-wide memory-only rows.
final relatedDramaLoader = RelatedDramaLoader();

/// Entry point used by detail pages: same-theme dramas for [current], or the
/// hot board when none of the upstream genre names is on the theme panel.
/// [genre] is the 类型 whose panel the caller maps the words against -- the
/// detail page reads that from the discover page, so the block and the 标签 row
/// cannot claim different things. Empty [RelatedDramas.items] means "do not
/// render the block"; this never throws.
Future<RelatedDramas> loadRelated(
  AppRuntime runtime,
  DramaDetail current, {
  String genre = 'short_play',
}) => relatedDramaLoader.load(runtime, current, genre: genre);
