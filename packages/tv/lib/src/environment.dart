import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'pane_boundary.dart';
import 'back_scope.dart';
import 'back_dispatcher.dart';

/// Flavor is authoritative; desktop override is for testing, not TV detection.
bool get tvBuild =>
    appFlavor == 'tv' || const bool.fromEnvironment('HONGGUO_TV');
bool isRemoteConfirm(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.select ||
    key == LogicalKeyboardKey.enter ||
    key == LogicalKeyboardKey.numpadEnter ||
    key == LogicalKeyboardKey.gameButtonA;
bool isRemoteBack(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.escape ||
    key == LogicalKeyboardKey.goBack ||
    key == LogicalKeyboardKey.gameButtonB;

class TvEnvironment extends InheritedWidget {
  final bool enabled;
  const TvEnvironment({super.key, required this.enabled, required super.child});
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TvEnvironment>()?.enabled ??
      tvBuild;
  @override
  bool updateShouldNotify(TvEnvironment oldWidget) =>
      enabled != oldWidget.enabled;
}

/// Routes unconsumed D-pad events only. Text editors keep their own key
/// handling, with one exception spelled out in [_editorGivesVerticalArrows]:
/// 上下 on a single-line box belong to the remote, not to a caret that has
/// nowhere to go.
class TvNavigation extends StatelessWidget {
  final Widget child;
  const TvNavigation({super.key, required this.child});

  /// Flutter only moves vertically inside the [Scrollable] that owns the
  /// focused node (`DirectionalFocusTraversalPolicyMixin` filters candidates
  /// by `Scrollable.maybeOf(..., axis: vertical)`), so on a TV page a nested
  /// grid or list can never be entered with the D-pad: the remote steps over
  /// it and lands on whatever shares the page's own scrollable. Measured on a
  /// v0.3.2 emulator, where the episode grid was unreachable.
  ///
  /// A remote user navigates by what is on screen, so this searches every
  /// focusable node of the scope by geometry instead — Flutter's own rule
  /// (prefer a node overlapping the source's band, then the nearest edge),
  /// without the scrollable restriction. Returns false when nothing lies in
  /// that direction, leaving the framework to handle the edge.
  static bool focusInDirection(FocusNode? from, TraversalDirection direction) {
    final scope = from?.nearestScope;
    if (from == null || scope == null) return false;
    final source = _globalRect(from);
    if (source == null) return false;
    final vertical =
        direction == TraversalDirection.up ||
        direction == TraversalDirection.down;
    final forward =
        direction == TraversalDirection.down ||
        direction == TraversalDirection.right;

    final ahead = <(FocusNode, Rect)>[];
    for (final node in scope.traversalDescendants) {
      if (node == from || !node.canRequestFocus || node.skipTraversal) {
        continue;
      }
      final rect = _globalRect(node);
      if (rect == null) continue;
      final beyond = vertical
          ? (forward ? rect.top - source.bottom : source.top - rect.bottom)
          : (forward ? rect.left - source.right : source.left - rect.right);
      if (beyond < 0) continue;
      ahead.add((node, rect));
    }
    if (ahead.isEmpty) return false;

    final band = vertical
        ? (Rect rect) => rect.left < source.right && rect.right > source.left
        : (Rect rect) => rect.top < source.bottom && rect.bottom > source.top;
    final inBand = ahead.where((entry) => band(entry.$2)).toList();
    final candidates = inBand.isEmpty ? ahead : inBand;
    // The nearest row/column wins; ties are broken on the cross axis. Same-row
    // chips all have an identical primary distance, so without a tie-break
    // List.sort keeps reading order and ArrowUp from a grid cell lands on the
    // leftmost chip in its band.
    int compare((FocusNode, Rect) a, (FocusNode, Rect) b) {
      double primary(Rect rect) => vertical
          ? rect.center.dy - source.center.dy
          : rect.center.dx - source.center.dx;
      double cross(Rect rect) => vertical
          ? rect.center.dx - source.center.dx
          : rect.center.dy - source.center.dy;
      final byPrimary = primary(a.$2).abs().compareTo(primary(b.$2).abs());
      if (byPrimary != 0) return byPrimary;
      if (inBand.isEmpty) {
        // Out of band: line up first, then travel the least.
        return cross(a.$2).abs().compareTo(cross(b.$2).abs());
      }
      // In band: the candidate whose box contains the source centre is the
      // one the viewer is pointing at. Otherwise prefer the box the source
      // overlaps most, then the nearest edge, then the nearest centre.
      // Two special shapes keep their old behaviour:
      //  * a source that fully contains every in-band candidate (a wide
      //    header entering a grid row) points at no column — reading order
      //    picks the first cell;
      //  * on a MiTV the centre can sit 2px from one chip's edge and 14px
      //    from the neighbour's, where overlap and edge distance — not the
      //    centre — decide (cell ~334px wide, chip ~161px).
      final sourceCross = vertical ? source.center.dx : source.center.dy;
      final sourceStart = vertical ? source.left : source.top;
      final sourceEnd = vertical ? source.right : source.bottom;
      bool covers(Rect rect) {
        final start = vertical ? rect.left : rect.top;
        final end = vertical ? rect.right : rect.bottom;
        return start <= sourceCross && sourceCross <= end;
      }

      double overlap(Rect rect) {
        final start = vertical ? rect.left : rect.top;
        final end = vertical ? rect.right : rect.bottom;
        final shared =
            (end < sourceEnd ? end : sourceEnd) -
            (start > sourceStart ? start : sourceStart);
        return shared > 0 ? shared : 0;
      }

      double gap(Rect rect) {
        final start = vertical ? rect.left : rect.top;
        final end = vertical ? rect.right : rect.bottom;
        if (sourceCross < start) return start - sourceCross;
        if (sourceCross > end) return sourceCross - end;
        return 0;
      }

      final aCovers = covers(a.$2), bCovers = covers(b.$2);
      if (aCovers != bCovers) return aCovers ? -1 : 1;
      if (aCovers) return cross(a.$2).abs().compareTo(cross(b.$2).abs());
      if (candidates.every(
        (entry) => vertical
            ? entry.$2.left >= sourceStart && entry.$2.right <= sourceEnd
            : entry.$2.top >= sourceStart && entry.$2.bottom <= sourceEnd,
      )) {
        return 0;
      }
      final byOverlap = overlap(b.$2).compareTo(overlap(a.$2));
      if (byOverlap != 0) return byOverlap;
      final byGap = gap(a.$2).compareTo(gap(b.$2));
      if (byGap != 0) return byGap;
      return cross(a.$2).abs().compareTo(cross(b.$2).abs());
    }

    candidates.sort(compare);
    final target = candidates.first.$1;
    // `canRequestFocus` already folds in every ancestor's
    // `descendantsAreFocusable`, so this request cannot be refused. The focus
    // itself lands in a microtask, which is why `hasFocus` is not checked --
    // reporting false here would let the framework re-pick a wrong node in
    // the same frame.
    target.requestFocus();
    return true;
  }

  /// The node's visible, laid-out box in global logical coordinates, or null
  /// when it cannot be a remote target.
  ///
  /// Known limitation: RenderViewport does not override paintsChild, so a chip
  /// scrolled out of TvChoiceRail's horizontal viewport keeps its layout rect
  /// and can still be chosen by geometry. Requesting focus on it scrolls it
  /// back into view, so focus is never invisible, but the rail may jump.
  static Rect? _globalRect(FocusNode node) {
    final context = node.context;
    if (context == null || !context.mounted) return null;
    final object = context.findRenderObject();
    if (object is! RenderBox || !object.attached) return null;
    try {
      if (!object.hasSize || object.size.isEmpty) return null;
      // A maintained Visibility can keep a laid-out, focusable subtree while
      // suppressing paint. Its render proxy is private; use the public query.
      if (!Visibility.of(context)) return null;
      for (
        RenderObject? current = object;
        current != null;
        current = current.parent
      ) {
        if (!current.attached) return null;
        if (current is RenderOffstage && current.offstage) return null;
        if (current is RenderSliverOpacity && current.opacity == 0) return null;
        final parent = current.parent;
        // The public render-tree contract also catches zero-opacity proxies and
        // other ancestors that suppress painting despite retaining geometry.
        if (parent != null && !parent.paintsChild(current)) return null;
      }
      final rect = node.rect;
      if (rect.isEmpty || !rect.width.isFinite || !rect.height.isFinite) {
        return null;
      }
      return rect;
    } on FlutterError {
      return null;
    }
  }

  /// Whether a focused text editor hands this vertical arrow back to the remote.
  ///
  /// An editor is asked for its keys before the traversal below -- and before the
  /// root [DefaultTextEditingShortcuts] that moves the caret -- so while a box
  /// holds focus, this handler was the last chance to move it, and the old answer
  /// was always "not mine". That made every search box on a TV pane the end of
  /// the walk: 上下 went nowhere, and the viewer had no key left that reached the
  /// rows under the box.
  ///
  /// Only a single-line box gives 上下 up, because a single line is exactly the
  /// case where those two arrows do nothing for the caret. A multi-line editor
  /// keeps them -- they are how a remote user moves between its lines. 左右 stay
  /// with the caret in every box, and so does 确认, which on a TV opens the
  /// keyboard instead of pressing the button behind the field.
  static bool _editorGivesVerticalArrows(
    EditableTextState editor,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final vertical =
        event.logicalKey == LogicalKeyboardKey.arrowUp ||
        event.logicalKey == LogicalKeyboardKey.arrowDown;
    return vertical && (editor.widget.maxLines ?? 1) <= 1;
  }

  @override
  Widget build(BuildContext context) => FocusTraversalGroup(
    policy: ReadingOrderTraversalPolicy(),
    child: Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (event is KeyUpEvent) return KeyEventResult.ignored;
        final primary = FocusManager.instance.primaryFocus;
        final editor = primary?.context
            ?.findAncestorStateOfType<EditableTextState>();
        if (editor != null && !_editorGivesVerticalArrows(editor, event)) {
          return KeyEventResult.ignored;
        }
        if (isRemoteBack(event.logicalKey) && primary?.context != null) {
          final dispatcher = event is KeyDownEvent
              ? TvBackDispatcher.dispatch(primary!.context!)
              : null;
          if (dispatcher != null) return KeyEventResult.handled;
          if (event is KeyRepeatEvent) return KeyEventResult.handled;
          final owner = TvBackScope.maybeOf(primary!.context!);
          if (owner != null) {
            if (event is KeyDownEvent) owner.onBack();
            return KeyEventResult.handled;
          }
          final navigator = Navigator.maybeOf(primary.context!);
          if (navigator?.canPop() == true) {
            if (event is KeyDownEvent) navigator!.maybePop();
            return KeyEventResult.handled;
          }
        }
        final direction = switch (event.logicalKey) {
          LogicalKeyboardKey.arrowUp => TraversalDirection.up,
          LogicalKeyboardKey.arrowDown => TraversalDirection.down,
          LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
          LogicalKeyboardKey.arrowRight => TraversalDirection.right,
          _ => null,
        };
        if (direction != null) {
          final pane = primary?.context == null
              ? null
              : TvPaneBoundary.maybeOf(primary!.context!);
          final moved =
              focusInDirection(primary, direction) ||
              (primary?.focusInDirection(direction) ?? false);
          if (!moved && direction == TraversalDirection.left) pane?.exitLeft();
          return KeyEventResult.handled;
        }
        // Material buttons support Enter. Add D-pad CENTER / gamepad activation.
        if (isRemoteConfirm(event.logicalKey)) {
          if (event is KeyDownEvent && primary?.context != null) {
            Actions.maybeInvoke(primary!.context!, const ActivateIntent());
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    ),
  );
}

/// Native capability facts are diagnostics, not a substitute for the TV flavor.
class TvDeviceProfile {
  final bool? television, leanback, lowRam;
  const TvDeviceProfile({this.television, this.leanback, this.lowRam});
  static Future<TvDeviceProfile> read() async {
    try {
      final data = await const MethodChannel('hongguo/tv-device')
          .invokeMapMethod<String, dynamic>('profile');
      return TvDeviceProfile(
        television: data?['television'] as bool?,
        leanback: data?['leanback'] as bool?,
        lowRam: data?['lowRam'] as bool?,
      );
    } on MissingPluginException {
      return const TvDeviceProfile();
    } on PlatformException {
      return const TvDeviceProfile();
    }
  }
}
