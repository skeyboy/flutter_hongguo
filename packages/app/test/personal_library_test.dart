import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/personal/personal_library.dart';
import 'package:hongguo_app/settings/settings_store.dart';

class MemoryBackend implements PreferencesBackend {
  Map<String, dynamic>? data;
  bool fail = false;
  @override
  Future<Map<String, dynamic>?> read() async => data;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    if (fail) throw StateError('disk full');
    data = value;
  }
}

const drama = Drama(id: 'a', title: '山海之间', episodeCount: 9);
WatchRecord record(int seconds, {int day = 1, bool local = false}) =>
    WatchRecord(
      drama: drama,
      vid: 'v3',
      episode: 3,
      positionMs: seconds * 1000,
      durationMs: 120000,
      updated: DateTime(2026, 10, day),
      local: local,
      quality: '720p',
    );
void main() {
  test(
    'favorites and progress persist across reopen, clear independently',
    () async {
      final backend = MemoryBackend();
      final library = PersonalLibrary(backend: backend);
      await Future.wait([
        library.toggleFavorite(drama),
        library.record(record(42, local: true)),
      ]);
      final restored = PersonalLibrary(backend: backend);
      await restored.load();
      expect(restored.favorites.single.title, drama.title);
      expect(restored.history.single.resumeAt, const Duration(seconds: 42));
      expect(restored.history.single.local, isTrue);
      expect(restored.history.single.quality, '720p');
      await restored.clearHistory();
      expect(restored.favorites, hasLength(1));
      expect(restored.history, isEmpty);
      await restored.toggleFavorite(drama);
      expect(restored.favorites, isEmpty);
    },
  );
  test(
    'newest progress wins; failure preserves data and queue recovers',
    () async {
      final backend = MemoryBackend();
      final library = PersonalLibrary(backend: backend);
      await library.record(record(80, day: 3));
      await library.record(record(10, day: 2));
      expect(library.history.single.positionMs, 80000);
      backend.fail = true;
      await expectLater(library.removeHistory('a'), throwsStateError);
      expect(library.history, hasLength(1));
      backend.fail = false;
      await library.toggleFavorite(drama);
      expect(library.favorites, hasLength(1));
      expect(library.history, hasLength(1));
    },
  );
  test(
    'completed episodes restart and malformed storage cannot be overwritten',
    () async {
      expect(record(119).resumeAt, const Duration(seconds: 119));
      expect(record(120).resumeAt, Duration.zero);
      final short = WatchRecord(
        drama: drama,
        vid: 'short',
        episode: 1,
        positionMs: 700,
        durationMs: 2000,
        updated: DateTime(2026),
      );
      expect(short.completed, isFalse);
      expect(short.resumeAt, const Duration(milliseconds: 700));
      final backend = MemoryBackend()..data = {'version': 2};
      final library = PersonalLibrary(backend: backend);
      await expectLater(library.toggleFavorite(drama), throwsStateError);
      expect(backend.data, {'version': 2});
      backend.data = null;
      await library.toggleFavorite(drama);
      expect(library.isFavorite('a'), isTrue);
    },
  );
  test('per-episode resume survives restart, latest series and completed episodes resolve independently', () async {
    final backend = MemoryBackend();
    final library = PersonalLibrary(backend: backend);
    const detail = DramaDetail(drama, [
      Episode(vid: 'v1', index: 1),
      Episode(vid: 'v2', index: 2),
      Episode(vid: 'v3', index: 3),
    ]);
    WatchRecord episode(int i, int pos, {bool finished = false}) => WatchRecord(
      drama: drama,
      vid: 'v$i',
      episode: i,
      positionMs: pos,
      durationMs: 120000,
      updated: DateTime(2026, 10, i),
      finished: finished,
    );
    await library.record(episode(1, 42000));
    await library.record(episode(2, 119000, finished: true));
    await library.record(episode(3, 67000));
    final restored = PersonalLibrary(backend: backend);
    await restored.load();
    expect(restored.history, hasLength(1));
    expect(restored.playbackStart(detail), (
      index: 2,
      offset: const Duration(seconds: 67),
    ));
    expect(restored.playbackStart(detail, selected: 0), (
      index: 0,
      offset: const Duration(seconds: 42),
    ));
    expect(restored.playbackStart(detail, selected: 1), (
      index: 1,
      offset: Duration.zero,
    ));
    await restored.removeHistory(drama.id);
    expect(restored.episodeFor(drama.id, 'v1'), isNull);
    expect(restored.playbackStart(detail), (index: 0, offset: Duration.zero));
  });
  test('old single-episode history migrates without losing favorites or the resume point', () async {
    final backend = MemoryBackend()
      ..data = {
        'version': 1,
        'favorites': [],
        'history': [record(42).toJson()],
      };
    final library = PersonalLibrary(backend: backend);
    await library.load();
    expect(
      library.episodeFor('a', 'v3')?.resumeAt,
      const Duration(seconds: 42),
    );
    expect(
      library.playbackStart(
        const DramaDetail(drama, [Episode(vid: 'changed', index: 1)]),
      ),
      (index: 0, offset: Duration.zero),
    );
    await library.clearHistory();
    final restored = PersonalLibrary(backend: backend);
    await restored.load();
    expect(restored.history, isEmpty);
    expect(restored.episodeFor('a', 'v3'), isNull);
  });
}
