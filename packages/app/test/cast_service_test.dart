import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/cast/cast_service.dart';
import 'package:hongguo_app/platform/multicast_lock.dart';
import 'package:hongguo_cast/hongguo_cast.dart';

import 'cast_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CastHarness harness;

  setUp(() async {
    harness = CastHarness();
    await harness.start();
  });
  tearDown(() => harness.finish());

  /// Real timers: the poll loop the queue watches runs on the event loop.
  Future<void> settle(bool Function() done) async {
    for (var tick = 0; tick < 200 && !done(); tick++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue);
  }

  int handed(CastHarness h) =>
      h.spy.actions.where((action) => action == 'SetAVTransportURI').length;

  KnownRenderer otherTelevision(CastHarness harness) => KnownRenderer(
    device: UpnpDevice(
      location: Uri.parse('http://192.168.1.41:49152/desc.xml'),
      udn: 'uuid:tv-2',
      friendlyName: '卧室电视',
      modelName: 'KT-43',
      services: harness.spy.device.services,
    ),
    expiresAt: DateTime.now().add(const Duration(minutes: 1)),
    lastSeenAt: DateTime.now(),
  );

  test('browse keeps the renderers that answered', () async {
    final subject = harness.service();
    addTearDown(subject.dispose);
    await subject.browse();
    expect(subject.devices, hasLength(1));
    expect(subject.devices.first.friendlyName, '客厅电视');
    expect(subject.error, isNull);
  });

  test('an empty scan says what to check instead of an empty list', () async {
    final subject = harness.service(hits: const []);
    addTearDown(subject.dispose);
    await subject.browse();
    expect(subject.devices, isEmpty);
    expect(subject.error, contains('AP 隔离'));
  });

  test('a phone without a LAN address is told so', () async {
    final subject = harness.service(
      bindServer: () async => throw const UpnpException(
        'No private Wi-Fi address; is the device on a LAN?',
      ),
    );
    addTearDown(subject.dispose);
    await subject.browse();
    expect(subject.error, contains('同一个局域网'));
  });

  test('casting serves the cached file and keeps it pinned', () async {
    final subject = harness.service();
    addTearDown(subject.dispose);
    await harness.cast(subject);
    expect(harness.spy.actions, ['SetAVTransportURI', 'Play']);
    final handedOver = harness.spy.arguments['SetAVTransportURI']!;
    expect(handedOver['CurrentURI'], startsWith('http://127.0.0.1:'));
    expect(handedOver['CurrentURIMetaData'], contains('video/mp4'));
    expect(handedOver['CurrentURIMetaData'], contains('大时代'));
    expect(subject.phase, CastPhase.streaming);
    expect(subject.duration, const Duration(minutes: 45));
    expect(subject.title, '大时代 · 第 1 集');
    expect(harness.runtime.pins, 1);
    expect(harness.runtime.releases, 0);
  });

  test('a refused hand-over releases the pin', () async {
    final failing = CastHarness(failOn: {'Play'});
    await failing.start();
    addTearDown(failing.finish);
    final subject = failing.service();
    addTearDown(subject.dispose);
    await failing.cast(subject);
    expect(subject.active, isFalse);
    expect(subject.error, '电视拒绝了该指令');
    expect(failing.runtime.releases, 1);
  });

  test('content that was never cached is refused', () async {
    harness.runtime.path = null;
    final subject = harness.service();
    addTearDown(subject.dispose);
    await harness.cast(subject);
    expect(subject.active, isFalse);
    expect(subject.error, contains('缓存'));
    expect(harness.runtime.releases, 1);
  });

  test('stopping revokes the file the television was pulling', () async {
    final subject = harness.service();
    addTearDown(subject.dispose);
    await harness.cast(subject);
    final url = Uri.parse(
      harness.spy.arguments['SetAVTransportURI']!['CurrentURI']!,
    );
    expect((await probe(url)).status, HttpStatus.ok);
    await subject.stop();
    expect((await probe(url)).status, HttpStatus.notFound);
    expect(harness.runtime.releases, 1);
    expect(subject.phase, CastPhase.stopped);
    expect(subject.active, isFalse);
  });

  test('range requests answer the television before it commits', () async {
    final subject = harness.service();
    addTearDown(subject.dispose);
    await harness.cast(subject);
    final url = Uri.parse(
      harness.spy.arguments['SetAVTransportURI']!['CurrentURI']!,
    );
    final first = await probe(url, range: '0-15');
    expect(first.status, HttpStatus.partialContent);
    expect(first.headers, contains('content-range: bytes 0-15/64'));
    expect(first.bodyBytes, 16);
    expect((await probe(url)).headers, contains('accept-ranges: bytes'));
  });

  test('the queue names the episode it is on and knows both ends', () async {
    final subject = harness.service();
    addTearDown(subject.dispose);
    await harness.cast(subject);
    expect(subject.canPrevious, isFalse);
    expect(subject.canNext, isTrue);
    await subject.next();
    expect(subject.canPrevious, isTrue);
    expect(subject.index, 1);
    expect(subject.title, '大时代 · 第 2 集');
    await subject.next();
    expect(subject.canNext, isFalse);
    expect(subject.index, 2);
    // Past the end the queue stays put rather than wrapping or going blank.
    expect(await subject.next(), isFalse);
    expect(subject.index, 2);
    expect(await subject.previous(), isTrue);
    expect(subject.index, 1);
  });

  test('re-pointing the session releases the previous episode', () async {
    final subject = harness.service();
    addTearDown(subject.dispose);
    await harness.cast(subject);
    await harness.cast(subject, index: 1);
    expect(
      harness.spy.actions.where((action) => action == 'Play'),
      hasLength(2),
    );
    expect(harness.runtime.pins, 2);
    expect(harness.runtime.releases, 1);
    expect(subject.title, '大时代 · 第 2 集');
  });

  test('quality switches keep the episode and put the playhead back', () async {
    final subject = harness.service();
    addTearDown(subject.dispose);
    await harness.cast(subject);
    await subject.seekTo(const Duration(minutes: 5));
    await subject.setQuality('720p');
    expect(handed(harness), 2);
    expect(subject.index, 0);
    expect(subject.quality, '720p');
    final seeked = harness.spy.arguments['Seek']!;
    expect(seeked['Unit'], 'REL_TIME');
    expect(seeked['Target'], '00:05:00.000');
  });

  test(
    'another television takes the same episode at the same position',
    () async {
      final subject = harness.service();
      addTearDown(subject.dispose);
      await harness.cast(subject);
      await subject.seekTo(const Duration(minutes: 12));
      await subject.switchTo(otherTelevision(harness));
      expect(handed(harness), 2);
      expect(subject.target?.udn, 'uuid:tv-2');
      expect(subject.title, '大时代 · 第 1 集');
      expect(harness.spy.arguments['Seek']!['Target'], '00:12:00.000');
    },
  );

  test('the tail of an episode hands the television the next one', () async {
    final subject = harness.service(poll: const Duration(milliseconds: 20));
    addTearDown(subject.dispose);
    await harness.cast(subject);
    harness.spy.relTime = '0:44:55.000';
    harness.spy.transportState = 'STOPPED';
    await settle(() => handed(harness) == 2);
    expect(subject.index, 1);
    expect(subject.title, '大时代 · 第 2 集');
  });

  test('a stop pressed by the viewer is not an episode ending', () async {
    final subject = harness.service(poll: const Duration(milliseconds: 20));
    addTearDown(subject.dispose);
    await harness.cast(subject);
    harness.spy.relTime = '0:44:55.000';
    await settle(() => subject.position > const Duration(seconds: 1));
    await subject.stop();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(handed(harness), 1);
    expect(subject.index, 0);
  });

  test('the handle is one per app session', () {
    expect(
      castServiceFor(harness.runtime),
      same(castServiceFor(harness.runtime)),
    );
  });

  test('the entry only appears where a phone can hand over a local file', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(castSupported(harness.runtime), isTrue);
    expect(castSupported(FakePlainRuntime()), isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(castSupported(harness.runtime), isFalse);
  });

  test('Android holds one multicast lock for the whole session', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('hongguo/multicast');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return true;
        });
    final lock = MulticastLock(channel);
    await lock.acquire();
    await lock.acquire();
    await lock.release();
    await lock.release();
    expect(calls, ['acquire', 'release']);
  });
}
