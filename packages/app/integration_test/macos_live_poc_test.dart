/// Opt-in real-upstream, single-episode acceptance on the current Mac only.
/// Excluded from the offline regression script and normal App entrypoint.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/features/player_page.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:media_kit/media_kit.dart' hide VideoTrack;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  testWidgets(
    'current Mac: native Dart algorithms → real first episode → local player',
    (tester) async {
      const seriesId = String.fromEnvironment('HONGGUO_POC_SERIES_ID');
      const expectedVid = String.fromEnvironment('HONGGUO_POC_VID');
      const prefetchCount = int.fromEnvironment(
        'HONGGUO_POC_PREFETCH',
        defaultValue: 0,
      );
      if (prefetchCount != 0 && (prefetchCount < 3 || prefetchCount > 5)) {
        throw ArgumentError('Prefetch count must be 0 or 3–5');
      }
      if (!Platform.isMacOS || seriesId.isEmpty || expectedVid.isEmpty) {
        throw StateError(
          'Explicit macOS and POC series/episode IDs are required',
        );
      }
      expect(runCoreDiagnostics().values.every((v) => v), isTrue);
      final runtime = await createRuntime();
      final detail = await runtime.catalog.detail(seriesId);
      expect(detail.episodes.first.vid, expectedVid);
      // Restrict to exactly one real episode: no automatic prefetch of other clips.
      final single = DramaDetail(
        detail.drama,
        detail.episodes.take(prefetchCount + 1).toList(),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: PlayerPage(runtime: runtime, detail: single),
        ),
      );
      await tester.pump();
      final dynamic state = tester.state(find.byType(PlayerPage));
      final player = state.player as Player;
      await player.setVolume(0);
      state.autoNext = false;
      for (var i = 0; i < 600; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (state.error != null) {
          throw StateError('Native player: ${state.error}');
        }
        if ((player.state.width ?? 0) > 0 &&
            player.state.duration > const Duration(seconds: 1) &&
            !state.preparing) {
          break;
        }
      }
      expect(state.preparing, isFalse);
      expect(state.error, isNull);
      expect(state.audioNotice, isNull);
      expect(player.state.width, greaterThan(0));
      expect(player.state.height, greaterThan(0));
      expect(
        player.state.tracks.audio.where((t) => !['auto', 'no'].contains(t.id)),
        isNotEmpty,
      );
      int? switchMs;
      List<String>? switchStages;
      if (prefetchCount > 0) {
        state.prefetch.sync(
          position: 0,
          quality: state.quality,
          count: prefetchCount,
          enabled: true,
        );
        for (var i = 0; i < 900; i++) {
          await tester.pump(const Duration(milliseconds: 200));
          if (state.prefetch.ready == prefetchCount) break;
        }
        expect(state.prefetch.ready, prefetchCount);
        final timer = Stopwatch()..start();
        await tester.tap(find.widgetWithText(FilledButton, '下一集'));
        for (var i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (state.position == 1 &&
              !state.preparing &&
              player.state.duration > Duration.zero) {
            break;
          }
        }
        timer.stop();
        switchMs = timer.elapsedMilliseconds;
        expect(state.position, 1);
        expect(state.preparing, isFalse);
        switchStages = List<String>.from(state.preparationStages);
        expect(switchStages, contains('已就绪'));
        expect(switchStages, isNot(contains('正在下载')));
      }
      final selectedEpisode = single.episodes[state.position as int];
      final source = player.state.playlist.medias.single.uri;
      final local = source.startsWith('file:')
          ? File.fromUri(Uri.parse(source))
          : File(source);
      expect(local.existsSync(), isTrue);
      final manifest = jsonDecode(
        File('${local.path}.json').readAsStringSync(),
      );
      expect(manifest['vid'], selectedEpisode.vid);
      expect(manifest['size'], local.lengthSync());
      await player.pause();
      final target = player.state.duration.inMilliseconds > 20000
          ? 10000
          : player.state.duration.inMilliseconds ~/ 2;
      await player.seek(Duration(milliseconds: target));
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if ((player.state.position.inMilliseconds - target).abs() < 1500) break;
      }
      expect(
        (player.state.position.inMilliseconds - target).abs(),
        lessThan(1500),
      );
      final frame = await player.screenshot(format: 'image/png');
      expect(frame, isNotNull);
      expect(frame!.length, greaterThan(100));
      final report = {
        'ok': true,
        'platform': Platform.operatingSystem,
        'nativeDart': true,
        'localServerUsed': false,
        'seriesId': seriesId,
        'initialVid': expectedVid,
        'vid': selectedEpisode.vid,
        'episodeIndex': selectedEpisode.index,
        'prefetchedEpisodes': prefetchCount,
        'switchMs': switchMs,
        'switchStages': switchStages,
        'title': detail.drama.title,
        'localFile': local.path,
        'bytes': local.lengthSync(),
        'width': player.state.width,
        'height': player.state.height,
        'durationMs': player.state.duration.inMilliseconds,
        'seekTargetMs': target,
        'seekPositionMs': player.state.position.inMilliseconds,
        'audioTrackRecognized': true,
        'audioOutputWarning': state.audioNotice,
        'frameBytes': frame.length,
      };
      final root = local.parent.parent;
      final reportFile =
          File(
            '${root.path}/${prefetchCount > 0 ? 'mac-prefetch-poc' : 'mac-live-poc'}-result.json',
          )..writeAsStringSync(
            '${const JsonEncoder.withIndent('  ').convert(report)}\n',
          );
      File(
        '${root.path}/${prefetchCount > 0 ? 'mac-prefetch-poc' : 'mac-live-poc'}-frame.png',
      ).writeAsBytesSync(frame);
      print('MAC_LIVE_POC_RESULT=${reportFile.path}');
      print('MAC_LIVE_POC_SUMMARY=${jsonEncode(report)}');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await runtime.dispose();
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
