import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/platform/background/host_policy.dart';
import 'package:hongguo_app/platform/background/native_downloads.dart';
import 'package:hongguo_app/settings/settings_store.dart';
import 'package:hongguo_core/hongguo_core.dart';

class _Vault implements SessionVault {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('only mobile hosts hand transfers to the system lane', () {
    for (final host in const [
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
    ]) {
      debugDefaultTargetPlatformOverride = host;
      expect(useSystemTransferLane(enabled: true), isFalse, reason: '$host');
    }
    for (final host in const [TargetPlatform.android, TargetPlatform.iOS]) {
      debugDefaultTargetPlatformOverride = host;
      expect(useSystemTransferLane(enabled: true), isTrue, reason: '$host');
      expect(useSystemTransferLane(enabled: false), isFalse, reason: '$host');
    }
  });

  test(
    'desktop downloads in app with background downloads switched on',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final payload = List<int>.generate(4096, (index) => index % 251);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var served = 0;
      unawaited(() async {
        await for (final request in server) {
          served++;
          request.response.add(payload);
          await request.response.close();
        }
      }());
      final root = Directory.systemTemp.createTempSync('download-lane-');
      addTearDown(() => root.deleteSync(recursive: true));
      final dio = Dio();
      addTearDown(dio.close);
      final downloads = NativeDownloads(
        () => const AppSettings(backgroundDownloads: true),
        dio,
        vault: _Vault(),
        journalDirectory: root,
      );
      final path = '${root.path}/11_best.mp4.1793000000000000.1.part';
      await downloads.download(
        '11',
        'best',
        VideoTrack(
          url: Uri.parse(
            'http://${server.address.address}:${server.port}/episode.mp4',
          ),
          spadeA: '',
          definition: 'best',
          size: payload.length,
        ),
        path,
        CancelToken(),
        (received, total) {},
      );
      expect(served, 1);
      expect(File(path).readAsBytesSync(), payload);
    },
  );
}
