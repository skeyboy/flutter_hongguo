import 'dart:async';

import 'package:hongguo_api/hongguo_api.dart';

import '../platform/runtime.dart';

enum PrefetchPhase { preparing, ready, failed }

class PrefetchEntry {
  final String vid, quality;
  PlaybackJob? job;
  PrefetchPhase phase = PrefetchPhase.preparing;
  PrefetchEntry(this.vid, this.quality);
}

/// Sliding window holds ready leases until playback acquires its own foreground
/// lease, so a completed next episode cannot be evicted between episodes.
class PrefetchWindow {
  final AppRuntime runtime;
  final List<Episode> episodes;
  final void Function()? onChanged;
  final _entries = <String, PrefetchEntry>{};
  bool _disposed = false;
  PrefetchWindow({
    required this.runtime,
    required this.episodes,
    this.onChanged,
  });
  int get total => _entries.length;
  int get ready =>
      _entries.values.where((e) => e.phase == PrefetchPhase.ready).length;
  int get preparing =>
      _entries.values.where((e) => e.phase == PrefetchPhase.preparing).length;
  PrefetchPhase? phaseFor(String vid, String quality) =>
      _entries['${vid}_$quality']?.phase;
  void sync({
    required int position,
    required String quality,
    required int count,
    required bool enabled,
  }) {
    if (_disposed) return;
    final wanted = <String, Episode>{};
    if (enabled) {
      for (
        var i = position + 1;
        i < episodes.length && i <= position + count;
        i++
      ) {
        wanted['${episodes[i].vid}_$quality'] = episodes[i];
      }
    }
    for (final key
        in _entries.keys.where((k) => !wanted.containsKey(k)).toList()) {
      _retire(_entries.remove(key)!);
    }
    for (final entry in wanted.entries) {
      if (_entries.containsKey(entry.key)) continue;
      final item = PrefetchEntry(entry.value.vid, quality);
      _entries[entry.key] = item;
      try {
        final job = runtime.prepare(
          item.vid,
          quality: quality,
          background: true,
        );
        item.job = job;
        unawaited(
          job.source
              .then<void>((_) {
                if (_disposed || !identical(_entries[entry.key], item)) {
                  job.release();
                  return;
                }
                item.phase = PrefetchPhase.ready;
                onChanged?.call();
              })
              .catchError((Object _) {
                job.release();
                if (_disposed || !identical(_entries[entry.key], item)) return;
                item.phase = PrefetchPhase.failed;
                onChanged?.call();
              }),
        );
      } catch (_) {
        item.phase = PrefetchPhase.failed;
      }
    }
    onChanged?.call();
  }

  void _retire(PrefetchEntry entry) {
    entry.job?.cancel();
    entry.job?.release();
  }

  void clear() {
    for (final entry in _entries.values) {
      _retire(entry);
    }
    _entries.clear();
    if (!_disposed) onChanged?.call();
  }

  void dispose() {
    _disposed = true;
    clear();
  }
}
