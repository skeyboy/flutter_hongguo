import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'anchored_panel.dart';

/// The mouse family's second look at one card: hold the pointer still for a
/// moment and the page offers a card you can act on.
///
/// The delay is the whole design. A pointer crosses a grid constantly -- to the
/// next row, to the scrollbar, to the chip it meant to hit -- so anything shorter
/// than a deliberate pause turns every pass over the list into a slideshow.
/// 1.5s is what the prototype measured and shipped with.
///
/// The open is owned here because it needs this box's rect; the close is the
/// page's, because 「移出后 300ms 收」is cancelled by the pointer arriving in the
/// preview card itself, and this widget has no way to know that happened.
class HoverPeek extends StatefulWidget {
  const HoverPeek({
    super.key,
    required this.enabled,
    required this.onShow,
    required this.onLeave,
    this.dismissWhenCovered,
    required this.child,
  });

  /// Only the mouse family gets a peek. Wrapping a touch card in one would make
  /// the first tap of every card a dead tap.
  final bool enabled;

  /// Called with this card's global rect and still-mounted source context once
  /// the pointer has held still.
  final void Function(Rect anchor, BuildContext sourceContext) onShow;

  /// Called the moment the pointer leaves: the page decides when that means
  /// closing.
  final VoidCallback onLeave;

  /// A page can preserve this lower layer while its own overlay covers the card.
  final bool Function()? dismissWhenCovered;

  final Widget child;

  @override
  State<HoverPeek> createState() => _HoverPeekState();
}

class _HoverPeekState extends State<HoverPeek> {
  static const _hold = Duration(milliseconds: 1500);

  final GlobalKey _anchor = GlobalKey();
  Timer? _timer;

  @override
  void didUpdateWidget(covariant HoverPeek oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled ||
        widget.child != oldWidget.child ||
        widget.key != oldWidget.key) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return MouseRegion(
      key: _anchor,
      // A pointer that moves off before the pause is up was never looking at
      // this card, so the pending open is dropped rather than allowed to land on
      // whatever the row is under now.
      onEnter: (_) {
        _timer?.cancel();
        _timer = Timer(_hold, () {
          _timer = null;
          if (!mounted || !widget.enabled) return;
          final sourceContext = _anchor.currentContext;
          if (sourceContext == null || !sourceContext.mounted) return;
          final rect = globalRectOf(sourceContext);
          if (rect != null) widget.onShow(rect, sourceContext);
        });
      },
      onExit: (event) {
        _timer?.cancel();
        _timer = null;
        final sourceContext = _anchor.currentContext;
        final rect = sourceContext == null ? null : globalRectOf(sourceContext);
        // Hit-testing can change without pointer movement. A stationary exit
        // dismisses only when the new layer really covers this source.
        if (rect != null && rect.contains(event.position)) {
          final view = WidgetsBinding.instance.rootElement?.findRenderObject();
          final source = _anchor.currentContext?.findRenderObject();
          if (view is! RenderView || source == null) {
            widget.onLeave();
            return;
          }
          final hits = HitTestResult();
          final sourceHit =
              view.hitTest(hits, position: event.position) &&
              hits.path.any((entry) => entry.target == source);
          if (sourceHit || (widget.dismissWhenCovered?.call() ?? true)) {
            widget.onLeave();
          }
          return;
        }
        widget.onLeave();
      },
      child: widget.child,
    );
  }
}
