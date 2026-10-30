/// The 榜单 module's vocabulary and payload.
///
/// Everything here is read from one response: `cell/change/v` returns the cards
/// and, in the same `cell_view`, the `cell_selector` tree that names every
/// 赛道 and every 榜 block under it. Four live samples measured 22-27 blocks
/// across five tracks, with one track missing its sub-selector entirely, so no
/// count, name or id in this file may be pinned by the client (the seed track
/// below is a request argument, not a vocabulary).
library;

import 'catalog.dart';

/// A 榜 block inside one 赛道 (`sub_selected_items`). `selected` is upstream's
/// own mark for the block it served when the tree was asked for without one, so
/// a client can name the default board without inventing it.
class RankBoard {
  final String id, label;
  final bool selected;
  const RankBoard(this.id, this.label, {this.selected = false});
}

/// A 赛道 published by `cell_selector.outer_row` (`selected_items`).
class RankTrack {
  final String id, label;
  final List<RankBoard> boards;
  final bool selected;
  const RankTrack(this.id, this.label, this.boards, {this.selected = false});
}

/// One ranked card.
///
/// `position` is the array index, because upstream sends no rank field. The
/// display strings keep upstream's own wording (`6182万热度`, `38万收藏`, `爆剧`,
/// `恋爱·全99集`) so the page cannot invent a number the response did not give.
/// `play_cnt` is deliberately absent: it disagreed with `rec_text_item` by four
/// orders of magnitude on the same card, and one card may state one 热度.
class RankEntry {
  final Drama drama;
  final int position;
  final String? heat, collect, score, badge, subtitle, dominateColor;
  const RankEntry({
    required this.drama,
    required this.position,
    this.heat,
    this.collect,
    this.score,
    this.badge,
    this.subtitle,
    this.dominateColor,
  });
}

class RankPage {
  final List<RankEntry> entries;
  final String? nextCursor;

  /// `rank_version`, which upstream sends as whole-minute epoch seconds — and
  /// as an empty string on 推荐榜. Null means the board makes no time claim.
  final DateTime? updatedAt;
  final List<RankTrack> tracks;

  /// Cards this board sent that are not episodes of a drama — the 演员 track
  /// ranks people, and its rows do not parse. Counted rather than dropped
  /// silently, so a page can say 「这一榜的条目不是剧」 instead of calling a board
  /// that answered twenty rows "empty".
  final int unrecognizedCards;
  const RankPage({
    this.entries = const [],
    this.nextCursor,
    this.updatedAt,
    this.tracks = const [],
    this.unrecognizedCards = 0,
  });
}

abstract interface class RankCatalogRepository implements CatalogRepository {
  /// One page of one 榜. `track` and `board` are `selected_items` and
  /// `sub_selected_items`, both read from the vocabulary this same response
  /// carries; calling with no arguments asks for the seed track and whatever
  /// board upstream considers default, which is how a client discovers the tree.
  Future<RankPage> rankBoard({
    String track = rankSeedTrack,
    String? board,
    String? cursor,
  });
}

final _selectorId = RegExp(r'^[a-z0-9_]{1,64}$');

/// `cell_selector` → tracks, keeping upstream's `show_name` and ids. A track
/// with no sub-selector yields no boards; the caller decides whether to draw
/// it, because upstream publishing an empty track is a normal outcome.
List<RankTrack> parseRankTracks(Map<String, dynamic> cellSelector) {
  final rows = _asMap(cellSelector['outer_row']);
  final tracks = <RankTrack>[];
  for (final value in _asList(rows['items'])) {
    final item = _asMap(value);
    final id = '${item['selector_item_id'] ?? ''}';
    if (id.isEmpty) continue;
    final sub = _asMap(item['sub_cell_selector']);
    final boards = <RankBoard>[];
    for (final board in _asList(_asMap(sub['outer_row'])['items'])) {
      final entry = _asMap(board);
      final boardId = '${entry['selector_item_id'] ?? ''}';
      if (boardId.isEmpty) continue;
      boards.add(
        RankBoard(
          boardId,
          '${entry['show_name'] ?? ''}',
          selected: entry['is_selected'] == true,
        ),
      );
    }
    tracks.add(
      RankTrack(
        id,
        '${item['show_name'] ?? ''}',
        boards,
        selected: item['is_selected'] == true,
      ),
    );
  }
  return List.unmodifiable(tracks);
}

/// One `cell_data` entry → a ranked card. `video_data[0]` holds both the drama
/// and the rank-only signals, so the position comes from the caller's index.
RankEntry parseRankCard(Map<String, dynamic> value, int position) {
  var raw = value['video_data'];
  if (raw is List) raw = raw.firstOrNull;
  final card = _asMap(raw).isNotEmpty ? _asMap(raw) : value;
  final rec = _asMap(card['rec_text_item']);
  final secondary = _asList(card['secondary_info_list']).map(_asMap);
  final collects = secondary
      .map((e) => '${e['content'] ?? ''}')
      .where((text) => text.contains('收藏'))
      .toList();
  final color = '${card['color_dominate'] ?? ''}';
  return RankEntry(
    position: position,
    drama: Drama.fromJson(value),
    heat: _blankToNull(rec['RecommendText']),
    collect: _blankToNull(collects.firstOrNull),
    score: _blankToNull(card['score']),
    badge: _blankToNull(_asMap(card['tag_info'])['text']),
    subtitle: _blankToNull(card['sub_title']),
    dominateColor:
        RegExp(r'^#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').hasMatch(color)
        ? color
        : null,
  );
}

/// `rank_version` → a timestamp. Empty, unparseable, or implausibly old values
/// (samples showed epoch seconds ~2026) become null rather than a fake "实时".
DateTime? parseRankVersion(dynamic value) {
  final seconds = int.tryParse('${value ?? ''}');
  if (seconds == null || seconds < 1000000000) return null;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

/// The track used only to obtain the first vocabulary read. Upstream marks one
/// track `is_selected`; asking for the 漫剧 domain keeps today's served content
/// while the response itself supplies the real track list.
const rankSeedTrack = 'comic_series_rank';

/// The one rank cell that publishes the whole 赛道 × 榜 tree (`tab_type` 26).
/// Every name, id and count under it comes from the response, not from here.
const rankCellId = '7470092475068071998';

String validateSelectorId(String value, String name) {
  if (!_selectorId.hasMatch(value)) {
    throw ArgumentError.value(value, name, '不是上游发布的标识');
  }
  return value;
}

Map<String, dynamic> _asMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<dynamic> _asList(dynamic value) => value is List ? value : [];
String? _blankToNull(dynamic value) {
  final text = '${value ?? ''}'.trim();
  return text.isEmpty ? null : text;
}
