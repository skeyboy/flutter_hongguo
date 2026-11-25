// Audit every TV-reachable page at the 1920x1080 remote surface for
// RenderFlex overflows. Catches the real FlutterError the renderer emits, so a
// layout regression fails CI instead of only being visible on the sofa.
//
// Test-host tooling only; never part of the application.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/cache_metadata_page.dart';
import 'package:hongguo_app/features/local_cache_page.dart';
import 'package:hongguo_app/features/my_page.dart';
import 'package:hongguo_app/features/settings_page.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import 'fakes.dart';

/// Run [body] with an onError that records RenderFlex overflows, restoring the
/// previous handler before returning so the framework still sees other errors.
Future<List<String>> _collectOverflow(Future<void> Function() body) async {
  final found = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    final text = details.exceptionAsString();
    if (text.contains('overflowed')) {
      found.add(text.split('\n').where((l) => l.trim().isNotEmpty).first);
    } else {
      previous?.call(details);
    }
  };
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  return found;
}

Widget _shell({required Widget home}) => MaterialApp(
  theme: ThemeData(colorScheme: const ColorScheme.dark()),
  builder: (context, inner) => TvEnvironment(
    enabled: true,
    child: TvNavigation(child: inner!),
  ),
  home: home,
);

Future<void> _surface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1920, 1080));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Future<void> _audit(
  WidgetTester tester,
  String name,
  Widget Function(FakeRuntime runtime) build,
) async {
  final runtime = FakeRuntime();
  addTearDown(() => runtime.dispose());
  final overflows = await _collectOverflow(() async {
    await tester.pumpWidget(_shell(home: build(runtime)));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    // A few frames for lazy sections and post-frame scroll/focus work.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
  if (overflows.isNotEmpty) {
    debugPrint('TV_OVERFLOW_PAGE=$name count=${overflows.length}');
    for (final item in overflows) {
      debugPrint('TV_OVERFLOW_DETAIL=$name :: $item');
    }
  } else {
    debugPrint('TV_OVERFLOW_PAGE=$name clean');
  }
  expect(overflows, isEmpty, reason: '$name overflowed: $overflows');
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // One test per page so a page's controller/timer cannot keep a shared test
  // alive and mask the others. TvDetailPage/TvFeedPage are covered by their own
  // integration tests — media_kit's native player keeps widget-test processes
  // alive, so they are intentionally excluded here.
  final pages = <String, Widget Function(FakeRuntime)>{
    'SettingsPage': (r) => SettingsPage(runtime: r, embedded: true),
    'MyPage': (r) => MyPage(runtime: r),
    'LocalCachePage': (r) => LocalCachePage(runtime: r),
    'CacheMetadataPage': (r) =>
        CacheMetadataPage(runtime: r, videos: const {'v1', 'v2'}),
  };
  for (final entry in pages.entries) {
    testWidgets('${entry.key} renders without RenderFlex overflow', (t) async {
      await _surface(t);
      await _audit(t, entry.key, entry.value);
    });
  }
  // DownloadsPage / DownloadEpisodesPage use DownloadManager's live timer and
  // are covered by downloads_tv_test.dart / download_ui_test.dart; including
  // them here keeps the widget-test isolate from exiting.

  // The real-device regression: system CJK font metrics + a shorter viewport
  // made the settings rail's unbounded Column overflow 88px at the bottom.
  // Ahem (the default test font) hides it, so scale text and shrink height.
  testWidgets('settings rail never overflows under large CJK-like text', (t) async {
    await t.binding.setSurfaceSize(const Size(1280, 600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final runtime = FakeRuntime();
    addTearDown(() => runtime.dispose());
    final view = t.binding.platformDispatcher.views.first;
    final overflows = await _collectOverflow(() async {
      await t.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(view)
              .copyWith(textScaler: TextScaler.linear(1.4)),
          child: _shell(home: SettingsPage(runtime: runtime, embedded: true)),
        ),
      );
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    });
    debugPrint('TV_RAIL_OVERFLOW=${overflows.length}');
    for (final item in overflows) {
      debugPrint('TV_RAIL_DETAIL=$item');
    }
    // The regression was a vertical (bottom) overflow of the rail Column.
    // Horizontal text nudge at an artificial 1.4x scale is out of scope.
    final vertical = overflows.where((o) => o.contains('on the bottom')).toList();
    expect(vertical, isEmpty, reason: 'settings rail overflowed vertically: $vertical');
  });
}
