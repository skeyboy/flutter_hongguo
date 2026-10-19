import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_app/playback/prefetch_window.dart';

import 'fakes.dart';

class PendingJob implements PlaybackJob {
  final completer = Completer<String>();
  bool cancelled = false, released = false;
  @override
  Future<String> get source => completer.future;
  @override
  void cancel() {
    cancelled = true;
    if (!completer.isCompleted) {
      completer.completeError(StateError('cancelled'));
    }
  }

  @override
  void release() {
    released = true;
  }
}

class PrefetchRuntime extends FakeRuntime {
  final jobs = <String, PendingJob>{};
  final calls = <String>[];
  @override
  PlaybackJob prepare(
    String vid, {
    String quality = 'best',
    void Function(PreparationProgress)? onProgress,
    bool background = false,
  }) {
    expect(background, isTrue);
    final key = '${vid}_$quality';
    calls.add(key);
    return jobs[key] = PendingJob();
  }
}

void main() {
  late PrefetchRuntime runtime;
  late PrefetchWindow window;
  setUp(() {
    runtime = PrefetchRuntime();
    window = PrefetchWindow(
      runtime: runtime,
      episodes: List.generate(
        10,
        (i) => Episode(vid: '${i + 1}', index: i + 1),
      ),
    );
  });
  tearDown(() async {
    window.dispose();
    await Future<void>.delayed(Duration.zero);
    await runtime.dispose();
  });
  test(
    'prepare next 3 then slide, retaining the remaining ready leases',
    () async {
      window.sync(position: 0, quality: 'best', count: 3, enabled: true);
      expect(runtime.calls, ['2_best', '3_best', '4_best']);
      for (final key in runtime.calls.toList()) {
        runtime.jobs[key]!.completer.complete('/tmp/$key.mp4');
      }
      await Future<void>.delayed(Duration.zero);
      expect(window.ready, 3);
      final retained = runtime.jobs['3_best'];
      window.sync(position: 1, quality: 'best', count: 3, enabled: true);
      expect(runtime.jobs['2_best']!.released, isTrue);
      expect(retained!.released, isFalse);
      expect(runtime.calls, ['2_best', '3_best', '4_best', '5_best']);
      expect(window.total, 3);
      expect(window.ready, 2);
    },
  );
  test(
    'five-episode window is bounded at series end and disable cancels all',
    () {
      window.sync(position: 7, quality: 'best', count: 5, enabled: true);
      expect(runtime.calls, ['9_best', '10_best']);
      expect(window.total, 2);
      window.sync(position: 7, quality: 'best', count: 5, enabled: false);
      expect(window.total, 0);
      expect(
        runtime.jobs.values.every((j) => j.cancelled && j.released),
        isTrue,
      );
    },
  );
  test('jumping and quality changes retire only the obsolete window', () {
    window.sync(position: 0, quality: 'best', count: 5, enabled: true);
    window.sync(position: 3, quality: 'best', count: 3, enabled: true);
    expect(runtime.calls.where((k) => k == '5_best'), hasLength(1));
    expect(runtime.jobs['2_best']!.cancelled, isTrue);
    expect(runtime.jobs['5_best']!.cancelled, isFalse);
    window.sync(position: 3, quality: '720p', count: 3, enabled: true);
    expect(runtime.jobs['5_best']!.released, isTrue);
    expect(runtime.jobs.containsKey('5_720p'), isTrue);
  });
  test(
    'failed background jobs do not retry forever or cancel successful jobs',
    () async {
      window.sync(position: 0, quality: 'best', count: 3, enabled: true);
      runtime.jobs['2_best']!.completer.completeError(StateError('network'));
      runtime.jobs['3_best']!.completer.complete('/tmp/3.mp4');
      await Future<void>.delayed(Duration.zero);
      expect(window.phaseFor('2', 'best'), PrefetchPhase.failed);
      expect(window.ready, 1);
      window.sync(position: 0, quality: 'best', count: 3, enabled: true);
      expect(runtime.calls, hasLength(3));
      expect(runtime.jobs['3_best']!.released, isFalse);
    },
  );
}
