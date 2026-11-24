import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/platform/data_root.dart';

void main() {
  test('无标记时使用系统数据目录', () {
    final support = Directory('/tmp/hongguo-support');
    final result = resolveDataRoot(
      executablePath: r'C:\Apps\Hongguo\hongguo_app.exe',
      markerExists: false,
      supportDirectory: support,
    );
    expect(result.portable, isFalse);
    expect(result.root.path, support.path);
  });

  test('有便携标记时数据落到 EXE 同目录的 HongguoData', () {
    final support = Directory('/tmp/hongguo-support');
    final separator = Platform.pathSeparator;
    final exe =
        '${separator}apps${separator}Hongguo${separator}hongguo_app.exe';
    final result = resolveDataRoot(
      executablePath: exe,
      markerExists: true,
      supportDirectory: support,
    );
    expect(result.portable, isTrue);
    expect(result.root.parent.path, endsWith('Hongguo'));
    expect(result.root.path, endsWith(portableDataDirName));
    expect(result.root.path, isNot(contains('hongguo-support')));
  });

  test('便携标记名固定，安装版打包不会误写', () {
    expect(portableMarkerName, 'PORTABLE');
    expect(portableDataDirName, 'HongguoData');
  });
}
