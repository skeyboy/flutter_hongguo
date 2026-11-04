import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  testWidgets('追加剧集 offers only the episodes the product does not hold', (
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
    // vid 1 is already inside the product, so the panel does not offer it --
    // the page behind it still shows it in 构成, which is not a choice.
    expect(
      find.descendant(of: panel, matching: find.textContaining('第 1 集')),
      findsNothing,
    );
    expect(
      find.descendant(of: panel, matching: find.textContaining('第 2 集')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.textContaining('第 3 集')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('merge-episode-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('merge-episode-1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('merge-episode-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-merge')));
    await tester.pumpAndSettle();

    final task = runtime.merges.tasks.single;
    expect(task.kind, 'append');
    expect(task.targetMergeId, 'm1');
    expect(task.items.single.vid, '2');
    expect(find.byType(MergeSelection), findsNothing);
    expect(find.textContaining('已加入合成队列'), findsOneWidget);
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
    expect(find.text('新建合成'), findsOneWidget);
    expect(find.textContaining('需至少两集'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('merge-episode-0')));
    await tester.pumpAndSettle();
    // One episode cannot become a product of its own.
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('confirm-merge')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('merge-episode-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-merge')));
    await tester.pumpAndSettle();

    expect(runtime.merges.tasks.single.kind, 'merge');
    expect(runtime.merges.tasks.single.items.length, 2);
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
}
