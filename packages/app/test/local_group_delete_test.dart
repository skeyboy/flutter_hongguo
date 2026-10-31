import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/catalog/local_group_delete.dart';
import 'package:hongguo_app/catalog/local_library.dart';
import 'package:hongguo_app/downloads/download_manager.dart';
import 'package:hongguo_app/platform/runtime.dart';

import 'download_fakes.dart';
import 'fakes.dart';

/// 归类删除 is the promise the per-file row never made: one action for a drama the
/// viewer is done with, and the answer says which files it could not take.
void main() {
  Future<LocalDramaGroup> shelf(DownloadFakeRuntime runtime) async =>
      groupLocalEpisodes(await runtime.localEpisodes())
          .firstWhere((group) => group.id == '123');

  test('a drama’s files and its unfinished records go together', () async {
    final runtime = DownloadFakeRuntime();
    addTearDown(runtime.dispose);
    final detail = await runtime.catalog.detail('123');
    await runtime.downloads.enqueue(detail, [0, 1, 2], '720p');
    await queueTick();
    await runtime.complete('11_720p', inUse: true);
    await queueTick();
    await runtime.complete('12_720p');
    await queueTick();
    expect(
      runtime.downloads.taskFor('13', '720p')!.phase,
      DownloadPhase.running,
    );

    final result = await removeLocalDrama(runtime, await shelf(runtime));

    expect(result.removed, 1);
    expect(result.kept, 1);
    expect(result.tasksForgotten, 1);
    expect(result.bytes, 100);
    expect(runtime.files.map((f) => f.vid), ['11']);
    expect(runtime.downloads.taskFor('11', '720p')!.phase, DownloadPhase.ready);
    expect(runtime.downloads.taskFor('12', '720p'), isNull);
    expect(runtime.downloads.taskFor('13', '720p'), isNull);
    expect(runtime.jobs['13_720p']!.cancelled, isTrue);
    expect(result.complete, isFalse);
    expect(result.caption, contains('1 个正在使用中或暂时删不掉'));
    expect(result.caption, contains('清掉 1 条未完成的下载'));
  });

  test('待识别视频 takes its files without touching any queue record', () async {
    final runtime = DownloadFakeRuntime();
    addTearDown(runtime.dispose);
    await runtime.downloads.enqueue(await runtime.catalog.detail('123'), [
      0,
    ], 'best');
    await queueTick();
    await runtime.complete('11_best');
    await queueTick();
    runtime.files.add(
      LocalEpisode(
        vid: '777',
        quality: 'best',
        bytes: 50,
        modified: DateTime.now(),
        inUse: false,
      ),
    );

    final group = groupLocalEpisodes(await runtime.localEpisodes())
        .firstWhere((g) => g.unidentified);
    final result = await removeLocalDrama(runtime, group);

    expect(result.removed, 1);
    expect(result.tasksForgotten, 0);
    expect(runtime.files.map((f) => f.vid), ['11']);
    expect(runtime.downloads.taskFor('11', 'best')!.phase, DownloadPhase.ready);
  });

  test('一个读不到自己缓存的宿主什么都不删，并把原因说出来', () async {
    final runtime = FakeRuntime();
    final group = LocalDramaGroup(
      id: '123',
      drama: FakeCatalog.demo,
      files: const [],
    );
    await expectLater(
      removeLocalDrama(runtime, group),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('未删除任何文件'),
        ),
      ),
    );
  });
}
