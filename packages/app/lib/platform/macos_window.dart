import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'background/host_policy.dart';

final macPlaybackRoutes = RouteObserver<PageRoute<dynamic>>();

/// AppKit owns the window; Flutter owns which playback route is visible.
class MacWindow {
  static const channel = MethodChannel('hongguo/macos-window');
  static final _players = <Object>{};
  static final _pinnedPlayers = <Object>{};
  static Future<void> invoke(String method, [Object? arguments]) async {
    if (!macHost) return;
    try {
      await channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Tests and other hosts have no AppKit window.
    } on PlatformException catch (error) {
      debugPrint('Mac window $method: ${error.code}');
    }
  }

  static Future<void> playerVisible(Object owner, bool visible) async {
    if (visible) {
      _players.add(owner);
    } else {
      _players.remove(owner);
    }
    await invoke('immersive', _players.isNotEmpty);
    await _applyTopmost();
  }

  static Future<void> playerPinned(Object owner, bool pinned) {
    if (pinned) {
      _pinnedPlayers.add(owner);
    } else {
      _pinnedPlayers.remove(owner);
    }
    return _applyTopmost();
  }

  static Future<void> releasePlayer(Object owner) {
    _pinnedPlayers.remove(owner);
    return playerVisible(owner, false);
  }

  static Future<void> _applyTopmost() =>
      invoke('topmost', _players.any(_pinnedPlayers.contains));
}

/// Normal pages reserve caption space; the video page owns its own overlay.
class MacWindowFrame extends StatelessWidget {
  final Widget child;
  final bool immersive;
  const MacWindowFrame({
    super.key,
    required this.child,
    this.immersive = false,
  });
  @override
  Widget build(BuildContext context) {
    if (!macHost) return child;
    return Overlay.wrap(
      child: Column(
        children: [
          immersive ? const SizedBox.shrink() : const _MacCaption(),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _MacCaption extends StatelessWidget {
  const _MacCaption();
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: SizedBox(
      key: const ValueKey('mac-window-caption'),
      height: 32,
      child: Row(
        children: [
          const SizedBox(width: 6),
          _CaptionButton(
            label: '隐藏窗口',
            color: const Color(0xffff5f57),
            icon: Icons.close,
            action: 'hide',
          ),
          _CaptionButton(
            label: '最小化窗口',
            color: const Color(0xffffbd2e),
            icon: Icons.remove,
            action: 'minimize',
          ),
          _CaptionButton(
            label: '切换全屏',
            color: const Color(0xff28c840),
            icon: Icons.open_in_full,
            action: 'fullscreenToggle',
          ),
          Expanded(
            child: GestureDetector(
              key: const ValueKey('mac-window-drag-area'),
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => MacWindow.invoke('drag'),
              onDoubleTap: () => MacWindow.invoke('zoom'),
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    ),
  );
}

class _CaptionButton extends StatefulWidget {
  final String label, action;
  final Color color;
  final IconData icon;
  const _CaptionButton({
    required this.label,
    required this.action,
    required this.color,
    required this.icon,
  });
  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool hovered = false, focused = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => hovered = true),
    onExit: (_) => setState(() => hovered = false),
    child: Focus(
      canRequestFocus: false,
      onFocusChange: (value) {
        if (mounted) setState(() => focused = value);
      },
      child: SizedBox(
        width: 24,
        height: 32,
        child: IconButton(
          key: ValueKey('mac-window-${widget.action}'),
          tooltip: widget.label,
          padding: EdgeInsets.zero,
          onPressed: () => MacWindow.invoke(widget.action),
          icon: Container(
            width: 13,
            height: 13,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
            ),
            child: hovered || focused
                ? Icon(widget.icon, size: 10, color: Colors.black87)
                : null,
          ),
        ),
      ),
    ),
  );
}
