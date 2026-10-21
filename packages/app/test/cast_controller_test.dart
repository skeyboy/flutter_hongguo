import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/cast/cast_controller.dart';
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

  test('browse keeps the renderers that answered', () async {
    final subject = harness.controller();
    addTearDown(subject.dispose);
    await subject.browse();
    expect(subject.devices, hasLength(1));
    expect(subject.devices.first.friendlyName, '客厅电视');
    expect(subject.error, isNull);
  });

  test('an empty scan says what to check instead of an empty list', () async {
    final subject = harness.controller(hits: const []);
    addTearDown(subject.dispose);
    await subject.browse();
    expect(subject.devices, isEmpty);
    expect(subject.error, contains('AP 隔离'));
  });

  test('a phone without a LAN address is told so', () async {
    final subject = harness.controller(
      bindServer: () async => throw const UpnpException(
        'No private Wi-Fi address; is the device on a LAN?',
      ),
    );
    addTearDown(subject.dispose);
    await subject.browse();
    expect(subject.error, contains('同一个局域网'));
  });

  test('casting serves the cached file and keeps it pinned', () async {
    final subject = harness.controller();
    addTearDown(subject.dispose);
    await harness.cast(subject);
    expect(harness.spy.actions, ['SetAVTransportURI', 'Play']);
    final handed = harness.spy.arguments['SetAVTransportURI']!;
    expect(handed['CurrentURI'], startsWith('http://127.0.0.1:'));
    expect(handed['CurrentURIMetaData'], contains('video/mp4'));
    expect(handed['CurrentURIMetaData'], contains('大时代'));
    expect(subject.phase, CastPhase.streaming);
    expect(subject.duration, const Duration(minutes: 45));
    expect(harness.runtime.pins, 1);
    expect(harness.runtime.releases, 0);
  });

  test('a refused hand-over releases the pin', () async {
    final failing = CastHarness(failOn: {'Play'});
    await failing.start();
    addTearDown(failing.finish);
    final subject = failing.controller();
    addTearDown(subject.dispose);
    await failing.cast(subject);
    expect(subject.active, isFalse);
    expect(subject.error, '电视拒绝了该指令');
    expect(failing.runtime.releases, 1);
  });

  test('content that was never cached is refused', () async {
    harness.runtime.path = null;
    final subject = harness.controller();
    addTearDown(subject.dispose);
    await harness.cast(subject);
    expect(subject.active, isFalse);
    expect(subject.error, contains('缓存'));
    expect(harness.runtime.releases, 1);
  });

  test('stopping revokes the file the television was pulling', () async {
    final subject = harness.controller();
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
    final subject = harness.controller();
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

  test('re-pointing the session releases the previous episode', () async {
    final subject = harness.controller();
    addTearDown(subject.dispose);
    await harness.cast(subject);
    await harness.cast(subject, vid: '2');
    expect(
      harness.spy.actions.where((action) => action == 'Play'),
      hasLength(2),
    );
    expect(harness.runtime.pins, 2);
    expect(harness.runtime.releases, 1);
    expect(subject.title, '大时代 · 第 2 集');
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
