import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/settings_page.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import 'fakes.dart';

const _prefetch = '提前缓存后续剧集';

class _DeferredSaveRuntime extends FakeRuntime {
  final saveStarted = Completer<void>();
  final saveRelease = Completer<void>();

  @override
  Future<void> saveSettings(
    AppSettings value, {
    SessionCredentials? credentials,
  }) async {
    if (!saveStarted.isCompleted) saveStarted.complete();
    await saveRelease.future;
    await super.saveSettings(value, credentials: credentials);
  }
}

Widget _shell({required Widget home, bool tv = false}) => MaterialApp(
  builder: (context, inner) => TvEnvironment(
    enabled: tv,
    child: TvNavigation(child: inner!),
  ),
  home: home,
);

Future<void> _mount(WidgetTester tester, FakeRuntime runtime) async {
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _shell(home: SettingsPage(runtime: runtime, closeOnSave: false)),
  );
  await tester.pumpAndSettle();
}

Future<void> _expectDiscardPrompt(WidgetTester tester) async {
  await tester.pump();
  expect(find.text('有未保存的更改'), findsOneWidget);
  expect(find.text('继续编辑'), findsOneWidget);
  expect(find.text('放弃并返回'), findsOneWidget);
  expect(find.byType(SettingsPage), findsOneWidget);
}

Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'system Back confirms ordinary switch, number and dropdown edits',
    (tester) async {
      final runtime = FakeRuntime();
      addTearDown(runtime.dispose);
      await _mount(tester, runtime);

      final prefetch = find.widgetWithText(SwitchListTile, _prefetch);
      await tester.tap(prefetch);
      await tester.pump();
      final episodes = find.byType(DropdownButton<int>).first;
      await tester.ensureVisible(episodes);
      await tester.pumpAndSettle();
      await tester.tap(episodes);
      await tester.pumpAndSettle();
      await tester.tap(find.text('5 集').last);
      await tester.pumpAndSettle();
      final sort = find.byKey(const ValueKey('catalog-sort-setting'));
      await tester.ensureVisible(sort);
      await tester.pumpAndSettle();
      await tester.tap(sort);
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏最多').last);
      await tester.pumpAndSettle();
      expect(runtime.saves, 0);

      await tester.binding.handlePopRoute();
      await _expectDiscardPrompt(tester);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);

      await tester.binding.handlePopRoute();
      await _expectDiscardPrompt(tester);
      await tester.tap(find.text('放弃并返回'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsNothing);
      expect(runtime.settings.prefetchEnabled, isTrue);
      expect(runtime.settings.prefetchEpisodes, 3);
      expect(runtime.settings.catalogSort, 'hot_score');
      expect(runtime.saves, 0);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'ordinary text edits are guarded by AppBar Back and system Back',
    (tester) async {
      final runtime = FakeRuntime();
      addTearDown(runtime.dispose);
      await _mount(tester, runtime);
      await tester.ensureVisible(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      final host = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '内容接口域名',
      );
      await tester.enterText(host, 'api.example.test');
      await tester.pump();

      await _back(tester);
      await _expectDiscardPrompt(tester);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);

      await tester.binding.handlePopRoute();
      await _expectDiscardPrompt(tester);
      await tester.tap(find.text('放弃并返回'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsNothing);
      expect(runtime.settings.apiHost, isNot('api.example.test'));
      expect(runtime.saves, 0);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('full save clears dirty credentials and shows a fixed SnackBar', (
    tester,
  ) async {
    bool? routeResult;
    final runtime = FakeRuntime();
    addTearDown(runtime.dispose);
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _shell(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                routeResult = await Navigator.of(context).push<bool>(
                  MaterialPageRoute<bool>(
                    builder: (_) =>
                        SettingsPage(runtime: runtime, closeOnSave: false),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    await tester.tap(find.widgetWithText(SwitchListTile, _prefetch));
    await tester.pump();
    await tester.ensureVisible(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ExpansionTile, '高级接口与签名参数'));
    await tester.pumpAndSettle();
    final cookie = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Cookie',
    );
    await tester.ensureVisible(cookie);
    await tester.pumpAndSettle();
    await tester.enterText(cookie, 'test-cookie-only');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(runtime.saves, 1);
    expect(runtime.settings.prefetchEnabled, isFalse);
    expect(runtime.credentials.cookie, 'test-cookie-only');
    expect(find.text('设置已保存'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(SnackBar)).dy,
      greaterThan(tester.getBottomLeft(find.byType(AppBar)).dy),
    );

    await _back(tester);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SettingsPage), findsNothing);
    expect(routeResult, isTrue);
    expect(runtime.settings.prefetchEnabled, isFalse);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await _back(tester);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SettingsPage), findsNothing);
    expect(routeResult, isFalse);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Back waits for an in-flight save, then closeOnSave closes', (
    tester,
  ) async {
    bool? routeResult;
    final runtime = _DeferredSaveRuntime();
    addTearDown(runtime.dispose);
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _shell(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                routeResult = await Navigator.of(context).push<bool>(
                  MaterialPageRoute<bool>(
                    builder: (_) =>
                        SettingsPage(runtime: runtime, closeOnSave: true),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, _prefetch));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(runtime.saveStarted.isCompleted, isTrue);
    expect(runtime.saveRelease.isCompleted, isFalse);
    expect(find.text('正在保存…'), findsOneWidget);
    expect(
      tester.widget<BackButton>(find.byType(BackButton)).onPressed,
      isNull,
    );

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('有未保存的更改'), findsNothing);
    expect(find.text('放弃并返回'), findsNothing);
    expect(routeResult, isNull);

    runtime.saveRelease.complete();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
    expect(routeResult, isTrue);
    expect(runtime.saves, 1);
    expect(runtime.settings.prefetchEnabled, isFalse);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('autosaved actions preserve unrelated dirty form data', (
    tester,
  ) async {
    final runtime = FakeRuntime();
    addTearDown(runtime.dispose);
    await _mount(tester, runtime);
    final prefetch = find.widgetWithText(SwitchListTile, _prefetch);
    await tester.tap(prefetch);
    await tester.pump();

    final theme = find.byWidgetPredicate(
      (widget) => widget is DropdownButton<String> && widget.value == 'light',
    );
    await tester.ensureVisible(theme);
    await tester.pumpAndSettle();
    await tester.tap(theme);
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色').last);
    await tester.pumpAndSettle();
    expect(runtime.settings.themeMode, 'dark');
    expect(runtime.settings.prefetchEnabled, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('有未保存的更改'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(runtime.settings.prefetchEnabled, isTrue);

    final update = find.byKey(const Key('自动检查更新'));
    await tester.ensureVisible(update);
    await tester.pumpAndSettle();
    await tester.tap(update);
    await tester.pumpAndSettle();
    expect(runtime.settings.updateChecksEnabled, isFalse);
    expect(runtime.settings.prefetchEnabled, isTrue);

    await tester.binding.handlePopRoute();
    await _expectDiscardPrompt(tester);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(runtime.settings.prefetchEnabled, isTrue);

    await _back(tester);
    await _expectDiscardPrompt(tester);
    await tester.tap(find.text('放弃并返回'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing);
    expect(runtime.settings.themeMode, 'dark');
    expect(runtime.settings.updateChecksEnabled, isFalse);
    expect(runtime.settings.prefetchEnabled, isTrue);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('TV switch rows expose checked, not selected, semantics', (
    tester,
  ) async {
    const customSource = CustomSourceConfig(
      uuid: '123e4567-e89b-42d3-a456-426614174000',
      name: '测试源',
      url: 'https://api.example.test/api.php/provide/vod/',
      enabled: true,
    );
    final runtime = FakeRuntime()
      ..settings = AppSettings(
        sources: SourceSettings().upsertCustom(customSource),
      );
    addTearDown(runtime.dispose);
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _shell(tv: true, home: SettingsPage(runtime: runtime, embedded: true)),
    );
    await tester.pumpAndSettle();

    final rows = tester.widgetList<TvFocusable>(find.byType(TvFocusable));
    final switches = rows.where((row) => row.checked != null);
    expect(switches, isNotEmpty);
    for (final row in switches) {
      expect(row.selected, isFalse);
    }
    final prefetchRow = switches.singleWhere(
      (row) => row.label.startsWith(_prefetch),
    );
    expect(prefetchRow.checked, isTrue);
    final semantics = tester.getSemantics(
      find.byWidgetPredicate(
        (widget) =>
            widget is TvFocusable &&
            widget.label.startsWith(_prefetch) &&
            widget.checked != null,
      ),
    );
    expect(semantics.getSemanticsData().flagsCollection.isChecked, isNotNull);
    expect(
      semantics.getSemanticsData().flagsCollection.isSelected,
      Tristate.isFalse,
    );
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
