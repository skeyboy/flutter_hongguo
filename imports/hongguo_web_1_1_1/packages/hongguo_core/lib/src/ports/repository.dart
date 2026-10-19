import '../models/models.dart';

abstract interface class CatalogRepository {
  Future<Page<Series>> search(String query, {int offset = 0, int limit = 20});
  Future<Page<Series>> browse({
    String genre = 'short_play',
    int offset = 0,
    int limit = 20,
    Set<String> seen = const {},
  });
  Future<SeriesDetail> detail(String seriesId);
}

abstract interface class PlaybackRepository {
  Future<MediaSource> prepare(
    String vid, {
    String quality = 'best',
    CancellationToken? cancellation,
    void Function(PreparationState)? onState,
  });
}

enum PreparationState {
  queued,
  downloading,
  decrypting,
  remuxing,
  ready,
  failed,
  cancelled,
}

class PreparationCancelled implements Exception {
  const PreparationCancelled();
  @override
  String toString() => '播放准备已取消';
}

class CancellationToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];
  bool get isCancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }

  void check() {
    if (_cancelled) throw const PreparationCancelled();
  }

  void Function() listen(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}
