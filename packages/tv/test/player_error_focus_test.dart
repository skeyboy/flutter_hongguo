/// 播放失败界面的遥控可达性：错误出现的那一帧焦点必须落到重试，
/// 且一次确认只重试一次，选集/返回仍能用方向键走到。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

TvPlayerSurface surface({
  String? error,
  bool busy = false,
  required VoidCallback retry,
  VoidCallback? exit,
  VoidCallback? toggle,
}) => TvPlayerSurface(
  video: const SizedBox.expand(),
  title: '测试视频',
  playing: false,
  busy: busy,
  error: error,
  position: const Duration(seconds: 10),
  duration: const Duration(minutes: 1),
  toggle: toggle ?? () {},
  previous: () {},
  next: () {},
  exit: exit ?? () {},
  retry: retry,
  seek: (_) {},
  episodeLabels: const ['第1集', '第2集'],
  episode: 0,
  selectEpisode: (_) {},
  quality: 'best',
  selectQuality: (_) {},
);

Future<void> mount(WidgetTester t, Widget child) async {
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(body: TvNavigation(child: child)),
    ),
  );
  // 加载态的 CircularProgressIndicator 是无限动画，pumpAndSettle 永不结束。
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
}

Future<void> press(WidgetTester t, LogicalKeyboardKey key) async {
  await t.sendKeyEvent(key);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('error on the busy→idle frame gives focus to retry', (t) async {
    late StateSetter update;
    var busy = true;
    String? error;
    await mount(
      t,
      StatefulBuilder(
        builder: (_, setState) {
          update = setState;
          return surface(error: error, busy: busy, retry: () {});
        },
      ),
    );
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-video');
    update(() {
      busy = false;
      error = '取源超时了';
    });
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-error-retry');
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('error already present at first mount focuses retry', (t) async {
    await mount(t, surface(error: '取源超时了', retry: () {}));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-error-retry');
  });

  testWidgets('select on retry activates retry exactly once', (t) async {
    var retries = 0;
    await mount(t, surface(error: '取源超时了', retry: () => retries++));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-error-retry');
    await press(t, LogicalKeyboardKey.select);
    expect(retries, 1);
    // 确认不该顺带打开控制栏，否则同一次按键会走两条重试路径。
    expect(find.text('测试视频'), findsNothing);
  });

  testWidgets('select while focus is still on root retries directly', (
    t,
  ) async {
    var retries = 0;
    await mount(t, surface(error: '取源超时了', retry: () => retries++));
    t
        .widget<Focus>(
          find.byWidgetPredicate(
            (w) => w is Focus && w.focusNode?.debugLabel == 'tv-video',
          ),
        )
        .focusNode!
        .requestFocus();
    await t.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-video');
    await press(t, LogicalKeyboardKey.select);
    expect(retries, 1);
    // 旧实现会先 show() 打开控制栏，需要按第二次确认才重试。
    expect(find.text('测试视频'), findsNothing);
  });

  testWidgets('D-pad walks from retry to 选集 and 返回', (t) async {
    await mount(t, surface(error: '取源超时了', retry: () {}));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-error-retry');
    await press(t, LogicalKeyboardKey.arrowDown);
    expect(FocusManager.instance.primaryFocus?.debugLabel, '选集');
    await press(t, LogicalKeyboardKey.arrowDown);
    expect(FocusManager.instance.primaryFocus?.debugLabel, '返回');
  });

  testWidgets('happy path still toggles playback and opens controls', (
    t,
  ) async {
    var toggles = 0;
    await mount(t, surface(error: null, retry: () {}, toggle: () => toggles++));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-video');
    await press(t, LogicalKeyboardKey.select);
    expect(toggles, 1);
    expect(find.text('测试视频'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-play');
  });
}
