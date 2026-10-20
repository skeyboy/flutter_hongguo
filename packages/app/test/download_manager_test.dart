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
  test('settings quota cancels oversized transfer and failed storage never starts a new task', () async {
    final runtime = DownloadFakeRuntime();
    addTearDown(runtime.dispose);
    runtime.settings = const AppSettings(maxCacheMb: 1, maxCacheFiles: 1);
    final detail = await runtime.catalog.detail('123');
    await expectLater(
      runtime.downloads.enqueue(detail, [0, 1], 'best'),
      throwsStateError,
    );
    runtime.backend.fail = true;
    await expectLater(
      runtime.downloads.enqueue(detail, [0], 'best'),
      throwsStateError,
    );
    expect(runtime.calls, isEmpty);
    expect(runtime.downloads.tasks, isEmpty);
    runtime.backend.fail = false;
    await runtime.downloads.enqueue(detail, [0], 'best');
    await queueTick();
    runtime.jobs['11_best']!.progress(
      const PreparationProgress.bytes(
        '正在下载',
        .1,
        received: 10,
        total: 2 * 1024 * 1024,
      ),
    );
    await queueTick();
    expect(runtime.jobs['11_best']!.cancelled, isTrue);
    expect(runtime.downloads.tasks.single.phase, DownloadPhase.failed);
    expect(runtime.downloads.tasks.single.message, contains('容量'));
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
}
