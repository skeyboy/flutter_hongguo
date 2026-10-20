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
          final moved = primary?.focusInDirection(direction) ?? false;
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
