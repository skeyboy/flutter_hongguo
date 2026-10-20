import 'package:flutter/foundation.dart';

enum TvPlayerLayer { video, controls, seek, panel }

/// Pure UI state. Never holds a player, transport, content key or file.
class TvPlayerState extends ChangeNotifier {
  TvPlayerLayer layer = TvPlayerLayer.video;
  Duration preview = Duration.zero;
  void showControls() {
    layer = TvPlayerLayer.controls;
    notifyListeners();
  }

  void openPanel() {
    layer = TvPlayerLayer.panel;
    notifyListeners();
  }

  void seekBy(Duration delta, Duration position, Duration duration) {
    if (layer != TvPlayerLayer.seek) preview = position;
    final end = duration.inMilliseconds.clamp(0, 1 << 53);
    preview = Duration(
      milliseconds: (preview + delta).inMilliseconds.clamp(0, end),
    );
    layer = TvPlayerLayer.seek;
    notifyListeners();
  }

  Duration? commit() {
    if (layer != TvPlayerLayer.seek) return null;
    final target = preview;
    layer = TvPlayerLayer.video;
    notifyListeners();
    return target;
  }

  /// True means consumed one layer; false means the route should pop.
  bool back() {
    if (layer == TvPlayerLayer.video) return false;
    layer = layer == TvPlayerLayer.panel
        ? TvPlayerLayer.controls
        : TvPlayerLayer.video;
    notifyListeners();
    return true;
  }
}
