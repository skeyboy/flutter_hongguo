import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';

import 'drama_cover.dart';

/// The pointer family's invitation on a catalog tile: the card steps forward a
/// notch, its cover rim catches the primary color with a soft glow, and a
/// top-lit sheen reads as light hitting the artwork. All engine-built effects
/// (AnimatedScale / BoxShadow / gradients) -- no runtime fragment shader, so
/// Impeller and every desktop backend stay on their fast paths. The touch
/// family never sees any of it: a mouse never enters their widgets.
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
  Duration get _duration =>
      MediaQuery.disableAnimationsOf(context)
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
                    // 边缘高亮 + 辉光: a foreground layer, so the layout never moves.
                    Positioned.fill(
                      child: IgnorePointer(
                        child: AnimatedContainer(
                          duration: _duration,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: hover
                                  ? accent.withValues(alpha: 0.9)
                                  : Colors.transparent,
                              width: 1.5,
                            ),
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
                        ),
                      ),
                    ),
                    // 适度的"shader"效果: a soft top-lit sheen clipped to the cover.
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: AnimatedOpacity(
                            duration: _duration,
                            opacity: hover ? 1 : 0,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.white.withValues(alpha: 0.12),
                                    Colors.transparent,
                                    Colors.black.withValues(alpha: 0.12),
                                  ],
                                  stops: const [0, 0.5, 1],
                                ),
                              ),
                            ),
                          ),
                        ),
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
              Text(
                widget.drama.title.isEmpty ? '未命名短剧' : widget.drama.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  height: 1.4,
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
    );
  }
}
