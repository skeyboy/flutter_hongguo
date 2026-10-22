import 'package:flutter/material.dart';
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

/// Routes unconsumed D-pad events only. Text editors retain their own key handling.
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
    // In band: the nearest row/column wins. Out of band: line up first, then
    // travel the least.
    int compare((FocusNode, Rect) a, (FocusNode, Rect) b) {
      double primary(Rect rect) => vertical
          ? rect.center.dy - source.center.dy
          : rect.center.dx - source.center.dx;
      double cross(Rect rect) => vertical
          ? rect.center.dx - source.center.dx
          : rect.center.dy - source.center.dy;
      final byPrimary = primary(a.$2).abs().compareTo(primary(b.$2).abs());
      if (inBand.isNotEmpty || byPrimary != 0) return byPrimary;
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

  /// The node's box in global logical coordinates, or null while it has no
  /// attached, laid-out widget.
  static Rect? _globalRect(FocusNode node) {
    if (node.context == null) return null;
    try {
      final rect = node.rect;
      return rect.isEmpty ? null : rect;
    } on FlutterError {
      return null;
    }
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
        final editing =
            primary?.context?.findAncestorStateOfType<EditableTextState>() !=
            null;
        if (editing) return KeyEventResult.ignored;
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
