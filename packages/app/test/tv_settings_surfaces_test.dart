// The two surfaces the TV design table still marked 「描边＝否」: the shared
// settings page and 下载管理. Both are phone pages, so the assertions pin the
// `TvEnvironment` branch, not the Android flavor, and every control is driven
// through the real key path (`select` travelling TvNavigation -> TvFocusable),
// because a `tester.tap` would pass even with the ring parked on a target
// nobody can reach.
//
// Phone-only rows the flavor hides with the compile-time `tvBuild` flag (后台与
// 悬浮播放, the phone prefetch budget) still render in these runs; this file only
// claims that whatever is on screen is reachable.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/settings_page.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import 'fakes.dart';

Widget _shell({required bool tv, required Widget home}) => MaterialApp(
  theme: ThemeData(colorScheme: const ColorScheme.dark()),
  builder: (context, inner) => TvEnvironment(
    enabled: tv,
    child: TvNavigation(child: inner!),
  ),
  home: home,
);

Future<void> _tvView(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1920, 1080));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

List<String> _targets(WidgetTester tester) => tester
    .widgetList<TvFocusable>(find.byType(TvFocusable))
    .map((w) => w.label)
    .toList();

String? _labelContaining(WidgetTester tester, String needle) =>
    _targets(tester).where((label) => label.contains(needle)).firstOrNull;

/// `find.byType(DropdownButton)` would never match: the widget the page builds
/// is `DropdownButton<String>`, and `byType` compares exact runtime types.
Finder _byWidgetType<T>(WidgetTester tester) =>
    find.byWidgetPredicate((w) => w is T);

FocusNode? _nodeByLabel(WidgetTester tester, String needle) {
  final candidates = tester.widgetList<TvFocusable>(
    find.byWidgetPredicate((w) => w is TvFocusable && w.label.contains(needle)),
  );
  if (candidates.isEmpty) return null;
  return _nodeOf(tester, candidates.first);
}

/// Both save targets read 「保存」 to the viewer, so the test that means the app
/// bar picks it by key instead of guessing which label match came first.
FocusNode? _nodeByKey(WidgetTester tester, Key key) {
  final found = find.byKey(key);
  if (found.evaluate().isEmpty) return null;
  return _nodeOf(tester, tester.widget<TvFocusable>(found));
}

FocusNode? _nodeOf(WidgetTester tester, Widget target) {
  FocusNode? node;
  void scan(Element element) {
    if (node != null) return;
    final widget = element.widget;
    if (widget is Focus && widget.focusNode != null) node = widget.focusNode;
    element.visitChildren(scan);
  }

  tester.element(find.byWidget(target)).visitChildren(scan);
  return node;
}

String? _focus() => FocusManager.instance.primaryFocus?.debugLabel;

Future<void> _press(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.select);
  await tester.pumpAndSettle();
}

Future<void> _activate(WidgetTester tester, String label) async {
  final node = _nodeByLabel(tester, label);
  expect(
    node,
    isNotNull,
    reason: 'no remote target labelled $label; tree has ${_targets(tester)}',
  );
  node!.requestFocus();
  await tester.pumpAndSettle();
  await _press(tester);
}

Future<void> _activateKey(WidgetTester tester, Key key) async {
  final node = _nodeByKey(tester, key);
  expect(node, isNotNull, reason: 'no remote target keyed $key');
  node!.requestFocus();
  await tester.pumpAndSettle();
  await _press(tester);
}

/// `embedded` keeps the page from popping the root route on save, and keeps the
/// AppBar BackButton - an `IconButton` - out of the tree the assertions scan.
Widget _settings(FakeRuntime runtime) =>
    SettingsPage(runtime: runtime, embedded: true);

String _sortLabel(String value) => switch (value) {
  'online_time' => '最新上架',
  'hot_collect' => '收藏最多',
  _ => '热度优先',
};

void main() {
  group('设置', () {
    testWidgets('every control is a remote target, no touch-only widget left', (
      t,
    ) async {
      await _tvView(t);
      final runtime = FakeRuntime();
      addTearDown(runtime.dispose);
      await t.pumpWidget(_shell(tv: true, home: _settings(runtime)));
      await t.pumpAndSettle();

      expect(_byWidgetType<SwitchListTile>(t), findsNothing);
      expect(_byWidgetType<DropdownButton<String>>(t), findsNothing);
      expect(_byWidgetType<DropdownButton<int>>(t), findsNothing);
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.byType(ListTile), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      // The section headings double as the sidebar jump targets, so the ring can
      // walk the page from either column.
      expect(_targets(t), contains('会话凭据'));
      expect(_labelContaining(t, '提前缓存后续剧集'), isNotNull);
      expect(_labelContaining(t, '全局排序'), isNotNull);
      expect(_labelContaining(t, '默认清晰度'), isNotNull);
      expect(_labelContaining(t, '重建设备身份'), isNotNull);
      expect(_labelContaining(t, '清理未在使用的缓存'), isNotNull);
      expect(_labelContaining(t, '保存设置'), isNotNull);
    });

    testWidgets('the sort spinner advances without a menu route', (t) async {
      await _tvView(t);
      final runtime = FakeRuntime();
      addTearDown(runtime.dispose);
      await t.pumpWidget(_shell(tv: true, home: _settings(runtime)));
      await t.pumpAndSettle();

      final before = _labelContaining(t, '全局排序');
      final stored = runtime.settings.catalogSort;
      // The state lives in the label: the row has to say which value it holds
      // before the confirm key changes it.
      const order = ['online_time', 'hot_score', 'hot_collect'];
      final next = _sortLabel(
        order[(order.indexOf(stored) + 1) % order.length],
      );
      expect(before, contains(_sortLabel(stored)));
      await _activate(t, '全局排序');
      expect(_labelContaining(t, '全局排序'), isNot(before));
      expect(_labelContaining(t, '全局排序'), contains(next));
      // Draft only: nothing is persisted until a save target is used.
      expect(runtime.saves, 0);

      await _activateKey(t, const Key('设置保存'));
      expect(runtime.saves, 1);
      expect(runtime.settings.catalogSort, isNot(stored));
    });

    testWidgets('a switch row toggles the state its label announces', (
      t,
    ) async {
      await _tvView(t);
      final runtime = FakeRuntime();
      addTearDown(runtime.dispose);
      await t.pumpWidget(_shell(tv: true, home: _settings(runtime)));
      await t.pumpAndSettle();

      final before = _labelContaining(t, '提前缓存后续剧集');
      expect(before, anyOf(contains('已开启'), contains('已关闭')));
      await _activate(t, '提前缓存后续剧集');
      final after = _labelContaining(t, '提前缓存后续剧集');
      expect(after, isNot(before));
      expect(after, contains(before!.contains('已开启') ? '已关闭' : '已开启'));
    });

    testWidgets('the number spinner cycles the stored budget', (t) async {
      await _tvView(t);
      final runtime = FakeRuntime();
      addTearDown(runtime.dispose);
      await t.pumpWidget(_shell(tv: true, home: _settings(runtime)));
      await t.pumpAndSettle();

      final stored = runtime.settings.maxCacheFiles;
      final before = _labelContaining(t, '自动缓存剧集数量');
      expect(before, contains('$stored 集'));
      await _activate(t, '自动缓存剧集数量');
      expect(_labelContaining(t, '自动缓存剧集数量'), isNot(before));
      await _activateKey(t, const Key('设置保存'));
      expect(runtime.settings.maxCacheFiles, isNot(stored));
    });

    testWidgets('the advanced fields stay behind their own target', (t) async {
      await _tvView(t);
      final runtime = FakeRuntime();
      addTearDown(runtime.dispose);
      await t.pumpWidget(_shell(tv: true, home: _settings(runtime)));
      await t.pumpAndSettle();

      // `ExpansionTile`'s ink header is a second focus target sharing the ring
      // with its whole subtree, so TV opens the section with its own row.
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.text('内容接口版本号'), findsNothing);
      await _activate(t, '展开 已收起');
      expect(find.text('内容接口版本号'), findsOneWidget);
      expect(_labelContaining(t, '收起 已展开'), isNotNull);
      await _activate(t, '收起 已展开');
      expect(find.text('内容接口版本号'), findsNothing);
    });

    testWidgets('rebuilding the device identity is answered with the D-pad', (
      t,
    ) async {
      await _tvView(t);
      final runtime = FakeRuntime();
      addTearDown(runtime.dispose);
      await t.pumpWidget(_shell(tv: true, home: _settings(runtime)));
      await t.pumpAndSettle();

      await _activate(t, '重建设备身份');
      expect(find.text('重建设备身份？'), findsOneWidget);
      // The ring is parked on 取消 so a stray 确认 cannot destroy the session.
      expect(_focus(), '取消');
      expect(runtime.deviceRotations, 0);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pumpAndSettle();
      expect(_focus(), '重建');
      await _press(t);
      expect(runtime.deviceRotations, 1);
    });

    testWidgets('a sidebar jump scrolls the page and the ring keeps walking', (
      t,
    ) async {
      await _tvView(t);
      final runtime = FakeRuntime();
      addTearDown(runtime.dispose);
      await t.pumpWidget(_shell(tv: true, home: _settings(runtime)));
      await t.pumpAndSettle();

      // The page's own scroll view, ahead of the text fields' inner scrollables
      // in document order.
      final scrollable = t.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(scrollable.position.pixels, 0);
      // The headings are the page's own jump targets, so a viewer can get to the
      // bottom of a long form without holding 下.
      await _activate(t, '会话凭据');
      expect(scrollable.position.pixels, greaterThan(0));

      final reachable = _targets(t);
      // Walking back up from the bottom of the form: every step has to land on
      // a declared target, not on a text field's inner node or on nothing.
      for (var i = 0; i < 3; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await t.pumpAndSettle();
        final landed = _focus();
        expect(landed, isNotNull, reason: 'the ring fell off the page');
        expect(
          reachable,
          contains(landed),
          reason: 'focus left the set of declared remote targets',
        );
      }
    });

    testWidgets('the phone branch keeps Material controls untouched', (
      t,
    ) async {
      final runtime = FakeRuntime();
      addTearDown(runtime.dispose);
      await t.pumpWidget(_shell(tv: false, home: _settings(runtime)));
      await t.pumpAndSettle();

      expect(find.byType(TvFocusable), findsNothing);
      expect(_byWidgetType<SwitchListTile>(t), findsWidgets);
      expect(_byWidgetType<DropdownButton<String>>(t), findsWidgets);
      expect(find.byType(ExpansionTile), findsOneWidget);
      expect(find.text('保存'), findsOneWidget);
    });
  });
}
