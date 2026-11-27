import 'package:flutter/material.dart';

/// The pointer family's invitation, shared by every list-shaped card: the card
/// steps forward a notch, its rim catches the theme primary with a soft glow,
/// and a top-lit sheen reads as light hitting the surface. All engine-built
/// effects (AnimatedScale / BoxShadow / gradients) -- no runtime fragment
/// shader, so Impeller and every desktop backend stay on their fast paths.
///
/// The touch family never sees any of it: a mouse never enters their widgets.
/// Layout is static -- the rim and sheen are foreground layers, the scale is a
/// transform, so neighbors never reflow.
class HoverGlow extends StatefulWidget {
  final Widget child;

  /// How far the card steps forward. A wide row reads better at 1.02; a tile
  /// can afford a little more.
  final double scale;

  /// The rim's rounding; match the child's own border radius.
  final double radius;

  /// Cover cards get a bottom shade to close the light off; text rows stop at
  /// the top light so copy keeps its contrast.
  final bool bottomShade;
  const HoverGlow({
    super.key,
    required this.child,
    this.scale = 1.02,
    this.radius = 12,
    this.bottomShade = false,
  });
  @override
  State<HoverGlow> createState() => _HoverGlowState();
}

class _HoverGlowState extends State<HoverGlow> {
  bool hover = false;
  Duration get _duration => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 150);

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: AnimatedScale(
        duration: _duration,
        curve: Curves.easeOutCubic,
        scale: hover ? widget.scale : 1.0,
        child: AnimatedContainer(
          duration: _duration,
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            border: Border.all(
              color: hover ? accent.withValues(alpha: 0.9) : Colors.transparent,
              width: 1.5,
            ),
            // A decoration can carry either a border or a gradient, not both:
            // the sheen is a second decoration, layered over the same rim.
            gradient: hover
                ? LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: 0.12),
                      Colors.transparent,
                      if (widget.bottomShade)
                        Colors.black.withValues(alpha: 0.12),
                    ],
                    stops: widget.bottomShade
                        ? const [0, 0.5, 1]
                        : const [0, 0.45],
                  )
                : null,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            boxShadow: hover
                ? [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.35),
                      blurRadius: 14,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
