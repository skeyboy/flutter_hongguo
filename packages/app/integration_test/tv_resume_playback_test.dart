import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/tv/tv_detail_page.dart';
import 'package:hongguo_app/personal/personal_library.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_app/playback/tv_video_view.dart';
import 'package:hongguo_app/settings/settings_store_native.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_tv/hongguo_tv.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

import 'tv_remote_test.dart' show TvPlaybackFixtureRuntime;

class _Runtime extends TvPlaybackFixtureRuntime
    implements PersonalLibraryRuntime {
  @override
  final PersonalLibrary personalLibrary;
  _Runtime(super.bytes, super.directory)
    : personalLibrary = PersonalLibrary(
        backend: FilePreferencesBackend(
          File('${directory.path}/personal.json'),
        ),
      ),
      super(
        episodes: 3,
        settings: const AppSettings(autoNext: true, prefetchEnabled: false),
      );
  @override
  Future<void> dispose() async {
    await personalLibrary.flush();
    personalLibrary.dispose();
    await super.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  testWidgets(
    'TV resumes last/per-episode positions, restarts completed episodes and auto advances',
    (t) async {
      final data = await rootBundle.load('assets/verification.cenc.mp4');
      final runtime = _Runtime(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        await Directory.systemTemp.createTemp('tv-resume-'),
      );
      addTearDown(runtime.dispose);
      final detail = await runtime.catalog.detail('123');
      final library = runtime.personalLibrary;
      for (final seed in [
        (0, 350, false, 1),
        (2, 1500, true, 2),
        (1, 450, false, 3),
      ]) {
        await library.record(
          WatchRecord(
            drama: detail.drama,
            vid: detail.episodes[seed.$1].vid,
            episode: seed.$1 + 1,
            positionMs: seed.$2,
            durationMs: 1500,
            finished: seed.$3,
            updated: DateTime(2026, 10, seed.$4),
          ),
        );
      }
      await t.pumpWidget(
        TvBackDispatcher(
          builder: (_, key) => MaterialApp(
            navigatorKey: key,
            builder: (_, child) => TvEnvironment(
              enabled: true,
              child: TvNavigation(child: child!),
            ),
            home: TvDetailPage(runtime: runtime, initial: detail.drama),
          ),
        ),
      );
      await t.pumpAndSettle();
      for (
        var i = 0;
        i < 50 &&
            FocusManager.instance.primaryFocus?.debugLabel != 'tv-detail-play';
        i++
      ) {
        await t.pump(const Duration(milliseconds: 100));
      }
      print('TV_SYSTEM_KEY=23');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      TvPlayerSurface surface() =>
          t.widget<TvPlayerSurface>(find.byType(TvPlayerSurface));
      TvPlaybackController player() =>
          t.widget<TvVideoView>(find.byType(TvVideoView)).controller;
      Future<void> ready(int index, {bool pause = true}) async {
        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          await t.pump();
          if (find.byType(TvPlayerSurface).evaluate().isNotEmpty &&
              !surface().busy &&
              surface().episode == index &&
              surface().duration > Duration.zero) {
            if (pause) await player().pause();
            await t.pump();
            return;
          }
        }
        fail('Episode $index not ready');
      }

      await ready(1);
      expect(runtime.prepared.last.vid, '124');
      expect(player().position.inMilliseconds, greaterThanOrEqualTo(450));
      // Selecting a different unfinished episode uses its own bookmark.
      surface().selectEpisode(0);
      await ready(0);
      expect(player().position.inMilliseconds, greaterThanOrEqualTo(350));
      // A completed episode must restart, not resume at the end.
      surface().selectEpisode(2);
      await ready(2);
      expect(player().position.inMilliseconds, lessThan(350));
      // Complete episode 1 and check auto-next opens episode 2 once.
      surface().selectEpisode(0);
      await ready(0);
      await player().seek(
        player().duration - const Duration(milliseconds: 100),
      );
      await player().video!.play();
      await ready(1);
      await library.flush();
      expect(library.episodeFor('123', '123')!.completed, isTrue);
      expect(runtime.prepared.last.vid, '124');
      final restored = PersonalLibrary(
        backend: FilePreferencesBackend(
          File('${runtime.directory.path}/personal.json'),
        ),
      );
      await restored.load();
      expect(restored.latestFor('123')!.vid, '124');
      expect(restored.episodeFor('123', '123')!.completed, isTrue);
      expect(
        restored.episodeFor('123', '124')!.resumeAt,
        greaterThan(Duration.zero),
      );
      restored.dispose();
      print(
        'TV_RESUME_PASS last_episode=true unfinished_resume=true completed_restart=true auto_next=true disk_persistence=true',
      );
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
    },
  );
}
