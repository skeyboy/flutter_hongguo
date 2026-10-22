import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Vertical swipe to the next/previous episode, plus its one-time hint.
///
/// Only fingers may switch episodes: a mouse drag over the picture is a desktop
/// mis-gesture, and the desktop path already has buttons and Page Up/Down.
class EpisodeSwipeArea extends StatefulWidget {
  const EpisodeSwipeArea({
    super.key,
    required this.child,
    required this.blocked,
    required this.onStep,
    this.onBlocked,
    this.hintText,
    this.onHintSeen,
    this.hintDuration = const Duration(seconds: 3),
  });

  final Widget child;

  /// True while preparation, an overlay or a remote session owns the picture.
  final bool Function() blocked;
  final ValueChanged<int> onStep;

  /// Reported when a swipe was dropped, so the page can explain the one case
  /// where silence would look like a broken gesture.
  final ValueChanged<int>? onBlocked;
  final String? hintText;
  final VoidCallback? onHintSeen;
  final Duration hintDuration;

  static const double dragThreshold = 80;
  static const double flingThreshold = 800;

  static bool fromFinger(PointerDeviceKind? kind) =>
      kind == PointerDeviceKind.touch || kind == PointerDeviceKind.stylus;

  @override
  State<EpisodeSwipeArea> createState() => _EpisodeSwipeAreaState();
}

class _EpisodeSwipeAreaState extends State<EpisodeSwipeArea> {
  static const _fade = Duration(milliseconds: 220);

  double _drag = 0;
  bool _finger = false, _hintSeen = false;

  /// 0 absent, 1 on screen, 2 fading out. The overlay stays mounted while it
  /// fades so the opacity change can animate.
  int _hint = 0;
  Timer? _hideHint, _reportHint;

  Duration get _fadeTime =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : _fade;

  @override
  void initState() {
    super.initState();
    if (widget.hintText != null) {
      _hint = 1;
      _countDownHint();
    }
  }

  @override
  void didUpdateWidget(covariant EpisodeSwipeArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.hintText == oldWidget.hintText) return;
    if (widget.hintText == null) {
      // Casting, floating or an error took the picture away mid-hint. Retire it
      // as spent: a hint that pops back after the next episode loads reads as a
      // bug, and it would otherwise render as an empty pill without its text.
      _retireHint();
      return;
    }
    // The page withholds the hint until playback is ready, so the text can
    // arrive after this widget's first build.
    if (_hint == 0 && !_hintSeen) {
      setState(() => _hint = 1);
      _countDownHint();
    }
  }

  void _countDownHint() {
    _hideHint?.cancel();
    _hideHint = Timer(widget.hintDuration, () {
      if (!mounted || _hint == 0) return;
      setState(() => _hint = 2);
      _reportHint?.cancel();
      _reportHint = Timer(_fadeTime, _retireHint);
    });
  }

  void _retireHint() {
    _hideHint?.cancel();
    _reportHint?.cancel();
    if (!mounted || _hintSeen) return;
    setState(() {
      _hint = 0;
      _hintSeen = true;
    });
    widget.onHintSeen?.call();
  }

  void _onStart(DragStartDetails details) {
    _drag = 0;
    _finger = EpisodeSwipeArea.fromFinger(details.kind);
  }

  void _onUpdate(DragUpdateDetails details) {
    if (_finger) _drag += details.delta.dy;
  }

  void _onEnd(DragEndDetails details) {
    if (!_finger) return;
    _finger = false;
    final velocity = details.primaryVelocity ?? 0;
    if (_drag.abs() <= EpisodeSwipeArea.dragThreshold &&
        velocity.abs() <= EpisodeSwipeArea.flingThreshold) {
      return;
    }
    // A flick can report no distance, so its velocity alone carries direction.
    final offset = (_drag == 0 ? velocity : _drag) < 0 ? 1 : -1;
    if (widget.blocked()) {
      widget.onBlocked?.call(offset);
      return;
    }
    if (_hint != 0) _retireHint();
    widget.onStep(offset);
  }

  @override
  void dispose() {
    _hideHint?.cancel();
    _reportHint?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Positioned.fill(
        child: GestureDetector(
          onVerticalDragStart: _onStart,
          onVerticalDragUpdate: _onUpdate,
          onVerticalDragEnd: _onEnd,
          child: widget.child,
        ),
      ),
      if (_hint != 0)
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: _fadeTime,
              opacity: _hint == 1 ? 1 : 0,
              child: Align(
                alignment: const Alignment(0, -0.42),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.swap_vert,
                          color: Colors.white70,
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          widget.hintText ?? '',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
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
}
