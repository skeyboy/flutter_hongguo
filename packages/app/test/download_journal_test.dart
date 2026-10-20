import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_app/platform/background/native_downloads.dart';
import 'package:hongguo_app/settings/settings_store.dart';

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
  test(
    'cancelled attempt cleanup cannot delete a resumed attempt journal or key',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'download-journal-test-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final dio = Dio();
      addTearDown(dio.close);
      final vault = _Vault()..values['hongguo.download.new'] = 'fixture';
      final journal = File('${root.path}/11_best.json');
      await journal.writeAsString(
        jsonEncode({
          'filename': '11_best.mp4.new.part',
          'keyRef': 'hongguo.download.new',
          'taskId': 'new',
        }),
      );
      final downloads = NativeDownloads(
        () => const AppSettings(),
        dio,
        vault: vault,
        journalDirectory: root,
      );
      await downloads.finish(
        '11',
        'best',
        workingPath: '${root.path}/11_best.mp4.old.part',
      );
      expect(await journal.exists(), isTrue);
      expect(vault.values['hongguo.download.new'], 'fixture');
      await downloads.finish(
        '11',
        'best',
        workingPath: '${root.path}/11_best.mp4.new.part',
      );
      expect(await journal.exists(), isFalse);
      expect(vault.values, isEmpty);
    },
  );
}
