import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart' as bg;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/update/update_transfer.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_update/hongguo_update.dart';

import 'update_fixture.dart';

/// The system lane as a notebook: it records the tasks it was handed, answers the
/// two questions the app asks it, and leaves whatever bytes it was told to leave
/// behind. No plugin, no notification, no phone.
class _FakeEngine implements InstallerEngine {
  _FakeEngine(this.directory);

  /// Where a finished transfer puts its file, so the lane can check bytes it never
  /// fetched itself.
  final String directory;

  final started = <bg.DownloadTask>[];
  final abandoned = <String>[];
  final live = <String>{};

  /// What the transfer lands on disk: the real bytes, corrupt ones, or none.
  Uint8List? Function() bytes = () => fixturePayload;

  /// Tasks the viewer (or a previous process) says are still running.
  void hold(String taskId) => live.add(taskId);

  /// Freezes a handover mid-transfer, so a second press arrives while this
  /// process is still waiting on the first one.
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

/// An address that answers 404, so 「nothing was fetched」 is a measurement: the
/// in-app lane goes through Dio, and a suite must not reach GitHub.
class _Refused implements HttpClientAdapter {
  final asked = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async {
    asked.add(options.uri.toString());
    return ResponseBody.fromBytes(Uint8List(0), 404);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory stage;
  late _FakeEngine engine;
  late UpdateJournal journal;
  late _Refused transport;
  late UpdateTransferLane lane;
  late File note;

  /// A lane wired to the system transfer lane, which is what this file is about.
  /// The policy is host-dependent, so it is supplied rather than derived.
  void wire({bool systemLane = true}) {
    engine = _FakeEngine(stage.path);
    journal = UpdateJournal(stageDirectory: () async => stage.path);
    transport = _Refused();
    lane = UpdateTransferLane(
      journal: journal,
      settings: () => const AppSettings(backgroundDownloads: true),
      dio: Dio()..httpClientAdapter = transport,
      packageDirectory: () async => stage.path,
      packagePath: 'updates',
      engine: engine,
      systemLaneAllowed: systemLane ? () => true : () => false,
    );
    note = File(
      '${stage.path}${Platform.pathSeparator}${UpdateJournal.fileName}',
    );
  }

  setUp(() async {
    stage = await Directory.systemTemp.createTemp('hongguo-update-transfer');
    wire();
  });
  tearDown(() async {
    if (stage.existsSync()) await stage.delete(recursive: true);
  });

  File staged({String name = fixtureApkName}) =>
      File('${stage.path}${Platform.pathSeparator}$name');

  Future<void> writeStaged({
    String name = fixtureApkName,
    Uint8List? bytes,
  }) async {
    await staged(name: name).writeAsBytes(bytes ?? fixturePayload);
  }

  group('the note', () {
    test('a record survives the process that wrote it', () async {
      await journal.put(
        UpdatePackageRecord(
          tag: 'v9.9.9',
          name: fixtureApkName,
          path: staged().path,
          downloadUrl: fixtureDownloadUrl,
          bytes: fixturePayload.length,
          sha256: fixtureDigest,
          stage: UpdatePackageStage.transferring,
          taskId: 'task-1',
        ),
      );
      final read = await journal.forTag('v9.9.9');
      expect(read?.taskId, 'task-1');
      expect(read?.stage, UpdatePackageStage.transferring);
      expect(read?.sha256, fixtureDigest);
      expect(await journal.forTag('v1.0.0'), isNull);
    });

    test(
      'one tag is written once, and a note nobody can parse is nothing owed',
      () async {
        final base = UpdatePackageRecord(
          tag: 'v9.9.9',
          name: fixtureApkName,
          path: staged().path,
          downloadUrl: fixtureDownloadUrl,
          bytes: fixturePayload.length,
          sha256: fixtureDigest,
          stage: UpdatePackageStage.transferring,
        );
        await journal.put(base.copyWith(taskId: 'first'));
        await journal.put(base.copyWith(taskId: 'second'));
        expect(await journal.records(), hasLength(1));
        expect((await journal.forTag('v9.9.9'))?.taskId, 'second');
        note.writeAsStringSync('{"not": "a list"}');
        expect(await journal.records(), isEmpty);
      },
    );

    test('a superseded release loses its note and its bytes', () async {
      // The keep limit is not decoration: two installers in private storage is
      // ~70 MB the app has no reason to hold on to.
      for (final tag in ['v1.0.0', 'v2.0.0', 'v3.0.0']) {
        final name = 'Hongguo-${tag.substring(1)}-android-arm64-v8a.apk';
        await writeStaged(name: name);
        await journal.put(
          UpdatePackageRecord(
            tag: tag,
            name: name,
            path: staged(name: name).path,
            downloadUrl: fixtureDownloadUrl,
            bytes: fixturePayload.length,
            sha256: fixtureDigest,
            stage: UpdatePackageStage.ready,
          ),
        );
      }
      expect((await journal.records()).map((r) => r.tag), ['v2.0.0', 'v3.0.0']);
      expect(
        staged(name: 'Hongguo-1.0.0-android-arm64-v8a.apk').existsSync(),
        isFalse,
      );
      expect(
        staged(name: 'Hongguo-3.0.0-android-arm64-v8a.apk').existsSync(),
        isTrue,
      );
    });

    test('dropping a tag deletes the file it named', () async {
      await writeStaged();
      await journal.put(
        UpdatePackageRecord(
          tag: 'v9.9.9',
          name: fixtureApkName,
          path: staged().path,
          downloadUrl: fixtureDownloadUrl,
          bytes: fixturePayload.length,
          sha256: fixtureDigest,
          stage: UpdatePackageStage.ready,
        ),
      );
      await journal.drop('v9.9.9');
      expect(await journal.forTag('v9.9.9'), isNull);
      expect(staged().existsSync(), isFalse);
    });

    test('a name with a separator in it is not a record', () async {
      // The path a record names is what an install is opened on, so a note from a
      // tampered file may not point anywhere outside the stage folder.
      note.writeAsStringSync(
        jsonEncode([
          {
            'tag': 'v9.9.9',
            'name': '../../.bashrc',
            'path': '/tmp/x',
            'url': fixtureDownloadUrl,
            'bytes': 1,
            'sha256': fixtureDigest,
            'stage': 'ready',
            'taskId': '',
          },
        ]),
      );
      expect(await journal.records(), isEmpty);
    });
  });

  group('the system lane', () {
    test('a transfer is handed over once and checked afterwards', () async {
      final file = await lane.fetch(fixtureAsset(), fixtureRelease());
      expect(engine.started, hasLength(1));
      expect(engine.started.single.filename, fixtureApkName);
      expect(engine.started.single.group, 'hongguo-update');
      expect(engine.started.single.directory, 'updates');
      expect(file.path, staged().path);
      expect(file.sha256, fixtureDigest);
      expect(file.reused, isFalse);
      // Nothing in this process fetched the bytes, so the note is what says they
      // belong to this release -- and that they arrived whole.
      expect((await journal.forTag('v9.9.9'))?.stage, UpdatePackageStage.ready);
      expect((await journal.forTag('v9.9.9'))?.taskId, isNotEmpty);
      expect(transport.asked, isEmpty);
    });

    test('bytes already on the device start no transfer', () async {
      await writeStaged();
      final file = await lane.fetch(fixtureAsset(), fixtureRelease());
      expect(engine.started, isEmpty);
      expect(file.reused, isTrue);
      expect((await journal.forTag('v9.9.9'))?.stage, UpdatePackageStage.ready);
    });

    test('a second press while this process waits on the system gets words, not bytes', () async {
      // The duplicate download this guards: two presses, one transfer. The
      // first handover has not returned yet when the second press arrives, so
      // the disk note -- written by that same first press -- is not what stops it.
      engine.block();
      final first = lane.fetch(fixtureAsset(), fixtureRelease());
      final second = lane.fetch(fixtureAsset(), fixtureRelease());
      await expectLater(
        second,
        throwsA(
          isA<UpdateFailure>().having(
            (e) => e.message,
            'message',
            contains('不需要重复下载'),
          ),
        ),
      );
      engine.unblock();
      expect(await first, isA<DownloadedRelease>());
      // One press, one task: the second never reached the system at all.
      expect(engine.started, hasLength(1));
    });

    test(
      'a transfer an earlier process handed over starts no second task',
      () async {
        // The other half: this process never pressed anything -- the app was killed
        // and reopened while the system kept filling the file. Only the note says so.
        await journal.put(
          UpdatePackageRecord(
            tag: 'v9.9.9',
            name: fixtureApkName,
            path: staged().path,
            downloadUrl: fixtureDownloadUrl,
            bytes: fixturePayload.length,
            sha256: fixtureDigest,
            stage: UpdatePackageStage.transferring,
            taskId: 'held-task',
          ),
        );
        engine.hold('held-task');
        await expectLater(
          lane.fetch(fixtureAsset(), fixtureRelease()),
          throwsA(
            isA<UpdateFailure>().having(
              (e) => e.message,
              'message',
              contains('不需要重复下载'),
            ),
          ),
        );
        expect(engine.started, isEmpty);
      },
    );

    test(
      'a transfer that delivered nothing is not promised as a package',
      () async {
        engine.bytes = () => null;
        await expectLater(
          lane.fetch(fixtureAsset(), fixtureRelease()),
          throwsA(
            isA<UpdateFailure>().having(
              (e) => e.message,
              'message',
              contains('没下载完'),
            ),
          ),
        );
        expect(await journal.forTag('v9.9.9'), isNull);
      },
    );

    test(
      'bytes that do not match are deleted, and the note goes with them',
      () async {
        engine.bytes = () => fixtureWrongPayload;
        await expectLater(
          lane.fetch(fixtureAsset(), fixtureRelease()),
          throwsA(
            isA<UpdateFailure>().having(
              (e) => e.message,
              'message',
              contains('校验值'),
            ),
          ),
        );
        expect(staged().existsSync(), isFalse);
        expect(await journal.forTag('v9.9.9'), isNull);
      },
    );

    test('a package the system finished while the app slept is adopted', () async {
      // The handover, then the process dies: only the note and the file remain.
      await journal.put(
        UpdatePackageRecord(
          tag: 'v9.9.9',
          name: fixtureApkName,
          path: staged().path,
          downloadUrl: fixtureDownloadUrl,
          bytes: fixturePayload.length,
          sha256: fixtureDigest,
          stage: UpdatePackageStage.transferring,
          taskId: 'task-away',
        ),
      );
      expect(await lane.settle('v9.9.9'), isNull, reason: 'not on disk yet');
      await writeStaged();
      final settled = await lane.settle('v9.9.9');
      expect(settled?.path, staged().path);
      expect(settled?.reused, isTrue);
      expect((await journal.forTag('v9.9.9'))?.stage, UpdatePackageStage.ready);
      expect(engine.started, isEmpty);
      // And the press that follows installs those bytes instead of fetching them.
      await lane.fetch(fixtureAsset(), fixtureRelease());
      expect(engine.started, isEmpty);
      expect(transport.asked, isEmpty);
    });

    test('a ready note whose file is gone is not promised again', () async {
      await lane.fetch(fixtureAsset(), fixtureRelease());
      staged().deleteSync();
      expect(await lane.settle('v9.9.9'), isNull);
      expect(await journal.forTag('v9.9.9'), isNull);
    });

    test('a note still being filled keeps its bytes and its task', () async {
      engine.hold('held-task');
      await journal.put(
        UpdatePackageRecord(
          tag: 'v9.9.9',
          name: fixtureApkName,
          path: staged().path,
          downloadUrl: fixtureDownloadUrl,
          bytes: fixturePayload.length,
          sha256: fixtureDigest,
          stage: UpdatePackageStage.transferring,
          taskId: 'held-task',
        ),
      );
      expect(await lane.isTransferring('v9.9.9'), isTrue);
      expect(await lane.settle('v9.9.9'), isNull);
      // The bytes are legitimately not there yet, so a transfer the system still
      // owns keeps its note: dropping it would be a promise to re-download.
      expect((await journal.forTag('v9.9.9'))?.taskId, 'held-task');
      expect(staged().existsSync(), isFalse);
    });

    test('cancel stops the system and forgets the package', () async {
      engine.hold('soon');
      await journal.put(
        UpdatePackageRecord(
          tag: 'v9.9.9',
          name: fixtureApkName,
          path: staged().path,
          downloadUrl: fixtureDownloadUrl,
          bytes: fixturePayload.length,
          sha256: fixtureDigest,
          stage: UpdatePackageStage.transferring,
          taskId: 'soon',
        ),
      );
      await lane.cancel('v9.9.9');
      expect(engine.abandoned, ['soon']);
      expect(await journal.forTag('v9.9.9'), isNull);
      expect(await lane.isTransferring('v9.9.9'), isFalse);
    });
  });

  group('the in-app lane', () {
    test(
      'a host with no system lane keeps its download in this process',
      () async {
        wire(systemLane: false);
        await expectLater(
          lane.fetch(fixtureAsset(), fixtureRelease()),
          throwsA(isA<UpdateFailure>()),
        );
        expect(engine.started, isEmpty);
        expect(transport.asked, [fixtureDownloadUrl]);
        // No note: a transfer this process runs and reports on itself owes nobody a
        // promise for the next launch.
        expect(note.existsSync(), isFalse);
      },
    );

    test('the viewer’s own switch is what closes the lane', () async {
      lane = UpdateTransferLane(
        journal: journal,
        settings: () => const AppSettings(backgroundDownloads: false),
        dio: Dio()..httpClientAdapter = transport,
        packageDirectory: () async => stage.path,
        packagePath: 'updates',
        engine: engine,
      );
      expect(lane.usesSystemLane, isFalse);
    });
  });
}
