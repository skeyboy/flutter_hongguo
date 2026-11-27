import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';

import 'drama_cover.dart';

/// The pointer family's invitation on a catalog tile: the whole item -- cover
/// and text alike -- steps forward a notch and its rim catches the primary
/// color with a soft glow, while the title grows half a step so the name leads
/// the eye. All engine-built effects (AnimatedScale / BoxShadow) -- no runtime
/// fragment shader, so Impeller and every desktop backend stay on their fast
/// paths. The touch family never sees any of it: a mouse never enters their
/// widgets.
class DramaCard extends StatefulWidget {
  final Drama drama;
  final VoidCallback onTap;

  /// The touch family's second gesture on a card: 长按 opens what the card owns
  /// rather than what it shows. Null leaves the card as it was, so the catalog
  /// grids that have no whole-item action stay one-target tiles.
  final VoidCallback? onLongPress;

  /// The pointer family's answer to the same gesture: a mouse holds no card long
  /// enough to trust, so 右键 is what a hand on a desktop actually reaches for. It
  /// opens exactly what [onLongPress] opens -- one target per card, either way.
  final VoidCallback? onSecondaryTap;
  final String? badge, subtitle;
  final ImageProvider? coverImage;
  final bool allowNetworkCover;
  const DramaCard({
    super.key,
    required this.drama,
    required this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.badge,
    this.subtitle,
    this.coverImage,
    this.allowNetworkCover = true,
  });
  @override
  State<DramaCard> createState() => _DramaCardState();
}

class _DramaCardState extends State<DramaCard> {
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
        scale: hover ? 1.03 : 1.0,
        child: InkWell(
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          onSecondaryTap: widget.onSecondaryTap,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: _duration,
            // The rim owns the whole item, not just the artwork: a card is one
            // target, and a border that stops at the cover reads as two. The
            // padding keeps the rim off the content: artwork and type breathe
            // inside the frame instead of touching it.
            padding: const EdgeInsets.all(8),
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: hover
                    ? accent.withValues(alpha: 0.9)
                    : Colors.transparent,
                width: 1,
              ),
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: hover
                  ? [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.22),
                        blurRadius: 9,
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: DramaCover(
                          drama: widget.drama,
                          imageProvider: widget.coverImage,
                          allowNetwork: widget.allowNetworkCover,
                        ),
                      ),
                      if (widget.badge != null || widget.drama.episodeCount > 0)
                        Positioned(
                          left: 8,
                          bottom: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              widget.badge ?? '${widget.drama.episodeCount} 集',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                // The name leads: half a step larger while the card is hovered,
                // animated on the same clock as the rim.
                AnimatedDefaultTextStyle(
                  duration: _duration,
                  style: TextStyle(
                    fontSize: hover ? 16 : 15,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  child: Text(
                    widget.drama.title.isEmpty ? '未命名短剧' : widget.drama.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.subtitle ??
                      (widget.drama.intro.isEmpty
                          ? '点开看看这个故事'
                          : widget.drama.intro),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
