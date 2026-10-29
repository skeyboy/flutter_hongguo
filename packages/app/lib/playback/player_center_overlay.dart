import 'dart:async';

import 'package:flutter/material.dart';

/// The picture's own feedback layer: what to press when the clip is stopped, and
/// what just happened when a gesture moved it.
///
/// It sits under the control bar in the stack, so a tap on the bar never reaches
/// the centre button, and it never covers the bar itself.
class PlayerCenterOverlay extends StatefulWidget {
  const PlayerCenterOverlay({
    super.key,
    required this.playing,
    required this.busy,
    required this.touch,
    this.buffering = false,
    this.onPlay,
  });

  final bool playing, busy, buffering, touch;
  final VoidCallback? onPlay;

  @override
  State<PlayerCenterOverlay> createState() => PlayerCenterOverlayState();
}

class PlayerCenterOverlayState extends State<PlayerCenterOverlay> {
  static const _showFor = Duration(milliseconds: 900);

  int? _flash;
  Timer? _flashTimer;

  /// Called for a ±10s move so the viewer sees which half answered, including
  /// when the chrome is hidden and no button exists to press.
  void flashSeek(int seconds) {
    _flashTimer?.cancel();
    setState(() => _flash = seconds);
    _flashTimer = Timer(_showFor, () {
      if (mounted) setState(() => _flash = null);
    });
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    super.dispose();
  }

  Widget _pill(String label, IconData icon) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .55),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final seconds = _flash;
    final showPlay =
        !widget.playing &&
        !widget.busy &&
        seconds == null &&
        widget.onPlay != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.buffering && !widget.busy)
          const Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: EdgeInsets.only(top: 64, right: 16),
              child: SizedBox(
                key: ValueKey('player-buffering'),
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: Colors.white70,
                ),
              ),
            ),
          ),
        if (seconds != null)
          Align(
            alignment: seconds < 0
                ? Alignment.centerLeft
                : Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: _pill(
                '${seconds > 0 ? '+' : '-'}${seconds.abs()}s',
                seconds > 0
                    ? Icons.fast_forward_rounded
                    : Icons.fast_rewind_rounded,
              ),
            ),
          )
        else if (showPlay)
          Center(
            child: Semantics(
              button: true,
              label: '继续播放',
              child: IconButton(
                key: const ValueKey('player-center-play'),
                tooltip: '继续播放',
                iconSize: widget.touch ? 40 : 46,
                onPressed: widget.onPlay,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: .45),
                  foregroundColor: Colors.white,
                  minimumSize: Size(
                    widget.touch ? 68 : 78,
                    widget.touch ? 68 : 78,
                  ),
                ),
                icon: const Icon(Icons.play_arrow_rounded),
              ),
            ),
          ),
      ],
    );
  }
}
