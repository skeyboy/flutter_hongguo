import 'package:flutter/widgets.dart';

/// Nested controls delegate Back to their owning surface before a Navigator.
class TvBackScope extends InheritedWidget {
  final VoidCallback onBack;
  const TvBackScope({super.key, required this.onBack, required super.child});
  static TvBackScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TvBackScope>();
  @override
  bool updateShouldNotify(TvBackScope oldWidget) => onBack != oldWidget.onBack;
}
