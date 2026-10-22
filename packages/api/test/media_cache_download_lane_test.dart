import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_api/hongguo_native_api.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

class BytesAdapter implements HttpClientAdapter {
  final Uint8List bytes;
  BytesAdapter(this.bytes);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        Headers.contentLengthHeader: ['${bytes.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The concurrency a user sets for manual downloads has to bound the actual
/// transfers, which live in [MediaCache] -- and it must not take the slots
/// playback and automatic prefetch are served from.
void main() {
  late Directory temp;
  late Dio dio;
  late VideoTrack track;
  late MediaCache cache;

  /// Vid of every job that entered its transfer, in start order.
  late List<String> started;
  late Map<String, Completer<void>> hold;

  /// Builds a cache whose transfers stop inside `resolve` until released, so
  /// "how many jobs are running" is observable without timing races.
  void build({required int maxConcurrent, required int maxDownloadConcurrent}) {
    started = [];
    hold = {};
    cache = MediaCache(
      directory: temp,
      dio: dio,
      resolve: (vid, quality) async {
        started.add(vid);
        await (hold[vid] ??= Completer<void>()).future;
        return track;
      },
      maxConcurrent: maxConcurrent,
      maxDownloadConcurrent: maxDownloadConcurrent,
    );
  }

  /// Waits until [count] jobs have entered their transfer, then gives the
  /// scheduler a grace period so an assertion on `started` also proves that no
  /// further job slipped in.
  Future<void> settleAt(int count) async {
    for (var i = 0; i < 200 && started.length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }

  void release(String vid) => (hold[vid] ??= Completer<void>()).complete();

  /// Which jobs reached their transfer. Several run at once and each awaits
  /// its own cache lookup, so the set is the contract, not the order.
  void expectStarted(Iterable<String> vids) {
    expect(started.toSet(), vids.toSet(), reason: 'started: $started');
    expect(started.length, vids.length, reason: 'started: $started');
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('hongguo-download-lane-');
    dio = Dio()
      ..httpClientAdapter = BytesAdapter(
        File('../core/test/fixtures/media/real.cenc.mp4').readAsBytesSync(),
      );
    final fixture = jsonDecode(
      File('../core/test/fixtures/node_oracle.json').readAsStringSync(),
    );
    track = VideoTrack(
      url: Uri.parse('https://a.qznovelvod.com/test.mp4'),
      spadeA: base64Encode(unhex(fixture['spade'][0]['raw'])),
      definition: '720p',
      size: 0,
    );
  });
  tearDown(() async {
    cache.close();
    dio.close(force: true);
    await temp.delete(recursive: true);
  });

  test('manual downloads run side by side up to their own limit', () async {
    build(maxConcurrent: 2, maxDownloadConcurrent: 3);
    final leases = [
      for (final vid in ['11', '12', '13', '14', '15'])
        cache.prepare(vid, background: true, manual: true),
    ];
    await settleAt(3);
    expectStarted(['11', '12', '13']);
    // The fourth transfer waits for a slot, and takes it as soon as one
    // download really finishes.
    release('11');
    expect(await leases.first.result, endsWith('11_best.mp4'));
    await settleAt(4);
    expectStarted(['11', '12', '13', '14']);
    for (final vid in ['12', '13', '14', '15']) {
      release(vid);
    }
    for (final lease in leases.skip(1)) {
      expect(await lease.result, endsWith('_best.mp4'));
    }
  });

  /// The number a device run is judged by: what the scheduler itself had in
  /// flight, not what a host-side poll happened to catch between two short
  /// transfers.
  test('the scheduler records the download lane at its own ceiling', () async {
    build(maxConcurrent: 2, maxDownloadConcurrent: 3);
    final leases = [
      for (final vid in ['11', '12', '13', '14', '15'])
        cache.prepare(vid, background: true, manual: true),
    ];
    await settleAt(3);
    expect(cache.peakManualTransfers, 3);
    expect(cache.peakAutomaticTransfers, 0);
    // Refilling the lane keeps it saturated: five transfers go through three
    // slots and the record has to stay at three, never four.
    for (final vid in ['11', '12', '13']) {
      release(vid);
    }
    for (final lease in leases.take(3)) {
      expect(await lease.result, endsWith('_best.mp4'));
    }
    await settleAt(5);
    expect(cache.peakManualTransfers, 3);
    for (final vid in ['14', '15']) {
      release(vid);
    }
    for (final lease in leases.skip(3)) {
      expect(await lease.result, endsWith('_best.mp4'));
    }
    expect(cache.peakManualTransfers, 3);
  });

  test('each lane peaks against its own budget', () async {
    build(maxConcurrent: 2, maxDownloadConcurrent: 3);
    final downloads = [
      for (final vid in ['11', '12', '13', '14'])
        cache.prepare(vid, background: true, manual: true),
    ];
    final playing = [
      for (final vid in ['21', '22', '23']) cache.prepare(vid),
    ];
    await settleAt(5);
    // Five transfers run side by side, three of them the user's own downloads.
    // A shared budget could never reach this, and one lane borrowing the
    // other's slots would push either number past its own limit.
    expectStarted(['11', '12', '13', '21', '22']);
    expect(cache.peakManualTransfers, 3);
    expect(cache.peakAutomaticTransfers, 2);
    cache.resetPeakTransfers();
    expect(cache.peakManualTransfers, 0);
    expect(cache.peakAutomaticTransfers, 0);
    for (final vid in ['11', '12', '13', '14', '21', '22', '23']) {
      release(vid);
    }
    for (final lease in downloads.followedBy(playing)) {
      expect(await lease.result, endsWith('_best.mp4'));
    }
    expect(cache.peakManualTransfers, lessThanOrEqualTo(3));
    expect(cache.peakAutomaticTransfers, lessThanOrEqualTo(2));
  });

  test(
    'download transfers never occupy the playback or prefetch budget',
    () async {
      // A TV build prepares one file at a time; the user can still download
      // several, and neither may hold up the episode being watched.
      build(maxConcurrent: 1, maxDownloadConcurrent: 4);
      final downloads = [
        for (final vid in ['11', '12', '13', '14'])
          cache.prepare(vid, background: true, manual: true),
      ];
      await settleAt(4);
      expectStarted(['11', '12', '13', '14']);
      final playback = cache.prepare('21');
      await settleAt(5);
      expectStarted(['11', '12', '13', '14', '21']);
      for (final vid in ['11', '12', '13', '14', '21']) {
        release(vid);
      }
      for (final lease in downloads) {
        expect(await lease.result, endsWith('_best.mp4'));
      }
      expect(await playback.result, endsWith('21_best.mp4'));
    },
  );

  test(
    'stopping automatic prefetch leaves the user downloads running',
    () async {
      build(maxConcurrent: 2, maxDownloadConcurrent: 2);
      final download = cache.prepare('11', background: true, manual: true);
      final prefetch = cache.prepare('12', background: true);
      final cancelled = expectLater(
        prefetch.result,
        throwsA(isA<MediaCancelled>()),
      );
      await settleAt(2);
      cache.cancelBackground();
      await cancelled;
      release('11');
      expect(await download.result, endsWith('11_best.mp4'));
    },
  );

  test(
    'configure moves the download lane without touching the prefetch lane',
    () async {
      build(maxConcurrent: 1, maxDownloadConcurrent: 1);
      final first = cache.prepare('11', background: true, manual: true);
      final second = cache.prepare('12', background: true, manual: true);
      await settleAt(1);
      expectStarted(['11']);
      await cache.configure(
        files: 30,
        bytes: 512 * 1024 * 1024,
        concurrency: 1,
        downloadConcurrency: 2,
      );
      await settleAt(2);
      expectStarted(['11', '12']);
      release('11');
      release('12');
      expect(await first.result, endsWith('11_best.mp4'));
      expect(await second.result, endsWith('12_best.mp4'));
    },
  );
}
