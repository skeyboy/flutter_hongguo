// 下载管理归类到剧目之后, the cross-check between a drama card and the queue is
// the feature: the card's numbers come from the disk, the rows show what the
// queue holds *and* what only playback cached, and every delete answers from
// re-reading the cache instead of from what it tried. These tests drive the two
// pages as a viewer would on a phone, because that is where a stale record is
// most likely to promise a file that is not there.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/downloads/download_manager.dart';
import 'package:hongguo_app/features/download_episodes_page.dart';
import 'package:hongguo_app/features/downloads_page.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import 'download_fakes.dart';
import 'fakes.dart';

Widget _app(Widget child) => MaterialApp(
  builder: (context, inner) => TvEnvironment(enabled: false, child: inner!),
  home: child,
);

/// A file the viewer never asked to download: the player cached it while they
/// watched, so the queue has no record of it at all.
Future<void> _cacheWhilePlaying(
  DownloadFakeRuntime runtime, {
  required String vid,
  String quality = '1080p',
}) async {
  runtime.files.add(
    LocalEpisode(
      vid: vid,
      quality: quality,
      bytes: 40,
      modified: DateTime.now(),
      inUse: false,
      detail: await runtime.libraryCache.readDetail(FakeCatalog.demo.id),
    ),
  );
}

/// Queues the demo drama and lets the first episode finish, so the page always
/// opens on a drama with real work in flight.
Future<DownloadFakeRuntime> _mount(
  WidgetTester tester, {
  List<int> episodes = const [0, 1],
}) async {
  final runtime = DownloadFakeRuntime();
  addTearDown(() async {
    final closing = runtime.dispose();
    await tester.pump();
    await closing;
  });
  await runtime.downloads.enqueue(
    await runtime.catalog.detail(FakeCatalog.demo.id),
    episodes,
    'best',
  );
  await tester.pumpWidget(_app(DownloadsPage(runtime: runtime)));
  await tester.pump();
  await runtime.complete('11_best');
  await tester.pump();
  // The next queued episode starts with no fraction yet, and an indeterminate
  // bar never lets pumpAndSettle settle.
  runtime.jobs['12_best']?.progress(PreparationProgress('正在传输', 0.4));
  await tester.pump();
  return runtime;
}

Future<void> _openCard(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('downloads-drama-123')));
  await tester.pumpAndSettle();
  expect(find.byType(DownloadEpisodesPage), findsOneWidget);
}

void main() {
  testWidgets('one card per drama, and the episode rows only after opening it', (
    tester,
  ) async {
    final runtime = await _mount(tester);
    await _cacheWhilePlaying(runtime, vid: '13');
    await tester.tap(find.byTooltip('刷新下载'));
    await tester.pumpAndSettle();

    // 已完成 counts what the disk holds, 下载中 what the queue still owes: the
    // playback-cached third episode is offline without ever having been asked
    // for, and the queued second one is not.
    expect(find.text('山海之间'), findsOneWidget);
    expect(find.text('已完成 2 / 3 集 · 下载中 1'), findsOneWidget);
    expect(find.text('第 1 集 · 自动画质'), findsNothing);

    await _openCard(tester);
    expect(find.textContaining('共 3 集'), findsOneWidget);
    expect(find.text('第 1 集 · 自动画质'), findsOneWidget);
    expect(find.text('第 2 集 · 自动画质'), findsOneWidget);
    expect(find.text('第 3 集 · 1080p'), findsOneWidget);
    // The cached-only episode has no record to speak for it, so the row says so
    // and still offers the one thing the viewer wants.
    expect(find.textContaining('播放时缓存'), findsOneWidget);
    expect(find.byTooltip('离线观看'), findsNWidgets(2));
    expect(find.byTooltip('删除本地文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分集进度 keeps two tracks of one episode as two rows', (
    tester,
  ) async {
    final runtime = await _mount(tester, episodes: [0]);
    await _cacheWhilePlaying(runtime, vid: '11', quality: '1080p');
    await tester.tap(find.byTooltip('刷新下载'));
    await tester.pumpAndSettle();

    await _openCard(tester);
    // The ready 自动画质 copy and the 1080p playback cache are different files;
    // deleting one must not claim to have deleted the other.
    expect(find.text('第 1 集 · 自动画质'), findsOneWidget);
    expect(find.text('第 1 集 · 1080p'), findsOneWidget);
    expect(runtime.files, hasLength(2));

    await tester.tap(find.byTooltip('删除本地文件'));
    await tester.pumpAndSettle();
    expect(find.text('删除本地剧集？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(runtime.files.map((f) => f.quality), ['best']);
    // The record survived its neighbour's file going away, because it never
    // owned that file.
    expect(runtime.downloads.tasks, hasLength(1));
    expect(runtime.downloads.tasks.single.phase, DownloadPhase.ready);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除本地文件 on a playback cache leaves every record alone', (
    tester,
  ) async {
    final runtime = await _mount(tester);
    await _cacheWhilePlaying(runtime, vid: '13');
    await tester.tap(find.byTooltip('刷新下载'));
    await tester.pumpAndSettle();
    await _openCard(tester);

    await tester.tap(find.byTooltip('删除本地文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(runtime.files.map((f) => f.vid), ['11']);
    expect(runtime.downloads.tasks, hasLength(2));

    // Back out, and the card is the drama as the disk now describes it.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(DownloadsPage), findsOneWidget);
    expect(find.text('已完成 1 / 2 集 · 下载中 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a record whose file is gone stops being counted as offline', (
    tester,
  ) async {
    final runtime = await _mount(tester, episodes: [0]);
    await tester.pumpAndSettle();
    expect(find.text('已完成 1 / 1 集'), findsOneWidget);

    // Somebody cleared the cache from outside the app.
    runtime.files.clear();
    await tester.tap(find.byTooltip('刷新下载'));
    await tester.pumpAndSettle();

    // The card is the queue joined to the disk, so the finished count drops and
    // the orphaned record becomes work the viewer can restart.
    expect(find.text('已完成 0 / 1 集 · 待继续 1'), findsOneWidget);
    expect(runtime.downloads.tasks.single.phase, DownloadPhase.failed);
    expect(runtime.downloads.tasks.single.message, contains('文件已移除，请重新下载'));

    await _openCard(tester);
    expect(find.textContaining('文件已移除，请重新下载'), findsOneWidget);
    expect(find.byTooltip('重试下载'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除本剧 reports the file it could not take and keeps its record', (
    tester,
  ) async {
    final runtime = DownloadFakeRuntime();
    addTearDown(() async {
      final closing = runtime.dispose();
      await tester.pump();
      await closing;
    });
    await runtime.downloads.enqueue(
      await runtime.catalog.detail(FakeCatalog.demo.id),
      [0],
      'best',
    );
    await tester.pumpWidget(_app(DownloadsPage(runtime: runtime)));
    await tester.pump();
    // The player still holds the file open, so the platform refuses the delete.
    await runtime.complete('11_best', inUse: true);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('删除本剧全部下载'));
    await tester.pumpAndSettle();
    expect(find.text('删除本剧全部下载？'), findsOneWidget);
    await tester.tap(find.text('删除全部'));
    await tester.pumpAndSettle();

    // The answer comes from reading the cache back, not from what was attempted:
    // the file is still there, so the record has to stay with it.
    expect(find.textContaining('1 个正在使用中或暂时删不掉'), findsOneWidget);
    expect(runtime.files, hasLength(1));
    expect(runtime.downloads.tasks, hasLength(1));
    expect(find.byKey(const ValueKey('downloads-drama-123')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
