import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

void main() {
  testWidgets(
    'focus selects every horizontal choice and keeps the label visible in both directions',
    (t) async {
      final selected = ValueNotifier('');
      addTearDown(selected.dispose);
      final changes = <String>[];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 420,
                height: 100,
                child: TvNavigation(
                  child: ValueListenableBuilder<String>(
                    valueListenable: selected,
                    builder: (_, value, _) => TvChoiceRail(
                      choices: [
                        const TvChoice('', '全部'),
                        for (var i = 0; i < 24; i++) TvChoice('$i', '题材选项 $i'),
                      ],
                      selected: value,
                      onSelected: (id) {
                        changes.add(id);
                        selected.value = id;
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final first = t.widget<TvFocusable>(
        find.byKey(const ValueKey('tv-theme-')),
      );
      first.focusNode!.requestFocus();
      await t.pumpAndSettle();
      for (var i = 0; i < 20; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await t.pumpAndSettle();
        expect(selected.value, '$i');
        final viewport = t.getRect(
              find.byKey(const ValueKey('tv-theme-scroll')),
            ),
            rect = t.getRect(find.byKey(ValueKey('tv-theme-$i')));
        expect(rect.left, greaterThanOrEqualTo(viewport.left - 1));
        expect(rect.right, lessThanOrEqualTo(viewport.right + 1));
      }
      for (var i = 18; i >= 0; i--) {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await t.pumpAndSettle();
        expect(selected.value, '$i');
      }
      expect(changes.length, 39);
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
    },
  );
}
