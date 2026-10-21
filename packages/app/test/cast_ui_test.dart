import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_cast/hongguo_cast.dart';
import 'package:hongguo_app/cast/cast_device_sheet.dart';
import 'package:hongguo_app/cast/cast_remote_page.dart';

import 'cast_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CastHarness harness;

  setUp(() async {
    harness = CastHarness();
    await harness.start();
  });
  tearDown(() => harness.finish());

  Widget host(Future<void> Function(BuildContext context) open) => MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => open(context),
          child: const Text('open'),
        ),
      ),
    ),
  );

  testWidgets('the picker offers each television and returns the chosen one', (
    tester,
  ) async {
    final subject = harness.controller();
    addTearDown(subject.dispose);
    await subject.browse();
    expect(subject.devices, hasLength(1));
    KnownRenderer? picked;
    await tester.pumpWidget(
      host(
        (context) async =>
            picked = await showCastDevicePicker(context, subject),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('选择附近的电视/盒子'), findsOneWidget);
    expect(find.text('客厅电视'), findsOneWidget);
    expect(find.text('KT-55'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cast-renderer-uuid:tv-1')));
    await tester.pumpAndSettle();
    expect(picked?.friendlyName, '客厅电视');
  });

  testWidgets('an uncontrollable receiver is listed but cannot be picked', (
    tester,
  ) async {
    final subject = harness.controller();
    addTearDown(subject.dispose);
    subject.devices = [
      knownRenderer(
        UpnpDevice(
          location: Uri.parse('http://192.168.1.41/desc.xml'),
          udn: 'uuid:old-tv',
          friendlyName: '旧电视',
          modelName: 'X1',
          services: const [],
        ),
      ),
    ];
    KnownRenderer? picked;
    await tester.pumpWidget(
      host(
        (context) async =>
            picked = await showCastDevicePicker(context, subject),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('该设备不支持播控'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cast-renderer-uuid:old-tv')));
    await tester.pumpAndSettle();
    expect(picked, isNull);
    expect(find.text('选择附近的电视/盒子'), findsOneWidget);
  });

  testWidgets(
    'the remote page drives the television and hands the position back',
    (tester) async {
      final subject = harness.controller();
      addTearDown(subject.dispose);
      await harness.cast(subject);
      Duration? resumeAt = const Duration(milliseconds: -1);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    resumeAt = await showCastRemote(context, subject),
                child: const Text('remote'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('remote'));
      await tester.pumpAndSettle();
      expect(find.text('正在 客厅电视 上播放'), findsOneWidget);
      expect(find.text('大时代 · 第 1 集'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('cast-volume-up')));
      await tester.pump();
      expect(harness.spy.arguments['SetVolume']!['DesiredVolume'], '60');

      await tester.tap(find.byKey(const ValueKey('cast-play')));
      await tester.pumpAndSettle();
      expect(harness.spy.actions, contains('Pause'));
      expect(find.text('已在电视上暂停'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('cast-play')));
      await tester.pumpAndSettle();
      expect(harness.spy.actions, contains('Play'));

      // Seeking from the remote is a REL_TIME command, and the position it set is
      // what the phone resumes from, not zero.
      await tester.drag(
        find.byKey(const ValueKey('cast-scrub')),
        const Offset(120, 0),
      );
      await tester.pumpAndSettle();
      expect(harness.spy.arguments['Seek']!['Unit'], 'REL_TIME');
      final seeked = subject.position;
      expect(seeked, greaterThan(Duration.zero));

      await tester.tap(find.byKey(const ValueKey('cast-exit')));
      await tester.pumpAndSettle();
      expect(resumeAt, seeked);
      expect(subject.active, isFalse);
      expect(harness.runtime.releases, 1);
    },
  );

  testWidgets('a failed hand-over never opens a remote page', (tester) async {
    final subject = harness.controller();
    addTearDown(subject.dispose);
    harness.spy.failOn = {'SetAVTransportURI'};
    await harness.cast(subject);
    expect(subject.active, isFalse);
    expect(subject.error, '电视拒绝了该指令');
    // Nothing keeps the decrypted file pinned once the television refused it.
    expect(harness.runtime.releases, 1);
  });
}
