// The TV half of the version check. The settings surface is driven with real
// key events (a `tap` would pass even with the ring parked on a different
// target), the startup assertion runs only in a `HONGGUO_TV=true` flavor build,
// and the prompt is checked for remote focus/activation and for Back dismissal.

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/bootstrap.dart';
import 'package:hongguo_app/features/settings_page.dart';
import 'package:hongguo_app/features/tv/tv_library_page.dart';
import 'package:hongguo_app/main.dart';
import 'package:hongguo_app/platform/macos_window.dart';
import 'package:hongguo_app/update/app_release.dart';
import 'package:hongguo_app/update/install_strategy.dart';
import 'package:hongguo_app/update/update_controller.dart';
import 'package:hongguo_app/update/update_dialog.dart';
import 'package:hongguo_app/update/update_host.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_tv/hongguo_tv.dart';
import 'package:hongguo_update/hongguo_update.dart';

import 'fakes.dart';
import 'update_fixture.dart';

String _currentJson() => jsonEncode({
  'tag_name': 'v${AppRelease.version}',
  'name': 'Hongguo',
  'body': '',
  'prerelease': false,
  'html_url': '',
  'published_at': '2026-01-01T00:00:00Z',
  'assets': [],
});

class _CountingFeed implements HttpClientAdapter {
  _CountingFeed(this.body);

  final String body;
  int requests = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        Headers.contentLengthHeader: [utf8.encode(body).length.toString()],
      },
    );
  }
}

/// A release note written the way GitHub actually ships it: headings, bullets,
/// inline code and a link. Long enough that its body must scroll on the remote.
String _markdownNotes() => [
  '# Hongguo 9.9.9 发布日志',
  '',
  '## 修改了什么',
  '- 发现页筛选带改为**可收起**的顶部抽屉',
  '- 修复 `SelectableText` 不换行的问题',
  '',
  '## 增加了什么',
  '- 详见 [发布页](https://github.com/o/r/releases/tag/v9.9.9)',
  for (var i = 0; i < 20; i++) '- 第 $i 条更新，正文需要遥控器翻页才能读完',
].join('\n');

class _RecordingInstall extends UpdateController {
  int installs = 0;

  _RecordingInstall()
    : super(
        dio: Dio(),
        readSettings: () => const AppSettings(),
        writeSettings: (_) async {},
        stageDirectory: () async => '.',
      );

  @override
  Future<InstallPlan?> install() async {
    installs++;
    message = '需要先允许本应用安装未知应用：请在设置中打开该权限，回到应用后会自动继续安装。';
    installOwed = true;
    notifyListeners();
    return InstallPlan(message: message!, owesInstall: true);
  }
}

Widget _tvShell({required Widget home}) => MaterialApp(
  navigatorObservers: [macPlaybackRoutes],
  builder: (context, inner) => TvEnvironment(
    enabled: true,
    child: TvNavigation(child: inner!),
  ),
  home: home,
);

Future<void> _tvView(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1920, 1080));
  addTearDown(() => t.binding.setSurfaceSize(null));
}

FocusNode? _nodeByKey(WidgetTester t, Key key) {
  final found = find.byKey(key);
  if (found.evaluate().isEmpty) return null;
  FocusNode? node;
  void scan(Element element) {
    if (node != null) return;
    final widget = element.widget;
    if (widget is Focus && widget.focusNode != null) node = widget.focusNode;
    element.visitChildren(scan);
  }

  t.element(found).visitChildren(scan);
  return node;
}

String? get _focus => FocusManager.instance.primaryFocus?.debugLabel;

void main() {
  testWidgets('TV settings shows 更新 and 检查更新 is a remote target', (
    t,
  ) async {
    await _tvView(t);
    final runtime = FakeRuntime();
    addTearDown(runtime.dispose);
    final feed = _CountingFeed(_currentJson());
    // Pin the session controller so the check is observable without a network.
    sharedUpdateController(runtime, transport: Dio()..httpClientAdapter = feed);
    await t.pumpWidget(
      _tvShell(home: SettingsPage(runtime: runtime, embedded: true)),
    );
    await t.pumpAndSettle();

    // The sidebar repeats the heading as a jump target, so scope the claim to
    // the card that actually holds the update rows.
    final section = find.ancestor(
      of: find.textContaining('当前版本 v${AppRelease.version}'),
      matching: find.byType(Card),
    );
    expect(section, findsOneWidget);
    expect(find.descendant(of: section, matching: find.text('更新')), findsOneWidget);
    final check = find.byKey(const Key('检查更新'));
    expect(check, findsOneWidget);
    expect(t.widget<TvFocusable>(check).label, contains('检查更新'));

    // The confirm key, not a pointer, has to reach it.
    _nodeByKey(t, const Key('检查更新'))!.requestFocus();
    await t.pumpAndSettle();
    expect(_focus, '检查更新');
    await t.sendKeyEvent(LogicalKeyboardKey.select);
    await t.pumpAndSettle();
    expect(feed.requests, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'TV startup mounts the prompt host and runs the throttled check',
    (t) async {
      await _tvView(t);
      final runtime = FakeRuntime();
      addTearDown(runtime.dispose);
      final feed = _CountingFeed(_currentJson());
      sharedUpdateController(runtime, transport: Dio()..httpClientAdapter = feed);
      await t.pumpWidget(
        ProviderScope(
          overrides: [runtimeProvider.overrideWith((_) async => runtime)],
          child: const HongguoApp(),
        ),
      );
      await t.pumpAndSettle();

      expect(find.byType(UpdatePromptHost), findsOneWidget);
      expect(find.byType(TvLibraryPage), findsOneWidget);
      expect(feed.requests, 1);
      expect(t.takeException(), isNull);
    },
    skip: !tvBuild,
  );

  testWidgets('TV prompt autofocuses 立即更新 and Back dismisses it', (
    t,
  ) async {
    await _tvView(t);
    final controller = _RecordingInstall()..offer = fixtureRelease();
    await t.pumpWidget(
      _tvShell(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () =>
                  unawaited(showUpdateDialog(context, controller)),
              child: const Text('打开更新提示'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开更新提示'));
    await t.pumpAndSettle();

    // The phone AlertDialog is untouched; TV gets its own focusable surface.
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(Dialog), findsOneWidget);
    final primary = find.byKey(const Key('立即更新'));
    expect(primary, findsOneWidget);
    expect(t.widget<TvFocusable>(primary).label, '立即更新');
    expect(_focus, '立即更新');
    expect(controller.installs, 0);

    await t.sendKeyEvent(LogicalKeyboardKey.select);
    await t.pumpAndSettle();
    expect(controller.installs, 1);
    // The owed handoff keeps the prompt up, so there is still a route to leave.
    expect(find.byType(Dialog), findsOneWidget);

    // D-pad can walk from the primary action to its neighbour.
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await t.pumpAndSettle();
    expect(_focus, '忽略本次更新');

    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('TV prompt renders markdown and the remote scrolls the body', (
    t,
  ) async {
    await _tvView(t);
    final base = fixtureRelease();
    final controller = _RecordingInstall()
      ..offer = ReleaseInfo(
        tag: base.tag,
        version: base.version,
        title: base.title,
        notes: _markdownNotes(),
        prerelease: base.prerelease,
        htmlUrl: base.htmlUrl,
        publishedAt: base.publishedAt,
        assets: base.assets,
      );
    await t.pumpWidget(
      _tvShell(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () =>
                  unawaited(showUpdateDialog(context, controller)),
              child: const Text('打开更新提示'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开更新提示'));
    await t.pumpAndSettle();

    // Markdown is rendered, not recited: heading text is present but the
    // leading '#', '-' and backticks are not part of the visible body.
    expect(find.textContaining('Hongguo 9.9.9 发布日志'), findsOneWidget);
    expect(find.textContaining('可收起'), findsOneWidget);
    final body = find.byKey(const Key('发布说明正文'));
    expect(body, findsOneWidget);
    final raw = t.widget<SelectableText>(body).textSpan!.toPlainText();
    expect(raw, isNot(contains('# ')));
    expect(raw, isNot(contains('- ')));
    expect(raw, contains('•'));
    expect(raw, contains('发布页'));
    expect(raw, isNot(contains('](')));

    // The note is its own focus target; arrow down scrolls inside it while the
    // action ring keeps its place at the bottom of the dialog.
    final notesScroll = find.descendant(
      of: find.byKey(const Key('更新说明')),
      matching: find.byType(Scrollable),
    );
    final position = t.state<ScrollableState>(notesScroll.first).position;
    expect(position.maxScrollExtent, greaterThan(0));

    _nodeByKey(t, const Key('发布说明焦点'))!.requestFocus();
    await t.pumpAndSettle();
    final before = position.pixels;
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pumpAndSettle();
    expect(position.pixels, greaterThan(before));

    // Buttons are never covered by the body: the primary action is still
    // reachable and Back still leaves the route.
    expect(find.byKey(const Key('立即更新')), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(t.takeException(), isNull);
  });
}
