/// v0.3.2 macOS download-concurrency verification driver (uncapped manual
/// downloads + prefetch-during-playback). Real upstream traffic only.
/// Emits V032B/V032SHOT markers; the orchestrator captures the live window.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/downloads/download_manager.dart';
import 'package:hongguo_app/features/downloads_page.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_app/playback/prefetch_window.dart';

const _seriesA = '7697273659248872472';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('v0.3.2 downloadConcurrent=3, no quota, prefetch alive', (
    tester,
  ) async {
    Future<void> pumpTick() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    }

    Future<void> marker(String name) async {
      print('V032SHOT=$name');
      for (var i = 0; i < 75; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 160));
        await tester.pump();
      }
      print('V032SHOT_DONE=$name');
    }

    final base = await createRuntime();
    final runtime = base as ConfigurableRuntime;
    final manager = (base as DownloadRuntime).downloads;
    await runtime.saveSettings(
      runtime.settings.copyWith(downloadConcurrent: 3),
    );
    print(
      'V032B settings concurrent=${manager.settings().downloadConcurrent} '
      'preparations=${manager.settings().concurrentPreparations} '
      'maxCacheMb=${manager.settings().maxCacheMb} quality=default',
    );
    final detailA = await runtime.catalog.detail(_seriesA);
    print(
      'V032B seriesA=${detailA.drama.title} eps=${detailA.episodes.length}',
    );
    final details = <DramaDetail>[detailA];
    final seenIds = {detailA.drama.id};
    List<Drama> candidates = [];
    for (var attempt = 0; attempt < 3 && candidates.isEmpty; attempt++) {
      try {
        final page = await runtime.catalog.browse(
          sort: attempt == 0 ? 'hot_score' : 'online_time',
        );
        candidates = page.items.where((d) => !seenIds.contains(d.id)).toList()
          ..sort((a, b) => b.episodeCount.compareTo(a.episodeCount));
        print('V032B browse attempt=$attempt items=${page.items.length}');
      } catch (e) {
        print('V032B browseFail attempt=$attempt err=$e');
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    if (candidates.isEmpty) {
      print('V032B browseUnavailable=true; verifying with series A only');
    }
    for (final d in candidates.take(3)) {
      if (details.length >= 3) break;
      try {
        final dt = await runtime.catalog.detail(d.id);
        if (dt.episodes.length >= 20) {
          details.add(dt);
          print(
            'V032B series${details.length}=${dt.drama.title} eps=${dt.episodes.length}',
          );
        }
      } catch (e) {
        print('V032B detailFail id=${d.id} err=$e');
      }
    }
    // Reserve the last two episodes of series A for playback + prefetch so the
    // foreground pipeline is provably outside the manual download set.
    final reserved = <String>{
      detailA.episodes[detailA.episodes.length - 2].vid,
      detailA.episodes[detailA.episodes.length - 1].vid,
    };
    final jobs = <String, EpisodeDownload>{};
    for (final dt in details) {
      final positions = [
        for (var i = 0; i < dt.episodes.length; i++)
          if (!reserved.contains(dt.episodes[i].vid)) i,
      ];
      final added = await manager.enqueue(dt, positions, 'best');
      print(
        'V032B enqueued=${dt.drama.title} requested=${positions.length} added=$added',
      );
    }
    for (final task in manager.tasks) {
      if (task.phase == DownloadPhase.queued ||
          task.phase == DownloadPhase.running) {
        jobs[task.key] = task;
      }
    }
    print('V032B watchedTasks=${jobs.length}');
    final startMs = DateTime.now().millisecondsSinceEpoch;
    final cacheRoot = await getApplicationSupportDirectory();
    final cacheDir = Directory('${cacheRoot.path}/media-cache');
    final preFiles = cacheDir.existsSync()
        ? cacheDir.listSync().whereType<File>().map((f) => f.path).toSet()
        : <String>{};

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: DownloadsPage(runtime: base as DownloadRuntime),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await pumpTick();
      final queued = find.text('正在排队').evaluate().isNotEmpty;
      final running = find.text('正在下载').evaluate().isNotEmpty;
      if (queued || running) break;
    }
    await marker('downloads_running');

    final forbidden = ['额度', '容量不足', '空间不足', '超过上限'];
    String? quotaHit;
    int maxRunningObserved = 0;
    int maxMovingObserved = 0;
    final lastFraction = <String, double>{};
    var phase = 'downloads-only';
    PlaybackProbe? probe;
    var nextPhaseAt = startMs + 90000;
    var endedAt = 0;
    var deadline = startMs + 14 * 60 * 1000;

    while (DateTime.now().millisecondsSinceEpoch < deadline) {
      await Future<void>.delayed(const Duration(seconds: 3));
      await tester.pump();
      final t = DateTime.now().millisecondsSinceEpoch;
      final running = jobs.values
          .where((k) => k.phase == DownloadPhase.running)
          .toList();
      var moving = 0;
      for (final task in running) {
        final prev = lastFraction[task.key];
        final now = task.fraction;
        if (prev != null && now != null && now > prev) moving++;
        if (now != null) lastFraction[task.key] = now;
      }
      if (running.length > maxRunningObserved) {
        maxRunningObserved = running.length;
      }
      if (moving > maxMovingObserved) maxMovingObserved = moving;
      for (final task in jobs.values) {
        final msg = task.message;
        if (forbidden.any(msg.contains) ||
            forbidden.any(task.phase.name.contains)) {
          quotaHit ??= '${task.key}: $msg';
        }
      }
      final readyN = jobs.values
          .where((k) => k.phase == DownloadPhase.ready)
          .length;
      final failedN = jobs.values
          .where((k) => k.phase == DownloadPhase.failed)
          .length;
      final pausedN = jobs.values
          .where((k) => k.phase == DownloadPhase.paused)
          .length;
      final queuedN = jobs.values
          .where((k) => k.phase == DownloadPhase.queued)
          .length;
      final bytes = jobs.values
          .where((k) => k.phase == DownloadPhase.ready)
          .fold<int>(0, (a, k) => a + k.bytes);
      print(
        'V032B t=${((t - startMs) / 1000).round()}s phase=$phase '
        'running=${running.length} moving=$moving ready=$readyN '
        'queued=$queuedN paused=$pausedN failed=$failedN bytes=$bytes',
      );
      if (probe != null) probe.tick();
      if (phase == 'downloads-only' && t >= nextPhaseAt) {
        phase = 'playback+prefetch';
        print('V032B enterPlayback playing=$reserved');
        final vids = reserved.toList();
        probe = PlaybackProbe(runtime, manager, detailA, vids[0], vids[1]);
        await probe.start();
      }
      final allTerminal = readyN + failedN == jobs.length;
      if (allTerminal &&
          probe != null &&
          (probe.playCompletedMs != null || probe.playFailed) &&
          (probe.prefetchReady || probe.prefetchFailed)) {
        endedAt = DateTime.now().millisecondsSinceEpoch;
        break;
      }
    }
    print(
      'V032B monitorEnded elapsedS=${endedAt == 0 ? 'timeout' : ((endedAt - startMs) / 1000).round()}',
    );
    probe?.finish();
    await pumpTick();
    await marker('downloads_done');

    final ready = jobs.values
        .where((k) => k.phase == DownloadPhase.ready)
        .toList();
    final totalBytes = ready.fold<int>(0, (a, k) => a + k.bytes);
    final newFiles = <String, int>{};
    if (cacheDir.existsSync()) {
      for (final f in cacheDir.listSync().whereType<File>()) {
        if (preFiles.contains(f.path)) continue;
        newFiles[f.uri.pathSegments.last] = f.lengthSync();
      }
    }
    final report = {
      'startedUtc': DateTime.fromMillisecondsSinceEpoch(startMs)
          .toIso8601String(),
      'downloadConcurrent': manager.settings().downloadConcurrent,
      'concurrentPreparations': manager.settings().concurrentPreparations,
      'watchedTasks': jobs.length,
      'readyTasks': ready.length,
      'failedTasks': jobs.values
          .where((k) => k.phase == DownloadPhase.failed)
          .map((k) => k.key)
          .toList(),
      'pausedTasks': jobs.values
          .where((k) => k.phase == DownloadPhase.paused)
          .map((k) => k.key)
          .toList(),
      'queuedTasks': jobs.values
          .where((k) => k.phase == DownloadPhase.queued)
          .length,
      'totalReadyBytes': totalBytes,
      'maxManagerRunning': maxRunningObserved,
      'maxTransferringTasks': maxMovingObserved,
      'quotaBlockedMessage': quotaHit,
      'prefetchPlayMs': probe?.playCompletedMs,
      'prefetchInsertMs': probe?.prefetchInsertMs,
      'prefetchReadyMs': probe?.prefetchReadyMs,
      'prefetchPhaseLog': probe?.log,
      'newCacheFiles': newFiles,
      'perTask': [
        for (final k in jobs.values)
          {
            'key': k.key,
            'index': k.episode.index,
            'phase': k.phase.name,
            'bytes': k.bytes,
            'message': k.message,
          },
      ],
    };
    print('V032B REPORT=${jsonEncode(report)}');
    File('${cacheRoot.path}/mac-download-concurrency-result.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    expect(quotaHit, isNull, reason: 'no quota/capacity rejection may appear');
    print(
      'V032B FINAL ready=${ready.length}/${jobs.length} bytes=$totalBytes '
      'maxRunning=$maxRunningObserved maxMoving=$maxMovingObserved',
    );
    await manager.shutdown();
    await tester.pumpWidget(const SizedBox());
    await pumpTick();
    await runtime.dispose();
    print('V032DONE downloads');
  }, timeout: const Timeout(Duration(minutes: 45)));
}

class PlaybackProbe {
  final ConfigurableRuntime runtime;
  final DownloadManager manager;
  final DramaDetail detail;
  final String playVid, prefetchVid;
  final log = <String>[];
  int? playCompletedMs, playStartedMs, prefetchInsertMs, prefetchReadyMs;
  bool playFailed = false, prefetchReady = false, prefetchFailed = false;
  late final PrefetchWindow window;
  PlaybackJob? playJob;
  PlaybackProbe(
    this.runtime,
    this.manager,
    this.detail,
    this.playVid,
    this.prefetchVid,
  );

  Future<void> start() async {
    playStartedMs = DateTime.now().millisecondsSinceEpoch;
    manager.playbackEntered();
    log.add('playbackEntered');
    playJob = runtime.prepare(playVid, quality: 'best');
    unawaited(
      playJob!.source
          .then((_) {
            playCompletedMs =
                DateTime.now().millisecondsSinceEpoch - playStartedMs!;
            log.add('playReady +${playCompletedMs}ms');
          })
          .catchError((Object e) {
            playFailed = true;
            log.add('playFailed $e');
          }),
    );
    window = PrefetchWindow(runtime: runtime, episodes: detail.episodes);
    final pos = detail.episodes.indexWhere((e) => e.vid == playVid);
    prefetchInsertMs = DateTime.now().millisecondsSinceEpoch - playStartedMs!;
    window.sync(position: pos, quality: 'best', count: 2, enabled: true);
    log.add('prefetchSync insertAt=${prefetchInsertMs}ms vids=$prefetchVid');
  }

  void tick() {
    final phase = window.phaseFor(prefetchVid, 'best');
    if (phase == PrefetchPhase.ready && prefetchReadyMs == null) {
      prefetchReady = true;
      prefetchReadyMs = DateTime.now().millisecondsSinceEpoch - playStartedMs!;
      log.add('prefetchReady +$prefetchReadyMs ms running=${_running()}');
    } else if (phase == PrefetchPhase.failed) {
      prefetchFailed = true;
      log.add('prefetchFailed running=${_running()}');
    }
  }

  int _running() =>
      manager.tasks.where((t) => t.phase == DownloadPhase.running).length;

  bool get done =>
      playFailed || playCompletedMs != null || prefetchReady || prefetchFailed;

  void finish() {
    manager.playbackLeft();
    playJob?.release();
    window.dispose();
  }
}
