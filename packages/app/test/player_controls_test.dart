/// The control bar and the picture's own gesture layer, mounted against a fake
/// player. Before this seam existed the bar took a `media_kit` player, which
/// binds libmpv on construction, so none of it could be tested here.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/playback/compact_controls.dart';
import 'package:hongguo_app/playback/player_center_overlay.dart';
import 'package:hongguo_app/playback/player_progress_bar.dart';
import 'package:hongguo_app/playback/playback_transport.dart';
import 'package:hongguo_app/playback/transport_player.dart';

class _FakePlayer implements TransportPlayer {
  _FakePlayer({this._duration = const Duration(seconds: 64)});

  final _positionEvents = StreamController<Duration>.broadcast();
  final _durationEvents = StreamController<Duration>.broadcast();
  final _bufferEvents = StreamController<Duration>.broadcast();
  final _bufferingEvents = StreamController<bool>.broadcast();
  final _volumeEvents = StreamController<double>.broadcast();
  final _rateEvents = StreamController<double>.broadcast();

  Duration _position = Duration.zero;
  Duration _duration;
  Duration _buffer = Duration.zero;
  double _volume = 100;
  double _rate = 1.0;
  bool _buffering = false;

  final seeks = <Duration>[];
  final volumes = <double>[];
  final rates = <double>[];
  int toggles = 0;

  void move({Duration? position, Duration? duration, Duration? buffer}) {
    if (position != null) {
      _position = position;
      _positionEvents.add(position);
    }
    if (duration != null) {
      _duration = duration;
      _durationEvents.add(duration);
    }
    if (buffer != null) {
      _buffer = buffer;
      _bufferEvents.add(buffer);
    }
  }

  void stall(bool value) {
    _buffering = value;
    _bufferingEvents.add(value);
  }

  @override
  Stream<Duration> get position => _positionEvents.stream;
  @override
  Stream<Duration> get duration => _durationEvents.stream;
  @override
  Stream<Duration> get buffer => _bufferEvents.stream;
  @override
  Stream<bool> get buffering => _bufferingEvents.stream;
  @override
  Stream<double> get volume => _volumeEvents.stream;
  @override
  Stream<double> get rate => _rateEvents.stream;

  @override
  Duration get positionValue => _position;
  @override
  Duration get durationValue => _duration;
  @override
  Duration get bufferValue => _buffer;
  @override
  bool get bufferingValue => _buffering;
  @override
  double get volumeValue => _volume;
  @override
  double get rateValue => _rate;

  @override
  Future<void> seek(Duration target) async {
    seeks.add(target);
    move(position: target);
  }

  @override
  Future<void> setVolume(double percent) async {
    volumes.add(percent);
    _volume = percent;
    _volumeEvents.add(percent);
  }

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
    _rate = rate;
    _rateEvents.add(rate);
  }

  @override
  Future<void> playOrPause() async => toggles++;
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// The bar on its own, at a size that fits whichever surface is under test.
Future<void> _mountBar(
  WidgetTester tester,
  _FakePlayer player,
  ControlSurface surface, {
  List<String> qualities = const ['best', '720p', '1080p'],
  String quality = 'best',
  ValueChanged<String>? onQuality,
  ValueChanged<int>? onSeekBy,
  bool buffering = false,
}) async {
  await tester.binding.setSurfaceSize(
    surface.touch && surface.portrait
        ? const Size(390, 260)
        : const Size(1100, 260),
  );
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _host(
      Align(
        alignment: Alignment.bottomCenter,
        child: PlaybackTransport(
          player: player,
          surface: surface,
          playing: true,
          fullscreen: false,
          busy: false,
          buffering: buffering,
          episode: 3,
          onMenuChanged: (_) {},
          episodes: () {},
          previous: () {},
          next: () {},
          fullscreenToggle: () {},
          canPrevious: true,
          canNext: true,
          qualities: qualities,
          quality: quality,
          onQuality: onQuality ?? (_) {},
          onSeekBy: onSeekBy,
          floating: () {},
          cast: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

PlayerProgressPainter _painter(WidgetTester tester) {
  final paint = tester
      .widgetList<CustomPaint>(
        find.descendant(
          of: find.byKey(const ValueKey('player-progress')),
          matching: find.byType(CustomPaint),
        ),
      )
      .firstWhere((entry) => entry.painter is PlayerProgressPainter);
  return paint.painter as PlayerProgressPainter;
}

Future<void> _tapPicture(WidgetTester tester, double fraction) async {
  final rect = tester.getRect(
    find.byKey(const ValueKey('compact-player-picture')),
  );
  await tester.tapAt(rect.topLeft + Offset(rect.width * fraction, 60));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

void main() {
  test('formatTransportTime switches to hours past one hour', () {
    expect(formatTransportTime(const Duration(seconds: 64)), '01:04');
    expect(formatTransportTime(const Duration(seconds: 3665)), '1:01:05');
    expect(formatTransportTime(Duration.zero), '00:00');
  });

  group('clusters per surface', () {
    testWidgets('desktopWide carries the full left cluster and the settings', (
      tester,
    ) async {
      await _mountBar(tester, _FakePlayer(), ControlSurface.desktopWide);
      for (final key in [
        'transport-play',
        'transport-seek-back',
        'transport-seek-forward',
        'transport-previous',
        'transport-next',
        'transport-volume',
        'transport-volume-slider',
        'transport-quality',
        'transport-speed',
        'cast-device',
        'enter-pip',
        'transport-fullscreen',
        'toggle-episodes',
        'player-progress',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(find.text('00:00 / 01:04'), findsOneWidget);
      expect(find.text('第 3 集 · 选集'), findsOneWidget);
    });

    testWidgets('desktopNarrow folds the slider away and drops the extras', (
      tester,
    ) async {
      await _mountBar(tester, _FakePlayer(), ControlSurface.desktopNarrow);
      expect(find.byKey(const ValueKey('transport-volume')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('transport-volume-slider')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('transport-previous')), findsNothing);
      expect(find.byKey(const ValueKey('transport-quality')), findsNothing);
      expect(find.byKey(const ValueKey('enter-pip')), findsNothing);
    });

    testWidgets('mobilePortrait is one row: play, progress, speed, episodes', (
      tester,
    ) async {
      await _mountBar(tester, _FakePlayer(), ControlSurface.mobilePortrait);
      expect(find.byKey(const ValueKey('transport-play')), findsOneWidget);
      expect(find.byKey(const ValueKey('transport-speed')), findsOneWidget);
      expect(find.byKey(const ValueKey('toggle-episodes')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('transport-fullscreen')),
        findsOneWidget,
      );
      for (final key in [
        'transport-seek-back',
        'transport-seek-forward',
        'transport-volume',
        'transport-quality',
        'cast-device',
        'enter-pip',
        'transport-previous',
      ]) {
        expect(
          find.byKey(ValueKey(key)),
          findsNothing,
          reason: '$key has no place in portrait',
        );
      }
    });

    testWidgets('mobileLandscape keeps the settings but never the volume', (
      tester,
    ) async {
      await _mountBar(tester, _FakePlayer(), ControlSurface.mobileLandscape);
      expect(find.byKey(const ValueKey('transport-seek-back')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('transport-seek-forward')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('transport-quality')), findsOneWidget);
      expect(find.byKey(const ValueKey('cast-device')), findsOneWidget);
      expect(find.byKey(const ValueKey('transport-volume')), findsNothing);
      expect(find.byKey(const ValueKey('enter-pip')), findsNothing);
    });
  });

  group('progress bar', () {
    testWidgets('the buffer layer appears only between zero and everything', (
      tester,
    ) async {
      final player = _FakePlayer();
      await _mountBar(tester, player, ControlSurface.desktopWide);
      expect(_painter(tester).bufferVisible, isFalse);
      player.move(buffer: const Duration(seconds: 20));
      await tester.pumpAndSettle();
      expect(_painter(tester).buffered, closeTo(.3125, .001));
      expect(_painter(tester).bufferVisible, isTrue);
      player.move(buffer: const Duration(seconds: 64));
      await tester.pumpAndSettle();
      expect(_painter(tester).bufferVisible, isFalse, reason: 'fully buffered');
    });

    testWidgets('a pointer over the bar reads out the time it would land on', (
      tester,
    ) async {
      await _mountBar(tester, _FakePlayer(), ControlSurface.desktopWide);
      final rect = tester.getRect(
        find.byKey(const ValueKey('player-progress')),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(
        location: rect.topLeft + Offset(rect.width * .5, 0),
      );
      await tester.pump();
      await mouse.moveTo(rect.topLeft + Offset(rect.width * .5, 6));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('progress-bubble-time')),
        findsOneWidget,
      );
      expect(find.text('00:32'), findsOneWidget);
      expect(_painter(tester).engaged, isTrue);
    });

    testWidgets('a tap on the bar seeks to the spot, not to the playhead', (
      tester,
    ) async {
      final player = _FakePlayer();
      await _mountBar(tester, player, ControlSurface.desktopWide);
      final rect = tester.getRect(
        find.byKey(const ValueKey('player-progress')),
      );
      await tester.tapAt(
        rect.topLeft + Offset(rect.width * .25, rect.height / 2),
      );
      await tester.pumpAndSettle();
      expect(player.seeks, [const Duration(seconds: 16)]);
    });

    testWidgets('a drag previews under the finger and commits on release', (
      tester,
    ) async {
      final player = _FakePlayer();
      await _mountBar(tester, player, ControlSurface.desktopWide);
      final rect = tester.getRect(
        find.byKey(const ValueKey('player-progress')),
      );
      final finger = await tester.startGesture(
        rect.topLeft + Offset(rect.width * .2, rect.height / 2),
      );
      await tester.pump();
      await finger.moveTo(
        rect.topLeft + Offset(rect.width * .75, rect.height / 2),
      );
      await tester.pump();
      expect(_painter(tester).played, closeTo(.75, .01));
      expect(player.seeks, isEmpty, reason: 'no seek while the drag runs');
      await finger.up();
      await tester.pumpAndSettle();
      expect(player.seeks.last, const Duration(seconds: 48));
    });

    testWidgets('an unknown length stops the bar answering pointers', (
      tester,
    ) async {
      final player = _FakePlayer(duration: Duration.zero);
      await _mountBar(tester, player, ControlSurface.desktopWide);
      final rect = tester.getRect(
        find.byKey(const ValueKey('player-progress')),
      );
      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();
      expect(player.seeks, isEmpty);
    });
  });

  group('settings in the bar', () {
    testWidgets('the volume icon mutes and returns to the level before', (
      tester,
    ) async {
      final player = _FakePlayer();
      await _mountBar(tester, player, ControlSurface.desktopNarrow);
      await tester.tap(find.byKey(const ValueKey('transport-volume')));
      await tester.pumpAndSettle();
      expect(player.volumes, [0]);
      await tester.tap(find.byKey(const ValueKey('transport-volume')));
      await tester.pumpAndSettle();
      expect(player.volumes, [0, 100]);
    });

    testWidgets('the speed menu ticks the active rate', (tester) async {
      final player = _FakePlayer();
      await _mountBar(tester, player, ControlSurface.desktopWide);
      await tester.tap(find.byKey(const ValueKey('transport-speed')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check), findsOneWidget);
      await tester.tap(find.text('1.5×'));
      await tester.pumpAndSettle();
      expect(player.rates, [1.5]);
      expect(find.text('1.5×'), findsOneWidget);
    });

    testWidgets('清晰度 shows one locked level and hides none', (tester) async {
      await _mountBar(
        tester,
        _FakePlayer(),
        ControlSurface.desktopWide,
        qualities: ['best'],
      );
      final locked = find.byKey(const ValueKey('transport-quality'));
      expect(locked, findsOneWidget);
      expect(tester.widget<PopupMenuButton<String>>(locked).enabled, isFalse);
      await _mountBar(
        tester,
        _FakePlayer(),
        ControlSurface.desktopWide,
        qualities: [],
      );
      expect(find.byKey(const ValueKey('transport-quality')), findsNothing);
    });

    testWidgets('the bar asks the page for a ±10s move', (tester) async {
      final moves = <int>[];
      await _mountBar(
        tester,
        _FakePlayer(),
        ControlSurface.desktopWide,
        onSeekBy: moves.add,
      );
      await tester.tap(find.byKey(const ValueKey('transport-seek-back')));
      await tester.tap(find.byKey(const ValueKey('transport-seek-forward')));
      await tester.pumpAndSettle();
      expect(moves, [-10, 10]);
    });
  });

  group('the picture answers for itself', () {
    testWidgets(
      'a pause puts a play button in the centre, playing removes it',
      (tester) async {
        var resumed = 0;
        Widget overlay(bool playing) => _host(
          Stack(
            children: [
              PlayerCenterOverlay(
                playing: playing,
                busy: false,
                touch: false,
                onPlay: () => resumed++,
              ),
            ],
          ),
        );
        await tester.pumpWidget(overlay(true));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('player-center-play')), findsNothing);
        await tester.pumpWidget(overlay(false));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('player-center-play')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('player-center-play')));
        await tester.pumpAndSettle();
        expect(resumed, 1);
      },
    );

    testWidgets('a seek flash names the half and outlives nothing', (
      tester,
    ) async {
      final key = GlobalKey<PlayerCenterOverlayState>();
      await tester.pumpWidget(
        _host(
          PlayerCenterOverlay(
            key: key,
            playing: true,
            busy: false,
            touch: true,
            buffering: true,
          ),
        ),
      );
      // A stall spins a CircularProgressIndicator forever, so this test pumps a
      // count of frames rather than settling.
      await tester.pump();
      expect(find.byKey(const ValueKey('player-buffering')), findsOneWidget);
      key.currentState!.flashSeek(-10);
      await tester.pump();
      expect(find.text('-10s'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1000));
      expect(find.text('-10s'), findsNothing);
    });
  });

  group('tap semantics', () {
    Future<void> mount(
      WidgetTester tester, {
      required bool touch,
      required List<int> seeks,
      required List<bool> boosts,
      required void Function() toggle,
    }) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _host(
          CompactControls(
            playing: true,
            busy: false,
            touch: touch,
            video: const ColoredBox(color: Colors.black),
            controls: const SizedBox(height: 80),
            onTogglePlay: toggle,
            onSeekBy: seeks.add,
            onSpeedBoost: touch ? boosts.add : null,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a click is the play key under a mouse', (tester) async {
      var toggles = 0;
      await mount(
        tester,
        touch: false,
        seeks: [],
        boosts: [],
        toggle: () => toggles++,
      );
      await _tapPicture(tester, .5);
      expect(toggles, 1);
    });

    testWidgets('a tap that woke the bars does not also pause', (tester) async {
      var toggles = 0;
      final key = GlobalKey<CompactControlsState>();
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _host(
          CompactControls(
            key: key,
            playing: true,
            busy: false,
            touch: true,
            video: const ColoredBox(color: Colors.black),
            controls: const SizedBox(height: 80),
            onTogglePlay: () => toggles++,
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(key.currentState!.visible, isFalse);
      await _tapPicture(tester, .5);
      expect(key.currentState!.visible, isTrue);
      expect(toggles, 0);
    });

    testWidgets('double tapping a third moves ten seconds that way', (
      tester,
    ) async {
      final moves = <int>[];
      await mount(tester, touch: true, seeks: moves, boosts: [], toggle: () {});
      for (final fraction in [.2, .8]) {
        final rect = tester.getRect(
          find.byKey(const ValueKey('compact-player-picture')),
        );
        final at = rect.topLeft + Offset(rect.width * fraction, 60);
        await tester.tapAt(at);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tapAt(at);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
      }
      expect(moves, [-10, 10]);
    });

    testWidgets('holding the picture runs at 2× until release', (tester) async {
      final boosts = <bool>[];
      await mount(
        tester,
        touch: true,
        seeks: [],
        boosts: boosts,
        toggle: () {},
      );
      final rect = tester.getRect(
        find.byKey(const ValueKey('compact-player-picture')),
      );
      final finger = await tester.startGesture(rect.center);
      await tester.pump(const Duration(milliseconds: 700));
      expect(boosts, [true]);
      await finger.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(boosts, [true, false]);
    });

    testWidgets('a pointer parked on the progress bar holds the chrome up', (
      tester,
    ) async {
      final key = GlobalKey<CompactControlsState>();
      await tester.binding.setSurfaceSize(const Size(1100, 300));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _host(
          CompactControls(
            key: key,
            playing: true,
            busy: false,
            touch: false,
            video: const ColoredBox(color: Colors.black),
            controls: const SizedBox(height: 80),
          ),
        ),
      );
      key.currentState!.holdOnProgress(true);
      await tester.pump(const Duration(seconds: 8));
      expect(key.currentState!.visible, isTrue);
      key.currentState!.holdOnProgress(false);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(key.currentState!.visible, isFalse);
    });

    testWidgets('the collapse chevron is gone', (tester) async {
      await mount(tester, touch: true, seeks: [], boosts: [], toggle: () {});
      expect(find.byTooltip('隐藏播放操作'), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsNothing);
    });
  });
}
