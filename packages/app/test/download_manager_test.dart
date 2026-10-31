import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/downloads/download_manager.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'download_fakes.dart';

void main() {
  test('deduplicated sequential queue survives page departure and publishes only real files', () async {
    final runtime = DownloadFakeRuntime();
    addTearDown(runtime.dispose);
    final detail = await runtime.catalog.detail('123');
    await runtime.downloads.enqueue(detail, [0, 0, 1], '720p');
    await queueTick();
    expect(runtime.calls, ['11_720p']);
    expect(await runtime.downloads.enqueue(detail, [0], '720p'), 0);
    await runtime.complete('11_720p');
    await queueTick();
    expect(runtime.downloads.taskFor('11', '720p')!.phase, DownloadPhase.ready);
    expect(runtime.calls, ['11_720p', '12_720p']);
    expect(runtime.jobs['11_720p']!.releases, 1);
    expect(runtime.downloads.retains('11', '720p'), isTrue);
    runtime.jobs['12_720p']!.completer.complete('/missing.mp4');
    await queueTick();
    expect(
      runtime.downloads.taskFor('12', '720p')!.phase,
      DownloadPhase.failed,
    );
    expect(runtime.downloads.readyCount, 1);
  });
  test('mobile background and single-slot playback pause automatically, manual pauses stay paused', () async {
    final runtime = DownloadFakeRuntime(mobile: true);
    addTearDown(runtime.dispose);
    runtime.settings = runtime.settings.copyWith(concurrentPreparations: 1);
    final detail = await runtime.catalog.detail('123');
    await runtime.downloads.enqueue(detail, [0, 1], 'best');
    await queueTick();
    final first = runtime.jobs['11_best']!;
    runtime.downloads.setForeground(false);
    await queueTick();
    expect(first.cancelled, isTrue);
    expect(runtime.calls, ['11_best']);
    expect(
      runtime.downloads.tasks.every((t) => t.phase == DownloadPhase.paused),
      isTrue,
    );
    runtime.downloads.setForeground(true);
    await queueTick();
    expect(runtime.calls, ['11_best', '11_best']);
    runtime.downloads.playbackEntered();
    await queueTick();
    expect(
      runtime.downloads.tasks.every((t) => t.phase == DownloadPhase.paused),
      isTrue,
    );
    runtime.downloads.playbackLeft();
    await queueTick();
    expect(runtime.calls.length, 3);
    runtime.downloads.pause('11_best');
    await queueTick();
    runtime.downloads.setForeground(false);
    runtime.downloads.setForeground(true);
    await queueTick();
    expect(
      runtime.downloads.taskFor('11', 'best')!.phase,
      DownloadPhase.paused,
    );
  });
  test('restored pending work does not start networking; ready files are reconciled and in-use deletion refused', () async {
    final backend = DownloadBackend();
    final first = DownloadFakeRuntime(backend: backend);
    final detail = await first.catalog.detail('123');
    await first.downloads.enqueue(detail, [0, 1], 'best');
    await queueTick();
    await first.complete('11_best', inUse: true);
    await queueTick();
    final saved = List<LocalEpisode>.of(first.files);
    await first.dispose();
    final restored = DownloadFakeRuntime(backend: backend)..files.addAll(saved);
    addTearDown(restored.dispose);
    await restored.downloads.reconcile();
    expect(restored.calls, isEmpty);
    expect(
      restored.downloads.taskFor('11', 'best')!.phase,
      DownloadPhase.ready,
    );
    expect(
      restored.downloads.taskFor('12', 'best')!.phase,
      DownloadPhase.paused,
    );
    await expectLater(restored.downloads.remove('11_best'), throwsStateError);
    restored.files.clear();
    await restored.downloads.reconcile();
    expect(
      restored.downloads.taskFor('11', 'best')!.phase,
      DownloadPhase.failed,
    );
  });
  test('cache budget no longer cancels oversized transfers; failed storage never starts a new task', () async {
    final runtime = DownloadFakeRuntime();
    addTearDown(runtime.dispose);
    runtime.settings = const AppSettings(maxCacheMb: 1, maxCacheFiles: 1);
    final detail = await runtime.catalog.detail('123');
    runtime.backend.fail = true;
    await expectLater(
      runtime.downloads.enqueue(detail, [0], 'best'),
      throwsStateError,
    );
    expect(runtime.calls, isEmpty);
    expect(runtime.downloads.tasks, isEmpty);
    runtime.backend.fail = false;
    // The old quota would have rejected two retained downloads under a
    // one-file budget; downloads no longer check cache limits at all.
    await runtime.downloads.enqueue(detail, [0, 1], 'best');
    await queueTick();
    expect(runtime.calls, ['11_best']);
    runtime.jobs['11_best']!.progress(
      const PreparationProgress.bytes(
        '正在下载',
        .1,
        received: 10,
        total: 2 * 1024 * 1024,
      ),
    );
    await queueTick();
    expect(runtime.jobs['11_best']!.cancelled, isFalse);
    expect(
      runtime.downloads.taskFor('11', 'best')!.phase,
      DownloadPhase.running,
    );
    await runtime.complete('11_best');
    await queueTick();
    expect(runtime.downloads.taskFor('11', 'best')!.phase, DownloadPhase.ready);
    // The second transfer starts only after the first slot frees (default
    // concurrency is one) and completes beyond the old file budget.
    expect(runtime.calls, ['11_best', '12_best']);
    await runtime.complete('12_best');
    await queueTick();
    expect(runtime.downloads.taskFor('12', 'best')!.phase, DownloadPhase.ready);
    expect(runtime.downloads.readyCount, 2);
  });
  test(
    'downloadConcurrent runs up to N transfers side by side and refills slots',
    () async {
      final runtime = DownloadFakeRuntime();
      addTearDown(runtime.dispose);
      final detail = await runtime.catalog.detail('123');
      await runtime.downloads.enqueue(detail, [0, 1, 2], 'best');
      await queueTick();
      expect(runtime.calls, ['11_best']);
      runtime.settings = runtime.settings.copyWith(downloadConcurrent: 3);
      runtime.downloads.policyChanged();
      await queueTick();
      expect(runtime.calls, ['11_best', '12_best', '13_best']);
      expect(
        runtime.downloads.tasks
            .where((t) => t.phase == DownloadPhase.running)
            .length,
        3,
      );
      await runtime.complete('12_best');
      await queueTick();
      expect(runtime.calls.length, 3);
      expect(
        runtime.downloads.tasks
            .where((t) => t.phase == DownloadPhase.running)
            .length,
        2,
      );
    },
  );
  test('resume re-queues a task even beyond the old download budget', () async {
    final runtime = DownloadFakeRuntime();
    addTearDown(runtime.dispose);
    runtime.settings = const AppSettings(maxCacheMb: 1, maxCacheFiles: 1);
    final detail = await runtime.catalog.detail('123');
    await runtime.downloads.enqueue(detail, [0, 1], 'best');
    await queueTick();
    await runtime.complete('11_best');
    await queueTick();
    expect(runtime.downloads.taskFor('11', 'best')!.phase, DownloadPhase.ready);
    // 12 is now running while the retained budget already exceeds maxCacheFiles;
    // pausing and resuming must not be rejected by any quota.
    expect(
      runtime.downloads.taskFor('12', 'best')!.phase,
      DownloadPhase.running,
    );
    runtime.downloads.pause('12_best');
    await queueTick();
    runtime.downloads.resume('12_best');
    expect(
      runtime.downloads.taskFor('12', 'best')!.phase,
      DownloadPhase.running,
    );
    await queueTick();
    expect(
      runtime.downloads.taskFor('12', 'best')!.message,
      isNot(contains('上限')),
    );
    await runtime.complete('12_best');
    await queueTick();
    expect(runtime.downloads.readyCount, 2);
  });
  test(
    'a published download stays protected if final state storage fails',
    () async {
      final runtime = DownloadFakeRuntime();
      addTearDown(runtime.dispose);
      await runtime.downloads.enqueue(await runtime.catalog.detail('123'), [
        0,
      ], 'best');
      await queueTick();
      runtime.backend.fail = true;
      await runtime.complete('11_best');
      await queueTick();
      expect(runtime.downloads.tasks.single.phase, DownloadPhase.ready);
      expect(runtime.downloads.retains('11', 'best'), isTrue);
      expect(runtime.downloads.warning, isNotNull);
      runtime.backend.fail = false;
      await runtime.downloads.reconcile();
      expect(runtime.downloads.warning, isNull);
      expect((runtime.backend.data!['tasks'] as List).single['phase'], 'ready');
    },
  );
  test('unknown storage version is not overwritten by lifecycle changes or shutdown', () async {
    final backend = DownloadBackend()..data = {'version': 2, 'tasks': []};
    final runtime = DownloadFakeRuntime(backend: backend);
    await expectLater(runtime.downloads.load(), throwsStateError);
    runtime.downloads.setForeground(false);
    await runtime.dispose();
    expect(backend.data!['version'], 2);
  });

  group('后台下载 continues across an app run', () {
    /// Leaves one transfer mid-flight and one waiting, then closes the queue the
    /// way an app run ends, and hands back the records it persisted.
    Future<DownloadBackend> leaveUnfinished() async {
      final backend = DownloadBackend();
      final runtime = DownloadFakeRuntime(backend: backend, mobile: true)
        ..settings = const AppSettings(backgroundDownloads: true);
      final detail = await runtime.catalog.detail('123');
      await runtime.downloads.enqueue(detail, [0, 1], 'best');
      await queueTick();
      expect(runtime.calls, ['11_best']);
      await runtime.downloads.shutdown();
      return backend;
    }

    DownloadFakeRuntime reopen(DownloadBackend backend, {bool tv = false}) =>
        DownloadFakeRuntime(backend: backend, mobile: true, television: tv)
          ..settings = const AppSettings(backgroundDownloads: true);

    test(
      'an opted-in phone re-queues and runs what the last run left unfinished',
      () async {
        final backend = await leaveUnfinished();
        final restored = reopen(backend);
        addTearDown(restored.dispose);

        await restored.downloads.reconcile();
        await queueTick();

        expect(restored.calls, ['11_best']);
        expect(
          restored.downloads.taskFor('11', 'best')!.phase,
          DownloadPhase.running,
        );
        expect(
          restored.downloads.taskFor('12', 'best')!.phase,
          DownloadPhase.queued,
        );
        expect(
          restored.downloads.taskFor('12', 'best')!.message,
          '正在继续上次的后台下载',
        );
      },
    );
    test('a phone that never opted in still asks for the tap', () async {
      final backend = await leaveUnfinished();
      final restored = reopen(backend);
      restored.settings = const AppSettings(backgroundDownloads: false);
      addTearDown(restored.dispose);

      await restored.downloads.reconcile();
      await queueTick();

      expect(restored.calls, isEmpty);
      expect(
        restored.downloads.taskFor('11', 'best')!.phase,
        DownloadPhase.paused,
      );
      expect(
        restored.downloads.taskFor('12', 'best')!.phase,
        DownloadPhase.paused,
      );
    });
    test('a pause the viewer chose is not overridden by 后台下载', () async {
      final backend = DownloadBackend();
      final runtime = DownloadFakeRuntime(backend: backend, mobile: true)
        ..settings = const AppSettings(backgroundDownloads: true);
      final detail = await runtime.catalog.detail('123');
      await runtime.downloads.enqueue(detail, [0, 1], 'best');
      await queueTick();
      runtime.downloads.pause('12_best');
      await queueTick();
      await runtime.downloads.shutdown();

      final restored = reopen(backend);
      addTearDown(restored.dispose);
      await restored.downloads.reconcile();
      await queueTick();

      expect(restored.calls, ['11_best']);
      expect(
        restored.downloads.taskFor('12', 'best')!.phase,
        DownloadPhase.paused,
      );
      expect(restored.downloads.resumableCount, 1);

      // 队列只有一个传输槽：先让 11 真的下完，才看得出 12 是被观众按下、
      // 不是被队列排满。
      await restored.complete('11_best');
      await queueTick();
      expect(
        restored.downloads.taskFor('11', 'best')!.phase,
        DownloadPhase.ready,
      );
      expect(restored.calls, ['11_best']);

      expect(restored.downloads.resumeAll(), 1);
      await queueTick();
      expect(restored.calls, ['11_best', '12_best']);
    });
    test('TV keeps its transfers in the foreground', () async {
      final backend = await leaveUnfinished();
      final restored = reopen(backend, tv: true);
      addTearDown(restored.dispose);

      await restored.downloads.reconcile();
      await queueTick();

      expect(restored.calls, isEmpty);
      expect(
        restored.downloads.taskFor('11', 'best')!.phase,
        DownloadPhase.paused,
      );
    });
  });
}
