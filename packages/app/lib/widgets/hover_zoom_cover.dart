import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';

import 'drama_cover.dart';

/// Whether the pointer is over a widget, handed to a builder so any card can
/// link its own layers (title, rim, artwork) to the same gesture. Touch
/// devices never fire it, so a phone sees nothing of what a mouse gets.
class HoverBuilder extends StatefulWidget {
  final Widget Function(BuildContext context, bool hover) builder;
  const HoverBuilder({super.key, required this.builder});
  @override
  State<HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<HoverBuilder> {
  bool hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => hover = true),
    onExit: (_) => setState(() => hover = false),
    child: widget.builder(context, hover),
  );
}

/// The pointer family's artwork answer, shared by every card that shows a
/// cover: the picture zooms a notch and leans 2px toward the viewer's eye --
/// inside its own frame. The clip sits outside the transforms, so the frame,
/// the layout and any text beside or below it stay exactly where they were:
/// the frame holds still while the picture moves behind it, a gallery hang
/// leaning out of its mat.
///
/// The zoom keeps every edge covered at a 2px lean (8% of even the smallest
/// cover in the app is wider than that), so the rise never opens a gap.
class HoverZoomCover extends StatelessWidget {
  final Drama drama;
  final ImageProvider? imageProvider;
  final bool allowNetwork;

  /// Whether the pointer is on the owning card; false collapses both motions
  /// and is also what a touch or TV host passes for every frame.
  final bool hover;

  /// The frame's rounding; DramaCover clips at 12 itself, so the two agree by
  /// default and the outer clip is what the viewer actually sees.
  final double radius;
  const HoverZoomCover({
    super.key,
    required this.drama,
    required this.hover,
    this.imageProvider,
    this.allowNetwork = true,
    this.radius = 12,
  });

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 150);
    return ClipRRect(
      key: const ValueKey('hover-zoom-frame'),
      borderRadius: BorderRadius.circular(radius),
      child: AnimatedScale(
        duration: duration,
        curve: Curves.easeOutCubic,
        scale: hover ? 1.08 : 1.0,
        child: AnimatedContainer(
          duration: duration,
          curve: Curves.easeOutCubic,
          transform: Matrix4.translationValues(0, hover ? -2 : 0, 0),
          child: DramaCover(
            drama: drama,
            imageProvider: imageProvider,
            allowNetwork: allowNetwork,
          ),
        ),
      ),
    );
  }
}
