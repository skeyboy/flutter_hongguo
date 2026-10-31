// 下载管理 has to be drivable with a remote alone on an Android TV: the three
// filters, both AppBar actions and each half of every task row are `TvFocusable`
// targets there, because a ChoiceChip or an IconButton leaves the viewer holding
// a focus nobody can see. The page is shared with the phone and desktop builds,
// so the assertions pin the `TvEnvironment` branch rather than the Android flavor.
//
// Targets are exercised through the real key path -- a `select` event travelling
// `TvNavigation` -> `TvFocusable` -- and the destructive one through its
// confirmation, because that is where a stray confirm key could delete a file.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/downloads/download_manager.dart';
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

void main() {
  group('下载管理 on TV', () {
    testWidgets(
      'filters, app bar and both halves of each row are remote targets',
      (tester) async {
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
          '山海之间 第 1 集 离线观看',
          '山海之间 第 1 集 删除下载记录',
          '山海之间 第 2 集 暂停下载',
          '山海之间 第 2 集 取消下载',
        ]) {
          expect(_targets(tester), contains(label));
        }
        // Touch-only chrome of the phone layout must not survive on TV: an
        // IconButton or ChoiceChip leaves the remote holding an invisible focus.
        expect(find.byType(IconButton), findsNothing);
        expect(find.byType(ChoiceChip), findsNothing);
        expect(_nodeByLabel(tester, '刷新下载')!.skipTraversal, isFalse);

        await _activate(tester, '已完成');
        // The active filter is filled, not just ringed: the ring only says
        // where the remote sits.
        expect(
          tester
              .widget<TvFocusable>(
                find.byKey(const ValueKey('downloads-filter-tv-2')),
              )
              .selected,
          isTrue,
        );
        expect(_nodeByLabel(tester, '山海之间 第 2 集 暂停下载'), isNull);
        expect(_nodeByLabel(tester, '山海之间 第 1 集 离线观看'), isNotNull);

        await _activate(tester, '全部');
        expect(_nodeByLabel(tester, '山海之间 第 2 集 取消下载'), isNotNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('离线观看 is the ready row primary action', (tester) async {
      await _useTvView(tester);
      final runtime = await _transferring(tester);
      await tester.pumpWidget(_tv(DownloadsPage(runtime: runtime)));
      await tester.pump();
      await _finish(tester, runtime, '11_best');
      await tester.pumpAndSettle();
      expect(runtime.downloads.tasks.single.phase, DownloadPhase.ready);

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
      // With no file left the record is resumable, so the same slot now offers
      // 继续下载.
      expect(_nodeByLabel(tester, '山海之间 第 1 集 继续下载'), isNotNull);
      expect(_nodeByLabel(tester, '山海之间 第 1 集 离线观看'), isNull);
      await tester.pumpAndSettle();
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

    testWidgets('a transferring row is pause and cancel, two separate keys', (
      tester,
    ) async {
      await _useTvView(tester);
      final runtime = await _transferring(tester);
      await tester.pumpWidget(_tv(DownloadsPage(runtime: runtime)));
      await tester.pump();
      _report(runtime, '11_best');
      await tester.pumpAndSettle();

      expect(_nodeByLabel(tester, '山海之间 第 1 集 暂停下载'), isNotNull);
      expect(_nodeByLabel(tester, '山海之间 第 1 集 取消下载'), isNotNull);
      expect(find.textContaining('40%'), findsOneWidget);

      await _activate(tester, '山海之间 第 1 集 暂停下载');
      expect(runtime.downloads.tasks.single.phase, DownloadPhase.paused);
      // A paused record keeps neither half of the transferring row: the primary
      // slot becomes 继续下载 and the trailing one deletes the record.
      expect(_nodeByLabel(tester, '山海之间 第 1 集 继续下载'), isNotNull);
      expect(_nodeByLabel(tester, '山海之间 第 1 集 暂停下载'), isNull);
      expect(_nodeByLabel(tester, '山海之间 第 1 集 删除下载记录'), isNotNull);
      expect(_nodeByLabel(tester, '山海之间 第 1 集 取消下载'), isNull);
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
      // The row was never a ListTile, and it is still not one: the phone keeps
      // its two trailing icon buttons per task.
      expect(find.byType(ListTile), findsNothing);
      // The two app bar actions, the drama header's whole-drama delete and the
      // ready row's play and delete pair plus the transferring row's pause and
      // cancel pair. Nothing is waiting to continue here, so 继续全部 stays away.
      expect(find.byType(IconButton), findsNWidgets(7));
      expect(find.byType(ChoiceChip), findsNWidgets(3));
      expect(find.byTooltip('离线观看'), findsOneWidget);
      expect(find.byTooltip('删除本剧全部下载'), findsOneWidget);
      expect(find.byTooltip('删除下载记录'), findsOneWidget);
      expect(find.byTooltip('暂停下载'), findsOneWidget);

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
      expect(runtime.files, isEmpty);
      expect(runtime.downloads.tasks, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  });
}
