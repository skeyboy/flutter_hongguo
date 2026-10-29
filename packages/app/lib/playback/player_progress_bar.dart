import 'dart:async';

import 'package:flutter/material.dart';

import 'transport_player.dart';

/// `mm:ss`, switching to `h:mm:ss` once the clock passes an hour. The bar used to
/// clamp everything to minutes, which reads as `104:32` on a long episode.
String formatTransportTime(Duration value) {
  final seconds = value.isNegative ? 0 : value.inSeconds;
  String two(int n) => n.toString().padLeft(2, '0');
  if (seconds >= 3600) {
    return '${seconds ~/ 3600}:${two((seconds % 3600) ~/ 60)}:${two(seconds % 60)}';
  }
  return '${two(seconds ~/ 60)}:${two(seconds % 60)}';
}

/// A progress bar that reports where the viewer is, how far the stream has, and
/// what a pointer would land on before they commit to it.
///
/// A [Slider] could not do any of that: it has one track, no room for a hover
/// read-out, and a hit area that is whatever the thumb happens to cover.
class PlayerProgressBar extends StatefulWidget {
  const PlayerProgressBar({
    super.key,
    required this.player,
    required this.enabled,
    required this.touch,
    this.accent,
    this.onActivityChanged,
  });

  final TransportPlayer player;

  /// False while the episode has no known length: the bar still draws, but it
  /// stops answering pointers.
  final bool enabled;

  /// Touch hosts get a taller hit strip and no hover read-out, which they can
  /// never produce.
  final bool touch;

  final Color? accent;

  /// Hovering or dragging is an activity: the surrounding chrome must not fade
  /// out from under a pointer that is about to land mid-clip.
  final ValueChanged<bool>? onActivityChanged;

  @override
  State<PlayerProgressBar> createState() => PlayerProgressBarState();
}

class PlayerProgressBarState extends State<PlayerProgressBar> {
  static const _bubbleWidth = 52.0;

  /// Held while a drag is in flight: the playhead keeps moving under the finger,
  /// so the preview has to win over the stream until the viewer lets go.
  double? _preview;
  double? _hover;

  double _fractionAt(double x, double width) =>
      width <= 0 ? 0.0 : (x / width).clamp(0.0, 1.0);

  Duration get _total => widget.player.durationValue;

  void _activity(bool active) => widget.onActivityChanged?.call(active);

  Future<void> _commit(double fraction) async {
    if (_total > Duration.zero) await widget.player.seek(_total * fraction);
  }

  void _look(double x, double width) {
    final at = _fractionAt(x, width);
    if (at == _hover) return;
    setState(() => _hover = at);
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent ?? Theme.of(context).colorScheme.primary;
    return StreamBuilder<Duration>(
      stream: widget.player.duration,
      initialData: _total,
      builder: (context, duration) => StreamBuilder<Duration>(
        stream: widget.player.position,
        initialData: widget.player.positionValue,
        builder: (context, position) => StreamBuilder<Duration>(
          stream: widget.player.buffer,
          initialData: widget.player.bufferValue,
          builder: (context, buffer) {
            final total = duration.data ?? Duration.zero;
            final played = _preview ?? _ratio(position.data);
            final buffered = _ratio(buffer.data);
            return SizedBox(
              height: widget.touch ? 30 : 22,
              child: LayoutBuilder(
                builder: (context, box) {
                  final width = box.maxWidth;
                  return MouseRegion(
                    cursor: widget.enabled
                        ? SystemMouseCursors.click
                        : MouseCursor.defer,
                    onEnter: widget.touch
                        ? null
                        : (event) {
                            _look(event.localPosition.dx, width);
                            _activity(true);
                          },
                    onHover: widget.touch
                        ? null
                        : (event) => _look(event.localPosition.dx, width),
                    onExit: widget.touch
                        ? null
                        : (_) {
                            setState(() => _hover = null);
                            if (_preview == null) _activity(false);
                          },
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: widget.enabled
                                ? (d) => unawaited(
                                    _commit(
                                      _fractionAt(d.localPosition.dx, width),
                                    ),
                                  )
                                : null,
                            onHorizontalDragStart: widget.enabled
                                ? (d) {
                                    setState(
                                      () => _preview = _fractionAt(
                                        d.localPosition.dx,
                                        width,
                                      ),
                                    );
                                    _activity(true);
                                  }
                                : null,
                            onHorizontalDragUpdate: widget.enabled
                                ? (d) => setState(
                                    () => _preview = _fractionAt(
                                      d.localPosition.dx,
                                      width,
                                    ),
                                  )
                                : null,
                            onHorizontalDragEnd: widget.enabled
                                ? (_) {
                                    final at = _preview;
                                    setState(() => _preview = null);
                                    if (at != null) unawaited(_commit(at));
                                    _activity(false);
                                  }
                                : null,
                            onHorizontalDragCancel: widget.enabled
                                ? () {
                                    setState(() => _preview = null);
                                    _activity(false);
                                  }
                                : null,
                            child: Semantics(
                              slider: true,
                              enabled: widget.enabled,
                              label: '播放进度',
                              value: '${(played * 100).round()}%',
                              textDirection: Directionality.of(context),
                              child: CustomPaint(
                                painter: PlayerProgressPainter(
                                  played: played,
                                  buffered: buffered,
                                  hover: widget.touch ? null : _hover,
                                  accent: accent,
                                  engaged: _hover != null || _preview != null,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (!widget.touch &&
                            _hover != null &&
                            total > Duration.zero)
                          Positioned(
                            bottom: 18,
                            left: (width * _hover! - _bubbleWidth / 2).clamp(
                              0.0,
                              (width - _bubbleWidth).clamp(0.0, width),
                            ),
                            child: IgnorePointer(
                              child: _TimeBubble(
                                at: total * _hover!,
                                width: _bubbleWidth,
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }

  double _ratio(Duration? at) {
    final total = _total;
    if (total.inMilliseconds <= 0) return 0;
    return _fractionAt(
      (at ?? Duration.zero).inMilliseconds.toDouble(),
      total.inMilliseconds.toDouble(),
    );
  }
}

class _TimeBubble extends StatelessWidget {
  final Duration at;
  final double width;
  const _TimeBubble({required this.at, required this.width});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .82),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          formatTransportTime(at),
          key: const ValueKey('progress-bubble-time'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 11),
        ),
      ),
    ),
  );
}

class PlayerProgressPainter extends CustomPainter {
  final double played, buffered, hover;
  final Color accent;
  final bool engaged;

  PlayerProgressPainter({
    required this.played,
    required this.buffered,
    required double? hover,
    required this.accent,
    required this.engaged,
  }) : hover = hover ?? 0;

  /// A local file reports the whole clip as buffered, which is not information;
  /// the layer is only worth drawing between zero and everything.
  bool get bufferVisible => buffered > 0 && buffered < 1;

  void _bar(Canvas canvas, Rect rect, Paint paint) => canvas.drawRRect(
    RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
    paint,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final height = engaged ? 5.0 : 3.0;
    final y = (size.height - height) / 2;
    _bar(
      canvas,
      Rect.fromLTRB(0, y, size.width, y + height),
      Paint()..color = Colors.white.withValues(alpha: .24),
    );
    if (bufferVisible) {
      _bar(
        canvas,
        Rect.fromLTRB(0, y, size.width * buffered, y + height),
        Paint()..color = Colors.white.withValues(alpha: .4),
      );
    }
    _bar(
      canvas,
      Rect.fromLTRB(0, y, size.width * played, y + height),
      Paint()..color = accent,
    );
    final thumb = Offset(size.width * played, size.height / 2);
    canvas.drawCircle(
      thumb,
      engaged ? 7 : 5,
      Paint()..color = Colors.white.withValues(alpha: .34),
    );
    canvas.drawCircle(thumb, engaged ? 5 : 3.5, Paint()..color = accent);
    if (hover <= 0 || (hover - played).abs() < .005) return;
    // A second, fainter marker shows what a click would land on.
    canvas.drawCircle(
      Offset(size.width * hover, size.height / 2),
      4,
      Paint()..color = Colors.white.withValues(alpha: .8),
    );
  }

  @override
  bool shouldRepaint(PlayerProgressPainter other) =>
      other.played != played ||
      other.buffered != buffered ||
      other.hover != hover ||
      other.accent != accent ||
      other.engaged != engaged;
}
