import 'dart:ui' show CheckedState, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

Widget _box(FocusNode node, {bool autofocus = false, double height = 40}) =>
    Focus(
      focusNode: node,
      autofocus: autofocus,
      child: SizedBox(width: 80, height: height),
    );

Widget _host(FocusNode source, List<Widget> targets) => MaterialApp(
  home: Scaffold(
    body: TvNavigation(
      child: Align(
        alignment: Alignment.topLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [_box(source, autofocus: true), ...targets],
        ),
      ),
    ),
  ),
);

void _disposeAfterTest(WidgetTester tester, List<FocusNode> nodes) {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    for (final node in nodes) {
      node.dispose();
    }
  });
}

Future<void> _expectHiddenSkipped(
  WidgetTester tester,
  Widget Function(FocusNode) hide,
) async {
  final source = FocusNode(debugLabel: 'source');
  final hidden = FocusNode(debugLabel: 'hidden');
  final visible = FocusNode(debugLabel: 'visible');
  _disposeAfterTest(tester, [source, hidden, visible]);
  await tester.pumpWidget(_host(source, [hide(hidden), _box(visible)]));
  await tester.pump();
  expect(source.hasFocus, isTrue);
  expect(hidden.canRequestFocus, isTrue);
  expect(hidden.skipTraversal, isFalse);
  expect(
    hidden.rect.isEmpty,
    isFalse,
    reason: 'hidden target retains geometry',
  );

  expect(
    TvNavigation.focusInDirection(source, TraversalDirection.right),
    isTrue,
  );
  await tester.pump();
  expect(visible.hasFocus, isTrue);
  expect(hidden.hasFocus, isFalse);
}

void main() {
  final hiddenCases = <String, Widget Function(FocusNode)>{
    'offstage': (node) => Offstage(offstage: true, child: _box(node)),
    'maintained hidden': (node) =>
        Visibility.maintain(visible: false, child: _box(node)),
    'zero opacity': (node) => Opacity(opacity: 0, child: _box(node)),
  };
  for (final entry in hiddenCases.entries) {
    testWidgets('${entry.key} target is skipped for a visible one', (
      tester,
    ) async {
      await _expectHiddenSkipped(tester, entry.value);
    });
  }

  testWidgets('zero-size target is skipped for a visible one', (tester) async {
    final source = FocusNode(debugLabel: 'source');
    final empty = FocusNode(debugLabel: 'empty');
    final visible = FocusNode(debugLabel: 'visible');
    _disposeAfterTest(tester, [source, empty, visible]);
    await tester.pumpWidget(
      _host(source, [_box(empty, height: 0), _box(visible)]),
    );
    await tester.pump();
    expect(source.hasFocus, isTrue);
    expect(empty.canRequestFocus, isTrue);
    expect(empty.rect.isEmpty, isTrue);

    expect(
      TvNavigation.focusInDirection(source, TraversalDirection.right),
      isTrue,
    );
    await tester.pump();
    expect(visible.hasFocus, isTrue);
    expect(empty.hasFocus, isFalse);
  });

  testWidgets('an aligned visible target wins over a closer diagonal one', (
    tester,
  ) async {
    final source = FocusNode(debugLabel: 'source');
    final diagonal = FocusNode(debugLabel: 'diagonal');
    final aligned = FocusNode(debugLabel: 'aligned');
    _disposeAfterTest(tester, [source, diagonal, aligned]);
    await tester.pumpWidget(
      _host(source, [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 180, 0, 0),
          child: _box(diagonal),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(220, 10, 0, 0),
          child: _box(aligned),
        ),
      ]),
    );
    await tester.pump();
    expect(source.hasFocus, isTrue);

    expect(
      TvNavigation.focusInDirection(source, TraversalDirection.right),
      isTrue,
    );
    await tester.pump();
    expect(aligned.hasFocus, isTrue);
    expect(diagonal.hasFocus, isFalse);
  });

  testWidgets('checked and selected expose independent semantics flags', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final controls = <({String key, bool? checked, bool selected})>[
      (key: 'checked only', checked: true, selected: false),
      (key: 'selected only', checked: null, selected: true),
      (key: 'unchecked selected', checked: false, selected: true),
      (key: 'checked selected', checked: true, selected: true),
    ];
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TvNavigation(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final control in controls)
                    TvFocusable(
                      key: ValueKey(control.key),
                      label: control.key,
                      checked: control.checked,
                      selected: control.selected,
                      onActivate: () {},
                      child: const SizedBox(width: 80, height: 40),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      for (final control in controls) {
        final node = tester.getSemantics(find.byKey(ValueKey(control.key)));
        final expectedChecked = switch (control.checked) {
          null => CheckedState.none,
          false => CheckedState.isFalse,
          true => CheckedState.isTrue,
        };
        expect(
          node.flagsCollection.isChecked,
          expectedChecked,
          reason: '${control.key}: checked state',
        );
        expect(
          node.flagsCollection.isSelected,
          control.selected ? Tristate.isTrue : Tristate.isFalse,
          reason: '${control.key}: selected state',
        );
      }
    } finally {
      semantics.dispose();
    }
  });
}
