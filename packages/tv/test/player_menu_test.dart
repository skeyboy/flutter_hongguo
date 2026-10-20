import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

Future<void> press(WidgetTester t, LogicalKeyboardKey key) async {
  await t.sendKeyEvent(key);
  await t.pumpAndSettle();
}

TvPlayerSurface surface({
  bool busy = false,
  int episode = 0,
  ValueChanged<Duration>? seek,
  ValueChanged<String>? quality,
  VoidCallback? load,
  VoidCallback? toggle,
}) => TvPlayerSurface(
  video: const SizedBox(),
  title: '测试视频',
  playing: false,
  busy: busy,
  progress: '下载中',
  position: const Duration(seconds: 10),
  duration: const Duration(minutes: 1),
  toggle: toggle ?? () {},
  previous: () {},
  next: () {},
  exit: () {},
  retry: () {},
  seek: seek ?? (_) {},
  episodeLabels: const ['第1集', '第2集'],
  episode: episode,
  selectEpisode: (_) {},
  quality: 'best',
  selectQuality: quality ?? (_) {},
  loadQualities: load,
  qualityOptions: const [
    TvQualityOption('best', '自动'),
    TvQualityOption('480p', '480p', detail: '480×854'),
  ],
);
Future<void> mount(WidgetTester t, TvPlayerSurface child) async {
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(body: TvNavigation(child: child)),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> menu(WidgetTester t, String id) async {
  await press(t, LogicalKeyboardKey.arrowUp);
  for (
    var i = 0;
    i < 9 && FocusManager.instance.primaryFocus?.debugLabel != id;
    i++
  ) {
    await press(t, LogicalKeyboardKey.arrowRight);
  }
  expect(FocusManager.instance.primaryFocus?.debugLabel, id);
}

void main() {
  testWidgets('a disabled previous action restores focus to play', (t) async {
    var episode = 1;
    late StateSetter update;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvNavigation(
            child: StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                return surface(episode: episode);
              },
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await menu(t, 'tv-menu-previous');
    update(() => episode = 0);
    await t.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-play');
  });
  testWidgets('visible menu recovers if primary focus is the video root', (
    t,
  ) async {
    final seeks = <Duration>[];
    await mount(t, surface(seek: seeks.add));
    await menu(t, 'tv-menu-progress');
    t
        .widget<Focus>(
          find.byWidgetPredicate(
            (w) => w is Focus && w.focusNode?.debugLabel == 'tv-video',
          ),
        )
        .focusNode!
        .requestFocus();
    await t.pumpAndSettle();
    await press(t, LogicalKeyboardKey.select);
    expect(find.textContaining('预览 0:10'), findsOneWidget);
    await press(t, LogicalKeyboardKey.arrowRight);
    await press(t, LogicalKeyboardKey.select);
    expect(seeks, [const Duration(seconds: 15)]);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-menu-progress');
    expect(find.text('选集'), findsOneWidget);
  });

  testWidgets(
    'quality menu uses supplied data and loads current-episode metadata',
    (t) async {
      final selected = <String>[];
      var loads = 0;
      await mount(t, surface(quality: selected.add, load: () => loads++));
      await menu(t, 'tv-menu-quality');
      await press(t, LogicalKeyboardKey.select);
      expect(loads, 1);
      expect(find.text('480p · 480×854'), findsOneWidget);
      expect(find.text('720p'), findsNothing);
      expect(find.text('1080p'), findsNothing);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-quality-best');
      await press(t, LogicalKeyboardKey.arrowRight);
      await press(t, LogicalKeyboardKey.select);
      expect(selected, ['480p']);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-menu-quality');
    },
  );

  testWidgets('confirm during preparation never hides the loading UI', (
    t,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TvNavigation(child: surface(busy: true))),
      ),
    );
    await t.pump(const Duration(milliseconds: 200));
    await t.sendKeyEvent(LogicalKeyboardKey.select);
    await t.pump(const Duration(milliseconds: 200));
    expect(find.text('下载中'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('选集'), findsNothing);
  });
}
