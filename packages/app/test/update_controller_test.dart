import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/update/update_controller.dart';
import 'package:hongguo_core/hongguo_core.dart';

void main() {
  test('a chunked transfer announces one point at a time, and always lands', () {
    final controller = UpdateController(
      dio: Dio(),
      readSettings: () => const AppSettings(),
      writeSettings: (_) async {},
      stageDirectory: () async => '.',
    );
    var rebuilds = 0;
    controller.addListener(() => rebuilds++);
    // The live macOS installer and the ~5 KB socket chunks it really arrives in.
    const total = 22547501;
    for (var received = 0; received < total; received += 5460) {
      controller.reportProgress(received, total);
    }
    controller.reportProgress(total, total);
    expect(controller.progress, 1.0);
    // Fewer than one rebuild per chunk, and nowhere near none: the first live
    // run compared every chunk with the one before it, so 4,129 of them rebuilt
    // nothing and the dialog ran the whole download without a bar.
    expect(rebuilds, greaterThan(50));
    expect(rebuilds, lessThan(4129));
  });
}
