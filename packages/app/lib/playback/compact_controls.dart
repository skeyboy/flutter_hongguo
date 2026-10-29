import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One visibility clock for title, exit and transport, for touch and mouse.
class CompactControls extends StatefulWidget {
  final Widget video, controls;
  final Widget? header;

  /// The picture's own feedback layer (centre play, seek ripple, buffer ring).
  /// It is drawn whether or not the bars are up, because a double tap that
  /// landed mid-clip has to answer even when there is no button to press.
  final Widget? center;
  final bool playing, busy;

  /// Touch hosts keep the old contract — the first tap after the bars have faded
  /// only brings them back. A mouse has hover for that, so a click is free to be
  /// play/pause instead.
  final bool touch;
  final Duration hideAfter;
  final ValueChanged<bool>? onVisibilityChanged;
  final VoidCallback? onTogglePlay;

  /// A double tap on the left or right third; the page seeks and flashes.
  final ValueChanged<int>? onSeekBy;

  /// Hold-to-accelerate, touch hosts only.
  final ValueChanged<bool>? onSpeedBoost;
  const CompactControls({
    super.key,
    required this.video,
    required this.controls,
    required this.playing,
    required this.busy,
    this.touch = true,
    this.header,
    this.center,
    this.hideAfter = const Duration(seconds: 3),
    this.onVisibilityChanged,
    this.onTogglePlay,
    this.onSeekBy,
    this.onSpeedBoost,
  });
  @override
  State<CompactControls> createState() => CompactControlsState();
}

class CompactControlsState extends State<CompactControls> {
  bool visible = true, keyboardFocus = false, wokeOnDown = false;
  bool keyboardReveal = false;

  /// A pointer parked on the progress bar: the bars must not fade while the
  /// viewer is lining up a landing point.
  bool progressHold = false;
  Timer? timer;
  final pointers = <int>{};

  /// Where the first tap of a double tap landed, as a fraction of the width.
  double? _doubleFraction;
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_keyboardActivity);
  }

  bool _keyboardActivity(KeyEvent event) {
    if (event is KeyDownEvent &&
        mounted &&
        ModalRoute.of(context)?.isCurrent != false &&
        FocusScope.of(context).hasFocus) {
      keyboardReveal = true;
      if (event.logicalKey == LogicalKeyboardKey.tab) keyboardFocus = true;
      show();
    }
    return false;
  }

  bool get mayHide =>
      visible &&
      widget.playing &&
      !widget.busy &&
      pointers.isEmpty &&
      !progressHold &&
      !keyboardFocus &&
      !MediaQuery.accessibleNavigationOf(context);

  void holdOnProgress(bool value) {
    if (progressHold == value) return;
    progressHold = value;
    if (value) {
      show();
    } else {
      _schedule();
    }
  }

  void _schedule() {
    timer?.cancel();
    if (mayHide) {
      timer = Timer(widget.hideAfter, () {
        if (mounted && mayHide) hide();
      });
    }
  }

  void pointerActivity() {
    keyboardFocus = false;
    keyboardReveal = false;
    show();
  }

  void show() {
    if (!visible) {
      setState(() => visible = true);
      widget.onVisibilityChanged?.call(true);
    }
    _schedule();
  }

  void hide() {
    if (!visible ||
        !widget.playing ||
        widget.busy ||
        MediaQuery.accessibleNavigationOf(context)) {
      return;
    }
    timer?.cancel();
    setState(() => visible = false);
    widget.onVisibilityChanged?.call(false);
  }

  /// A tap on the picture. Under a mouse this is the play key, because hover
  /// already handles waking; under a finger it stays the wake-and-toggle the
  /// touch contract promises.
  void _tap() {
    final woke = wokeOnDown;
    wokeOnDown = false;
    if (!widget.touch) {
      widget.onTogglePlay?.call();
      return;
    }
    if (woke) {
      // The pointer-down already showed the bars; this tap's job was only that.
    } else if (visible) {
      hide();
    } else {
      show();
    }
  }

  void _doubleTap() {
    wokeOnDown = false;
    final at = _doubleFraction;
    _doubleFraction = null;
    if (at != null && at < .35) {
      widget.onSeekBy?.call(-10);
    } else if (at != null && at > .65) {
      widget.onSeekBy?.call(10);
    } else {
      widget.onTogglePlay?.call();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant CompactControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing != oldWidget.playing || widget.busy != oldWidget.busy) {
      if (!widget.playing || widget.busy) {
        // Parent playback state can change while the controls are hidden.
        visible = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onVisibilityChanged?.call(true);
        });
      }
      _schedule();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    HardwareKeyboard.instance.removeHandler(_keyboardActivity);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent) {
        if (event.logicalKey == LogicalKeyboardKey.tab) keyboardFocus = true;
        show();
      }
      return KeyEventResult.ignored;
    },
    onFocusChange: (value) {
      if (!value) {
        keyboardFocus = false;
        _schedule();
      }
    },
    child: MouseRegion(
      cursor: visible ? MouseCursor.defer : SystemMouseCursors.none,
      onEnter: (event) {
        if (event.kind == PointerDeviceKind.mouse) {
          keyboardFocus = false;
          keyboardReveal = false;
          show();
        }
      },
      onExit: (_) {
        keyboardFocus = false;
        _schedule();
      },
      onHover: (event) {
        if (event.kind == PointerDeviceKind.mouse &&
            event.delta.distanceSquared > 0) {
          keyboardFocus = false;
          keyboardReveal = false;
          show();
        }
      },
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          wokeOnDown = !visible;
          keyboardReveal = false;
          keyboardFocus = false;
          pointers.add(event.pointer);
          show();
        },
        onPointerUp: (event) {
          pointers.remove(event.pointer);
          _schedule();
        },
        onPointerCancel: (event) {
          pointers.remove(event.pointer);
          _schedule();
        },
        onPointerSignal: (_) => show(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              // The gestures belong to the picture, not to everything above it:
              // a double-tap recognizer that is also an ancestor of the buttons
              // holds the arena and the button never answers.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _tap,
                onDoubleTapDown: (event) {
                  final width = context.size?.width ?? 0;
                  _doubleFraction = width <= 0
                      ? null
                      : event.localPosition.dx / width;
                },
                onDoubleTap: _doubleTap,
                onLongPressStart: widget.touch
                    ? (_) => widget.onSpeedBoost?.call(true)
                    : null,
                onLongPressEnd: widget.touch
                    ? (_) => widget.onSpeedBoost?.call(false)
                    : null,
                onLongPressCancel: widget.touch
                    ? () => widget.onSpeedBoost?.call(false)
                    : null,
                child: SizedBox.expand(
                  key: const ValueKey('compact-player-picture'),
                  child: widget.video,
                ),
              ),
            ),
            if (widget.center != null) widget.center!,
            IgnorePointer(
              ignoring: !visible,
              child: ExcludeFocus(
                excluding: !visible,
                child: ExcludeSemantics(
                  excluding: !visible,
                  child: AnimatedSwitcher(
                    duration:
                        keyboardReveal ||
                            MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 140),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeOutCubic,
                    child: !visible
                        ? const SizedBox.shrink()
                        : Stack(
                            key: const ValueKey('player-chrome'),
                            fit: StackFit.expand,
                            children: [
                              if (widget.header != null)
                                Positioned(
                                  top: 0,
                                  left: 0,
                                  right: 0,
                                  child: widget.header!,
                                ),
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: Material(
                                  key: const ValueKey(
                                    'compact-playback-controls',
                                  ),
                                  color: Colors.black.withValues(alpha: .72),
                                  child: widget.controls,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
