import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart' as bg;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/update/install_strategy.dart';
import 'package:hongguo_app/update/update_controller.dart';
import 'package:hongguo_app/update/update_dialog.dart';
import 'package:hongguo_app/update/update_transfer.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_update/hongguo_update.dart';

import 'update_fixture.dart';

/// The operating system's lane, spelled as the two questions this app asks it.
///
/// It hands over bytes the way the real one does -- into the same folder the
/// controller stages in, under the name the task carries -- so what the lane
/// checks afterwards is a file that really exists rather than a story.
class _Lane implements InstallerEngine {
  _Lane(this.directory);

  final String directory;
  final started = <bg.DownloadTask>[];
  final live = <String>{};
  final abandoned = <String>[];

  Uint8List? Function() bytes = () => fixturePayload;

  /// Freezes a handover so a press can arrive while the system still runs it.
  void block() => _paused = Completer<void>();
  void unblock() => _paused?.complete();
  Completer<void>? _paused;

  @override
  Future<void> transfer(
    bg.DownloadTask task, {
    void Function(int received, int total)? onProgress,
  }) async {
    started.add(task);
    live.add(task.taskId);
    await _paused?.future;
    final payload = bytes();
    if (payload != null) {
      File('$directory${Platform.pathSeparator}${task.filename}')
          .writeAsBytesSync(payload);
      onProgress?.call(payload.length, payload.length);
    }
    live.remove(task.taskId);
  }

  @override
  Future<bool> isLive(String taskId) async => live.contains(taskId);

  @override
  Future<void> abandon(String taskId) async {
    abandoned.add(taskId);
    live.remove(taskId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory stage;
  late _Lane lane;
  late UpdateJournal journal;
  late ReleaseInfo release;
  late ReleaseAsset asset;
  late File stagedFile;
  late List<DownloadedRelease> handoffs;
  late UpdateController controller;

  /// A controller on the lane a phone has: the download leaves this process.
  UpdateController wire({bool systemLane = true}) => UpdateController(
    dio: Dio(),
    readSettings: () => const AppSettings(backgroundDownloads: true),
    writeSettings: (_) async {},
    stageDirectory: () async => stage.path,
    installerEngine: lane,
    systemLaneAllowed: systemLane ? () => true : () => false,
    handoff: (file, release, android) async {
      handoffs.add(file);
      return const InstallPlan(message: '已交给系统安装器。');
    },
  );

  setUp(() async {
    stage = await Directory.systemTemp.createTemp('hongguo-update-background');
    lane = _Lane(stage.path);
    journal = UpdateJournal(stageDirectory: () async => stage.path);
    release = fixtureRelease();
    // Whatever this host installs, the release carries it: the suite runs on a
    // macOS laptop and on the Linux and Windows CI hosts alike.
    asset = currentUpdateTarget().installer(release)!;
    stagedFile = File('${stage.path}${Platform.pathSeparator}${asset.name}');
    handoffs = [];
    controller = wire();
  });
  tearDown(() async {
    if (stage.existsSync()) await stage.delete(recursive: true);
  });

  /// Until the handover comes back to this process -- or the suite says it never
  /// did, rather than passing on a flag that is still true.
  Future<void> settled(UpdateController target) async {
    for (var i = 0; i < 500 && target.transferring; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(target.transferring, isFalse, reason: 'the transfer never returned');
  }

  Future<void> handOver() async {
    await journal.put(
      UpdatePackageRecord(
        tag: release.tag,
        name: asset.name,
        path: stagedFile.path,
        downloadUrl: asset.downloadUrl,
        bytes: asset.bytes,
        sha256: asset.sha256!,
        stage: UpdatePackageStage.transferring,
        taskId: 'task-away',
      ),
    );
  }

  test('a press hands the installer over and lets the dialog go', () async {
    controller.offer = release;
    // The point of the lane: the press that starts a multi-minute download is not
    // the thing that has to stay alive, so nothing is awaited here.
    expect(await controller.install(), isNull);
    expect(controller.transferring, isTrue);
    expect(controller.message, contains('后台下载'));
    expect(handoffs, isEmpty);
    await settled(controller);
    expect(controller.installReady, isTrue);
    expect(controller.message, allOf(contains('已下载完成'), contains('是否安装')));
    // Re-raised so the root page asks again once the player has cleared.
    expect(controller.unseenOffer?.tag, release.tag);
    expect(lane.started, hasLength(1));
    expect(
      (await journal.forTag(release.tag))?.stage,
      UpdatePackageStage.ready,
    );
  });

  test(
    'the same press repeated while the system runs it starts no second task',
    () async {
      controller.offer = release;
      lane.block();
      final first = controller.install();
      // The press that answers 正在后台下载 is the one that opened the transfer.
      expect(await first, isNull);
      expect(controller.transferring, isTrue);
      expect(await controller.install(), isNull);
      lane.unblock();
      await settled(controller);
      // Two presses, one download: neither the controller nor the lane let the
      // second one reach the system.
      expect(lane.started, hasLength(1));
      expect(controller.installReady, isTrue);
    },
  );

  test('installing a package that already landed costs no bytes', () async {
    controller.offer = release;
    await controller.install();
    await settled(controller);
    expect(controller.installReady, isTrue);

    await controller.install();
    expect(handoffs, hasLength(1));
    // The reuse is said out loud: the file this device already held is what the
    // system was handed, not a fresh copy of it.
    expect(handoffs.single.reused, isTrue);
    expect(handoffs.single.path, stagedFile.path);
    expect(controller.installReady, isFalse);
    expect(lane.started, hasLength(1));
  });

  test(
    'a package the system finished while the app slept becomes a question',
    () async {
      // The process that pressed 立即更新 is gone; only the note and the bytes remain.
      await handOver();
      stagedFile.writeAsBytesSync(fixturePayload);
      final returned = wire();
      returned.offer = release;
      await returned.settleOnReturn();
      expect(returned.installReady, isTrue);
      expect(returned.message, contains('是否安装'));
      expect(lane.started, isEmpty);
      expect(
        (await journal.forTag(release.tag))?.stage,
        UpdatePackageStage.ready,
      );
    },
  );

  test(
    'a transfer the system still owns comes back as a bar, not a button',
    () async {
      await handOver();
      lane.live.add('task-away');
      final returned = wire();
      returned.offer = release;
      await returned.settleOnReturn();
      expect(returned.transferring, isTrue);
      expect(returned.installReady, isFalse);
      expect(returned.message, contains('仍在后台下载'));
      expect(lane.started, isEmpty);
    },
  );

  test('a host with no lane to hand a download over reads no note', () async {
    await handOver();
    // The desktop build has no background lane, so it must not be asked whether a
    // package arrived -- and must not touch the folder either.
    final desk = wire(systemLane: false);
    desk.offer = release;
    await desk.settleOnReturn();
    expect(desk.installReady, isFalse);
    expect(desk.transferring, isFalse);
    expect(desk.message, isNull);
  });

  testWidgets('the dialog says 后台下载 while it runs and 立即安装 when it lands', (
    tester,
  ) async {
    controller.offer = release;
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UpdateDialog(controller: controller, release: release),
        ),
      ),
    );
    // One turn is the real event loop moving the handover along and the fake
    // clock letting the dialog hear about it: the bytes live outside the test's
    // clock, and the sentence they produce lives inside it.
    Future<void> turn() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }

    Future<void> until(bool Function() settled) async {
      for (var i = 0; i < 200 && !settled(); i++) {
        await turn();
      }
    }

    lane.block();
    await tester.tap(find.byKey(const Key('立即更新')));
    await until(() => controller.transferring);
    expect(controller.transferring, isTrue);
    expect(controller.busy, isTrue);
    expect(find.text('正在后台下载…'), findsOneWidget);
    expect(find.textContaining('安装包正在后台下载'), findsOneWidget);

    lane.unblock();
    await until(() => !controller.transferring);
    expect(controller.installReady, isTrue);
    expect(find.text('立即安装'), findsOneWidget);
    expect(find.textContaining('已下载完成'), findsOneWidget);
  });
}
