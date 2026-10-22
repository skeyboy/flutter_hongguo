// A nested grid cannot scroll (`NeverScrollableScrollPhysics`), so revealing a
// focused cell only in the *nearest* scrollable left the focus below the fold
// and off the accessibility tree: measured on the emulator, the D-pad walk from
// the second episode row down stopped reporting any focus. Revealing with
// `keepVisibleAtEnd` then failed the other way -- that policy never reduces the
// offset, so walking back up out of the grid lost the focus too (emulator, up
// from the last episode row). The item has to be revealed in every scrollable
// around it, in both directions.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

const _screenBottom = 1080.0;

Widget _grid() => SizedBox(
  width: 410,
  child: GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      mainAxisExtent: 400,
    ),
    itemCount: 6,
    itemBuilder: (context, i) => TvFocusable(
      key: ValueKey('cell-$i'),
      label: 'cell $i',
      onActivate: () {},
      child: const SizedBox(height: 390),
    ),
  ),
);

Widget _host() => MaterialApp(
  home: Scaffold(
    body: TvNavigation(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TvFocusable(
              label: 'header',
              autofocus: true,
              onActivate: () {},
              child: const SizedBox(width: 400, height: 1500),
            ),
            _grid(),
            const SizedBox(height: 400),
          ],
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('walking down reveals each cell', (tester) async {
    tester.view.physicalSize = const Size(1920, _screenBottom);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'header');

    for (final index in <int>[0, 2]) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'cell $index');
      final rect = tester.getRect(find.byKey(ValueKey('cell-$index')));
      expect(
        rect.top,
        greaterThanOrEqualTo(0),
        reason: 'cell $index is above the fold',
      );
      expect(
        rect.bottom,
        lessThanOrEqualTo(_screenBottom),
        reason: 'cell $index is below the fold',
      );
    }
  });

  testWidgets('walking back up reveals the cell above the fold', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, _screenBottom);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    for (var step = 0; step < 3; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'cell 4');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'cell 2');
    final rect = tester.getRect(find.byKey(const ValueKey('cell-2')));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(
      rect.bottom,
      lessThanOrEqualTo(_screenBottom),
      reason: 'the page never scrolled back for the cell above the fold',
    );
  });
}
