import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WatchRecord {
  final Series series;
  final int episode, positionMs;
  const WatchRecord(this.series, this.episode, this.positionMs);
  Map<String, dynamic> toJson() => {
    'series': series.toJson(),
    'episode': episode,
    'position_ms': positionMs,
  };
}

class LibraryStore extends ChangeNotifier {
  final SharedPreferences preferences;
  final Map<String, Series> favorites = {};
  final Map<String, WatchRecord> history = {};
  Future<void> _writes = Future.value();
  LibraryStore(this.preferences) {
    try {
      for (final value
          in jsonDecode(preferences.getString('favorites') ?? '[]') as List) {
        final s = Series.fromJson(asObject(value));
        favorites[s.id] = s;
      }
      for (final value
          in jsonDecode(preferences.getString('history') ?? '[]') as List) {
        final j = asObject(value), s = Series.fromJson(asObject(j['series']));
        history[s.id] = WatchRecord(
          s,
          intValue(j['episode'], 1),
          intValue(j['position_ms']),
        );
      }
    } on FormatException {
      favorites.clear();
      history.clear();
    }
  }
  Future<void> toggle(Series series) async {
    if (favorites.containsKey(series.id)) {
      favorites.remove(series.id);
    } else {
      favorites[series.id] = series;
    }
    notifyListeners();
    await _save();
  }

  Future<void> record(Series series, int episode, Duration position) async {
    history.remove(series.id);
    history[series.id] = WatchRecord(series, episode, position.inMilliseconds);
    while (history.length > 100) {
      history.remove(history.keys.first);
    }
    notifyListeners();
    await _save();
  }

  Future<void> _save() {
    final fav = jsonEncode(favorites.values.map((s) => s.toJson()).toList()),
        hist = jsonEncode(history.values.map((r) => r.toJson()).toList());
    return _writes = _writes.catchError((_) {}).then((_) async {
      await preferences.setString('favorites', fav);
      await preferences.setString('history', hist);
    });
  }
}
