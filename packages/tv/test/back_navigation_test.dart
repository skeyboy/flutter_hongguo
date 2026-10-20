import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

Future<void> mountPlayer(WidgetTester t, {VoidCallback? onExit}) async {
  final nav = GlobalKey<NavigatorState>();
  await t.pumpWidget(
    MaterialApp(
      navigatorKey: nav,
      home: const Scaffold(body: Text('目录页')),
    ),
  );
  nav.currentState!.push(
    MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('详情页'))),
  );
  await t.pumpAndSettle();
  nav.currentState!.push(
    MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        body: TvNavigation(
          child: TvPlayerSurface(
            video: const SizedBox(),
            title: '播放页',
            playing: true,
            busy: false,
            position: const Duration(seconds: 10),
            duration: const Duration(minutes: 1),
            toggle: () {},
            previous: () {},
            next: () {},
            retry: () {},
            seek: (_) {},
            exit: () async {
              onExit?.call();
              await WidgetsBinding.instance.endOfFrame;
              if (context.mounted) await Navigator.of(context).maybePop();
            },
            episodeLabels: const ['第1集', '第2集'],
            episode: 0,
            selectEpisode: (_) {},
            quality: 'best',
            selectQuality: (_) {},
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('keyboard Back repeats cannot pop player and detail together', (
    t,
  ) async {
    var exits = 0;
    await mountPlayer(t, onExit: () => exits++);
    await t.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await t.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
    await t.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(exits, 1);
    expect(find.text('详情页'), findsOneWidget);
    expect(find.text('目录页'), findsNothing);
    await t.pump(const Duration(seconds: 1));
    expect(find.text('详情页'), findsOneWidget);
  });

  testWidgets(
    'system Back closes one player layer, then detail, then catalog',
    (t) async {
      await mountPlayer(t);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pumpAndSettle();
      expect(find.text('选集'), findsOneWidget);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.byType(TvPlayerSurface), findsOneWidget);
      expect(find.text('选集'), findsNothing);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('详情页'), findsOneWidget);
      expect(find.text('目录页'), findsNothing);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('目录页'), findsOneWidget);
    },
  );

  testWidgets(
    'inner controls Back delegates to its player instead of another navigator',
    (t) async {
      await mountPlayer(t);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pumpAndSettle();
      await t.tap(find.text('选集'));
      await t.pumpAndSettle();
      expect(find.text('选择分集'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('选择分集'), findsNothing);
      expect(find.text('选集'), findsOneWidget);
      expect(find.byType(TvPlayerSurface), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byType(TvPlayerSurface), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('详情页'), findsOneWidget);
    },
  );

  testWidgets('explicit exit closes the route even when controls are visible', (
    t,
  ) async {
    await mountPlayer(t);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.pumpAndSettle();
    for (
      var i = 0;
      i < 8 && FocusManager.instance.primaryFocus?.debugLabel != 'tv-menu-exit';
      i++
    ) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pumpAndSettle();
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-menu-exit');
    await t.sendKeyEvent(LogicalKeyboardKey.select);
    await t.pumpAndSettle();
    expect(find.text('详情页'), findsOneWidget);
  });
}
