import 'package:flutter/foundation.dart';
import 'package:hongguo_api/hongguo_api.dart';

/// The one sentence a page pushed above the discover page can say to it:
/// 「回到发现页，并把主题行收窄到这个词」.
///
/// 主题 is the discover page's own state, and a route sitting above it has no
/// `setState` to borrow, so the ask travels through this process-wide object the
/// same way `relatedDramaLoader` does (one device-wide vocabulary, memory-only).
/// The discover page publishes the 类型 it is standing on, because the panel is
/// published per 类型: mapping a drama's genre words against a different type's
/// table would paint a chip that the theme row it lands on has never heard of.
class CatalogThemeHandoff extends ChangeNotifier {
  String _genre = 'short_play';
  String get genre => _genre;

  CatalogFilter? _asked;

  /// Written by the discover page wherever its 一级 actually settles.
  set genre(String value) {
    if (_genre == value) return;
    _genre = value;
    notifyListeners();
  }

  /// Written by a 标签 chip, which pops back to the discover page right after.
  void ask(CatalogFilter theme) {
    _asked = theme;
    notifyListeners();
  }

  /// Read once: an ask nobody takes cannot fire a second time.
  CatalogFilter? take() {
    final value = _asked;
    _asked = null;
    return value;
  }
}

final catalogThemeHandoff = CatalogThemeHandoff();
