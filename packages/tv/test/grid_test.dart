import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

void main() {
  testWidgets('D-pad builds and focuses rows outside lazy viewport', (t) async {
    final ids = List.generate(60, (i) => '$i');
    await t.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 480,
          height: 300,
          child: TvNavigation(
            child: TvGrid(
              ids: ids,
              itemBuilder: (_, i) => Text('card $i'),
              label: (i) => 'card $i',
              activate: (_) {},
            ),
          ),
        ),
      ),
    );
    await t.pump();
    final first = t.widget<TvFocusable>(
      find.byWidgetPredicate((w) => w is TvFocusable && w.label == 'card 0'),
    );
    first.focusNode!.requestFocus();
    await t.pump();
    for (var i = 0; i < 12; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pumpAndSettle();
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('tv-grid-0'));
    final id = int.parse(
      FocusManager.instance.primaryFocus!.debugLabel!.split('-').last,
    );
    expect(id, greaterThanOrEqualTo(12));
    await t.pumpWidget(const SizedBox());
  });
}
