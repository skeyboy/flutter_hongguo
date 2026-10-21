import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One visibility clock for title, exit and transport, for touch and mouse.
class CompactControls extends StatefulWidget {
  final Widget video, controls;
  final Widget? header;
  final bool playing, busy;
  final Duration hideAfter;
  final ValueChanged<bool>? onVisibilityChanged;
  const CompactControls({
    super.key,
    required this.video,
    required this.controls,
    required this.playing,
    required this.busy,
    this.header,
    this.hideAfter = const Duration(seconds: 3),
    this.onVisibilityChanged,
  });
  @override
  State<CompactControls> createState() => CompactControlsState();
}

class CompactControlsState extends State<CompactControls> {
  bool visible = true, keyboardFocus = false, wokeOnDown = false;
  bool keyboardReveal = false;
  Timer? timer;
  final pointers = <int>{};
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
      !keyboardFocus &&
      !MediaQuery.accessibleNavigationOf(context);
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
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (wokeOnDown) {
              wokeOnDown = false;
            } else if (visible) {
              hide();
            } else {
              show();
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: SizedBox.expand(
                  key: const ValueKey('compact-player-picture'),
                  child: widget.video,
                ),
              ),
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
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Align(
                                          alignment: Alignment.centerRight,
                                          child: SizedBox(
                                            height: 30,
                                            child: IconButton(
                                              tooltip: '隐藏播放操作',
                                              padding: EdgeInsets.zero,
                                              onPressed: hide,
                                              icon: const Icon(
                                                Icons.expand_more,
                                                size: 20,
                                              ),
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                        widget.controls,
                                      ],
                                    ),
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
    ),
  );
}
