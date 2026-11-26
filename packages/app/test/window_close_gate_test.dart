import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/platform/window_close_gate.dart';
import 'package:hongguo_core/hongguo_core.dart';

class _FakeActions implements WindowCloseActions {
  int hides = 0, quits = 0, applies = 0;
  WindowCloseBehavior? appliedBehavior;
  bool? appliedRemember;

  @override
  Future<void> hide() async => hides++;
  @override
  Future<void> quit() async => quits++;
  @override
  Future<void> applyPreferences({
    required WindowCloseBehavior closeBehavior,
    required bool rememberWindowState,
  }) async {
    applies++;
    appliedBehavior = closeBehavior;
    appliedRemember = rememberWindowState;
  }
}

class _RecordingPersist {
  AppSettings? saved;
  Future<void> call(AppSettings settings) async => saved = settings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  WindowCloseCoordinator coordinator(
    AppSettings settings, {
    required _FakeActions actions,
    required _RecordingPersist persist,
  }) => WindowCloseCoordinator(
    readSettings: () async => settings,
    persist: persist.call,
    actions: actions,
  );

  testWidgets('ask 时取消确认框：不执行任何动作也不写设置', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final actions = _FakeActions();
    final persist = _RecordingPersist();
    late WindowCloseCoordinator ref;
    ref = coordinator(const AppSettings(), actions: actions, persist: persist);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: WindowCloseGate.navigatorKey,
        home: Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => unawaited(ref.resolve()),
              child: const Text('close'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('close'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('window-close-confirm')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('close-confirm-cancel')));
    await tester.pumpAndSettle();
    expect(actions.hides, 0);
    expect(actions.quits, 0);
    expect(persist.saved, isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('ask 选择退出并记住：写设置、下发偏好并退出', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final actions = _FakeActions();
    final persist = _RecordingPersist();
    late WindowCloseCoordinator ref;
    ref = coordinator(const AppSettings(), actions: actions, persist: persist);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: WindowCloseGate.navigatorKey,
        home: Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => unawaited(ref.resolve()),
              child: const Text('close'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('close-choice-exit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('close-remember-choice')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('close-confirm-ok')));
    await tester.pumpAndSettle();
    expect(persist.saved?.windowCloseBehavior, WindowCloseBehavior.exit);
    expect(actions.applies, 1);
    expect(actions.appliedBehavior, WindowCloseBehavior.exit);
    expect(actions.quits, 1);
    expect(actions.hides, 0);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('ask 选择最小化到托盘且不记住：只隐藏，设置不变', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final actions = _FakeActions();
    final persist = _RecordingPersist();
    late WindowCloseCoordinator ref;
    ref = coordinator(const AppSettings(), actions: actions, persist: persist);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: WindowCloseGate.navigatorKey,
        home: Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => unawaited(ref.resolve()),
              child: const Text('close'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('close-confirm-ok')));
    await tester.pumpAndSettle();
    expect(actions.hides, 1);
    expect(actions.quits, 0);
    expect(actions.applies, 0);
    expect(persist.saved, isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  test('偏好已定时直接执行，不弹确认框', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      for (final entry in [
        (WindowCloseBehavior.tray, 'hide'),
        (WindowCloseBehavior.exit, 'quit'),
      ]) {
        final actions = _FakeActions();
        final persist = _RecordingPersist();
        final ref = coordinator(
          AppSettings(windowCloseBehavior: entry.$1),
          actions: actions,
          persist: persist,
        );
        await ref.resolve();
        expect(
          actions.hides,
          entry.$2 == 'hide' ? 1 : 0,
          reason: '${entry.$1}',
        );
        expect(
          actions.quits,
          entry.$2 == 'quit' ? 1 : 0,
          reason: '${entry.$1}',
        );
        expect(persist.saved, isNull);
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('导航未就绪时退回托盘隐藏，不吞关闭请求', () async {
    // 测试宿主默认平台是 android；关窗流程只在桌面端生效。
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final actions = _FakeActions();
      final persist = _RecordingPersist();
      final ref = coordinator(
        const AppSettings(),
        actions: actions,
        persist: persist,
      );
      await ref.resolve();
      expect(actions.hides, 1);
      expect(actions.quits, 0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('移动端不处理关闭请求', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final actions = _FakeActions();
      final persist = _RecordingPersist();
      final ref = coordinator(
        const AppSettings(),
        actions: actions,
        persist: persist,
      );
      await ref.resolve();
      expect(actions.hides, 0);
      expect(actions.quits, 0);
      expect(persist.saved, isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
