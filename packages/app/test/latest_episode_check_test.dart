import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/catalog/local_library.dart';
import 'package:hongguo_app/downloads/download_manager.dart';
import 'package:hongguo_app/downloads/latest_episode_check.dart';
import 'package:hongguo_app/platform/runtime_contract.dart';

import 'download_fakes.dart';

/// 检查最新剧集 is a read. The bug this file pins is the opposite shape: the shelf
/// used to answer an online gap by filling 下载中 itself, so a viewer who only
/// wanted to know whether the show grew got transfers they never named.
/// Only a pick in 下载选集 may queue.
void main() {
  Future<LocalDramaGroup> shelf(DownloadFakeRuntime runtime) async =>
      groupLocalEpisodes(await runtime.localEpisodes())
          .firstWhere((group) => group.id == '123');

  Future<void> cacheEpisode(
    DownloadFakeRuntime runtime,
    int position,
    String quality,
  ) async {
    final detail = await runtime.catalog.detail('123');
    await runtime.downloads.enqueue(detail, [position], quality);
    await queueTick();
    await runtime.complete('${11 + position}_$quality');
    await queueTick();
  }

  test(
    '检查 reports the gap at the shelf’s quality and queues none of it',
    () async {
      final runtime = DownloadFakeRuntime();
      addTearDown(runtime.dispose);
      runtime.catalog.episodes = const [Episode(vid: '11', index: 1)];
      await cacheEpisode(runtime, 0, '1080p');

      // 上游更新了：这部剧现在在线 3 集。
      runtime.catalog.episodes = const [
        Episode(vid: '11', index: 1),
        Episode(vid: '12', index: 2),
        Episode(vid: '13', index: 3),
      ];
      final result = await checkLatestEpisodes(runtime, await shelf(runtime));
      await queueTick();

      expect(result.online, 3);
      expect(result.cached, 1);
      expect(result.downloadable, 2);
      expect(result.inQueue, 0);
      expect(result.quality, '1080p');
      expect(result.hasNew, isTrue);
      expect(result.caption, contains('2 集可下载'));
      expect(result.caption, contains('选择下载新集'));
      // The one transfer on record is the one the viewer actually asked for.
      expect(runtime.calls, ['11_1080p']);
      expect(runtime.downloads.tasks, hasLength(1));
      expect(runtime.downloads.tasks.single.phase, DownloadPhase.ready);
      // 「检查」 still means the shelf learns how long the series is.
      final merged = await runtime.libraryCache.readDetail('123');
      expect(merged!.episodes.map((e) => e.vid), ['11', '12', '13']);
      expect(merged.drama.episodeCount, 3);
    },
  );

  test(
    '已是最新 says so and starts nothing when the shelf holds every episode',
    () async {
      final runtime = DownloadFakeRuntime();
      addTearDown(runtime.dispose);
      for (final position in [0, 1, 2]) {
        await cacheEpisode(runtime, position, 'best');
      }

      final result = await checkLatestEpisodes(runtime, await shelf(runtime));
      await queueTick();

      expect(result.downloadable, 0);
      expect(result.inQueue, 0);
      expect(result.hasNew, isFalse);
      expect(result.caption, contains('已是最新'));
      expect(runtime.calls, ['11_best', '12_best', '13_best']);
    },
  );

  test(
    'a queued or paused episode is counted as 在下载中, not offered as new work',
    () async {
      final runtime = DownloadFakeRuntime();
      addTearDown(runtime.dispose);
      final detail = await runtime.catalog.detail('123');
      await runtime.downloads.enqueue(detail, [0, 1], 'best');
      await queueTick();
      await runtime.complete('11_best');
      await queueTick();
      runtime.downloads.pause('12_best');
      await queueTick();

      final result = await checkLatestEpisodes(runtime, await shelf(runtime));
      await queueTick();

      expect(result.cached, 1);
      expect(result.inQueue, 1);
      expect(result.downloadable, 1);
      expect(result.caption, contains('1 集可下载'));
      expect(result.caption, contains('另有 1 集已在下载中'));
      expect(
        runtime.downloads.taskFor('12', 'best')!.phase,
        DownloadPhase.paused,
      );
      // The check neither resumed the paused one nor started the third.
      expect(runtime.calls, ['11_best', '12_best']);
      expect(runtime.downloads.tasks, hasLength(2));
    },
  );

  test(
    'a cancelled episode is offered again, but not reopened by itself',
    () async {
      final runtime = DownloadFakeRuntime();
      addTearDown(runtime.dispose);
      await cacheEpisode(runtime, 0, 'best');
      final detail = await runtime.catalog.detail('123');
      await runtime.downloads.enqueue(detail, [1], 'best');
      await queueTick();
      runtime.downloads.cancel('12_best');
      await queueTick();

      final online = await scanOnlineEpisodes(runtime, await shelf(runtime));

      // A cancelled record holds no file, so 第 2 集 is part of the gap again; a
      // read that reopened it would restart what the viewer just stopped.
      expect(online.missing, [1, 2]);
      expect(online.inQueue, 0);
      expect(runtime.calls, ['11_best', '12_best']);
      expect(
        runtime.downloads.taskFor('12', 'best')!.phase,
        DownloadPhase.cancelled,
      );
    },
  );

  test('扫描只报告缺口：读在线、合并集数，但不替观众排队', () async {
    final runtime = DownloadFakeRuntime();
    addTearDown(runtime.dispose);
    runtime.catalog.episodes = const [Episode(vid: '11', index: 1)];
    await cacheEpisode(runtime, 0, '1080p');

    runtime.catalog.episodes = const [
      Episode(vid: '11', index: 1),
      Episode(vid: '12', index: 2),
      Episode(vid: '13', index: 3),
    ];
    final online = await scanOnlineEpisodes(runtime, await shelf(runtime));

    expect(online.hasNew, isTrue);
    expect(online.missing, [1, 2]);
    expect(online.inQueue, 0);
    expect(online.quality, '1080p');
    expect(online.cached, 1);
    expect(online.detail.episodes.map((e) => e.vid), ['11', '12', '13']);
    // Nothing left the shelf: no new transfer, and no new queue record.
    expect(runtime.calls, ['11_1080p']);
    expect(runtime.downloads.tasks, hasLength(1));
    // The read still grew the shelf's own idea of the series, which is what
    // the 已缓存 X / Y badge is built from.
    final merged = await runtime.libraryCache.readDetail('123');
    expect(merged!.drama.episodeCount, 3);
  });

  test('待识别视频 has no series id to ask with, so nothing goes out', () async {
    final runtime = DownloadFakeRuntime();
    addTearDown(runtime.dispose);
    runtime.files.add(
      LocalEpisode(
        vid: '777',
        quality: 'best',
        bytes: 1,
        modified: DateTime.now(),
        inUse: false,
      ),
    );
    final group = groupLocalEpisodes(await runtime.localEpisodes())
        .firstWhere((g) => g.unidentified);

    await expectLater(
      checkLatestEpisodes(runtime, group),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('补全剧目信息'),
        ),
      ),
    );
    expect(runtime.catalog.browseCalls, 0);
    expect(runtime.calls, isEmpty);
  });

  test(
    'an unreachable answer leaves the shelf and the queue exactly as they were',
    () async {
      final runtime = DownloadFakeRuntime();
      addTearDown(runtime.dispose);
      await cacheEpisode(runtime, 0, '720p');
      final group = await shelf(runtime);
      runtime.catalog.detailFail = true;

      await expectLater(
        checkLatestEpisodes(runtime, group),
        throwsA(isA<CatalogError>()),
      );
      await queueTick();

      expect(runtime.calls, ['11_720p']);
      expect(runtime.files.map((f) => f.vid), ['11']);
      expect(runtime.downloads.tasks, hasLength(1));
    },
  );
}
