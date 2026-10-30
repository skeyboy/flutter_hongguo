import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hongguo_api/hongguo_api.dart';

/// Everything 榜单 owns, kept out of the discover page because the two layers do
/// not answer to each other: `rankBoard(track, board)` takes neither 类型 nor 题
/// 材, so a trip to a board must not write the shared levels behind the viewer's
/// back -- which is exactly what the old 模式 chip did to its own page.
///
/// One 榜 block is one record, keyed by `track|board`, and a block the viewer
/// already read keeps its rows, its cursor and where its list stood. Neither row
/// is pinned here: upstream publishes both vocabularies in the same response as
/// the cards, and four samples disagreed about how many of each there were.
class RankingController extends ChangeNotifier {
  RankingController({required this.catalog});

  final CatalogRepository catalog;

  /// The two rows, as the last answer published them. Empty until that answer,
  /// which is why the page paints a skeleton row instead of assuming names.
  List<RankTrack> tracks = const [];
  String track = rankSeedTrack;

  /// `null` means "the block this 赛道 serves by default" -- the request that
  /// discovers the tree sends no `sub_selected_items`, and the answer says which
  /// board it was (`is_selected`), so the name is taken from upstream rather than
  /// guessed and the rows on screen are labelled with what produced them.
  String? board;

  final _boards = <String, _BoardFeed>{};
  final _scroll = <String, ScrollController>{};

  _BoardFeed get _current => _feedFor(track, board);
  List<RankEntry> get entries => _current.entries;
  String? get cursor => _current.cursor;
  Object? get error => _current.error;

  /// The record's own identity, so a page can name the list it is scrolling
  /// without reaching through a private type.
  String get currentKey => _current.key;

  /// `rank_version` as upstream sent it: an empty string on 推荐榜, which is why
  /// a time on screen is only ever a claim the answer already made.
  DateTime? get updatedAt => _current.updatedAt;
  bool get loading => _current.loading;
  bool get loadingMore => _current.loadingMore;

  /// Cards this board sent that are not dramas (the 演员 track ranks people) --
  /// counted so the page can say so rather than calling a full board empty.
  int get unrecognizedCards => _current.unrecognizedCards;

  bool get supported => catalog is RankCatalogRepository;

  RankTrack? get selectedTrack {
    for (final value in tracks) {
      if (value.id == track) return value;
    }
    return null;
  }

  List<RankBoard> get boards => selectedTrack?.boards ?? const [];

  String keyOf(String track, String? board) => '$track|${board ?? ''}';

  /// One list per 榜, attached to exactly one live scrollable. The offset the
  /// viewer left it at is stored on the record, so coming back to a board is the
  /// same list they left -- the rule the discover feed layer already holds to.
  ScrollController scrollOf(String key) => _scroll.putIfAbsent(key, () {
    return ScrollController(initialScrollOffset: _boards[key]?.scroll ?? 0);
  });

  _BoardFeed _feedFor(String track, String? board) =>
      _boards.putIfAbsent(keyOf(track, board), () {
        final key = keyOf(track, board);
        final live = _scroll[key];
        return _BoardFeed(key, track, board, scroll: live?.offset ?? 0);
      });

  /// Entering the destination, and each time a row changes what is named. A 榜
  /// already read is shown as it was left and costs no request.
  ///
  /// `loading` is the shape the row is painted in -- true before the first
  /// answer, because a block nobody has asked for is exactly what a spinner
  /// means -- so the guard against asking twice is the flight itself, not that.
  Future<void> open() async {
    final feed = _current;
    if (feed.visited || feed.inFlight) return;
    await _load(feed);
  }

  Future<void> retry() => _load(_current);

  /// The next page of the 榜 on screen, asked of its own record: a board switched
  /// mid-flight must not have that answer filed under what is named now.
  Future<void> more() async {
    final feed = _current;
    if (feed.cursor == null ||
        feed.loading ||
        feed.loadingMore ||
        feed.error != null) {
      return;
    }
    await _load(feed, more: true);
  }

  void selectTrack(String id) {
    if (id == track) return;
    _captureScroll();
    track = id;
    // A 赛道 whose sub-selector did not come back this time has no boards to name,
    // so its request asks for its default -- and the row shows no board chip
    // until upstream says it has any.
    final named = _defaultBoard(_trackById(id));
    board = named;
    _emit();
    unawaited(open());
  }

  void selectBoard(String id) {
    if (id == board) return;
    _captureScroll();
    board = id;
    _emit();
    unawaited(open());
  }

  RankTrack? _trackById(String id) {
    for (final value in tracks) {
      if (value.id == id) return value;
    }
    return null;
  }

  static String? _defaultBoard(RankTrack? track) {
    if (track == null || track.boards.isEmpty) return null;
    for (final value in track.boards) {
      if (value.selected) return value.id;
    }
    return track.boards.first.id;
  }

  Future<void> _load(_BoardFeed feed, {bool more = false}) async {
    final rank = catalog;
    if (rank is! RankCatalogRepository) {
      _fail(feed, '这个运行时没有接榜单接口');
      return;
    }
    feed.scope.cancel();
    final scope = feed.scope = CatalogRequestScope();
    final ticket = ++feed.revision;
    feed
      ..inFlight = true
      ..loading = !more
      ..loadingMore = more
      ..error = null;
    _emit();
    try {
      final page = await scope.run(
        () => rank.rankBoard(
          track: feed.track,
          board: feed.board,
          cursor: more ? feed.cursor : null,
        ),
      );
      if (ticket != feed.revision) return;
      if (page.tracks.isNotEmpty) tracks = page.tracks;
      // The rows came from the 赛道's own default block, so the block the answer
      // marks `is_selected` becomes this record's key -- otherwise the chip row
      // would read "nothing selected" above a list that is somebody's ranking.
      if (feed.board == null) {
        final named = _defaultBoard(_trackById(feed.track));
        if (named != null && !_boards.containsKey(keyOf(feed.track, named))) {
          final old = feed.key;
          feed
            ..board = named
            ..key = keyOf(feed.track, named);
          _boards
            ..remove(old)
            ..[feed.key] = feed;
          if (feed.track == track) board = named;
        }
      }
      if (more) {
        feed.entries.addAll(page.entries);
      } else {
        feed.entries
          ..clear()
          ..addAll(page.entries);
        feed.updatedAt = page.updatedAt;
        feed.unrecognizedCards = page.unrecognizedCards;
      }
      feed
        ..cursor = page.nextCursor
        ..loading = false
        ..loadingMore = false
        ..visited = true;
    } catch (failure) {
      if (ticket != feed.revision) return;
      _fail(feed, failure);
      return;
    } finally {
      // Only the request that still owns the record clears the flag: a board
      // switched mid-flight has already started its own, and that one is what
      // `open()` must not double-tap.
      if (identical(feed.scope, scope)) feed.inFlight = false;
    }
    _emit();
  }

  void _fail(_BoardFeed feed, Object failure) {
    feed
      ..loading = false
      ..loadingMore = false
      ..error = failure;
    _emit();
  }

  void _captureScroll() {
    final feed = _current;
    final controller = _scroll[feed.key];
    if (controller?.hasClients == true) feed.scroll = controller!.offset;
  }

  void _emit() => notifyListeners();

  @override
  void dispose() {
    for (final feed in _boards.values) {
      feed.revision++;
      feed.scope.cancel();
    }
    for (final controller in _scroll.values) {
      controller.dispose();
    }
    super.dispose();
  }
}

/// One 榜 block's rows, in flight or remembered.
class _BoardFeed {
  _BoardFeed(this.key, this.track, this.board, {this.scroll = 0});

  String key;

  /// What these rows were asked for. Both live on the record rather than read
  /// from the controller, so an answer that lands after the viewer moved on is
  /// still filed under the 榜 that asked for it.
  final String track;

  /// `sub_selected_items`; null is upstream's default for the track and is
  /// re-named once the answer says which block it served.
  String? board;

  final List<RankEntry> entries = [];
  int unrecognizedCards = 0;
  String? cursor;
  Object? error;
  DateTime? updatedAt;
  double scroll;
  CatalogRequestScope scope = CatalogRequestScope();
  int revision = 0;
  bool loading = true, loadingMore = false, visited = false, inFlight = false;
}
