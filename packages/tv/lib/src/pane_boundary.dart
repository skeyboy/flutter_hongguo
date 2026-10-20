import 'package:flutter/widgets.dart';

/// A pane owns directional traversal. Only a left-edge miss may return to the
/// sidebar; geometry must not choose a different sidebar entry implicitly.
class TvPaneBoundary extends InheritedWidget {
  final VoidCallback exitLeft;
  const TvPaneBoundary({
    super.key,
    required this.exitLeft,
    required super.child,
  });
  static TvPaneBoundary? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TvPaneBoundary>();
  @override
  bool updateShouldNotify(TvPaneBoundary oldWidget) =>
      exitLeft != oldWidget.exitLeft;
}
