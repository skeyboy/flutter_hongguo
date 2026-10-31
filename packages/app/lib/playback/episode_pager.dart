import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_tv/hongguo_tv.dart' show TvFocusable, TvNavigation;

/// Height-limited, multi-row, horizontally paged episode grid for all ends.
///
/// The block is always `rows` cells tall no matter how many episodes exist;
/// episodes are cut into pages and each page is one **non-scrolling** grid
/// inside a horizontal [PageView]. Phones pass `rows: 3, cellExtent: 100`
/// (matching the old detail-page SliverGrid), desktop and TV `rows: 4` with a
/// wider cell.
///
/// Paging: chevron buttons plus a「第 a/b 页」indicator; touch and mouse drag
/// may also fling pages. Highlighting reads [EpisodePager.currentIndex] lazily
/// so a page switch never rebuilds the host.
///
/// Focus hand-off (see design §2): a cell at the head of its page pressing
/// Left turns one page back and focuses the previous page's last cell; the
/// tail cell pressing Right turns forward and focuses the next page's first
/// cell, following the hand-written arrow-key pattern of
/// `packages/tv/lib/src/choice_rail.dart:61-87`. Inside a `TvNavigation`
/// subtree the cells/arrows render as `TvFocusable` and vertical moves are
/// served by `TvNavigation.focusInDirection`; anywhere else the same paging
/// behaviour is served by a plain `Focus` + `onKeyEvent` cell, so the widget
/// never requires the TV environment.
class EpisodePager extends StatefulWidget {
  const EpisodePager({
    super.key,
    required this.episodes,
    required this.currentIndex,
    required this.onSelected,
    required this.rows,
    required this.cellExtent,
    this.controller,
    this.aspectRatio = 1.5,
    this.spacing = 10,
    this.numberFontSize = 16,
    this.pageFontSize = 14,
  });

  final List<Episode> episodes;

  /// Global index of the playing episode, or a negative value for none.
  final int Function() currentIndex;

  /// Global (not page-local) index of the tapped episode.
  final ValueChanged<int> onSelected;

  /// Fixed visible rows; the block height never grows beyond this.
  final int rows;

  /// Target cell width; columns are derived from the available width.
  final double cellExtent;

  final EpisodePagerController? controller;

  /// Cell width/height. The replaced detail-page grid used 100x66, i.e. 1.5.
  final double aspectRatio;
  final double spacing;

  /// Text sizes for the cell number and the「第 a/b 页」line. They stay at the
  /// 16/14 every non-TV build has always read; a TV host raises them onto the
  /// scale its own page already uses (docs/design/video-detail-redesign.md §8:
  /// 16/14 physical pixels on a 1920-wide screen, next to this widget's own 26
  /// arrows and the page's 32 title).
  final double numberFontSize, pageFontSize;

  @override
  State<EpisodePager> createState() => _EpisodePagerState();
}

/// Reveal handle, mirroring `VideoPlaybackController`: the host holds it, the
/// state attaches while mounted.
class EpisodePagerController {
  _EpisodePagerState? _state;

  /// Shows [page] (0-based, clamped to the last page).
  void jumpToPage(int page) => _state?._turnTo(page);

  /// Shows the page holding the current episode.
  void showCurrent() {
    final state = _state;
    if (state == null) return;
    final index = state.widget.currentIndex();
    if (index < 0) return;
    state._turnTo(index ~/ state._perPage);
  }
}

class _EpisodePagerState extends State<EpisodePager> {
  late final PageController _page = PageController()
    ..addListener(_onPageScroll);

  /// One node per global episode index, created with its cell and owned here
  /// so a page turn (which unmounts the old page) never disposes the node
  /// another hand-off still needs.
  final Map<int, FocusNode> _cellNodes = {};
  final FocusNode _prevNode = FocusNode(debugLabel: 'episode-pager-prev');
  final FocusNode _nextNode = FocusNode(debugLabel: 'episode-pager-next');

  int _shownPage = 0;

  /// Cached from the last layout so key handlers and the controller can turn
  /// pages outside a frame.
  int _columns = 1;

  int get _perPage => widget.rows * _columns;
  int get _pageCount => math.max(1, (widget.episodes.length / _perPage).ceil());

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    // Columns only exist after the first layout, so the reveal of the current
    // episode happens one frame later; the pager never opens on an
    // irrelevant page.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = widget.currentIndex();
      if (current >= 0) _turnTo(current ~/ _perPage);
    });
  }

  @override
  void didUpdateWidget(EpisodePager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      if (oldWidget.controller?._state == this) {
        oldWidget.controller!._state = null;
      }
      widget.controller?._state = this;
    }
    if (oldWidget.episodes.length != widget.episodes.length &&
        _shownPage >= _pageCount) {
      _turnTo(_pageCount - 1);
    }
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller!._state = null;
    _page.removeListener(_onPageScroll);
    _page.dispose();
    _prevNode.dispose();
    _nextNode.dispose();
    for (final node in _cellNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _onPageScroll() {
    if (!_page.hasClients) return;
    final page = (_page.page ?? 0).round().clamp(0, _pageCount - 1);
    if (page != _shownPage) setState(() => _shownPage = page);
  }

  FocusNode _cellNode(int global) => _cellNodes.putIfAbsent(
    global,
    () => FocusNode(debugLabel: 'episode-cell-$global'),
  );

  /// Jumps (never animates): the hand-off must be able to focus a cell of the
  /// target page in the very next frame, and `animateToPage` would leave that
  /// page outside a zero-cacheExtent viewport while we ask for focus.
  void _turnTo(int page, {int? focusEpisode, FocusNode? focusFallback}) {
    final target = page.clamp(0, _pageCount - 1);
    if (target != _shownPage) setState(() => _shownPage = target);
    if (_page.hasClients && (_page.page ?? target).round() != target) {
      _page.jumpToPage(target);
    }
    if (focusEpisode != null) _handFocus(focusEpisode, focusFallback);
  }

  /// The target page is built one frame after the jump, so its cell node does
  /// not exist yet when the turn is asked for. Wait for it, and never leave the
  /// remote without a focus: if the cell still cannot be reached, park on
  /// [focusFallback], the arrow that points back at the page we came from.
  Future<void> _handFocus(int episode, FocusNode? fallback) async {
    final node = _cellNode(episode);
    for (var attempt = 0; attempt < 2 && node.context == null; attempt++) {
      WidgetsBinding.instance.ensureVisualUpdate();
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted) return;
    if (node.context != null) {
      node.requestFocus();
    } else {
      fallback?.requestFocus();
    }
  }

  KeyEventResult _onCellKey(int global, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    final page = global ~/ _perPage;
    final head = page * _perPage;
    final tail = math.min(head + _perPage, widget.episodes.length) - 1;
    if (key == LogicalKeyboardKey.arrowRight && global == tail) {
      // Consumed even at the last page: focus must never escape past the end.
      if (page + 1 < _pageCount) {
        _turnTo(
          page + 1,
          focusEpisode: (page + 1) * _perPage,
          focusFallback: _prevNode,
        );
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft && global == head) {
      if (page > 0) {
        _turnTo(
          page - 1,
          focusEpisode: (page - 1) * _perPage + _perPage - 1,
          focusFallback: _nextNode,
        );
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _step(int delta) {
    final target = (_shownPage + delta).clamp(0, _pageCount - 1);
    // The pressed arrow disables itself on an edge page, so the hand-off lands
    // on the neighbour cell; the arrow pointing back is still enabled there.
    final handoff = target == _pageCount - 1 && delta > 0
        ? widget.episodes.length - 1
        : target == 0 && delta < 0
        ? 0
        : null;
    _turnTo(
      target,
      focusEpisode: handoff,
      focusFallback: delta > 0 ? _prevNode : _nextNode,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tv = context.findAncestorWidgetOfExactType<TvNavigation>() != null;
    return LayoutBuilder(
      key: const ValueKey('episode-pager-frame'),
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        _columns = math.max(
          1,
          ((width + widget.spacing) / (widget.cellExtent + widget.spacing))
              .floor(),
        );
        final cellWidth = (width - (_columns - 1) * widget.spacing) / _columns;
        final cellHeight = cellWidth / widget.aspectRatio;
        final gridHeight =
            widget.rows * cellHeight + (widget.rows - 1) * widget.spacing;
        return Column(
          key: const ValueKey('episode-pager-column'),
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: gridHeight,
              width: width,
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  scrollbars: false,
                  // Paging by drag is a touch *and* desktop pointer gesture.
                  dragDevices: {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.stylus,
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.trackpad,
                  },
                ),
                child: PageView.builder(
                  key: const ValueKey('episode-pager-pageview'),
                  controller: _page,
                  scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                  itemCount: _pageCount,
                  itemBuilder: (context, page) => _grid(context, tv, page),
                ),
              ),
            ),
            _footer(tv),
          ],
        );
      },
    );
  }

  Widget _grid(BuildContext context, bool tv, int page) {
    final first = page * _perPage;
    final count = math.max(
      0,
      math.min(_perPage, widget.episodes.length - first),
    );
    return GridView.builder(
      key: ValueKey('episode-pager-grid-$page'),
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _columns,
        crossAxisSpacing: widget.spacing,
        mainAxisSpacing: widget.spacing,
        childAspectRatio: widget.aspectRatio,
      ),
      itemCount: count,
      itemBuilder: (context, i) => _cell(context, tv, first + i),
    );
  }

  Widget _cell(BuildContext context, bool tv, int global) {
    final episode = widget.episodes[global];
    final label = '第 ${episode.index} 集';
    final selected = widget.currentIndex() == global;
    final scheme = Theme.of(context).colorScheme;
    final node = _cellNode(global);
    final content = Center(
      child: Text(
        '${episode.index}',
        style: TextStyle(
          fontSize: widget.numberFontSize,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
          color: selected ? scheme.primary : null,
        ),
      ),
    );
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) => _onCellKey(global, event),
      child: tv
          ? TvFocusable(
              key: ValueKey('episode-pager-tv-cell-$global'),
              focusNode: node,
              label: label,
              selected: selected,
              onActivate: () => widget.onSelected(global),
              child: content,
            )
          : _MaterialCell(
              key: ValueKey('episode-pager-cell-$global'),
              focusNode: node,
              label: label,
              selected: selected,
              onTap: () => widget.onSelected(global),
              child: content,
            ),
    );
  }

  Widget _footer(bool tv) => Row(
    key: const ValueKey('episode-pager-footer'),
    children: [
      _arrow(tv, leading: true, enabled: _shownPage > 0, node: _prevNode),
      Expanded(
        child: Center(
          child: Text(
            '第 ${_shownPage + 1}/$_pageCount 页',
            key: const ValueKey('episode-pager-page-indicator'),
            style: TextStyle(fontSize: widget.pageFontSize),
          ),
        ),
      ),
      _arrow(
        tv,
        leading: false,
        enabled: _shownPage < _pageCount - 1,
        node: _nextNode,
      ),
    ],
  );

  Widget _arrow(
    bool tv, {
    required bool leading,
    required bool enabled,
    required FocusNode node,
  }) {
    final label = leading ? '上一页' : '下一页';
    final onTap = enabled ? () => _step(leading ? -1 : 1) : null;
    final icon = Icon(
      leading ? Icons.chevron_left : Icons.chevron_right,
      size: 26,
      // Disabled arrows grey out: IconButton does it itself, TvFocusable has
      // no disabled paint, so the icon carries the colour here.
      color: enabled ? null : Colors.grey,
    );
    if (tv) {
      return Tooltip(
        message: label,
        child: TvFocusable(
          key: ValueKey('episode-pager-arrow-$label'),
          focusNode: node,
          label: label,
          onActivate: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: icon,
          ),
        ),
      );
    }
    return IconButton(
      key: ValueKey('episode-pager-arrow-$label'),
      icon: icon,
      tooltip: label,
      focusNode: node,
      onPressed: onTap,
    );
  }
}

/// Plain-Material counterpart of `TvFocusable` with the same keyboard
/// contract: focus ring, selection fill, semantics label, Enter activation.
class _MaterialCell extends StatefulWidget {
  const _MaterialCell({
    super.key,
    required this.focusNode,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final FocusNode focusNode;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_MaterialCell> createState() => _MaterialCellState();
}

class _MaterialCellState extends State<_MaterialCell> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(_MaterialCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.focusNode, widget.focusNode)) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }
  }

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    // The pager owns the node; unhook only.
    widget.focusNode.removeListener(_onFocusChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final focused = widget.focusNode.hasFocus;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      child: Actions(
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: widget.focusNode,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.enter ||
                    event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
              widget.onTap();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 120),
              decoration: BoxDecoration(
                color: widget.selected ? scheme.primaryContainer : null,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: focused
                      ? scheme.primary
                      : widget.selected
                      ? scheme.primary
                      : scheme.outlineVariant,
                  width: focused ? 3 : 1,
                ),
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
