import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/widgets/anchored_panel.dart';

final _sourceKey = GlobalKey();
const _panelKey = ValueKey('anchored-panel');
const _peekKey = ValueKey('anchored-peek');
const _overlayKey = ValueKey('bounded-overlay');

void _expectInside(Rect rect, Rect bounds) {
  expect(rect.left, greaterThanOrEqualTo(bounds.left));
  expect(rect.top, greaterThanOrEqualTo(bounds.top));
  expect(rect.right, lessThanOrEqualTo(bounds.right));
  expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
}

void main() {
  testWidgets('panel follows its measured anchor after an overlay resize', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: Overlay(
              key: _overlayKey,
              initialEntries: [
                OverlayEntry(
                  builder: (context) => Stack(
                    children: [
                      Positioned(
                        right: 40,
                        top: 80,
                        child: SizedBox(
                          key: _sourceKey,
                          width: 160,
                          height: 48,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final sourceContext = _sourceKey.currentContext!;
    final firstAnchor = globalRectOf(sourceContext)!;
    var providerCalls = 0;
    final entry = showAnchoredPanel(
      context: sourceContext,
      anchor: firstAnchor,
      anchorProvider: () {
        providerCalls++;
        return globalRectOf(_sourceKey.currentContext!)!;
      },
      id: 'resizing-panel',
      alignRight: false,
      width: 380,
      panel: (context, close) =>
          const SizedBox(key: _panelKey, width: 380, height: 120),
    );
    await tester.pump();

    final firstOverlay = tester.getRect(find.byKey(_overlayKey));
    var panelRect = tester.getRect(find.byKey(_panelKey));
    expect(panelRect.left, closeTo(firstOverlay.left + 360, 0.001));
    expect(panelRect.top, closeTo(firstAnchor.bottom + 6, 0.001));
    expect(panelRect.width, 380);
    _expectInside(panelRect, firstOverlay);
    final callsBeforeResize = providerCalls;

    await tester.binding.setSurfaceSize(const Size(320, 600));
    await tester.pump();

    final resizedOverlay = tester.getRect(find.byKey(_overlayKey));
    final resizedAnchor = tester.getRect(find.byKey(_sourceKey));
    panelRect = tester.getRect(find.byKey(_panelKey));
    expect(providerCalls, greaterThan(callsBeforeResize));
    expect(resizedOverlay.width, 272);
    expect(panelRect.left, closeTo(resizedOverlay.left + 12, 0.001));
    expect(panelRect.top, closeTo(resizedAnchor.bottom + 6, 0.001));
    expect(panelRect.width, 248);
    _expectInside(panelRect, resizedOverlay);
    expect(tester.takeException(), isNull);

    entry.remove();
    await tester.pump();
  });

  testWidgets('peek flips and clamps to its live anchor and overlay bounds', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var anchorTop = 440.0;
    late StateSetter updateAnchor;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              updateAnchor = setState;
              return Stack(
                children: [
                  Positioned(
                    left: 40,
                    top: anchorTop,
                    child: SizedBox(key: _sourceKey, width: 160, height: 40),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    var providerCalls = 0;
    final entry = showAnchoredPeek(
      context: _sourceKey.currentContext!,
      anchor: tester.getRect(find.byKey(_sourceKey)),
      anchorProvider: () {
        providerCalls++;
        return globalRectOf(_sourceKey.currentContext!)!;
      },
      width: 300,
      card: (context) => const SizedBox(key: _peekKey, width: 300, height: 120),
    );
    await tester.pump();

    final overlayRect = tester.getRect(find.byType(Overlay));
    var peekRect = tester.getRect(find.byKey(_peekKey));
    var anchorRect = tester.getRect(find.byKey(_sourceKey));
    expect(peekRect.bottom, closeTo(anchorRect.top - 8, 0.001));
    expect(peekRect.top, closeTo(312, 0.001));
    _expectInside(peekRect, overlayRect);
    final callsBeforeMove = providerCalls;

    updateAnchor(() => anchorTop = 80);
    await tester.pump();
    entry.markNeedsBuild();
    await tester.pump();

    peekRect = tester.getRect(find.byKey(_peekKey));
    anchorRect = tester.getRect(find.byKey(_sourceKey));
    expect(providerCalls, greaterThan(callsBeforeMove));
    expect(peekRect.top, closeTo(anchorRect.bottom + 8, 0.001));
    expect(peekRect.bottom, closeTo(248, 0.001));
    _expectInside(peekRect, overlayRect);

    await tester.binding.setSurfaceSize(const Size(220, 600));
    await tester.pump();

    final resizedOverlay = tester.getRect(find.byType(Overlay));
    peekRect = tester.getRect(find.byKey(_peekKey));
    expect(peekRect.left, 12);
    expect(peekRect.width, 196);
    _expectInside(peekRect, resizedOverlay);
    expect(tester.takeException(), isNull);

    entry.remove();
    await tester.pump();
  });
}
