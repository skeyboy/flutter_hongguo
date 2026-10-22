// An arrow button that turns inert right when it holds the focus used to drop
// the focus instead of keeping it: `TvFocusable` expressed "inert" as
// `canRequestFocus: false`, and flipping that flag on a node which already has
// the primary focus unfocuses it. The page then has no focus for the remote to
// sit on, every D-pad key is swallowed, and only BACK escapes -- measured on
// the v0.3.2 TV emulator (build/verification/tv/v0.3.2/findings.md, D2).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

/// `first` starts focused; `onActivate: null` makes it inert afterwards.
Widget _host({VoidCallback? onFirstActivate, bool firstAutofocus = true}) =>
    MaterialApp(
      home: Scaffold(
        body: TvNavigation(
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TvFocusable(
                  label: 'first',
                  autofocus: firstAutofocus,
                  onActivate: onFirstActivate,
                  child: const SizedBox(width: 80, height: 40),
                ),
                TvFocusable(
                  label: 'other',
                  autofocus: !firstAutofocus,
                  onActivate: () {},
                  child: const SizedBox(width: 80, height: 40),
                ),
              ],
            ),
          ),
        ),
      ),
    );

void main() {
  String? focus() => FocusManager.instance.primaryFocus?.debugLabel;

  testWidgets('an item keeps the focus it holds when it turns inert', (
    tester,
  ) async {
    var activates = 0;
    await tester.pumpWidget(_host(onFirstActivate: () => activates++));
    await tester.pumpAndSettle();
    expect(focus(), 'first');

    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    expect(focus(), 'first', reason: 'D2: the page lost its focus entirely');
    // Inert means no activation, not no focus.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(activates, 0);
  });

  testWidgets('an inert item is still skipped when walking the row', (
    tester,
  ) async {
    await tester.pumpWidget(_host(firstAutofocus: false));
    await tester.pumpAndSettle();
    expect(focus(), 'other');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(focus(), 'other', reason: 'the D-pad stepped onto an inert item');
  });
}
