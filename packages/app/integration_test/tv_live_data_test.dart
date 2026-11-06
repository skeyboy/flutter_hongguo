/// Real-data Android TV fixtures (verification only; touch no product code).
///
/// Boot the shipping app with no catalog override, so every row, every detail
/// page and every stream is the live upstream's, and walk it with the system
/// D-pad that tool/verify_tv_device.py injects through adb. TV_SCREENSHOT
/// markers make the runner pull one still per state.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/player_page.dart';
import 'package:hongguo_app/main.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' hide VideoTrack;
import 'package:video_player/video_player.dart';

final Map<LogicalKeyboardKey, int> _systemKeys = {
  LogicalKeyboardKey.arrowUp: 19,
  LogicalKeyboardKey.arrowDown: 20,
  LogicalKeyboardKey.arrowLeft: 21,
  LogicalKeyboardKey.arrowRight: 22,
  LogicalKeyboardKey.select: 23,
  LogicalKeyboardKey.escape: 4,
};

Finder get _gridCards => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key as ValueKey<String>).value.startsWith('tv-grid-item-'),
);

String? get _focusLabel => FocusManager.instance.primaryFocus?.debugLabel;

bool get _focusInGrid => _focusLabel?.startsWith('tv-grid-') ?? false;

/// What the screen actually says, so a silent empty grid is distinguishable
/// from a refused identity, a spinner, or a card list whose keys changed.
String _visibleTexts(WidgetTester t) => find
    .byType(Text)
    .evaluate()
    .map((e) => (e.widget as Text).data)
    .whereType<String>()
    .where((s) => s.trim().isNotEmpty)
    .take(8)
    .join('|');

/// Real answers do not arrive on the frame the test binding drives, so every
/// wait here runs against the wall clock.
Future<void> _live(WidgetTester t, int ms) async {
  final until = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(until)) {
    await Future<void>.delayed(const Duration(milliseconds: 32));
    await t.pump();
  }
}

Future<void> _remote(WidgetTester t, LogicalKeyboardKey key) async {
  final code = _systemKeys[key];
  expect(code, isNotNull, reason: '$key has no Android keycode');
  print('TV_SYSTEM_KEY=$code');
  await _live(t, 750);
  print('TV_FOCUS=${FocusManager.instance.primaryFocus}');
}

Future<bool> _until(
  WidgetTester t,
  bool Function() done, {
  int tries = 60,
  String note = '',
}) async {
  for (var i = 0; i < tries && !done(); i++) {
    if (i % 10 == 9) {
      print(
        'TV_LIVE ev=wait n=${i + 1} $note '
        'focus=$_focusLabel texts=${_visibleTexts(t)}',
      );
    }
    await _live(t, 500);
  }
  final hit = done();
  if (!hit && note.isNotEmpty) {
    // The frame the runner pulls here shows what the device really rendered
    // at the moment the assertion is about to give up.
    print('TV_SCREENSHOT=stalled-$note');
  }
  return hit;
}

/// Every press here only lands if the runner is injecting Android system keys;
/// without it these fixtures would wait on a remote nobody is holding.
void _requireSystemDpad() {
  expect(
    const bool.fromEnvironment('HONGGUO_SYSTEM_DPAD'),
    isTrue,
    reason: 'run this through tool/verify_tv_device.py, not bare flutter test',
  );
}

/// Live home grid, then the D-pad route into the first card's detail page.
/// Returns the drama id the card carried.
Future<String> _openLiveDetail(WidgetTester t) async {
  await t.pumpWidget(const ProviderScope(child: HongguoApp()));
  expect(
    await _until(
      t,
      () => _gridCards.evaluate().isNotEmpty,
      tries: 90,
      note: 'home',
    ),
    isTrue,
    reason: 'the live catalog never filled the TV home grid',
  );
  print('TV_LIVE ev=grid count=${_gridCards.evaluate().length}');
  print('TV_SCREENSHOT=live-home');
  // Right leaves the 栏目 rail for the 题材 strip; only down reaches the cards.
  await _remote(t, LogicalKeyboardKey.arrowRight);
  for (var n = 0; n < 6 && !_focusInGrid; n++) {
    await _remote(t, LogicalKeyboardKey.arrowDown);
  }
  expect(
    await _until(t, () => _focusInGrid, tries: 8, note: 'grid-focus'),
    isTrue,
    reason: 'the D-pad never reached a live card ($_focusLabel)',
  );
  final opened = _focusLabel!.substring('tv-grid-'.length);
  await _remote(t, LogicalKeyboardKey.select);
  expect(
    await _until(
      t,
      () => find.text('▶ 开始观看').evaluate().isNotEmpty,
      tries: 90,
      note: 'detail',
    ),
    isTrue,
    reason: 'the live detail of $opened never offered playback',
  );
  print('TV_LIVE ev=detail card=$opened focus=$_focusLabel');
  print('TV_SCREENSHOT=live-detail');
  return opened;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  testWidgets('live upstream: 首页 -> 详情 -> 真实流播放 -> 返回', (WidgetTester t) async {
    _requireSystemDpad();
    final opened = await _openLiveDetail(t);

    await _remote(t, LogicalKeyboardKey.select);
    expect(
      await _until(
        t,
        () => find.byType(PlayerPage).evaluate().isNotEmpty,
        note: 'player-page',
      ),
      isTrue,
      reason: 'starting $opened never reached the player',
    );
    final streaming = await _until(
      t,
      () => find.byType(VideoPlayer).evaluate().isNotEmpty,
      tries: 360,
      note: 'player',
    );
    expect(streaming, isTrue, reason: 'the live stream never attached a view');
    await _live(t, 6000);
    final view = t.widget<VideoPlayer>(find.byType(VideoPlayer).first);
    print(
      'TV_LIVE ev=play playing=${view.controller.value.isPlaying} '
      'position=${view.controller.value.position} '
      'duration=${view.controller.value.duration}',
    );
    expect(
      view.controller.value.position,
      greaterThan(Duration.zero),
      reason: 'the live stream attached but never advanced',
    );
    print('TV_SCREENSHOT=live-player');

    await _remote(t, LogicalKeyboardKey.escape);
    expect(
      await _until(
        t,
        () => find.text('▶ 开始观看').evaluate().isNotEmpty,
        note: 'back-detail',
      ),
      isTrue,
      reason: 'back from playback did not land on the live detail',
    );
    print('TV_SCREENSHOT=live-detail-returned');

    await _remote(t, LogicalKeyboardKey.escape);
    expect(
      await _until(t, () => _focusInGrid, note: 'back-home'),
      isTrue,
      reason: 'back from detail lost the grid focus ($_focusLabel)',
    );
    print('TV_SCREENSHOT=live-home-returned');
  }, timeout: const Timeout(Duration(minutes: 12)));

  testWidgets('live upstream: 下载选集页的遥控器焦点环', (WidgetTester t) async {
    _requireSystemDpad();
    await _openLiveDetail(t);

    // The 下载剧集 handle sits to the right of 开始观看 on the TV detail page.
    for (var n = 0; n < 4 && _focusLabel != 'tv-detail-download'; n++) {
      await _remote(t, LogicalKeyboardKey.arrowRight);
    }
    expect(
      await _until(
        t,
        () => _focusLabel == 'tv-detail-download',
        note: 'dl-handle',
      ),
      isTrue,
      reason: 'the remote never reached 下载剧集 from 开始观看 ($_focusLabel)',
    );
    await _remote(t, LogicalKeyboardKey.select);
    final quality = find.byKey(const ValueKey('download-quality'));
    expect(
      await _until(t, () => quality.evaluate().isNotEmpty, note: 'dl-sheet'),
      isTrue,
      reason: '下载剧集 never opened its sheet',
    );
    print('TV_SCREENSHOT=live-download-sheet');

    // Down into the episode cells, then OK on one of them: the counter is the
    // app's own answer, so a selection that only moves focus proves nothing.
    for (var n = 0; n < 6 && !_focusInGrid; n++) {
      await _remote(t, LogicalKeyboardKey.arrowDown);
    }
    expect(
      await _until(t, () => _focusInGrid, tries: 10, note: 'dl-grid'),
      isTrue,
      reason: 'the remote never reached an episode cell ($_focusLabel)',
    );
    final cell = _focusLabel;
    await _remote(t, LogicalKeyboardKey.select);
    expect(
      await _until(t, () => find.text('1 集').evaluate().isNotEmpty),
      isTrue,
      reason: 'OK on cell $cell did not select an episode',
    );
    print('TV_LIVE ev=dl-selected cell=$cell');
    print('TV_SCREENSHOT=live-download-selected');

    // Back up out of the grid: the header and footer handles have to be part of
    // the same ring, or the remote is trapped in the sheet with a selection made.
    for (var n = 0; n < 5 && _focusInGrid; n++) {
      await _remote(t, LogicalKeyboardKey.arrowUp);
    }
    expect(
      await _until(t, () => !_focusInGrid, tries: 10, note: 'dl-escape-ring'),
      isTrue,
      reason: 'up arrows never left the episode grid ($_focusLabel)',
    );
    print('TV_LIVE ev=dl-header focus=$_focusLabel');

    await _remote(t, LogicalKeyboardKey.escape);
    expect(
      await _until(t, () => quality.evaluate().isEmpty),
      isTrue,
      reason: '返回 never closed the download sheet',
    );
    expect(
      find.text('▶ 开始观看'),
      findsOneWidget,
      reason: 'closing the sheet lost the detail page',
    );
    print('TV_SCREENSHOT=live-download-closed');
  }, timeout: const Timeout(Duration(minutes: 12)));
}
