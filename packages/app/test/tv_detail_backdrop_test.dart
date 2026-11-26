// Regression cover for the TV detail page's full-bleed artwork backdrop and
// the compact episode-pager footprint on the 1920x1080 remote surface.
//
// The backdrop must be seen but never felt: it owns no focus node, handles no
// key or pointer, and degrades to a dark gradient when the artwork is missing
// or fails. A fake cache manager keeps the image path deterministic — the
// widget-test environment has no network and no loading spinner may appear.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/features/tv/tv_detail_page.dart';
import 'package:hongguo_app/playback/episode_pager.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import 'fakes.dart';

const _backdropKey = ValueKey('tv-detail-backdrop');
const _cover = 'https://cdn.example.test/tv-backdrop.jpg';
final _originalCacheManager = CachedNetworkImageProvider.defaultCacheManager;

/// Fails every lookup immediately: `errorWidget` is the shrink, no spinner and
/// no socket. Counting requests also proves the URL was actually handed over.
class _OfflineImages extends Fake implements BaseCacheManager {
  int requests = 0;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    requests++;
    throw StateError('offline');
  }

  @override
  Future<void> removeFile(String key) async {}
}

Widget _tv(Widget child) => MaterialApp(
  theme: ThemeData(colorScheme: const ColorScheme.dark()),
  builder: (context, inner) =>
      TvEnvironment(enabled: true, child: TvNavigation(child: inner!)),
  home: child,
);

Future<void> _mount(WidgetTester tester, {String cover = ''}) async {
  await tester.binding.setSurfaceSize(const Size(1920, 1080));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _tv(
      TvDetailPage(
        // A changed key forces a fresh State (and a fresh future) when the
        // same test mounts two different covers in one widget tree.
        key: ValueKey(cover.isEmpty ? 'tv-detail-no-cover' : 'tv-detail-cover'),
        runtime: FakeRuntime(),
        initial: Drama(
          id: '123',
          title: '山海之间',
          intro: '一段关于相遇的故事',
          episodeCount: 3,
          cover: cover,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String? _focus() => FocusManager.instance.primaryFocus?.debugLabel;

/// Every focus node the tree actually owns, in build order. The backdrop is
/// the only new subtree, so an unchanged list means it joined no focus scope.
List<String> _focusLabels(WidgetTester tester) => tester
    .widgetList<Focus>(find.byType(Focus))
    .map((f) => f.focusNode?.debugLabel ?? '')
    .where((label) => label.isNotEmpty)
    .toList();

void main() {
  late _OfflineImages cache;
  setUp(() {
    cache = _OfflineImages();
    CachedNetworkImageProvider.defaultCacheManager = cache;
  });
  tearDown(() {
    CachedNetworkImageProvider.defaultCacheManager = _originalCacheManager;
    PaintingBinding.instance.imageCache.clear();
  });

  testWidgets('backdrop paints the drama cover without a spinner', (
    tester,
  ) async {
    await _mount(tester, cover: _cover);

    expect(find.byKey(_backdropKey), findsOneWidget);
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.imageUrl, _cover);
    expect(image.fit, BoxFit.cover);
    expect(cache.requests, 1);
    // A loading indicator is a visual focus thief on the sofa; on failure the
    // layer simply falls through to the dark gradient.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('backdrop is ExcludeFocus + IgnorePointer with no focus child', (
    tester,
  ) async {
    await _mount(tester, cover: _cover);

    final backdrop = tester.widget<ExcludeFocus>(find.byKey(_backdropKey));
    expect(backdrop.excluding, isTrue);
    expect(backdrop.child, isA<IgnorePointer>());
    expect((backdrop.child as IgnorePointer).ignoring, isTrue);
    // ExcludeFocus itself is a Focus gate with descendantsFocusable=false;
    // there is no focusable node inside the backdrop on top of that gate.
    expect(
      tester
          .widgetList<Focus>(
            find.descendant(
              of: find.byKey(_backdropKey),
              matching: find.byType(Focus),
            ),
          )
          .where((node) => node.canRequestFocus),
      isEmpty,
    );
    expect(
      find.descendant(
        of: find.byKey(_backdropKey),
        matching: find.byType(TvFocusable),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('artwork and fallback backdrops expose the same focus nodes', (
    tester,
  ) async {
    await _mount(tester, cover: _cover);
    final withArtwork = _focusLabels(tester);

    await _mount(tester);
    expect(_focusLabels(tester), withArtwork);
    // Missing cover never reaches the network, never crashes, and there is
    // still one dark page behind the content.
    expect(find.byKey(_backdropKey), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(cache.requests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the backdrop does not join the D-pad walk', (tester) async {
    await _mount(tester, cover: _cover);
    expect(_focus(), 'tv-detail-play');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_focus(), 'episode-cell-0');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(_focus(), 'tv-detail-play');
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV pager uses the compact 122/21/16 sizing', (tester) async {
    await _mount(tester);

    final pager = tester.widget<EpisodePager>(find.byType(EpisodePager));
    expect(pager.rows, 4);
    expect(pager.cellExtent, 122);
    expect(pager.numberFontSize, 21);
    expect(pager.pageFontSize, 16);

    final indicator = tester.widget<Text>(
      find.byKey(const ValueKey('episode-pager-page-indicator')),
    );
    expect(indicator.style!.fontSize, 16);
    final number = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(const ValueKey('episode-pager-tv-cell-0')),
            matching: find.byType(Text),
          )
          .first,
    );
    expect(number.style!.fontSize, 21);

    // Old call site measured ~499px of grid height at this width; the compact
    // cell extent yields ~357px (~28% less) without touching mobile defaults.
    final frame = tester.widget<SizedBox>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('episode-pager-pageview')),
            matching: find.byType(SizedBox),
          )
          .first,
    );
    expect(frame.height, lessThan(380));
    expect(frame.height, greaterThan(330));
  });
}
