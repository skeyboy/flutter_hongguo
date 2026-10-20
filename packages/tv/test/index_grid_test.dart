import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

class GridScene {
  final FocusNode sidebar = FocusNode(), tab = FocusNode();
  final ValueNotifier<List<String>> ids;
  final ValueNotifier<bool> hasMore;
  GridScene(int count, {bool more = false})
    : ids = ValueNotifier(List.generate(count, (i) => '$i')),
      hasMore = ValueNotifier(more);
  Widget build() => MaterialApp(
    home: Scaffold(
      body: TvNavigation(
        child: Row(
          children: [
            SizedBox(
              width: 160,
              child: TvFocusable(
                label: 'sidebar',
                focusNode: sidebar,
                onActivate: () {},
                child: const Text('sidebar'),
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  TvFocusable(
                    label: '顶部tab',
                    focusNode: tab,
                    onActivate: () {},
                    child: const Text('顶部tab'),
                  ),
                  Expanded(
                    child: TvPaneBoundary(
                      exitLeft: sidebar.requestFocus,
                      child: AnimatedBuilder(
                        animation: Listenable.merge([ids, hasMore]),
                        builder: (_, _) => TvGrid(
                          maxExtent: 190,
                          aspectRatio: 1,
                          ids: ids.value,
                          hasMore: hasMore.value,
                          onNearEnd: () {},
                          label: (i) => 'card $i',
                          itemBuilder: (_, i) => Text('card $i'),
                          activate: (_) {},
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  void dispose() {
    sidebar.dispose();
    tab.dispose();
    ids.dispose();
    hasMore.dispose();
  }
}

Future<GridScene> mount(WidgetTester t, int count, {bool more = false}) async {
  final scene = GridScene(count, more: more);
  addTearDown(scene.dispose);
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.binding.setSurfaceSize(const Size(840, 720));
  await t.pumpWidget(scene.build());
  await t.pumpAndSettle();
  t
      .widget<TvFocusable>(find.byKey(const ValueKey('0')))
      .focusNode!
      .requestFocus();
  await t.pumpAndSettle();
  return scene;
}

Future<void> press(WidgetTester t, LogicalKeyboardKey key) async {
  await t.sendKeyEvent(key);
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'indices cross rows in both directions; only index zero exits to sidebar',
    (t) async {
      final scene = await mount(t, 10);
      expect(
        (t.widget<GridView>(find.byType(GridView)).gridDelegate
                as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        4,
      );
      for (var i = 1; i < 10; i++) {
        await press(t, LogicalKeyboardKey.arrowRight);
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-grid-$i');
      }
      for (var i = 0; i < 3; i++) {
        await press(t, LogicalKeyboardKey.arrowRight);
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-grid-9');
        expect(scene.tab.hasFocus, isFalse);
      }
      for (var i = 8; i >= 0; i--) {
        await press(t, LogicalKeyboardKey.arrowLeft);
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-grid-$i');
        expect(scene.sidebar.hasFocus, isFalse);
      }
      await press(t, LogicalKeyboardKey.arrowLeft);
      expect(scene.sidebar.hasFocus, isTrue);
    },
  );

  testWidgets('rapid keys accumulate indices while lazy rows scroll', (
    t,
  ) async {
    final scene = await mount(t, 40);
    for (var i = 0; i < 24; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
    await t.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-grid-24');
    for (var i = 0; i < 24; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    }
    await t.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-grid-0');
    expect(scene.sidebar.hasFocus, isFalse);
    expect(scene.tab.hasFocus, isFalse);
  });

  testWidgets('one pending Right resumes after pagination appends', (t) async {
    final scene = await mount(t, 4, more: true);
    t
        .widget<TvFocusable>(find.byKey(const ValueKey('3')))
        .focusNode!
        .requestFocus();
    await t.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      await press(t, LogicalKeyboardKey.arrowRight);
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-grid-3');
    scene.ids.value = ['0', '1', '2', '3', '4', '5'];
    scene.hasMore.value = false;
    await t.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-grid-4');
  });

  testWidgets('leaving during pagination cannot steal sidebar focus', (
    t,
  ) async {
    final scene = await mount(t, 1, more: true);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await press(t, LogicalKeyboardKey.arrowLeft);
    expect(scene.sidebar.hasFocus, isTrue);
    scene.ids.value = ['0', '1'];
    scene.hasMore.value = false;
    await t.pumpAndSettle();
    expect(scene.sidebar.hasFocus, isTrue);
  });
}
