import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_tv/hongguo_tv.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('physical Back unwinds nested pushes and stays inside TV root', (
    t,
  ) async {
    late GlobalKey<NavigatorState> nav;
    Widget page(String title) => Scaffold(
      body: TvNavigation(child: Focus(autofocus: true, child: Text(title))),
    );
    await t.pumpWidget(
      TvBackDispatcher(
        builder: (_, key) {
          nav = key;
          return MaterialApp(navigatorKey: key, home: page('TV root'));
        },
      ),
    );
    await t.pumpAndSettle();
    Future<void> back() async {
      print('TV_SYSTEM_KEY=4');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await t.pumpAndSettle();
    }

    for (final title in ['detail', 'settings', 'cache']) {
      nav.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => page(title)),
      );
      await t.pumpAndSettle();
    }
    showDialog<void>(
      context: nav.currentContext!,
      builder: (_) => const AlertDialog(title: Text('dialog')),
    );
    await t.pumpAndSettle();
    await back();
    expect(find.text('dialog'), findsNothing);
    expect(find.text('cache'), findsOneWidget);
    for (final title in ['settings', 'detail', 'TV root']) {
      await back();
      expect(find.text(title), findsOneWidget);
    }
    for (var i = 0; i < 3; i++) {
      await back();
      expect(find.text('TV root'), findsOneWidget);
    }
    // Still interactive after repeated root Back, rather than a finished Activity.
    nav.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => page('reopen')),
    );
    await t.pumpAndSettle();
    await back();
    expect(find.text('TV root'), findsOneWidget);
    print(
      'TV_GLOBAL_BACK_PASS dialog_first=true one_press_one_pop=true root_does_not_exit=true reopen_after_root_back=true',
    );
  });
}
