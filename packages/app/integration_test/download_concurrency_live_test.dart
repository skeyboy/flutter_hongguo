/// Opt-in real-upstream check on a device the operator owns (this Mac, or the
/// TV emulator): the download concurrency setting has to bound the transfers
/// that actually move bytes. Cancels and deletes only what it created.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hongguo_app/downloads/download_manager.dart';
import 'package:hongguo_app/platform/runtime.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Every stage is reported as it happens: a run that stops moving is then
  // distinguishable from one that moved too slowly, on a device whose stdout
  // reaches the host only through logcat.
  void say(String message) => print(
    'DOWNLOAD-LIVE ${DateTime.now().toIso8601String().substring(11, 19)} $message',
  );
  testWidgets('live: 同时下载数量 bounds the transfers that really move bytes', (
    tester,
  ) async {
    const seriesId = String.fromEnvironment('HONGGUO_POC_SERIES_ID');
    const wanted = int.fromEnvironment(
      'HONGGUO_DOWNLOAD_CONCURRENT',
      defaultValue: 5,
    );
    if (!(Platform.isMacOS || Platform.isAndroid) || seriesId.isEmpty) {
      throw StateError(
        'Explicit Mac/Android device and POC series are required',
      );
    }
    final runtime = await createRuntime();
    final configurable = runtime as ConfigurableRuntime;
    final downloads = (runtime as DownloadRuntime).downloads;
    final original = configurable.settings;
    await downloads.load();
    say(
      'runtime ready limit=${original.downloadConcurrent} '
      'cachedTasks=${downloads.tasks.length}',
    );
    // Whatever the operator already had queued is off limits: the run only
    // ever touches tasks it added itself.
    final before = downloads.tasks.map((t) => t.key).toSet();
    List<EpisodeDownload> mine() =>
        downloads.tasks.where((t) => !before.contains(t.key)).toList();
    addTearDown(() async {
      for (final task in mine()) {
        await downloads.remove(task.key).catchError((Object _) {});
      }
      await configurable.saveSettings(original);
      await runtime.dispose();
    });
    final detail = await runtime.catalog.detail(seriesId);
    say('catalog detail episodes=${detail.episodes.length}');
    // One episode more than the limit stays queued, so the limit is what is
    // being measured rather than the size of the queue.
    final positions = [
      for (var i = 0; i < wanted + 1 && i < detail.episodes.length; i++) i,
    ];
    final concurrent = positions.length - 1;
    expect(concurrent, greaterThanOrEqualTo(3));
    // A queued episode would be skipped by enqueue, so the sample would shrink
    // to whatever the operator already had instead of measuring the limit.
    final clash = [for (final i in positions) '${detail.episodes[i].vid}_best']
        .where(before.contains)
        .toList();
    expect(clash, isEmpty, reason: 'These episodes are already in your queue');
    await configurable.saveSettings(
      original.copyWith(downloadConcurrent: concurrent),
    );
    final lanes = runtime as TransferLaneRuntime;
    // Anything this process transferred before the run is not this run's
    // evidence, so the counters start empty here.
    lanes.resetTransferLanePeaks();
    await downloads.enqueue(detail, positions, 'best');
    expect(mine(), hasLength(positions.length));
    say('enqueued=${positions.length} transferring up to $concurrent');
    var peak = 0;
    // The scheduler counts its own in-flight transfers at the instant it starts
    // one, so this is the real ceiling rather than what a 500 ms poll happens to
    // catch. The floor and the ceiling are read from the same number.
    var drained = false;
    for (var tick = 0; tick < 120 && !(drained && peak >= concurrent); tick++) {
      await tester.pump(const Duration(milliseconds: 500));
      peak = lanes.transferLanePeaks.manual;
      expect(peak, lessThanOrEqualTo(concurrent));
      drained = mine().every(
        (t) =>
            t.phase == DownloadPhase.ready || t.phase == DownloadPhase.failed,
      );
      if ((tick + 1) % 10 == 0) {
        say(
          'tick=${tick + 1} peak=$peak '
          'automatic=${lanes.transferLanePeaks.automatic} drained=$drained',
        );
      }
    }
    say(
      'DOWNLOAD_CONCURRENT=$concurrent peak=$peak '
      '${mine().map((t) => '${t.episode.vid}:${t.phase.name}:${t.bytes}b').join(' ')}',
    );
    // A run where nothing moved bytes says nothing about transfers, however
    // well the scheduler behaved: that is upstream or the device, not the limit.
    expect(
      mine().where((t) => t.bytes > 0).length,
      greaterThan(0),
      reason: 'No transfer moved a byte; the run measured nothing',
    );
    expect(
      drained,
      isTrue,
      reason: 'Queue still in flight when the wait ended',
    );
    expect(peak, concurrent);
    // Nothing of this run may outlive it: partial files and records go back
    // the way they came.
    for (final task in mine()) {
      downloads.cancel(task.key);
    }
    await tester.pump(const Duration(seconds: 2));
    for (final task in mine()) {
      await downloads.remove(task.key);
    }
    expect(mine(), isEmpty);
    expect(downloads.tasks.map((t) => t.key).toSet(), before);
    say('cleaned up; cachedTasks=${downloads.tasks.length}');
  });
}
