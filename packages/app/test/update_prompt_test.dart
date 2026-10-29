import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/platform/macos_window.dart';
import 'package:hongguo_app/update/app_release.dart';
import 'package:hongguo_app/update/update_controller.dart';
import 'package:hongguo_app/update/update_dialog.dart';
import 'package:hongguo_app/update/update_host.dart';
import 'package:hongguo_app/features/settings_page.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_update/hongguo_update.dart';

import 'fakes.dart';

/// A release whose note is long enough that the dialog has to scroll.
String _releaseJson({String tag = 'v9.9.9', List<String> files = const []}) {
  String paragraph(int index) =>
      '第 $index 段更新说明：播放页底部控制条重构，进度条支持拖拽预览。\n'
      '这一段的长度是故意的，正文必须能在弹窗内部滑动查看。\n';
  return jsonEncode({
    'tag_name': tag,
    'name': 'Hongguo $tag',
    'body': List.generate(30, paragraph).join(),
    'prerelease': false,
    'html_url': 'https://github.com/skeyboy/flutter_hongguo/releases/tag/$tag',
    'published_at': '2026-10-29T08:05:54Z',
    'assets': [
      for (final name in files)
        {
          'name': name,
          'size': 36447668,
          'digest': 'sha256:${'ab' * 32}',
          'browser_download_url': 'https://objects.githubusercontent.com/$name',
          'content_type': 'application/octet-stream',
        },
    ],
  });
}

class _FakeFeed implements HttpClientAdapter {
  _FakeFeed(this.body, {this.status = 200});

  final String body;
  final int status;
  final String? etag = 'W/"feed-1"';
  int requests = 0;
  String? lastIfNoneMatch;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    lastIfNoneMatch = options.headers['If-None-Match'] as String?;
    final text = status == 304 ? '' : body;
    return ResponseBody.fromString(
      text,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        // The byte count, not the character count: the note is Chinese, and a
        // short promise here would leave the reader waiting for bytes that never
        // arrive.
        Headers.contentLengthHeader: [utf8.encode(text).length.toString()],
        if (etag != null) 'etag': [etag!],
      },
    );
  }
}

/// Every platform's file at once, so whichever host runs this suite finds an
/// installer and the assertions do not depend on the machine.
const _allFiles = [
  'Hongguo-9.9.9-macos-arm64.dmg',
  'Hongguo-9.9.9-macos-x64.dmg',
  'Hongguo-9.9.9-windows-x64-setup.exe',
  'Hongguo-9.9.9-linux-x64.deb',
  'Hongguo-9.9.9-android-arm64-v8a.apk',
];

({UpdateController controller, _FakeFeed feed}) _wiring(
  FakeRuntime runtime, {
  List<String> files = _allFiles,
  int status = 200,
}) {
  final feed = _FakeFeed(_releaseJson(files: files), status: status);
  final controller = sharedUpdateController(
    runtime,
    transport: Dio()..httpClientAdapter = feed,
  );
  return (controller: controller, feed: feed);
}

void main() {
  Future<void> mountRoot(
    WidgetTester tester,
    UpdateController controller,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [macPlaybackRoutes],
        home: UpdatePromptHost(
          controller: controller,
          child: const Scaffold(body: Center(child: Text('根页'))),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a newer release prompts, scrolls and can be put off', (
    tester,
  ) async {
    final runtime = FakeRuntime();
    final wiring = _wiring(runtime);
    // The startup check is the product path, so the prompt has to be up already
    // once the first frame settled -- nothing in a test may await on the network.
    await mountRoot(tester, wiring.controller);
    expect(wiring.feed.requests, 1);
    expect(find.text('发现新版本 v9.9.9'), findsOneWidget);
    expect(wiring.controller.unseenOffer, isNotNull);
    // The note is far longer than the dialog, so it has to move inside its box.
    // A SelectableText owns a scrollable of its own, so the box is named.
    final notes = find.descendant(
      of: find.byKey(const Key('更新说明')),
      matching: find.byType(SingleChildScrollView),
    );
    expect(notes, findsOneWidget);
    // The selectable note carries a scrollable of its own, so the outer box is
    // the first one under it.
    final scroller = find
        .descendant(of: notes, matching: find.byType(Scrollable))
        .first;
    final before = tester.state<ScrollableState>(scroller).position.pixels;
    await tester.drag(notes, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(scroller).position.pixels,
      greaterThan(before),
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('以后再说')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(wiring.controller.unseenOffer, isNull);
    // Dismissing is not ignoring: the offer stays in the settings row.
    expect(wiring.controller.offer, isNotNull);
    expect(runtime.settings.ignoredUpdateVersion, isEmpty);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('忽略本次更新 records the tag and the next check stays quiet', (
    tester,
  ) async {
    final runtime = FakeRuntime();
    final wiring = _wiring(runtime);
    await mountRoot(tester, wiring.controller);
    await tester.tap(find.byKey(const Key('忽略本次更新')));
    await tester.pumpAndSettle();

    expect(runtime.settings.ignoredUpdateVersion, 'v9.9.9');
    expect(find.byType(AlertDialog), findsNothing);

    unawaited(wiring.controller.checkNow());
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(wiring.controller.message, contains('你已选择忽略'));
  });

  testWidgets('the prompt waits for the route above it', (tester) async {
    final runtime = FakeRuntime()
      ..settings = const AppSettings(updateChecksEnabled: false);
    final wiring = _wiring(runtime);
    final root = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [macPlaybackRoutes],
        home: UpdatePromptHost(
          controller: wiring.controller,
          child: Builder(
            key: root,
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => const Text('播放页'))),
                  child: const Text('进入播放页'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('进入播放页'));
    await tester.pumpAndSettle();
    // The switch off only gates the automatic path, never the manual one.
    expect(wiring.feed.requests, 0);

    unawaited(wiring.controller.checkNow());
    await tester.pumpAndSettle();
    // The player owns the screen: nothing may cover it mid-playback.
    expect(find.byType(AlertDialog), findsNothing);
    expect(wiring.controller.unseenOffer, isNotNull);

    Navigator.of(root.currentContext!).pop();
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 v9.9.9'), findsOneWidget);
  });

  testWidgets('the current version never prompts', (tester) async {
    final runtime = FakeRuntime();
    final feed = _FakeFeed(
      _releaseJson(tag: 'v${AppRelease.version}', files: _allFiles),
    );
    final controller = sharedUpdateController(
      runtime,
      transport: Dio()..httpClientAdapter = feed,
    );
    await mountRoot(tester, controller);
    expect(feed.requests, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.message, '已经是最新版本');
  });

  testWidgets('only a settled check gets to cache the feed', (tester) async {
    final runtime = FakeRuntime();
    final wiring = _wiring(runtime);
    await mountRoot(tester, wiring.controller);
    // An offer the user has not settled must never be answered by a bare 304: it
    // would read as 「没有新版本」 over a release they still owe.
    expect(runtime.settings.updateFeedEtag, isEmpty);
    unawaited(wiring.controller.checkNow());
    await tester.pumpAndSettle();
    expect(wiring.feed.lastIfNoneMatch, isNull);

    // With nothing owed the validator is worth keeping, and the next answer is a
    // free 304 that still says the same thing.
    final quiet = FakeRuntime()
      ..settings = const AppSettings(
        themeMode: 'light',
        updateFeedEtag: 'W/"feed-1"',
      );
    final feed = _FakeFeed('', status: 304);
    final controller = sharedUpdateController(
      quiet,
      transport: Dio()..httpClientAdapter = feed,
    );
    unawaited(controller.checkNow());
    await tester.pumpAndSettle();
    expect(feed.lastIfNoneMatch, 'W/"feed-1"');
    expect(controller.message, '自上次检查以来没有新版本');
    expect(quiet.settings.updateFeedEtag, 'W/"feed-1"');
  });

  testWidgets('a download in flight shows its own bar and its own bytes', (
    tester,
  ) async {
    // The live run can only see the transfer on a real host, so the dialog's
    // download state is pinned here instead: what the controller says while
    // bytes are moving is what the user has to be shown.
    final release = ReleaseInfo.fromJson(
      jsonDecode(_releaseJson(files: _allFiles)) as Map<String, dynamic>,
    );
    final controller = UpdateController(
      dio: Dio(),
      readSettings: () => const AppSettings(),
      writeSettings: (_) async {},
      stageDirectory: () async => '.',
    );
    controller.offer = release;
    controller.downloading = true;
    controller.progress = 0.4;
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UpdateDialog(controller: controller, release: release),
        ),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('正在下载 40%'), findsOneWidget);
    // The number is the file this device would fetch, and the fixture gives
    // every platform the same size so the assertion holds on any host.
    expect(find.text('本机安装包约 34.8 MB'), findsOneWidget);
  });

  testWidgets('settings checks on demand, keeps the switch its own', (
    tester,
  ) async {
    final runtime = FakeRuntime();
    final wiring = _wiring(runtime);
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(runtime: runtime, embedded: true)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('当前版本 v${AppRelease.version}'), findsOneWidget);
    expect(find.text('还没有检查过更新。'), findsOneWidget);

    final savesBefore = runtime.saves;
    await tester.ensureVisible(find.byKey(const Key('检查更新')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('检查更新')));
    await tester.pumpAndSettle();
    expect(wiring.feed.requests, 1);
    expect(find.textContaining('发现新版本 v9.9.9'), findsOneWidget);
    expect(find.textContaining('上次检查 '), findsOneWidget);
    expect(find.byKey(const Key('立即下载并安装')), findsOneWidget);
    // The check records its own timestamp, and only that.
    expect(runtime.saves, savesBefore + 1);

    await tester.ensureVisible(find.byKey(const Key('自动检查更新')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('自动检查更新')));
    await tester.pumpAndSettle();
    expect(runtime.settings.updateChecksEnabled, isFalse);
    expect(runtime.saves, savesBefore + 2);
  });

  testWidgets('a release without this device’s file says so', (tester) async {
    final runtime = FakeRuntime();
    final wiring = _wiring(
      runtime,
      files: const ['Hongguo-9.9.9-other-x64.zip'],
    );
    await mountRoot(tester, wiring.controller);
    final install = find.byKey(const Key('立即更新'));
    expect(install, findsOneWidget);
    expect(tester.widget<FilledButton>(install).onPressed, isNotNull);
    await tester.tap(install);
    await tester.pumpAndSettle();
    expect(wiring.feed.requests, 1);
    expect(wiring.controller.error, contains('没有适配本机的安装包'));
    expect(find.textContaining('没有适配本机的安装包'), findsOneWidget);
  });
}
