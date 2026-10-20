import 'dart:async';

import 'package:flutter/material.dart';

/// Touch controls cover the picture instead of reserving its height.
class CompactControls extends StatefulWidget {
  final Widget video, controls;
  final bool playing, busy;
  const CompactControls({
    super.key,
    required this.video,
    required this.controls,
    required this.playing,
    required this.busy,
  });
  @override
  State<CompactControls> createState() => CompactControlsState();
}

class CompactControlsState extends State<CompactControls> {
  bool visible = true;
  Timer? timer;
  final pointers = <int>{};
  bool get mayHide =>
      visible &&
      widget.playing &&
      !widget.busy &&
      pointers.isEmpty &&
      !MediaQuery.accessibleNavigationOf(context);
  void _schedule() {
    timer?.cancel();
    if (mayHide) {
      timer = Timer(const Duration(seconds: 5), () {
        if (mounted && mayHide) hide();
      });
    }
  }

  void show() {
    setState(() => visible = true);
    _schedule();
  }

  void hide() {
    timer?.cancel();
    pointers.clear();
    setState(() => visible = false);
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
      _schedule();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Positioned.fill(
        child: Listener(
          onPointerDown: (event) {
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
          child: SizedBox.expand(
            key: const ValueKey('compact-player-picture'),
            child: widget.video,
          ),
        ),
      ),
      if (visible)
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Listener(
            onPointerDown: (event) {
              pointers.add(event.pointer);
              _schedule();
            },
            onPointerUp: (event) {
              pointers.remove(event.pointer);
              _schedule();
            },
            onPointerCancel: (event) {
              pointers.remove(event.pointer);
              _schedule();
            },
            child: Material(
              key: const ValueKey('compact-playback-controls'),
              color: Colors.black.withValues(alpha: .78),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      tooltip: '隐藏播放操作',
                      onPressed: hide,
                      icon: const Icon(Icons.expand_more),
                      color: Colors.white,
                    ),
                  ),
                  widget.controls,
                ],
              ),
            ),
          ),
        ),
    ],
  );
}
