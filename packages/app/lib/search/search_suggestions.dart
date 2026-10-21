import 'package:hongguo_api/hongguo_api.dart';

/// Rows shown under the search box next to the recent terms.
enum SuggestionMark { latest, popular }

/// A recommended drama and the board it was read from.
class Suggestion {
  final Drama drama;
  final SuggestionMark mark;
  const Suggestion(this.drama, this.mark);
}

/// Reads the suggestion rows from the two boards the upstream really ranks.
///
/// There is no recommend call for short drama that carries a publish date or a
/// score, so a mark only claims what its request asked for: newest by
/// `online_time`, or most played by `hot_score`. Results stay in memory with a
/// short freshness window, because a stale row labelled 最新 would be a lie.
class SearchSuggester {
  SearchSuggester({DateTime Function()? now}) : now = now ?? DateTime.now;

  static const boards = [
    (sort: 'online_time', mark: SuggestionMark.latest),
    (sort: 'hot_score', mark: SuggestionMark.popular),
  ];
  static const rows = 6;
  static const fresh = Duration(minutes: 10);

  final DateTime Function() now;
  final _saved = <String, ({DateTime at, List<Suggestion> rows})>{};
  final _pending = <String, Future<List<Suggestion>>>{};

  /// The caller hands over the live client so a rotated device identity is never
  /// used from a cached suggestion list.
  Future<List<Suggestion>> load(
    CatalogRepository catalog, {
    String genre = 'short_play',
  }) {
    final cached = _saved[genre];
    if (cached != null && now().difference(cached.at) < fresh) {
      return Future.value(cached.rows);
    }
    return _pending[genre] ??= _fetch(catalog, genre).then((rows) {
      _pending.remove(genre);
      if (rows.isNotEmpty) _saved[genre] = (at: now(), rows: rows);
      return rows;
    });
  }

  Future<List<Suggestion>> _fetch(
    CatalogRepository catalog,
    String genre,
  ) async {
    final lists = await Future.wait(
      boards.map((board) => _page(catalog, genre, board.sort)),
    );
    final seen = <String>{};
    final rows = <Suggestion>[];
    for (
      var index = 0;
      index < 40 && rows.length < SearchSuggester.rows;
      index++
    ) {
      var remaining = false;
      for (var board = 0; board < lists.length; board++) {
        final items = lists[board];
        if (index >= items.length) continue;
        remaining = true;
        final drama = items[index];
        if (drama.id.isEmpty || drama.title.isEmpty || !seen.add(drama.id)) {
          continue;
        }
        if (rows.length < SearchSuggester.rows) {
          rows.add(Suggestion(drama, boards[board].mark));
        }
      }
      if (!remaining) break;
    }
    return List.unmodifiable(rows);
  }

  Future<List<Drama>> _page(
    CatalogRepository catalog,
    String genre,
    String sort,
  ) async {
    try {
      final page = await catalog.browse(genre: genre, sort: sort);
      return page.items;
    } on Object catch (_) {
      // One board being unavailable must not empty the whole panel.
      return const [];
    }
  }
}
