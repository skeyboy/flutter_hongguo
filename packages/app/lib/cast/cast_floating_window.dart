import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hongguo_cast/hongguo_cast.dart';

import 'cast_service.dart';

/// Keeps the running cast on screen above every page of the app.
///
/// The layer is inserted over the router, not into it: a route transition must
/// not be able to take the handle away, and the handle has to survive going back
/// to the library. [visible] is false while the remote page itself is frontmost,
/// because there the whole control surface is already on screen.
class CastFloatingLayer extends StatelessWidget {
  const CastFloatingLayer({
    super.key,
    required this.service,
    required this.visible,
    required this.onTap,
    required this.child,
  });

  final CastService service;
  final bool visible;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      child,
      if (visible)
        Positioned.fill(
          child: CastFloatingWindow(service: service, onTap: onTap),
        ),
    ],
  );
}

/// The draggable pill itself: what is playing, where, and the two commands that
/// are worth a tap without opening the page.
class CastFloatingWindow extends StatefulWidget {
  const CastFloatingWindow({
    super.key,
    required this.service,
    required this.onTap,
  });

  final CastService service;
  final VoidCallback onTap;

  @override
  State<CastFloatingWindow> createState() => _CastFloatingWindowState();
}

class _CastFloatingWindowState extends State<CastFloatingWindow> {
  static const _width = 244.0, _height = 56.0, _margin = 12.0;

  /// Top-left corner once the viewer has dragged it; null means "default spot".
  Offset? _anchor;

  Offset _clamp(Offset raw, Size size, EdgeInsets insets) => Offset(
    raw.dx.clamp(_margin, math.max(_margin, size.width - _width - _margin)),
    raw.dy.clamp(
      _margin + insets.top,
      math.max(_margin, size.height - _height - _margin - insets.bottom),
    ),
  );

  Offset _default(Size size, EdgeInsets insets) => _clamp(
    Offset(size.width - _width - _margin, size.height - _height - _margin),
    size,
    insets,
  );

  Offset _placed(Size size, EdgeInsets insets) =>
      _anchor == null ? _default(size, insets) : _clamp(_anchor!, size, insets);

  void _drag(DragUpdateDetails details, Size size, EdgeInsets insets) {
    final start = _placed(size, insets);
    setState(() => _anchor = _clamp(start + details.delta, size, insets));
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        if (!service.active) return const SizedBox.shrink();
        final size = MediaQuery.sizeOf(context);
        final insets = MediaQuery.paddingOf(context);
        final at = _placed(size, insets);
        final playing = service.phase == CastPhase.streaming;
        return Stack(
          children: [
            Positioned(
              key: const ValueKey('cast-float'),
              left: at.dx,
              top: at.dy,
              child: Semantics(
                button: true,
                label: '返回投屏控制',
                child: GestureDetector(
                  onTap: widget.onTap,
                  onPanUpdate: (details) => _drag(details, size, insets),
                  child: Material(
                    color: theme.colorScheme.surfaceContainerHighest,
                    shadowColor: theme.colorScheme.shadow.withValues(
                      alpha: .35,
                    ),
                    elevation: 6,
                    borderRadius: BorderRadius.circular(_height / 2),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                      width: _width,
                      height: _height,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Row(
                          children: [
                            Icon(
                              Icons.cast_connected_rounded,
                              size: 18,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    service.title ?? '投屏中',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelMedium,
                                  ),
                                  Text(
                                    service.target?.friendlyName ?? '电视',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              key: const ValueKey('cast-float-play'),
                              tooltip: playing ? '暂停' : '继续播放',
                              onPressed: () =>
                                  playing ? service.pause() : service.resume(),
                              iconSize: 22,
                              visualDensity: VisualDensity.compact,
                              icon: Icon(
                                playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                            ),
                            IconButton(
                              key: const ValueKey('cast-float-stop'),
                              tooltip: '退出投屏',
                              onPressed: service.stop,
                              iconSize: 22,
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
