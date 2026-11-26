import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// The platform operation this helper drives. Injectable so tests can run on
/// any host without a registered plugin.
typedef ScreenWakeLockToggle = Future<void> Function(bool enabled);

/// Keeps the screen awake while video is playing.
///
/// On Android TV the system starts a Dream (screen saver) after a period of
/// idle *input*. A foreground video is not user input, so the box can dim and
/// stop the Activity mid-episode, which pauses the `video_player` platform
/// view used by the TV build. `wakelock_plus` sets/clears
/// `FLAG_KEEP_SCREEN_ON` on the foreground Activity window on Android, which
/// prevents the Dream from taking over.
///
/// The mobile/desktop path is deliberately left alone: `media_kit_video`'s
/// `Video` widget already owns a reference-counted wakelock there, so callers
/// should only drive this helper on the TV playback path.
class ScreenWakeLock {
  ScreenWakeLock({ScreenWakeLockToggle? toggle, bool Function()? supported})
    : _toggle = toggle ?? _platformToggle,
      _supported = supported ?? _defaultSupported;

  final ScreenWakeLockToggle _toggle;
  final bool Function() _supported;

  /// Whether this helper currently wants the lock held.
  bool _active = false;
  bool get active => _active;

  /// Platform calls are serialised so a slow `enable` cannot land after a
  /// newer `disable` and leave the lock held once the player page is gone.
  Future<void> _tail = Future<void>.value();

  /// Enable while playback is active, disable when it is not. Idempotent.
  Future<void> setActive(bool active) {
    if (!_supported()) {
      // A supported override can change at runtime; never keep a stale flag.
      _active = false;
      return Future<void>.value();
    }
    if (active == _active) return _tail;
    _active = active;
    final next = _tail.then((_) async {
      try {
        await _toggle(active);
      } catch (_) {
        // A platform refusal must never break playback. Roll the local flag
        // back so a later request can try again from a clean state.
        if (_active == active) _active = !active;
      }
    });
    _tail = next;
    return next;
  }

  Future<void> acquire() => setActive(true);

  Future<void> release() => setActive(false);

  /// Call from the player page's dispose / route pop. The release is ordered
  /// after any queued acquire, so leaving the page cannot re-acquire the lock.
  Future<void> dispose() => release();

  static bool _defaultSupported() =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> _platformToggle(bool enabled) async {
    if (!_defaultSupported()) return;
    try {
      await WakelockPlus.toggle(enable: enabled);
    } on MissingPluginException catch (_) {
      // Not registered in this build/test: a wake lock is best effort.
    } catch (_) {
      // Device refused to change the flag; playback must carry on regardless.
    }
  }
}
