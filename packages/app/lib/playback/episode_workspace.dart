import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Layout and temporary panel state are independent of the native Player.
class EpisodeWorkspace extends StatefulWidget {
  final Widget video, episodes;
  final bool playing, busy;
  final Duration hideAfter;
  final ValueChanged<bool>? onVisibilityChanged;
  final bool manageBack;
  final VoidCallback? onSettings;
  const EpisodeWorkspace({
    super.key,
    required this.video,
    required this.episodes,
    required this.playing,
    required this.busy,
    this.hideAfter = const Duration(seconds: 5),
    this.onVisibilityChanged,
    this.manageBack = true,
    this.onSettings,
  });
  @override
  State<EpisodeWorkspace> createState() => EpisodeWorkspaceState();
}

class EpisodeWorkspaceState extends State<EpisodeWorkspace> {
  bool _visible = false;
  bool _pinned = false, _hovering = false, _keyboardFocus = false;
  Timer? _timer;
  final _pointers = <int>{};
  final _panelFocus = FocusNode(debugLabel: 'episode-panel');

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_keyboardActivity);
  }

  bool _keyboardActivity(KeyEvent event) {
    if (event is KeyDownEvent && _panelFocus.hasFocus) {
      _keyboardFocus = true;
      _schedule();
    }
    return false;
  }

  bool get visible => _visible;
  bool get pinned => _pinned;
  bool get _mayHide =>
      visible &&
      !pinned &&
      widget.playing &&
      !widget.busy &&
      !_hovering &&
      !_keyboardFocus &&
      _pointers.isEmpty &&
      !MediaQuery.accessibleNavigationOf(context);

  void _schedule() {
    _timer?.cancel();
    if (_mayHide) {
      _timer = Timer(widget.hideAfter, () {
        if (mounted && _mayHide) hide();
      });
    }
  }

  void toggle() {
    setState(() {
      _visible = !visible;
      _pointers.clear();
      _hovering = false;
      _keyboardFocus = false;
    });
    widget.onVisibilityChanged?.call(visible);
    _schedule();
  }

  void hide() {
    if (!visible) return;
    _timer?.cancel();
    setState(() {
      _visible = false;
      _pointers.clear();
      _hovering = false;
      _keyboardFocus = false;
    });
    widget.onVisibilityChanged?.call(false);
  }

  void selected() {
    if (!pinned) hide();
  }

  void _pin() {
    setState(() => _pinned = !_pinned);
    _schedule();
  }

  @override
  void didUpdateWidget(covariant EpisodeWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing != oldWidget.playing || widget.busy != oldWidget.busy) {
      _schedule();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    HardwareKeyboard.instance.removeHandler(_keyboardActivity);
    _panelFocus.dispose();
    super.dispose();
  }

  Widget _panel() => MouseRegion(
    onEnter: (_) {
      _hovering = true;
      _schedule();
    },
    onExit: (_) {
      _hovering = false;
      _schedule();
    },
    child: Focus(
      focusNode: _panelFocus,
      onFocusChange: (focused) {
        if (!focused) {
          _keyboardFocus = false;
          _schedule();
        }
      },
      child: Listener(
        onPointerDown: (event) {
          _pointers.add(event.pointer);
          _keyboardFocus = false;
          _schedule();
        },
        onPointerUp: (event) {
          _pointers.remove(event.pointer);
          _schedule();
        },
        onPointerCancel: (event) {
          _pointers.remove(event.pointer);
          _schedule();
        },
        onPointerSignal: (_) {
          _keyboardFocus = false;
          _schedule();
        },
        child: Material(
          key: const ValueKey('episode-panel'),
          elevation: pinned ? 0 : 12,
          color: Theme.of(context).colorScheme.surface,
          child: SafeArea(
            left: false,
            child: Column(
              children: [
                Row(
                  children: [
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        '选集',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    if (widget.onSettings != null)
                      IconButton(
                        key: const ValueKey('episode-settings'),
                        tooltip: '播放设置',
                        onPressed: widget.onSettings,
                        icon: const Icon(Icons.settings_outlined, size: 20),
                      ),
                    IconButton(
                      tooltip: pinned ? '恢复自动隐藏' : '保持选集展开',
                      onPressed: _pin,
                      icon: Icon(
                        pinned ? Icons.push_pin : Icons.push_pin_outlined,
                      ),
                    ),
                    IconButton(
                      tooltip: '隐藏选集',
                      onPressed: hide,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Expanded(child: widget.episodes),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final width = math.min(340.0, size.maxWidth * .8);
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyI): toggle,
          if (visible) const SingleActivator(LogicalKeyboardKey.escape): hide,
        },
        child: Focus(
          autofocus: true,
          child: PopScope(
            canPop: !widget.manageBack || !visible,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && widget.manageBack) hide();
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: SizedBox.expand(
                    key: const ValueKey('player-picture'),
                    child: widget.video,
                  ),
                ),
                if (visible) ...[
                  Positioned.fill(
                    child: GestureDetector(
                      key: const ValueKey('episode-dismiss-area'),
                      behavior: HitTestBehavior.opaque,
                      onTap: hide,
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: .12),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    width: width,
                    child: _panel(),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}
