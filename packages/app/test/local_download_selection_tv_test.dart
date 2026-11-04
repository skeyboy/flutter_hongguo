// The tv flavor is the only place the 下载选集 panel swaps its buttons for the
// focus-ring grid, because `tvBuild` is a build-time flavor flag rather than a
// per-window setting -- `TvEnvironment` alone keeps the touch widgets in the
// tree. So the shelf's 选择下载新集 entry is walked here with
// `--dart-define=HONGGUO_TV=true` (see tool/verify_tv.sh), the same way
// tv_settings_test.dart previews that flavor.
//
// What this pins: an episode the shelf already holds is an inert cell the ring
// still stops on and reports as 已下载, and the episodes it lacks are the ones a
// press adds to the count.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/catalog/local_library.dart';
import 'package:hongguo_app/downloads/download_manager.dart';
import 'package:hongguo_app/features/local_cache_page.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import 'download_fakes.dart';

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

/// The queue only advances when a frame pumps it, and a plain `pumpAndSettle`
/// never converges while the picker is still reading the task record -- so every
/// hop here is a known number of frames.
Future<void> drain(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

/// One cached episode of 山海之间 at 720p, so the shelf has a series id, a quality
/// and one file there is no reason to fetch a second time.
Future<DownloadFakeRuntime> _shelf(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  final runtime = DownloadFakeRuntime();
  final detail = await runtime.catalog.detail('123');
  await runtime.downloads.enqueue(detail, [0], '720p');
  await drain(tester);
  await runtime.complete('11_720p');
  await drain(tester);
  expect(
    runtime.downloads.taskFor('11', '720p')!.phase,
    DownloadPhase.ready,
    reason: 'the shelf setup must reach a real cached file',
  );
  return runtime;
}

void main() {
  testWidgets(
    'tv flavor 的选集格子：已缓存那集惰性，缺的两集才计入',
    (tester) async {
      final runtime = await _shelf(tester);
      addTearDown(() async {
        final closing = runtime.dispose();
        await tester.pump();
        await closing;
      });
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final group = groupLocalEpisodes(await runtime.localEpisodes())
          .firstWhere((g) => g.id == '123');
      await tester.pumpWidget(
        _tv(LocalEpisodesPage(runtime: runtime, initial: group)),
      );
      await tester.pumpAndSettle();

      await _activate(tester, '选择下载新集');
      await drain(tester);
      expect(find.text('下载剧集'), findsOneWidget);
      // The picker starts at the quality the series was cached at, so a top-up
      // does not silently drop the drama into a second track.
      expect(find.text('720p'), findsWidgets);

      await _activate(tester, '第 1 集');
      expect(find.text('下载 0 集'), findsOneWidget);
      expect(find.text('已下载'), findsOneWidget);

      await _activate(tester, '第 2 集');
      expect(find.text('下载 1 集'), findsOneWidget);
      await _activate(tester, '第 3 集');
      expect(find.text('下载 2 集'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    // The focus-ring grid only exists in the tv flavor; the shared app run
    // without `--dart-define=HONGGUO_TV` keeps the touch buttons, which
    // local_cache_management_test.dart already walks. Same guard as
    // tv_settings_test.dart.
    skip: !tvBuild,
  );
}
