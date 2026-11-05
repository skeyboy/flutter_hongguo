import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/catalog/local_library.dart';
import 'package:hongguo_app/features/local_cache_page.dart';
import 'package:hongguo_app/features/merge_tasks_page.dart';
import 'package:hongguo_app/features/merged_page.dart';
import 'package:hongguo_app/features/my_page.dart';
import 'package:hongguo_app/merge/merge_export.dart';
import 'package:hongguo_app/merge/merge_manager.dart' as merge;
import 'package:hongguo_app/merge/merge_selection.dart';
import 'package:hongguo_app/merge/merged_library.dart';

import 'merge_fakes.dart';

/// The merge lanes the viewer can reach: 我的 entries, the product's own record,
/// the picker fed by the cache scan, and the queue's controls.
///
/// Nothing here runs a real merge -- the queue is held by playback -- so every
/// assertion is about what a phone or a PC window shows and what it enqueues.
void main() {
  testWidgets('我的 page carries the merged library and the queue', (
    tester,
  ) async {
    final runtime = MergeFakeRuntime();
    addTearDown(runtime.cleanUp);
    runtime.seedFiles('d1', [1, 2]);
    runtime.seedProduct();
    await tester.pumpWidget(MaterialApp(home: MyPage(runtime: runtime)));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 部 · 离线可播 · 可导出'), findsOneWidget);
    expect(find.text('暂无进行中的任务'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('my-merged')));
    await tester.pumpAndSettle();
    expect(find.byType(MergedPage), findsOneWidget);
    expect(find.text('山海之间 合集'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('my-merge-tasks')));
    await tester.pumpAndSettle();
    expect(find.byType(MergeTasksPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a merged resource shows its composition and its deliveries', (
    tester,
  ) async {
    final runtime = MergeFakeRuntime();
    addTearDown(runtime.cleanUp);
    runtime.seedFiles('d1', [1, 2]);
    final out = Directory('${runtime.temp.path}/out')..createSync();
    final delivered = File('${out.path}/山海之间 合集.mp4')
      ..writeAsBytesSync(List<int>.filled(2 * 1024 * 1024, 0));
    runtime.seedProduct(
      items: [item(1), item(2)],
      exports: [
        // The older copy is gone, so the record says so; the newest one still
        // stands and already holds every episode.
        MergedExport(
          path: '${out.path}/旧副本.mp4',
          mode: 'new',
          at: DateTime(2026, 11, 2, 10),
          bytes: 3 * 1024 * 1024,
        ),
        MergedExport(
          path: delivered.path,
          mode: 'new',
          at: DateTime(2026, 11, 3, 10, 30),
          bytes: 2 * 1024 * 1024,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MergedPage(runtime: runtime, mergeId: 'm1'),
      ),
    );
    await tester.pumpAndSettle();

    // The manifest is the only description the merged file has.
    expect(find.text('构成'), findsOneWidget);
    expect(find.text('第 2 集'), findsWidgets);
    expect(find.textContaining('起始 0:01:00'), findsOneWidget);
    expect(find.text('导出记录'), findsOneWidget);
    expect(find.textContaining('已移动或删除'), findsOneWidget);
    expect(find.textContaining('新片段'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('merged-export')));
    await tester.pumpAndSettle();
    expect(find.byType(MergeExport), findsOneWidget);
    expect(find.text('导出合并资源'), findsOneWidget);
    // On a desktop test host the panel will not hand a file out until a real
    // directory is chosen, so the submit stays inert.
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('confirm-export')))
          .onPressed,
      isNull,
    );
    // The one delivery already made is what 追加 can grow, so it is offered.
    expect(
      find.byKey(const ValueKey('merge-export-mode-append')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('merge-export-mode-append')));
    await tester.pumpAndSettle();
    expect(find.textContaining('该导出已包含全部分集'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('追加剧集 greys the episodes the product already holds', (
    tester,
  ) async {
    final runtime = MergeFakeRuntime();
    addTearDown(runtime.cleanUp);
    runtime.seedFiles('d1', [1, 2, 3]);
    runtime.seedProduct(items: [item(1, vid: '1')]);
    await tester.pumpWidget(
      MaterialApp(
        home: MergedPage(runtime: runtime, mergeId: 'm1'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('merged-append')));
    await tester.pumpAndSettle();
    final panel = find.byType(MergeSelection);
    expect(panel, findsOneWidget);
    // vid 1 stays visible and says 已含: hiding it would leave the viewer
    // choosing against a list they cannot check.
    expect(
      find.descendant(of: panel, matching: find.textContaining('第 1 集')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.text('已含')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.text('已下')),
      findsNWidgets(2),
    );

    // Pressing the tile that is already inside the product tells the viewer so
    // instead of quietly queueing a job the kernel will refuse.
    await tester.tap(find.byKey(const ValueKey('merge-episode-0')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已在合并资源中'), findsOneWidget);
    expect(runtime.merges.tasks, isEmpty);
    // Let that message expire, or it stands in front of the one being checked
    // at the end: a messenger shows one snackbar at a time.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('merge-episode-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('merge-next')));
    await tester.pumpAndSettle();
    // One episode is enough when the product it grows already exists.
    expect(find.text('合成预检'), findsOneWidget);
    expect(find.textContaining('编解码一致'), findsOneWidget);
    expect(find.textContaining('Σ源 1.0 MB + 5%'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('confirm-merge')));
    await tester.pumpAndSettle();

    final task = runtime.merges.tasks.single;
    expect(task.kind, 'append');
    expect(task.targetMergeId, 'm1');
    expect(task.items.single.vid, '2');
    expect(find.byType(MergeSelection), findsNothing);
    expect(find.textContaining('已加入合成队列'), findsOneWidget);
    // The queue is held by playback, and the panel says so with the job.
    expect(find.textContaining('正在播放'), findsOneWidget);
  });

  testWidgets('the cache shelf merges offline files with no detail request', (
    tester,
  ) async {
    final runtime = MergeFakeRuntime();
    addTearDown(runtime.cleanUp);
    runtime.seedFiles('d1', [1, 2, 3]);
    // Any read of the online catalog would throw: a merge is made of what is
    // already on this device, and this is the offline drama case.
    runtime.catalog.detailFail = true;
    final group = groupLocalEpisodes(runtime.files).single;
    await tester.pumpWidget(
      MaterialApp(
        home: LocalEpisodesPage(runtime: runtime, initial: group),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('local-merge')));
    await tester.pumpAndSettle();
    expect(find.text('选择剧集进行合成'), findsOneWidget);
    // A group entry starts from everything the shelf holds.
    expect(find.textContaining('已选 3 集'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('merge-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('merge-episode-0')));
    await tester.pumpAndSettle();
    // One episode cannot become a product of its own.
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('merge-next')))
          .onPressed,
      isNull,
    );
    expect(find.text('至少选择两集'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('merge-episode-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('merge-next')));
    await tester.pumpAndSettle();
    expect(runtime.probed, [2]);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('confirm-merge')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('confirm-merge')));
    await tester.pumpAndSettle();

    expect(runtime.merges.tasks.single.kind, 'merge');
    expect(runtime.merges.tasks.single.items.length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a refused precheck keeps 开始合成 pressed out', (tester) async {
    final runtime = MergeFakeRuntime();
    addTearDown(runtime.cleanUp);
    runtime.seedFiles('d1', [1, 2]);
    runtime.probeReject = '第 2 集的编码参数与第 1 集不同，暂时无法无损合并';
    final group = groupLocalEpisodes(runtime.files).single;
    await tester.pumpWidget(
      MaterialApp(
        home: LocalEpisodesPage(runtime: runtime, initial: group),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('local-merge')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('merge-next')));
    await tester.pumpAndSettle();

    expect(find.text('编码参数不一致'), findsOneWidget);
    expect(find.textContaining('编码参数与第 1 集不同'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('confirm-merge')))
          .onPressed,
      isNull,
    );
    expect(runtime.merges.tasks, isEmpty);

    // 返回修改 keeps the choice, so the viewer can drop the odd episode.
    await tester.tap(find.byKey(const ValueKey('merge-back')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 2 集'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a split precheck queues one job per 片 in one confirm', (
    tester,
  ) async {
    final runtime = MergeFakeRuntime();
    addTearDown(runtime.cleanUp);
    runtime.seedFiles('d1', [1, 2, 3, 4]);
    // The worker's answer for a selection in two formats: the writer refuses the
    // set as a whole and offers the 片 it does accept, with the lone episode
    // carrying the reason it is on its own.
    runtime.probeReject = '第 3 集的编码参数与第 1 集不同，暂时无法无损合并';
    runtime.probeGroups = [
      [1, 2],
      [3, 4],
    ];
    final group = groupLocalEpisodes(runtime.files).single;
    await tester.pumpWidget(
      MaterialApp(
        home: LocalEpisodesPage(runtime: runtime, initial: group),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('local-merge')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('merge-next')));
    await tester.pumpAndSettle();

    expect(find.text('可拆成 2 片'), findsOneWidget);
    expect(find.textContaining('第 1-2 集'), findsOneWidget);
    expect(find.textContaining('第 3-4 集'), findsOneWidget);
    // Nothing is thrown away by the split, so the size stays the whole selection.
    expect(find.textContaining('将排入 2 片 · 4 集'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('confirm-merge')))
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const ValueKey('confirm-merge')));
    await tester.pumpAndSettle();

    final tasks = runtime.merges.tasks;
    expect(tasks, hasLength(2));
    // The 片 are named apart: the shelf's title plus the order they were queued
    // in, so two products from one click do not collide in the list.
    expect(tasks.map((t) => t.title).toList(), ['山海之间 合集 2', '山海之间 合集 1']);
    expect(tasks.map((t) => t.items.map((i) => i.index).toList()).toList(), [
      [3, 4],
      [1, 2],
    ]);
    expect(find.byType(MergeSelection), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a 片 left alone is not queued, and says so', (tester) async {
    final runtime = MergeFakeRuntime();
    addTearDown(runtime.cleanUp);
    runtime.seedFiles('d1', [1, 2, 3]);
    runtime.probeReject = '第 3 集的编码参数与第 1 集不同，暂时无法无损合并';
    runtime.probeGroups = [
      [1, 2],
      [3],
    ];
    final group = groupLocalEpisodes(runtime.files).single;
    await tester.pumpWidget(
      MaterialApp(
        home: LocalEpisodesPage(runtime: runtime, initial: group),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('local-merge')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('merge-next')));
    await tester.pumpAndSettle();

    expect(find.text('可合成一片'), findsOneWidget);
    expect(find.textContaining('落单'), findsOneWidget);
    expect(find.textContaining('将排入 1 片 · 2 集'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('confirm-merge')));
    await tester.pumpAndSettle();

    final task = runtime.merges.tasks.single;
    expect(task.items.map((i) => i.index).toList(), [1, 2]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a phone runs the same two steps inside the bottom sheet', (
    tester,
  ) async {
    final runtime = MergeFakeRuntime();
    addTearDown(runtime.cleanUp);
    runtime.seedFiles('d1', [1, 2, 3]);
    // The container is chosen off MediaQuery, so the size has to land on the
    // view -- a tight RenderView would leave MediaQuery at 800x600 and this
    // would silently be the desktop dialog again.
    tester.view.physicalSize = const Size(400, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final group = groupLocalEpisodes(runtime.files).single;
    await tester.pumpWidget(
      MaterialApp(
        home: LocalEpisodesPage(runtime: runtime, initial: group),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('local-merge')));
    await tester.pumpAndSettle();
    final panel = find.byType(MergeSelection);
    expect(panel, findsOneWidget);
    expect(MediaQuery.sizeOf(tester.element(panel)), const Size(400, 780));
    expect(find.textContaining('已选 3 集 · 合计约'), findsOneWidget);

    // Dropping one episode is a tap on its tile, and the grid still totals.
    await tester.tap(find.byKey(const ValueKey('merge-episode-0')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 2 集 · 合计约'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('merge-next')));
    await tester.pumpAndSettle();
    expect(find.text('合成预检'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-merge')));
    await tester.pumpAndSettle();

    expect(runtime.merges.tasks.single.items.length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全选可合 takes only what is on disk', (tester) async {
    final runtime = MergeFakeRuntime();
    addTearDown(runtime.cleanUp);
    runtime.seedFiles('d1', [1, 2]);
    final detail = DramaDetail(
      Drama(id: 'd1', title: '山海之间', episodeCount: 4),
      [for (var i = 1; i <= 4; i++) Episode(vid: '$i', index: i)],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showMergeSelection(
                  context,
                  runtime,
                  options: [
                    for (final episode in detail.episodes)
                      MergeEpisodeOption(
                        vid: episode.vid,
                        quality: 'best',
                        dramaId: 'd1',
                        label: '第 ${episode.index} 集',
                        index: episode.index,
                        bytes: episode.index <= 2 ? 1024 * 1024 : 0,
                        available: episode.index <= 2,
                      ),
                  ],
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('merge-select-all')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 2 集'), findsOneWidget);
    // The undownloaded tile answers with where to go, not with a selection.
    await tester.tap(find.byKey(const ValueKey('merge-episode-2')));
    await tester.pumpAndSettle();
    expect(find.textContaining('该集未下载，请先去下载'), findsOneWidget);
    expect(find.textContaining('已选 2 集'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the queue shows a held job with the controls its phase answers',
    (tester) async {
      final runtime = MergeFakeRuntime();
      addTearDown(runtime.cleanUp);
      runtime.seedFiles('d1', [1, 2]);
      await runtime.merges.enqueue(
        items: [
          merge.MergeSelection(
            vid: '1',
            quality: 'best',
            index: 1,
            title: '第 1 集',
            dramaId: 'd1',
          ),
          merge.MergeSelection(
            vid: '2',
            quality: 'best',
            index: 2,
            title: '第 2 集',
            dramaId: 'd1',
          ),
        ],
        title: '山海之间 合集',
      );
      expect(runtime.merges.pendingCount, 1);
      expect(runtime.merges.runningCount, 0);

      await tester.pumpWidget(
        MaterialApp(home: MergeTasksPage(runtime: runtime)),
      );
      await tester.pumpAndSettle();
      final task = runtime.merges.tasks.single;
      expect(find.text('合成 · 山海之间 合集'), findsOneWidget);
      expect(find.textContaining('正在播放'), findsOneWidget);
      expect(find.byKey(ValueKey('merge-cancel-${task.id}')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('merge-new')));
      await tester.pumpAndSettle();
      expect(find.byType(MergeSelection), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an ffmpeg machine is offered 兼容合成 and joins what 无损 split', (
    tester,
  ) async {
    final runtime = MergeFakeRuntime(lane: MergeUiTranscoder());
    addTearDown(runtime.cleanUp);
    runtime.seedFiles('d1', [1, 2, 3]);
    runtime.probeReject = '第 3 集的编码参数与第 1 集不同，暂时无法无损合并';
    runtime.probeGroups = [
      [1, 2],
      [3],
    ];
    final group = groupLocalEpisodes(runtime.files).single;
    await tester.pumpWidget(
      MaterialApp(
        home: LocalEpisodesPage(runtime: runtime, initial: group),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('local-merge')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('merge-next')));
    await tester.pumpAndSettle();

    // Two lanes, named: 无损 stays the default, and the refusal points at the
    // other one instead of ending the conversation.
    expect(find.text('合成方式'), findsOneWidget);
    expect(find.text('无损合成'), findsOneWidget);
    expect(find.text('兼容合成'), findsOneWidget);
    expect(find.byKey(const ValueKey('merge-mode-escape')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('merge-mode-compatible')));
    await tester.pumpAndSettle();

    // Every file reads 1080x1920 here, so the encoder takes the whole selection
    // as one product -- the reason the lane exists. Nothing is re-probed: the
    // same 预检 answer, simply read by the other rule.
    expect(find.text('重编码可合成一片'), findsOneWidget);
    expect(find.textContaining('ffmpeg · libx264'), findsOneWidget);
    expect(find.textContaining('源文件合计 3.0 MB'), findsOneWidget);
    expect(find.textContaining('将排入 1 片 · 3 集 · 产物约'), findsOneWidget);

    // Back to 无损: the split and the invitation both come back, unchanged.
    await tester.tap(find.byKey(const ValueKey('merge-mode-lossless')));
    await tester.pumpAndSettle();
    expect(find.text('可合成一片'), findsOneWidget);
    expect(find.byKey(const ValueKey('merge-mode-escape')), findsOneWidget);
    expect(find.textContaining('将排入 1 片 · 2 集'), findsOneWidget);

    // The refusal's own button says the same thing as the segment, from where the
    // viewer was already looking.
    final escape = find.byKey(const ValueKey('merge-mode-escape'));
    await tester.ensureVisible(escape);
    await tester.pumpAndSettle();
    await tester.tap(escape);
    await tester.pumpAndSettle();
    expect(find.textContaining('将排入 1 片 · 3 集 · 产物约'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('confirm-merge')));
    await tester.pumpAndSettle();

    final task = runtime.merges.tasks.single;
    expect(task.mode, 'compatible');
    expect(task.isCompatible, isTrue);
    expect(task.items.map((i) => i.index).toList(), [1, 2, 3]);

    await tester.pumpWidget(
      MaterialApp(home: MergeTasksPage(runtime: runtime)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('兼容合成 · 山海之间 合集'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a device with no ffmpeg is shown one way to merge', (
    tester,
  ) async {
    final runtime = MergeFakeRuntime();
    addTearDown(runtime.cleanUp);
    runtime.seedFiles('d1', [1, 2, 3]);
    runtime.probeReject = '第 3 集的编码参数与第 1 集不同，暂时无法无损合并';
    runtime.probeGroups = [
      [1, 2],
      [3],
    ];
    final group = groupLocalEpisodes(runtime.files).single;
    await tester.pumpWidget(
      MaterialApp(
        home: LocalEpisodesPage(runtime: runtime, initial: group),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('local-merge')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('merge-next')));
    await tester.pumpAndSettle();

    // No second lane, and no invitation to a lane that would only fail: the
    // refusal stands on its own, as it did before the encoder existed.
    expect(find.text('合成方式'), findsNothing);
    expect(find.byKey(const ValueKey('merge-mode-escape')), findsNothing);
    expect(find.text('可合成一片'), findsOneWidget);
    expect(find.textContaining('将排入 1 片 · 2 集'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('追加 keeps the one lane that can grow a file in place', (
    tester,
  ) async {
    final runtime = MergeFakeRuntime(lane: MergeUiTranscoder());
    addTearDown(runtime.cleanUp);
    runtime.seedFiles('d1', [1, 2, 3]);
    runtime.seedProduct(items: [item(1, vid: '1')]);
    await tester.pumpWidget(
      MaterialApp(
        home: MergedPage(runtime: runtime, mergeId: 'm1'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('merged-append')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('merge-episode-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('merge-next')));
    await tester.pumpAndSettle();

    // A re-encode writes a whole new file, so it has nothing to offer an append;
    // the choice disappears with the target rather than failing on press.
    expect(find.text('合成方式'), findsNothing);
    expect(find.textContaining('编解码一致'), findsOneWidget);
    expect(runtime.merges.tasks, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a product says which lane wrote it', (tester) async {
    final runtime = MergeFakeRuntime();
    addTearDown(runtime.cleanUp);
    runtime.seedFiles('d1', [1, 2]);
    runtime.seedProduct(items: [item(1), item(2)], mode: 'compatible');
    runtime.seedProduct(
      mergeId: 'm2',
      title: '无损的那一份',
      items: [
        item(3, vid: '3'),
        item(4, vid: '4'),
      ],
    );
    await tester.pumpWidget(MaterialApp(home: MergedPage(runtime: runtime)));
    await tester.pumpAndSettle();

    // A list of products is a list of lanes: only the re-encoded one is marked,
    // because that is the one that plays on a phone without the source codec.
    expect(find.textContaining('· 兼容合成 ·'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('merged-m1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('兼容合成 · 重编码为 H.264'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('merged-m2')));
    await tester.pumpAndSettle();
    expect(find.textContaining('无损合成 · 直接搬运源文件字节'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
