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
