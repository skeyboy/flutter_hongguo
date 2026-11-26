import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/widgets/anchored_panel.dart';
import 'package:hongguo_app/widgets/hover_peek.dart';

final _sourceKey = GlobalKey();

void main() {
  testWidgets('disabling HoverPeek during the hold never calls onShow', (
    tester,
  ) async {
    var enabled = true;
    var showCalls = 0;
    late StateSetter updateEnabled;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              updateEnabled = setState;
              return Center(
                child: HoverPeek(
                  enabled: enabled,
                  onShow: (anchor, sourceContext) => showCalls++,
                  onLeave: () {},
                  child: SizedBox(key: _sourceKey, width: 200, height: 100),
                ),
              );
            },
          ),
        ),
      ),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(_sourceKey)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1400));
    expect(showCalls, 0);

    updateEnabled(() => enabled = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(seconds: 1));
    expect(showCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an opaque overlay closes a stale hover preview', (tester) async {
    var occluded = false;
    var leaveCalls = 0;
    late StateSetter updateOccluded;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              updateOccluded = setState;
              return Stack(
                children: [
                  Center(
                    child: HoverPeek(
                      enabled: true,
                      onShow: (_, _) {},
                      onLeave: () => leaveCalls++,
                      child: SizedBox(key: _sourceKey, width: 200, height: 100),
                    ),
                  ),
                  if (occluded)
                    Positioned.fill(
                      child: MouseRegion(
                        opaque: true,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {},
                          child: const ColoredBox(color: Colors.transparent),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(_sourceKey)));
    await tester.pump();

    updateOccluded(() => occluded = true);
    await tester.pumpAndSettle();
    expect(leaveCalls, 1);

    updateOccluded(() => occluded = false);
    await tester.pump();
    await mouse.moveTo(const Offset(10, 10));
    await tester.pump();
    expect(leaveCalls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pointer removal inside the source dismisses its preview', (
    tester,
  ) async {
    var leaveCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: HoverPeek(
              enabled: true,
              onShow: (_, _) {},
              onLeave: () => leaveCalls++,
              child: SizedBox(key: _sourceKey, width: 200, height: 100),
            ),
          ),
        ),
      ),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byKey(_sourceKey)));
    await tester.pump();
    await mouse.removePointer();
    await tester.pump();
    expect(leaveCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('enabled hover calls back once with its mounted source rect', (
    tester,
  ) async {
    final anchors = <Rect>[];
    final sourceContexts = <BuildContext>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: HoverPeek(
              enabled: true,
              onShow: (anchor, sourceContext) {
                anchors.add(anchor);
                sourceContexts.add(sourceContext);
              },
              onLeave: () {},
              child: SizedBox(key: _sourceKey, width: 200, height: 100),
            ),
          ),
        ),
      ),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(_sourceKey)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1499));
    expect(anchors, isEmpty);

    await tester.pump(const Duration(milliseconds: 1));
    expect(anchors, hasLength(1));
    expect(sourceContexts, hasLength(1));
    expect(sourceContexts.single.mounted, isTrue);
    expect(anchors.single, tester.getRect(find.byKey(_sourceKey)));
    expect(globalRectOf(sourceContexts.single), anchors.single);

    await tester.pump(const Duration(seconds: 2));
    expect(anchors, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
