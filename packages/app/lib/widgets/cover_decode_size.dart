import 'dart:async';

import 'package:flutter/foundation.dart';

/// Decode sizes come in a ladder rather than the measured cell width: a window
/// drag changes that width every logical pixel, and a new decode size is a new
/// image provider, which rebuilds the image widget out of its slot and drops it
/// back onto its placeholder for a frame.
const int _bucketStep = 128, _minBucket = 128, _maxBucket = 1664;

/// The device-pixel width the artwork should be decoded to for a cell of
/// [logicalWidth], rounded up to the ladder. Zero means "no finite width was
/// measured", which the caller passes on as an unbounded decode.
int coverDecodeBucket(double logicalWidth, double devicePixelRatio) {
  if (!logicalWidth.isFinite ||
      logicalWidth <= 0 ||
      !devicePixelRatio.isFinite ||
      devicePixelRatio <= 0) {
    return 0;
  }
  final pixels = (logicalWidth * devicePixelRatio).ceil();
  final bucket = ((pixels + _bucketStep - 1) ~/ _bucketStep) * _bucketStep;
  return bucket.clamp(_minBucket, _maxBucket);
}

/// Whether the viewport is still being resized. Lists hold the decode size they
/// last committed while this reads true, and re-decode once when it settles.
class ResizeGate {
  ResizeGate._();

  static final ResizeGate instance = ResizeGate._();

  static const Duration _settle = Duration(milliseconds: 250);

  final ValueNotifier<bool> holding = ValueNotifier<bool>(false);
  int _touches = 0;
  int _watchers = 0;
  Timer? _release;

  /// Cells that are on screen want to hear when the resizing settles. Counting
  /// them is what lets the window's timer go away with the last one, rather than
  /// outliving every listener and holding the gate shut for nobody.
  void addListener(VoidCallback listener) {
    _watchers++;
    holding.addListener(listener);
  }

  void removeListener(VoidCallback listener) {
    holding.removeListener(listener);
    if (_watchers > 0) _watchers--;
    if (_watchers > 0) return;
    _release?.cancel();
    _release = null;
    holding.value = false;
  }

  /// Called by every layout pass that measures a size, so a drag that keeps
  /// arriving keeps the gate closed instead of settling mid-gesture.
  void touch() {
    _touches++;
    if (holding.value) return;
    holding.value = true;
    _scheduleRelease();
  }

  /// One timer per settle window: it re-arms when it wakes to find more
  /// measurements than the ones it went to sleep on, rather than being cancelled
  /// and recreated by every cell of every frame.
  void _scheduleRelease() {
    final seen = _touches;
    _release?.cancel();
    _release = Timer(_settle, () {
      _release = null;
      if (_touches != seen) {
        _scheduleRelease();
        return;
      }
      holding.value = false;
    });
  }

  /// Between cases the window whose timer was left running no longer exists, so
  /// a gate closed by the previous case would never open again.
  @visibleForTesting
  void debugReset() {
    _release?.cancel();
    _release = null;
    _touches = 0;
    _watchers = 0;
    holding.value = false;
  }
}
