import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android stops delivering multicast and broadcast Wi-Fi traffic to an app
/// that holds no `MulticastLock`, and SSDP discovery is silent without it.
///
/// Only the Android host has the lock; every other platform is a no-op, and a
/// denied permission degrades to "the device list stays empty" rather than an
/// exception the player screen would have to catch.
class MulticastLock {
  MulticastLock([this._channel = const MethodChannel('hongguo/multicast')]);

  final MethodChannel _channel;
  bool _held = false;

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> acquire() async {
    if (!_supported || _held) return;
    try {
      await _channel.invokeMethod<void>('acquire');
      _held = true;
    } on PlatformException {
      /* permission missing: discovery keeps working where it does not need it */
    } on MissingPluginException {
      /* host built without the Android plugin registrant */
    }
  }

  Future<void> release() async {
    if (!_supported || !_held) return;
    _held = false;
    try {
      await _channel.invokeMethod<void>('release');
    } on PlatformException {
      /* already gone */
    } on MissingPluginException {
      /* already gone */
    }
  }
}
