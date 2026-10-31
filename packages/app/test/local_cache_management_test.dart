import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/catalog/local_library.dart';
import 'package:hongguo_app/downloads/download_manager.dart';
import 'package:hongguo_app/features/downloads_page.dart';
import 'package:hongguo_app/features/local_cache_page.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import 'desktop_fakes.dart';
import 'download_fakes.dart';

/// The two drama-level actions a cached shelf now offers -- 拉取最新剧集 and
/// 归类删除 -- walked once per family. The remote family is the reason each is its
/// own labelled target: a row-wide target would hide the destructive one.
Widget _tv(Widget child) => MaterialApp(
  theme: ThemeData(colorScheme: const ColorScheme.dark()),
  builder: (context, inner) =>
      TvEnvironment(enabled: true, child: TvNavigation(child: inner!)),
  home: child,
);

FocusNode? _nodeByLabel(WidgetTester tester, String needle) {
  final candidates = tester.widgetList<TvFocusable>(
    find.byWidgetPredicate((w) => w is TvFocusable && w.label.contains(needle)),
  );
  if (candidates.isEmpty) return null;
  FocusNode? node;
  void scan(Element element) {
    if (node != null) return;
    final widget = element.widget;
    if (widget is Focus && widget.focusNode != null) node = widget.focusNode;
    element.visitChildren(scan);
  }

  tester.element(find.byWidget(candidates.first)).visitChildren(scan);
  return node;
}

Future<void> _activate(WidgetTester tester, String label) async {
  final node = _nodeByLabel(tester, label);
  expect(node, isNotNull, reason: 'no target labelled $label in the tree');
  node!.requestFocus();
  await tester.pumpAndSettle();
  await tester.sendKeyEvent(LogicalKeyboardKey.select);
  await tester.pumpAndSettle();
}

/// The fake-async-safe form of a tick. The queue advances on microtasks and on
/// zero-delay timers that only `pump` elapses, so `queueTick` -- right in a
/// plain test -- would hang forever inside a widget test's zone.
///
/// The 400ms hop also finishes a route or dialog transition, which `tap` needs
/// before it can reach the button. 下载管理 deliberately never reaches a settled
/// frame while an episode is in flight -- its row shows an indeterminate
/// progress bar -- so these tests pump a known number of frames instead of
/// calling `pumpAndSettle`.
Future<void> drain(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

/// One cached episode of 山海之间, so the shelf has a series id and a quality.
///
/// An empty surface is mounted first: the queue can only be walked forward by
/// pumping, and there is nothing to pump against before the page under test.
Future<DownloadFakeRuntime> _shelf(WidgetTester tester, String quality) async {
  await tester.pumpWidget(const SizedBox.shrink());
  final runtime = DownloadFakeRuntime();
  final detail = await runtime.catalog.detail('123');
  await runtime.downloads.enqueue(detail, [0], quality);
  await drain(tester);
  await runtime.complete('11_$quality');
  await drain(tester);
  expect(
    runtime.downloads.taskFor('11', quality)!.phase,
    DownloadPhase.ready,
    reason: 'the shelf setup must reach a real cached file',
  );
  return runtime;
}

/// A queue left in whatever state the page is supposed to react to.
Future<DownloadFakeRuntime> _queue(
  WidgetTester tester,
  List<int> positions,
  String quality, {
  required Future<void> Function(DownloadFakeRuntime) then,
}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  final runtime = DownloadFakeRuntime();
  final detail = await runtime.catalog.detail('123');
  await runtime.downloads.enqueue(detail, positions, quality);
  await drain(tester);
  await then(runtime);
  await drain(tester);
  return runtime;
}

Future<void> _openShelf(
  WidgetTester tester,
  DownloadFakeRuntime runtime, {
  required bool tv,
}) async {
  if (tv) {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }
  final group = groupLocalEpisodes(await runtime.localEpisodes())
      .firstWhere((g) => g.id == '123');
  final page = LocalEpisodesPage(runtime: runtime, initial: group);
  await tester.pumpWidget(tv ? _tv(page) : MaterialApp(home: page));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    '触屏 pulls the newest episodes into the queue and reports the read',
    (tester) async {
      final runtime = await _shelf(tester, '1080p');
      addTearDown(() async {
        final closing = runtime.dispose();
        await tester.pump();
        await closing;
      });
      await _openShelf(tester, runtime, tv: false);

      expect(find.byKey(const ValueKey('local-pull')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('local-pull')));
      await drain(tester);
      await tester.pumpAndSettle();

      expect(runtime.calls, ['11_1080p', '12_1080p']);
      expect(
        runtime.downloads.taskFor('13', '1080p')!.phase,
        DownloadPhase.queued,
      );
      expect(find.textContaining('新加入 2 集下载（1080p）'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('触屏 归类删除 asks first, then takes the drama’s files and records', (
    tester,
  ) async {
    final runtime = await _shelf(tester, 'best');
    addTearDown(() async {
      final closing = runtime.dispose();
      await tester.pump();
      await closing;
    });
    await _openShelf(tester, runtime, tv: false);

    await tester.tap(find.byKey(const ValueKey('local-remove-group')));
    await tester.pumpAndSettle();
    expect(find.text('删除本剧全部缓存？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(runtime.files, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('local-remove-group')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除全部'));
    await drain(tester);
    await tester.pumpAndSettle();

    expect(runtime.files, isEmpty);
    expect(runtime.downloads.tasks, isEmpty);
    expect(find.textContaining('已删除 1 个文件'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('遥控 reaches 拉取最新剧集 and answers 删除本剧缓存 alone', (tester) async {
    final runtime = await _shelf(tester, '720p');
    addTearDown(() async {
      final closing = runtime.dispose();
      await tester.pump();
      await closing;
    });
    await _openShelf(tester, runtime, tv: true);

    expect(_nodeByLabel(tester, '拉取最新剧集'), isNotNull);
    await _activate(tester, '拉取最新剧集');
    expect(runtime.calls, ['11_720p', '12_720p']);

    await _activate(tester, '删除本剧缓存');
    expect(find.text('删除本剧全部缓存？'), findsOneWidget);
    // The ring parks on 取消, so a stray 确认 key cannot delete a shelf.
    await _activate(tester, '删除全部');
    await tester.pumpAndSettle();

    expect(runtime.files.map((f) => f.vid), isEmpty);
    expect(runtime.downloads.tasks, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('下载管理 offers 继续全部 only while something is waiting to continue', (
    tester,
  ) async {
    final runtime = await _queue(
      tester,
      [0, 1],
      'best',
      then: (rt) async {
        await rt.complete('11_best');
        await drain(tester);
        rt.downloads.pause('12_best');
      },
    );
    addTearDown(() async {
      final closing = runtime.dispose();
      await tester.pump();
      await closing;
    });
    expect(runtime.calls, ['11_best', '12_best']);

    await tester.pumpWidget(MaterialApp(home: DownloadsPage(runtime: runtime)));
    await drain(tester);
    expect(find.byTooltip('继续全部下载'), findsOneWidget);
    await tester.tap(find.byTooltip('继续全部下载'));
    await drain(tester);

    expect(runtime.calls, ['11_best', '12_best', '12_best']);
    expect(find.textContaining('已重新排队 1 条下载'), findsOneWidget);

    await runtime.complete('12_best');
    await drain(tester);
    expect(find.byTooltip('继续全部下载'), findsNothing);
  });

  testWidgets('下载管理 删除本剧 takes the whole drama, not one row', (tester) async {
    final runtime = await _queue(
      tester,
      [0, 1],
      '720p',
      then: (rt) async {
        await rt.complete('11_720p');
      },
    );
    addTearDown(() async {
      final closing = runtime.dispose();
      await tester.pump();
      await closing;
    });
    expect(
      runtime.downloads.taskFor('12', '720p')!.phase,
      DownloadPhase.running,
      reason: 'the second episode is still in flight when the shelf is deleted',
    );

    await tester.pumpWidget(MaterialApp(home: DownloadsPage(runtime: runtime)));
    await drain(tester);
    await tester.tap(find.byTooltip('删除本剧全部下载'));
    await drain(tester);
    expect(find.text('删除本剧全部下载？'), findsOneWidget);
    await tester.tap(find.text('删除全部'));
    await drain(tester);

    expect(runtime.files, isEmpty);
    expect(runtime.downloads.tasks, isEmpty);
    expect(runtime.jobs['12_720p']!.cancelled, isTrue);
    expect(find.textContaining('暂无下载'), findsOneWidget);
  });

  testWidgets('榜单 grows no 下载更多: the board has no shelf to update', (
    tester,
  ) async {
    // 榜单 is only reachable inside the app shell, so the guard is read there: the
    // board opened and drew its own 赛道, and none of the shelf's new controls came
    // with it -- a board row has no drama group to update or delete.
    await mount(tester, DesktopCatalog());
    await tester.tap(find.text('榜单').first);
    await tester.pumpAndSettle();

    expect(find.text('真人剧'), findsWidgets);
    expect(find.text('拉取最新剧集'), findsNothing);
    expect(find.text('删除本剧缓存'), findsNothing);
    expect(find.textContaining('下载更多'), findsNothing);
    expect(find.byTooltip('继续全部下载'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });
}
