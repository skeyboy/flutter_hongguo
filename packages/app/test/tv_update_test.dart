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
}
