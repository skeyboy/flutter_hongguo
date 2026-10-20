import 'package:flutter/foundation.dart';
import 'package:hongguo_api/hongguo_api.dart';

import '../catalog/library_cache.dart' show dramaJson;
import '../settings/settings_store.dart';

class WatchRecord {
  final Drama drama;
  final String vid, quality;
  final int episode, positionMs, durationMs;
  final bool local, finished;
  final DateTime updated;
  const WatchRecord({
    required this.drama,
    required this.vid,
    required this.episode,
    required this.positionMs,
    required this.durationMs,
    required this.updated,
    this.quality = 'best',
    this.local = false,
    this.finished = false,
  });
  bool get completed =>
      finished || (durationMs > 0 && positionMs >= durationMs);
  Duration get resumeAt =>
      completed ? Duration.zero : Duration(milliseconds: positionMs);
  Map<String, dynamic> toJson() => {
    'drama': dramaJson(drama),
    'vid': vid,
    'episode': episode,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'updated': updated.toUtc().toIso8601String(),
    'quality': quality,
    'local': local,
    'finished': finished,
  };
  factory WatchRecord.fromJson(Map<String, dynamic> json) => WatchRecord(
    drama: Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
    vid: json['vid'] as String,
    episode: json['episode'] as int,
    positionMs: (json['positionMs'] as int).clamp(0, 1 << 40),
    durationMs: (json['durationMs'] as int).clamp(0, 1 << 40),
    updated: DateTime.parse(json['updated'] as String),
    quality: json['quality'] as String? ?? 'best',
    local: json['local'] == true,
    finished: json['finished'] == true,
  );
}

/// Personal data is independent of feed/video eviction and signing credentials.
/// Commit before notifying; serialize all edits to prevent lost progress/favorites.
class PersonalLibrary extends ChangeNotifier {
  final PreferencesBackend? backend;
  PersonalLibrary({this.backend});
  final _favorites = <String, Drama>{};
  final _history = <String, WatchRecord>{};
  final _episodes = <String, WatchRecord>{};
  static String _key(String dramaId, String vid) => '$dramaId:$vid';
  WatchRecord? latestFor(String dramaId) => _history[dramaId];
  WatchRecord? episodeFor(String dramaId, String vid) =>
      _episodes[_key(dramaId, vid)];

  ({int index, Duration offset}) playbackStart(
    DramaDetail detail, {
    int? selected,
  }) {
    var index =
        selected ??
        detail.episodes.indexWhere(
          (e) => e.vid == latestFor(detail.drama.id)?.vid,
        );
    if (index < 0 || index >= detail.episodes.length) index = 0;
    if (detail.episodes.isEmpty) return (index: 0, offset: Duration.zero);
    final saved = episodeFor(detail.drama.id, detail.episodes[index].vid);
    return (index: index, offset: saved?.resumeAt ?? Duration.zero);
  }

  Future<void>? _loading;
  Future<void> _writes = Future.value();
  List<Drama> get favorites =>
      List.unmodifiable(_favorites.values.toList().reversed);
  List<WatchRecord> get history => List.unmodifiable(
    _history.values.toList()..sort((a, b) => b.updated.compareTo(a.updated)),
  );
  bool isFavorite(String id) => _favorites.containsKey(id);
  Future<void> load() => _loading ??= _load().catchError((Object error) {
    _loading = null;
    throw error;
  });
  Future<void> _load() async {
    final data = await backend?.read();
    if (data == null) return;
    if (data['version'] != 1) throw StateError('个人记录版本不受支持');
    final favorites = <String, Drama>{};
    final history = <String, WatchRecord>{};
    for (final value in data['favorites'] as List? ?? []) {
      final drama = Drama.fromJson(Map<String, dynamic>.from(value as Map));
      if (drama.id.isNotEmpty) favorites[drama.id] = drama;
    }
    for (final value in data['history'] as List? ?? []) {
      final record = WatchRecord.fromJson(
        Map<String, dynamic>.from(value as Map),
      );
      if (record.drama.id.isNotEmpty && record.vid.isNotEmpty) {
        history[record.drama.id] = record;
      }
    }
    final episodes = <String, WatchRecord>{
      for (final r in history.values) _key(r.drama.id, r.vid): r,
    };
    for (final value in data['episodeHistory'] as List? ?? []) {
      final record = WatchRecord.fromJson(
        Map<String, dynamic>.from(value as Map),
      );
      final key = _key(record.drama.id, record.vid);
      if (record.drama.id.isNotEmpty &&
          record.vid.isNotEmpty &&
          (episodes[key] == null ||
              !episodes[key]!.updated.isAfter(record.updated))) {
        episodes[key] = record;
      }
    }
    _favorites.addAll(favorites);
    _history.addAll(history);
    _episodes.addAll(episodes);
    notifyListeners();
  }

  Future<void> _edit(
    void Function(
      Map<String, Drama>,
      Map<String, WatchRecord>,
      Map<String, WatchRecord>,
    )
    edit,
  ) {
    final result = _writes.then((_) async {
      await load();
      final favorites = Map<String, Drama>.from(_favorites);
      final history = Map<String, WatchRecord>.from(_history);
      final episodes = Map<String, WatchRecord>.from(_episodes);
      edit(favorites, history, episodes);
      final ordered = history.values.toList()
        ..sort((a, b) => b.updated.compareTo(a.updated));
      final retained = {for (final r in ordered.take(500)) r.drama.id: r};
      final episodeValues =
          episodes.values
              .where((r) => retained.containsKey(r.drama.id))
              .toList()
            ..sort((a, b) => b.updated.compareTo(a.updated));
      final retainedEpisodes = {
        for (final r in episodeValues.take(10000)) _key(r.drama.id, r.vid): r,
      };
      await backend?.write({
        'version': 1,
        'favorites': favorites.values.map(dramaJson).toList(),
        'history': retained.values.map((r) => r.toJson()).toList(),
        'episodeHistory': retainedEpisodes.values
            .map((r) => r.toJson())
            .toList(),
      });
      _favorites
        ..clear()
        ..addAll(favorites);
      _history
        ..clear()
        ..addAll(retained);
      _episodes
        ..clear()
        ..addAll(retainedEpisodes);
      notifyListeners();
    });
    _writes = result.catchError((Object _) {});
    return result;
  }

  Future<void> toggleFavorite(Drama drama) => _edit((favorites, _, _) {
    if (favorites.containsKey(drama.id)) {
      favorites.remove(drama.id);
    } else {
      if (favorites.length >= 2000) throw StateError('收藏已达 2000 部，请先整理收藏');
      favorites[drama.id] = drama;
    }
  });
  Future<void> record(WatchRecord value) => _edit((_, history, episodes) {
    final key = _key(value.drama.id, value.vid);
    final previous = episodes[key];
    if (previous == null || !previous.updated.isAfter(value.updated)) {
      episodes[key] = value;
    }
    final old = history[value.drama.id];
    if (old == null || !old.updated.isAfter(value.updated)) {
      history[value.drama.id] = value;
    }
  });
  Future<void> removeHistory(String id) => _edit((_, history, episodes) {
    history.remove(id);
    episodes.removeWhere((_, value) => value.drama.id == id);
  });
  Future<void> clearHistory() => _edit((_, history, episodes) {
    history.clear();
    episodes.clear();
  });
  Future<void> flush() => _writes;
}
