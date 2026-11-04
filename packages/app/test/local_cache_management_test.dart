import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
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

/// The drama-level actions a cached shelf now offers -- 检查最新剧集、挑几集下载 and
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

/// A shelf that already holds every episode the catalog has, so an online read
/// has nothing left to offer.
Future<DownloadFakeRuntime> _fullShelf(
  WidgetTester tester,
  String quality,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  final runtime = DownloadFakeRuntime();
  final detail = await runtime.catalog.detail('123');
  await runtime.downloads.enqueue(detail, [0, 1, 2], quality);
  for (final position in [0, 1, 2]) {
    await drain(tester);
    await runtime.complete('${11 + position}_$quality');
  }
  await drain(tester);
  expect(
    runtime.files,
    hasLength(3),
    reason: 'the shelf must really hold all 3',
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

/// The 本地缓存剧集 grid itself -- the surface the card's second gesture is read
/// against, since that is where a cached drama is one card.
///
/// The default surface is a phone, which is also what picks the container the
/// gesture opens: 400 wide hosts the bottom sheet, not the dialog.
///
/// The size goes on the view, not through `setSurfaceSize`: the panel reads
/// `MediaQuery.sizeOf`, and `setSurfaceSize` only tightens the RenderView's
/// constraints -- the view's own metrics, and so the MediaQuery under them,
/// would stay 800x600 and every phone-shaped case here would open a dialog.
Future<void> _openGrid(
  WidgetTester tester,
  DownloadFakeRuntime runtime, {
  Size surface = const Size(400, 780),
}) async {
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: LocalCachePage(runtime: runtime)));
  await tester.pumpAndSettle();
  expect(
    MediaQuery.sizeOf(tester.element(find.byType(LocalCachePage))),
    surface,
    reason: 'the panel shape is read off MediaQuery, so the surface must land there',
  );
}

void main() {
  testWidgets('触屏 checks the online gap and queues none of it', (tester) async {
    final runtime = await _shelf(tester, '1080p');
    addTearDown(() async {
      final closing = runtime.dispose();
      await tester.pump();
      await closing;
    });
    await _openShelf(tester, runtime, tv: false);

    expect(find.byKey(const ValueKey('local-check')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('local-check')));
    await drain(tester);
    await tester.pumpAndSettle();

    // The answer is a number, not a queue. The two episodes the shelf does not
    // hold get named; nothing starts moving until a cell is picked.
    expect(find.textContaining('2 集可下载'), findsOneWidget);
    expect(runtime.calls, ['11_1080p']);
    expect(runtime.downloads.tasks, hasLength(1));
    expect(runtime.downloads.taskFor('13', '1080p'), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('触屏 从缓存剧目挑新集：已缓存那集禁选，只排观众点名的', (tester) async {
    final runtime = await _shelf(tester, '1080p');
    addTearDown(() async {
      final closing = runtime.dispose();
      await tester.pump();
      await closing;
    });
    await _openShelf(tester, runtime, tv: false);

    await tester.tap(find.byKey(const ValueKey('local-download')));
    await drain(tester);

    // The detail page's own panel, opened on the online read instead of the
    // shelf snapshot, and starting at the quality this series was cached at.
    expect(find.text('下载剧集'), findsOneWidget);
    expect(find.text('1080p'), findsWidgets);
    // 第 1 集 is the file already on disk: labelled, and not a target.
    expect(find.text('已下载'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('download-episode-0')),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('全选'));
    await drain(tester);
    expect(find.text('下载 2 集'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-download')));
    await drain(tester);
    await tester.pumpAndSettle();

    expect(
      runtime.downloads.taskFor('12', '1080p')!.phase,
      isNot(DownloadPhase.ready),
    );
    expect(
      runtime.downloads.taskFor('13', '1080p')!.phase,
      DownloadPhase.queued,
    );
    expect(runtime.calls, ['11_1080p', '12_1080p']);
    expect(find.textContaining('已加入下载'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('都缓存好了不弹空窗口，只报这次在线读数', (tester) async {
    final runtime = await _fullShelf(tester, '1080p');
    addTearDown(() async {
      final closing = runtime.dispose();
      await tester.pump();
      await closing;
    });
    await _openShelf(tester, runtime, tv: false);

    await tester.tap(find.byKey(const ValueKey('local-download')));
    await drain(tester);
    await tester.pumpAndSettle();

    expect(find.text('下载剧集'), findsNothing);
    expect(find.textContaining('已是最新：在线 3 集'), findsOneWidget);
    expect(runtime.downloads.tasks, hasLength(3));
    expect(runtime.calls, ['11_1080p', '12_1080p', '13_1080p']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('遥控 挑集下载是可聚焦的目标，开的还是同一个选集窗口', (tester) async {
    final runtime = await _shelf(tester, '720p');
    addTearDown(() async {
      final closing = runtime.dispose();
      await tester.pump();
      await closing;
    });
    await _openShelf(tester, runtime, tv: true);

    // The cell-by-cell walk of the picker belongs to the tv flavor (`HONGGUO_TV`),
    // which is what test/local_download_selection_tv_test.dart runs; here the
    // shelf's own action row is the thing under test: a labelled remote target
    // that reaches the online read.
    expect(_nodeByLabel(tester, '选择下载新集'), isNotNull);
    await _activate(tester, '选择下载新集');
    await drain(tester);

    expect(find.text('下载剧集'), findsOneWidget);
    // The one episode already on disk arrives labelled as such, so neither
    // family is offered a file it can already play.
    expect(find.text('已下载'), findsOneWidget);
    expect(runtime.calls, ['11_720p']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按剧目的面板多一枚挑集下载，开的还是同一个选集窗口', (tester) async {
    final runtime = await _shelf(tester, 'best');
    addTearDown(() async {
      final closing = runtime.dispose();
      await tester.pump();
      await closing;
    });
    await _openGrid(tester, runtime);

    await tester.longPress(find.byKey(const ValueKey('local-drama-123')));
    await drain(tester);
    expect(find.byKey(const ValueKey('local-sheet-download')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('local-sheet-download')));
    await drain(tester);

    expect(find.text('下载剧集'), findsOneWidget);
    expect(find.text('已下载'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('download-episode-1')));
    await drain(tester);
    await tester.tap(find.byKey(const ValueKey('confirm-download')));
    await drain(tester);
    await tester.pumpAndSettle();

    // One named episode went out, not the whole gap the other row would take.
    expect(runtime.calls, ['11_best', '12_best']);
    expect(runtime.downloads.taskFor('13', 'best'), isNull);
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('遥控 reaches 检查最新剧集 and answers 删除本剧缓存 alone', (tester) async {
    final runtime = await _shelf(tester, '720p');
    addTearDown(() async {
      final closing = runtime.dispose();
      await tester.pump();
      await closing;
    });
    await _openShelf(tester, runtime, tv: true);

    expect(_nodeByLabel(tester, '检查最新剧集'), isNotNull);
    await _activate(tester, '检查最新剧集');
    expect(runtime.calls, ['11_720p']);

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

  testWidgets('长按剧目卡片 replaces the whole trip into the shelf', (tester) async {
    final runtime = await _shelf(tester, '1080p');
    addTearDown(() async {
      final closing = runtime.dispose();
      await tester.pump();
      await closing;
    });
    await _openGrid(tester, runtime);

    await tester.longPress(find.byKey(const ValueKey('local-drama-123')));
    await drain(tester);
    // A phone-sized window gets the bottom sheet, and the page names the gesture
    // a finger actually has.
    expect(find.textContaining('长按一部剧'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('检查最新剧集'), findsOneWidget);
    expect(find.text('删除本剧缓存'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('local-sheet-check')));
    await drain(tester);
    await tester.pumpAndSettle();

    // The card's own press did what the shelf page's button did: ask the catalog
    // how long the series is now, report the gap, and leave the queue alone.
    expect(runtime.calls, ['11_1080p']);
    expect(find.textContaining('2 集可下载'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('右键剧目卡片 opens the same panel, in a dialog the window can host', (
    tester,
  ) async {
    final runtime = await _shelf(tester, '1080p');
    addTearDown(() async {
      final closing = runtime.dispose();
      await tester.pump();
      await closing;
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await _openGrid(tester, runtime, surface: const Size(1440, 960));

    // A pointer is told 右键, because holding a card down is not what a hand on a
    // mouse does to reach a menu.
    expect(find.textContaining('右键一部剧'), findsOneWidget);
    expect(find.textContaining('长按一部剧'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('local-drama-123')),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await drain(tester);

    // The same rows and the same keys as the phone's sheet, only in a dialog:
    // one gesture per family, one copy of the delete behind one confirmation.
    expect(find.byType(BottomSheet), findsNothing);
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byKey(const ValueKey('local-sheet-check')),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('local-sheet-check')));
    await drain(tester);
    await tester.pumpAndSettle();

    expect(runtime.calls, ['11_1080p']);
    expect(find.textContaining('2 集可下载'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按剧目卡片 删除本剧缓存 still asks first, then takes the drama', (
    tester,
  ) async {
    final runtime = await _shelf(tester, 'best');
    addTearDown(() async {
      final closing = runtime.dispose();
      await tester.pump();
      await closing;
    });
    await _openGrid(tester, runtime);

    await tester.longPress(find.byKey(const ValueKey('local-drama-123')));
    await drain(tester);
    await tester.tap(find.byKey(const ValueKey('local-sheet-remove')));
    await drain(tester);
    expect(find.text('删除本剧全部缓存？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(runtime.files, hasLength(1));

    await tester.longPress(find.byKey(const ValueKey('local-drama-123')));
    await drain(tester);
    await tester.tap(find.byKey(const ValueKey('local-sheet-remove')));
    await drain(tester);
    await tester.tap(find.text('删除全部'));
    await drain(tester);
    await tester.pumpAndSettle();

    expect(runtime.files, isEmpty);
    expect(runtime.downloads.tasks, isEmpty);
    expect(find.byKey(const ValueKey('local-drama-123')), findsNothing);
    expect(find.textContaining('已删除 1 个文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('遥控 holds a card as a plain press: the shelf opens, no sheet', (
    tester,
  ) async {
    final runtime = await _shelf(tester, '720p');
    addTearDown(() async {
      final closing = runtime.dispose();
      await tester.pump();
      await closing;
    });
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_tv(LocalCachePage(runtime: runtime)));
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const ValueKey('local-drama-tv-123')));
    await drain(tester);
    // A remote has no long press, so holding the card is the activation it already
    // had: the viewer lands inside the drama, where both actions are labelled
    // targets, and the touch family's sheet -- with its delete -- never opens.
    expect(find.byKey(const ValueKey('local-sheet-remove')), findsNothing);
    expect(find.text('删除本剧全部缓存？'), findsNothing);
    expect(_nodeByLabel(tester, '删除本剧缓存'), isNotNull);
    expect(runtime.files, hasLength(1));
    expect(tester.takeException(), isNull);
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
    expect(find.text('检查最新剧集'), findsNothing);
    expect(find.text('删除本剧缓存'), findsNothing);
    expect(find.textContaining('下载更多'), findsNothing);
    expect(find.byTooltip('继续全部下载'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });
}
