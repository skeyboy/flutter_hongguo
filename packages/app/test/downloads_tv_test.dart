// 下载管理 has to be drivable with a remote alone on an Android TV: the three
// filters, both AppBar actions and every card and row are `TvFocusable` targets
// there, because a ChoiceChip or an IconButton leaves the viewer holding a focus
// nobody can see. The list is one card per drama and the per-episode actions live
// on the page a card opens, so this suite walks the whole trip.
//
// Targets are exercised through the real key path -- a `select` event travelling
// `TvNavigation` -> `TvFocusable` -- and the destructive one through its
// confirmation, because that is where a stray confirm key could delete a file.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/downloads/download_manager.dart';
import 'package:hongguo_app/features/download_episodes_page.dart';
import 'package:hongguo_app/features/downloads_page.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import 'download_fakes.dart';
import 'fakes.dart';

/// The app root in the tv flavor: `TvEnvironment` carries the decision and
/// `TvNavigation` is the single key handler, so the page gets the same focus
/// walk it has on the emulator.
Widget _tv(Widget child) => MaterialApp(
  theme: ThemeData(colorScheme: const ColorScheme.dark()),
  builder: (context, inner) =>
      TvEnvironment(enabled: true, child: TvNavigation(child: inner!)),
  home: child,
);

/// The labels the remote can actually stop on, read off the widgets rather than
/// the nodes: a page may hand `TvFocusable` a node carrying its own debug label.
List<String> _targets(WidgetTester tester) => tester
    .widgetList<TvFocusable>(find.byType(TvFocusable))
    .map((w) => w.label)
    .toList();

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

String? _focus() => FocusManager.instance.primaryFocus?.debugLabel;

Future<void> _activate(WidgetTester tester, String label) async {
  final node = _nodeByLabel(tester, label);
  expect(
    node,
    isNotNull,
    reason: 'no remote target labelled $label; tree has ${_targets(tester)}',
  );
  node!.requestFocus();
  await tester.pumpAndSettle();
  await tester.sendKeyEvent(LogicalKeyboardKey.select);
  await tester.pumpAndSettle();
}

/// The queue is owned by the runtime, so a test that leaves a transfer in
/// flight has to shut it down with the tree still standing.
void _closeRuntime(WidgetTester tester, DownloadFakeRuntime runtime) {
  addTearDown(() async {
    final closing = runtime.dispose();
    await tester.pump();
    await closing;
  });
}

/// Tasks the page can act on, without any networking: the fake hands the queue
/// its own jobs, so the first episode transfers and the rest wait their turn.
Future<DownloadFakeRuntime> _transferring(
  WidgetTester tester, {
  int episodes = 1,
}) async {
  final runtime = DownloadFakeRuntime();
  _closeRuntime(tester, runtime);
  await runtime.downloads.enqueue(
    await runtime.catalog.detail(FakeCatalog.demo.id),
    [for (var i = 0; i < episodes; i++) i],
    'best',
  );
  return runtime;
}

// A `null` fraction renders an indeterminate bar, which never settles, so the
// fake reports progress the way the media pipeline does.
void _report(DownloadFakeRuntime runtime, String key, {double fraction = 0.4}) {
  expect(
    runtime.jobs[key],
    isNotNull,
    reason: '$key should have reached the transfer stage',
  );
  runtime.jobs[key]!.progress(PreparationProgress('正在传输', fraction));
}

/// Publishes the validated file the queue is waiting for, so the task lands in
/// `ready` and the next queued one starts.
Future<void> _finish(
  WidgetTester tester,
  DownloadFakeRuntime runtime,
  String key,
) async {
  await runtime.complete(key);
  await tester.pump();
}

Future<void> _useTvView(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1920, 1080));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

/// The one way into a drama's rows with a remote: the card, never a long press.
Future<void> _openDrama(WidgetTester tester) async {
  await _activate(tester, '山海之间 分集进度');
  await tester.pumpAndSettle();
  expect(find.byType(DownloadEpisodesPage), findsOneWidget);
}

void main() {
  group('下载管理 on TV', () {
    testWidgets('a drama card is one target, and it opens the episode rows', (
      tester,
    ) async {
      await _useTvView(tester);
      final runtime = await _transferring(tester, episodes: 2);
      await tester.pumpWidget(_tv(DownloadsPage(runtime: runtime)));
      await tester.pump();
      await _finish(tester, runtime, '11_best');
      _report(runtime, '12_best');
      await tester.pumpAndSettle();

      for (final label in const [
        '查看离线剧集',
        '刷新下载',
        '全部',
        '下载中',
        '已完成',
        '山海之间 分集进度',
        '山海之间 删除本剧',
      ]) {
        expect(_targets(tester), contains(label));
      }
      // Touch-only chrome of the phone layout must not survive on TV: an
      // IconButton or ChoiceChip leaves the remote holding an invisible focus.
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(ChoiceChip), findsNothing);
      // The card answers for the whole drama in one line, so the viewer knows
      // what is still missing before opening it.
      expect(find.text('已完成 1 / 2 集 · 下载中 1'), findsOneWidget);
      // The per-episode rows are not on this page at all.
      expect(_nodeByLabel(tester, '山海之间 第 1 集 离线观看'), isNull);

      await _openDrama(tester);
      for (final label in const [
        '山海之间 第 1 集 离线观看',
        '山海之间 第 1 集 删除下载记录',
        '山海之间 第 2 集 暂停下载',
        '山海之间 第 2 集 取消下载',
      ]) {
        expect(_nodeByLabel(tester, label), isNotNull, reason: label);
      }
      expect(find.textContaining('40%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the filters run on dramas, not on single rows', (
      tester,
    ) async {
      await _useTvView(tester);
      final runtime = await _transferring(tester);
      await tester.pumpWidget(_tv(DownloadsPage(runtime: runtime)));
      await tester.pump();
      await _finish(tester, runtime, '11_best');
      await tester.pumpAndSettle();

      await _activate(tester, '下载中');
      expect(
        tester
            .widget<TvFocusable>(
              find.byKey(const ValueKey('downloads-filter-tv-1')),
            )
            .selected,
        isTrue,
      );
      // Nothing is moving for this drama anymore, so the series leaves the list
      // entirely -- and the empty state says where to look instead of blaming
      // the viewer.
      expect(_nodeByLabel(tester, '山海之间 分集进度'), isNull);
      expect(find.textContaining('这个筛选下还没有剧目'), findsOneWidget);

      await _activate(tester, '已完成');
      expect(_nodeByLabel(tester, '山海之间 分集进度'), isNotNull);
      expect(find.text('已完成 1 / 1 集'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('离线观看 is the ready row primary action', (tester) async {
      await _useTvView(tester);
      final runtime = await _transferring(tester);
      await tester.pumpWidget(_tv(DownloadsPage(runtime: runtime)));
      await tester.pump();
      await _finish(tester, runtime, '11_best');
      await tester.pumpAndSettle();
      await _openDrama(tester);

      // The player needs a real media pipeline, so the watch path is proved
      // from its own first step: the file goes away, and the row answers with
      // the error that path raises instead of pretending nothing happened.
      runtime.files.clear();
      final node = _nodeByLabel(tester, '山海之间 第 1 集 离线观看');
      expect(node, isNotNull);
      expect(node!.skipTraversal, isFalse);
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.pump();
      expect(find.text('本地文件已移除，请重新下载'), findsOneWidget);
      // With no file left the record is a failed one, so the same slot now asks
      // the queue to run it again.
      expect(_nodeByLabel(tester, '山海之间 第 1 集 重试下载'), isNotNull);
      expect(_nodeByLabel(tester, '山海之间 第 1 集 离线观看'), isNull);
      // The card behind the rows reloaded against the same empty disk, so it
      // no longer claims an offline copy the viewer cannot watch.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('已完成 0 / 1 集 · 待继续 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('删除 answers its confirmation with the remote alone', (
      tester,
    ) async {
      await _useTvView(tester);
      final runtime = await _transferring(tester);
      await tester.pumpWidget(_tv(DownloadsPage(runtime: runtime)));
      await tester.pump();
      await _finish(tester, runtime, '11_best');
      await tester.pumpAndSettle();
      await _openDrama(tester);

      await _activate(tester, '山海之间 第 1 集 删除下载记录');
      expect(find.text('删除已下载视频？'), findsOneWidget);
      // The ring starts on 取消, so a stray confirm key cannot destroy a
      // download, and the destructive answer is one step to the right.
      expect(_focus(), '取消');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(_focus(), '删除');

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('删除已下载视频？'), findsNothing);
      expect(runtime.downloads.tasks, isEmpty);
      expect(runtime.files, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('删除本剧 takes the records and the files in one confirm', (
      tester,
    ) async {
      await _useTvView(tester);
      final runtime = await _transferring(tester, episodes: 2);
      await tester.pumpWidget(_tv(DownloadsPage(runtime: runtime)));
      await tester.pump();
      await _finish(tester, runtime, '11_best');
      await _finish(tester, runtime, '12_best');
      await tester.pumpAndSettle();
      expect(runtime.files, hasLength(2));

      await _activate(tester, '山海之间 删除本剧');
      expect(find.text('删除本剧全部下载？'), findsOneWidget);
      expect(find.textContaining('2 条下载记录与 2 个本地缓存文件一并删除'), findsOneWidget);
      expect(_focus(), '取消');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(_focus(), '删除全部');
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(runtime.downloads.tasks, isEmpty);
      expect(runtime.files, isEmpty);
      // The report is read back off the disk, not from what was attempted.
      expect(find.textContaining('已删除 2 个文件'), findsOneWidget);
      expect(find.byType(DownloadsPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a transferring row is pause and cancel, two separate keys', (
      tester,
    ) async {
      await _useTvView(tester);
      final runtime = await _transferring(tester);
      await tester.pumpWidget(_tv(DownloadsPage(runtime: runtime)));
      await tester.pump();
      _report(runtime, '11_best');
      await tester.pumpAndSettle();
      await _openDrama(tester);

      expect(_nodeByLabel(tester, '山海之间 第 1 集 暂停下载'), isNotNull);
      expect(_nodeByLabel(tester, '山海之间 第 1 集 取消下载'), isNotNull);

      await _activate(tester, '山海之间 第 1 集 暂停下载');
      expect(runtime.downloads.tasks.single.phase, DownloadPhase.paused);
      // A paused record keeps neither half of the transferring row: the primary
      // slot becomes 继续下载 and the trailing one deletes the record.
      expect(_nodeByLabel(tester, '山海之间 第 1 集 继续下载'), isNotNull);
      expect(_nodeByLabel(tester, '山海之间 第 1 集 暂停下载'), isNull);
      expect(_nodeByLabel(tester, '山海之间 第 1 集 删除下载记录'), isNotNull);
      expect(_nodeByLabel(tester, '山海之间 第 1 集 取消下载'), isNull);
      // The card behind it says the same thing the row just became.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('已完成 0 / 1 集 · 待继续 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a pushed route answers the remote Back key, not an arrow', (
      tester,
    ) async {
      await _useTvView(tester);
      final runtime = await _transferring(tester);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: ThemeData(colorScheme: const ColorScheme.dark()),
          builder: (context, inner) =>
              TvEnvironment(enabled: true, child: TvNavigation(child: inner!)),
          home: const Scaffold(body: Center(child: Text('片单'))),
        ),
      );
      await tester.pumpAndSettle();
      navigator.currentState!.push(
        MaterialPageRoute(builder: (_) => DownloadsPage(runtime: runtime)),
      );
      await tester.pump();
      await _finish(tester, runtime, '11_best');
      await tester.pumpAndSettle();

      // The app bar arrow is dropped on TV: it is an IconButton the ring cannot
      // reach, and 返回 already pops this route through TvNavigation.
      expect(find.byType(DownloadsPage), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);
      final refresh = _nodeByLabel(tester, '刷新下载');
      expect(refresh, isNotNull);
      refresh!.requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(DownloadsPage), findsNothing);
      expect(find.text('片单'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('下载管理 on a phone', () {
    testWidgets('keeps its chips, icons and plain confirm dialog', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final runtime = await _transferring(tester, episodes: 2);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, inner) =>
              TvEnvironment(enabled: false, child: inner!),
          home: DownloadsPage(runtime: runtime),
        ),
      );
      await tester.pump();
      await _finish(tester, runtime, '11_best');
      _report(runtime, '12_best');
      await tester.pumpAndSettle();

      expect(find.byType(TvFocusable), findsNothing);
      // The list is no longer a wall of rows: one card for the drama, and the
      // rows it hides are the reason the card is tappable.
      expect(find.byType(ListTile), findsNothing);
      expect(find.byType(DownloadEpisodesPage), findsNothing);
      // The two app bar actions and the card's whole-drama delete. Nothing is
      // waiting to continue here, so 继续全部 stays away.
      expect(find.byType(IconButton), findsNWidgets(3));
      expect(find.byType(ChoiceChip), findsNWidgets(3));
      expect(find.byTooltip('删除本剧全部下载'), findsOneWidget);
      expect(find.text('分集进度'), findsOneWidget);
      expect(find.text('已完成 1 / 2 集 · 下载中 1'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('downloads-drama-123')));
      await tester.pumpAndSettle();
      expect(find.byType(DownloadEpisodesPage), findsOneWidget);
      expect(find.byTooltip('离线观看'), findsOneWidget);
      expect(find.byTooltip('删除下载记录'), findsOneWidget);
      expect(find.byTooltip('暂停下载'), findsOneWidget);
      expect(find.byTooltip('取消下载'), findsOneWidget);

      await tester.tap(find.byTooltip('删除下载记录'));
      await tester.pumpAndSettle();
      expect(find.text('删除已下载视频？'), findsOneWidget);
      expect(find.byType(TvFocusable), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(runtime.downloads.tasks, hasLength(2));

      await tester.tap(find.byTooltip('删除下载记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      // Only the ready episode's file went, with its record; the transferring
      // one never had a file to lose.
      expect(runtime.files, isEmpty);
      expect(runtime.downloads.tasks, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  });
}
