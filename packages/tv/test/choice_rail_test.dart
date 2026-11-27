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

  testWidgets(
    'ArrowUp from a lower cell restores the aligned choice, not the left neighbour',
    (t) async {
      final selected = ValueNotifier('');
      addTearDown(selected.dispose);
      final changes = <String>[];
      const ids = ['', 'love', 'comedy', 'suspense'];
      final cells = {
        for (final id in ids) id: FocusNode(debugLabel: 'cell-$id'),
      };
      addTearDown(() {
        for (final node in cells.values) {
          node.dispose();
        }
      });

      Future<void> mountCells(List<(double center, String id)> positions) async {
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 460,
                  height: 400,
                  child: TvNavigation(
                    child: Stack(
                      children: [
                        Positioned(
                          top: 0,
                          left: 0,
                          child: SizedBox(
                            width: 460,
                            height: 56,
                            child: ValueListenableBuilder<String>(
                              valueListenable: selected,
                              builder: (_, value, _) => TvChoiceRail(
                                choices: const [
                                  TvChoice('', '全部'),
                                  TvChoice('love', '爱情'),
                                  TvChoice('comedy', '喜剧'),
                                  TvChoice('suspense', '悬疑'),
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
                        for (final (center, id) in positions)
                          Positioned(
                            left: center - 80,
                            top: 140,
                            child: SizedBox(
                              width: 160,
                              height: 60,
                              child: Focus(
                                focusNode: cells[id],
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }

      // Measure the rail first, then line each cell up with a chip's centre.
      await mountCells(const []);
      await t.pumpAndSettle();
      final centers = [
        for (final id in ids)
          t.getRect(find.byKey(ValueKey('tv-theme-$id'))).center.dx,
      ];
      await mountCells([
        for (var i = 0; i < ids.length; i++) (centers[i], ids[i]),
      ]);
      await t.pumpAndSettle();

      cells['suspense']!.requestFocus();
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pumpAndSettle();

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv-theme-suspense',
        reason: 'the cell on the right must return to the right-hand chip',
      );
      expect(changes, contains('suspense'));
      expect(changes.last, 'suspense');
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('the rail gives the focused first and last chips room', (
    t,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        home: TvNavigation(
          child: TvChoiceRail(
            choices: const [TvChoice('first', '第一项'), TvChoice('last', '最后一项')],
            selected: '',
            onSelected: (_) {},
          ),
        ),
      ),
    );
    expect(
      t
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .padding,
      equals(const EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
    );
  });
}
