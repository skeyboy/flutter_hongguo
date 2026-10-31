import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/catalog/local_library.dart';
import 'package:hongguo_app/downloads/download_manager.dart';
import 'package:hongguo_app/downloads/latest_episode_pull.dart';
import 'package:hongguo_app/platform/runtime_contract.dart';

import 'download_fakes.dart';

/// 下载更多 needs a subject, and a cached drama is the only surface that has one:
/// the shelf already knows the series id and the quality the viewer picked.
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
    '拉取最新 queues what the shelf is missing at the shelf’s quality',
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
      final result = await pullLatestEpisodes(runtime, await shelf(runtime));
      await queueTick();

      expect(result.online, 3);
      expect(result.cached, 1);
      expect(result.added, 2);
      expect(result.quality, '1080p');
      expect(result.hasNew, isTrue);
      expect(runtime.calls, ['11_1080p', '12_1080p']);
      expect(
        runtime.downloads.taskFor('13', '1080p')!.phase,
        DownloadPhase.queued,
      );
      expect(result.caption, contains('新加入 2 集下载（1080p）'));
      // 「更新」 also means the shelf's own record of how long the series is.
      final merged = await runtime.libraryCache.readDetail('123');
      expect(merged!.episodes.map((e) => e.vid), ['11', '12', '13']);
      expect(merged.drama.episodeCount, 3);
    },
  );

  test(
    '已是最新 adds nothing when the shelf already holds every episode',
    () async {
      final runtime = DownloadFakeRuntime();
      addTearDown(runtime.dispose);
      for (final position in [0, 1, 2]) {
        await cacheEpisode(runtime, position, 'best');
      }

      final result = await pullLatestEpisodes(runtime, await shelf(runtime));

      expect(result.added, 0);
      expect(result.hasNew, isFalse);
      expect(result.caption, contains('已是最新'));
      expect(runtime.calls, ['11_best', '12_best', '13_best']);
    },
  );

  test(
    'a queued or paused episode is not silently queued a second time',
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

      final result = await pullLatestEpisodes(runtime, await shelf(runtime));
      await queueTick();

      expect(result.added, 1);
      expect(
        runtime.downloads.taskFor('12', 'best')!.phase,
        DownloadPhase.paused,
      );
      expect(
        runtime.downloads.taskFor('13', 'best')!.phase,
        isNot(DownloadPhase.paused),
      );
      expect(runtime.calls, ['11_best', '12_best', '13_best']);
    },
  );

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
      pullLatestEpisodes(runtime, group),
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
        pullLatestEpisodes(runtime, group),
        throwsA(isA<CatalogError>()),
      );
      await queueTick();

      expect(runtime.calls, ['11_720p']);
      expect(runtime.files.map((f) => f.vid), ['11']);
      expect(runtime.downloads.tasks, hasLength(1));
    },
  );
}
