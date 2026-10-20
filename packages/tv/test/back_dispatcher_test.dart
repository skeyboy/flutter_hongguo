import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

void main() {
  testWidgets('system and keyboard Back pop one level and never exit root', (
    t,
  ) async {
    late GlobalKey<NavigatorState> nav;
    var exits = 0;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') exits++;
        return null;
      },
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    Widget page(String name) => Scaffold(
      body: TvNavigation(child: Focus(autofocus: true, child: Text(name))),
    );
    await t.pumpWidget(
      TvBackDispatcher(
        builder: (_, key) {
          nav = key;
          return MaterialApp(navigatorKey: key, home: page('root'));
        },
      ),
    );
    await t.pumpAndSettle();
    for (final name in ['detail', 'settings', 'nested']) {
      nav.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => page(name)),
      );
      await t.pumpAndSettle();
    }
    final first = t.binding.handlePopRoute();
    final duplicate = t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await Future.wait([first, duplicate]);
    expect(find.text('settings'), findsOneWidget);
    await t.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await t.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
    await t.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.text('detail'), findsOneWidget);
    final last = t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await last;
    expect(find.text('root'), findsOneWidget);
    final rootBack = t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await rootBack;
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.text('root'), findsOneWidget);
    expect(exits, 0);
  });
  testWidgets('focused nested stack pops before outer stack and root stays', (
    t,
  ) async {
    late GlobalKey<NavigatorState> outer;
    final inner = GlobalKey<NavigatorState>();
    Widget page(String title) => Scaffold(
      body: TvNavigation(child: Focus(autofocus: true, child: Text(title))),
    );
    await t.pumpWidget(
      TvBackDispatcher(
        builder: (_, key) {
          outer = key;
          return MaterialApp(navigatorKey: key, home: page('outer root'));
        },
      ),
    );
    await t.pumpAndSettle();
    outer.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Navigator(
          key: inner,
          onGenerateRoute: (_) =>
              MaterialPageRoute<void>(builder: (_) => page('inner root')),
        ),
      ),
    );
    await t.pumpAndSettle();
    inner.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => page('inner detail')),
    );
    await t.pumpAndSettle();
    Future<void> back() async {
      final result = t.binding.handlePopRoute();
      await t.pumpAndSettle();
      await result;
    }

    await back();
    expect(find.text('inner root'), findsOneWidget);
    await back();
    expect(find.text('outer root'), findsOneWidget);
    await back();
    expect(find.text('outer root'), findsOneWidget);
  });
  testWidgets(
    'Back during push animation still removes only the incoming page',
    (t) async {
      late GlobalKey<NavigatorState> nav;
      await t.pumpWidget(
        TvBackDispatcher(
          builder: (_, key) {
            nav = key;
            return MaterialApp(
              navigatorKey: key,
              home: const Scaffold(body: Text('root')),
            );
          },
        ),
      );
      await t.pumpAndSettle();
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('incoming')),
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 30));
      final result = t.binding.handlePopRoute();
      await t.pumpAndSettle();
      await result;
      expect(find.text('root'), findsOneWidget);
      expect(find.text('incoming'), findsNothing);
    },
  );
}
