import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// The 选集 panel opens wherever its list last stood, so on a 90-episode drama
/// it opens at 第 1 集 while the viewer is watching 第 74 集 -- the one row they
/// came for is below the fold. This wraps that list for both of its shapes (the
/// wide surface's side drawer and the tall one's bottom sheet) and aims it at
/// the episode actually playing.
///
/// The aim is read off the grid's own layout rather than off a measured cell:
/// `SliverConstraints.precedingScrollExtent` says where the sliver starts in the
/// scroll's content and `SliverGridLayout.getGeometryForChildIndex` says where
/// the cell sits inside the sliver, which together reach an episode the lazy
/// grid has not built yet. The episode count therefore decides what happens
/// rather than being a case of its own -- a list that already fits clamps to no
/// movement at all, and only a long one is asked to travel.
class EpisodeReveal extends StatefulWidget {
  const EpisodeReveal({
    super.key,
    required this.index,
    required this.count,
    required this.scroll,
    required this.grid,
    required this.child,
  });

  /// The playing episode, counted in the order the grid lays its cells out.
  final int index;
  final int count;

  /// The two handles into the list the page builds. One controller serves both
  /// panels because only one of them is ever in the tree: the drawer is built
  /// for the wide surface and the sheet for the tall one.
  final ScrollController scroll;
  final GlobalKey grid;
  final Widget child;

  @override
  State<EpisodeReveal> createState() => _EpisodeRevealState();
}

class _EpisodeRevealState extends State<EpisodeReveal> {
  /// How far down the panel the aimed cell is left standing: enough rows above
  /// it to show what came before, more below to show what the viewer reaches
  /// next. An episode near the start of the list is never shoved down -- the
  /// clamp holds the list at its own top.
  static const _alignment = 0.34;

  @override
  Widget build(BuildContext context) => widget.child;

  @override
  void initState() {
    super.initState();
    // The panel only puts this list in the tree while it is open, so being
    // mounted is what "the viewer just tapped 选集" means -- and the frame that
    // lays the grid out is the first one whose geometry can be aimed at.
    _afterLayout(_aim);
  }

  @override
  void didUpdateWidget(covariant EpisodeReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index == oldWidget.index && widget.count == oldWidget.count) {
      return;
    }
    _afterLayout(_follow);
  }

  void _afterLayout(void Function() aim) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) aim();
    });
  }

  /// The panel opened: put the playing episode where it reads as the subject of
  /// the list, whether or not it was already on screen.
  void _aim() {
    final aim = _read();
    if (aim == null || aim.target == aim.position.pixels) return;
    // No animation on the way in: the viewer should never see the panel start
    // at the wrong place and then slide.
    aim.position.jumpTo(aim.target);
  }

  /// The episode changed under a panel already open. Where the viewer put the
  /// list is their own choice, so a cell they can already see is left alone and
  /// only one below or above the fold is travelled to.
  void _follow() {
    final aim = _read();
    if (aim == null || aim.onScreen || aim.target == aim.position.pixels) {
      return;
    }
    aim.position.animateTo(
      aim.target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  /// `null` while there is nothing to aim at yet: no laid-out grid, no attached
  /// list, or an index the list does not have.
  ({ScrollPosition position, double target, bool onScreen})? _read() {
    final grid = widget.grid.currentContext?.findRenderObject();
    final position = widget.scroll.hasClients ? widget.scroll.position : null;
    if (grid is! RenderSliverGrid || position == null) return null;
    if (widget.index < 0 || widget.index >= widget.count) return null;
    final cell = grid.gridDelegate
        .getLayout(grid.constraints)
        .getGeometryForChildIndex(widget.index);
    final top = grid.constraints.precedingScrollExtent + cell.scrollOffset;
    final viewport = position.viewportDimension;
    return (
      position: position,
      target: (top - (viewport - cell.mainAxisExtent) * _alignment)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble(),
      onScreen:
          position.pixels <= top &&
          top + cell.mainAxisExtent <= position.pixels + viewport,
    );
  }
}
