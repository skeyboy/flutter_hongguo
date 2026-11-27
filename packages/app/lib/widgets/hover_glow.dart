import 'package:flutter/material.dart';

/// The pointer family's invitation, shared by every list-shaped card: the card
/// steps forward a notch, and its whole rim -- text included -- catches the
/// theme primary with a soft glow. All engine-built effects (AnimatedScale /
/// BoxShadow) -- no runtime fragment shader, so Impeller and every desktop
/// backend stay on their fast paths.
///
/// No sheen: light painted over artwork read as a stain the moment a cover
/// happened to be bright. The rim alone is the statement.
///
/// The touch family never sees any of it: a mouse never enters their widgets.
/// Layout is static -- the rim is a foreground layer, the scale a transform,
/// so neighbors never reflow.
class HoverGlow extends StatefulWidget {
  final Widget child;

  /// How far the card steps forward. A wide row reads better at 1.02; a tile
  /// can afford a little more.
  final double scale;

  /// The rim's rounding; match the child's own border radius.
  final double radius;

  /// Fired whenever the pointer crosses the card, so a card can let its own
  /// text step forward in the same breath (the rim answers the eye, the type
  /// answers the name).
  final ValueChanged<bool>? onHover;

  /// The keyboard family's version of the same invitation. Off by default so
  /// the main's mouse-only cards keep their exact contract; filter chips and
  /// controls turn it on to follow the focus system (a focused node owns the
  /// rim just as a hovering pointer does).
  final bool focusAware;

  /// Fired only when keyboard focus enters or leaves, so a row can centre the
  /// chip the viewer reached without moving under a passing mouse.
  final ValueChanged<bool>? onFocus;
  const HoverGlow({
    super.key,
    required this.child,
    this.scale = 1.02,
    this.radius = 12,
    this.onHover,
    this.focusAware = false,
    this.onFocus,
  });
  @override
  State<HoverGlow> createState() => _HoverGlowState();
}

class _HoverGlowState extends State<HoverGlow> {
  bool hover = false;
  bool focused = false;
  bool lit = false;
  Duration get _duration => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 150);

  void _setHover(bool value) {
    if (hover == value) return;
    hover = value;
    _sync();
  }

  void _setFocus(bool value) {
    if (!widget.focusAware || focused == value) return;
    focused = value;
    widget.onFocus?.call(value);
    _sync();
  }

  void _sync() {
    final next = hover || focused;
    if (lit == next) return;
    lit = next;
    setState(() {});
    widget.onHover?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    Widget child = widget.child;
    if (widget.focusAware) {
      // A non-focusable observer: the button inside stays the Tab stop and
      // keeps its own activation keys, while `hasFocus` covers the whole
      // focus chain, so this rim lights on keyboard focus too.
      child = Focus(
        canRequestFocus: false,
        onFocusChange: _setFocus,
        child: child,
      );
    }
    return MouseRegion(
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: AnimatedScale(
        duration: _duration,
        curve: Curves.easeOutCubic,
        scale: lit ? widget.scale : 1.0,
        child: AnimatedContainer(
          duration: _duration,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            boxShadow: lit
                ? [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.22),
                      blurRadius: 9,
                    ),
                  ]
                : null,
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            border: Border.all(
              color: lit ? accent.withValues(alpha: 0.9) : Colors.transparent,
              width: 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
