import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 便携标记。与 EXE 同目录存在时，全部应用数据写进 EXE 旁边的私有目录，
/// 而不是系统 AppData —— Windows 便携 ZIP 解压到 U 盘即可整包搬走。
const portableMarkerName = 'PORTABLE';
const portableDataDirName = 'HongguoData';

/// 只做路径决策，不建目录、不碰文件系统；便于离线单测注入。
({Directory root, bool portable}) resolveDataRoot({
  required String executablePath,
  required bool markerExists,
  required Directory supportDirectory,
}) {
  if (markerExists) {
    final parent = File(executablePath).parent;
    return (
      root: Directory(
        '${parent.path}${Platform.pathSeparator}$portableDataDirName',
      ),
      portable: true,
    );
  }
  return (root: supportDirectory, portable: false);
}

/// 默认实现：Windows/Linux/macOS 都用 EXE 同目录的标记判断。
Future<({Directory root, bool portable})> currentDataRoot() async {
  Directory support;
  try {
    support = await getApplicationSupportDirectory();
  } on MissingPluginException {
    // Widget 测试没有原生 path_provider；落到系统临时目录即可。
    support = Directory.systemTemp;
  }
  final executable = Platform.resolvedExecutable;
  String marker;
  try {
    marker =
        '${File(executable).parent.path}${Platform.pathSeparator}$portableMarkerName';
  } on UnsupportedError {
    marker = '';
  }
  final decision = resolveDataRoot(
    executablePath: executable,
    markerExists: marker.isNotEmpty && File(marker).existsSync(),
    supportDirectory: support,
  );
  // 便携目录不可写（只读介质、权限不足）时退回系统目录，不让 App 起不来。
  if (decision.portable) {
    try {
      await decision.root.create(recursive: true);
    } catch (_) {
      // 别再问一次 plugin：上面的 support 已经是可写目录（或测试回退）。
      return (root: support, portable: false);
    }
  } else {
    await decision.root.create(recursive: true);
  }
  return decision;
}

/// 设置页展示用：当前是便携模式还是系统数据目录。
Future<bool> isPortableMode() async => (await currentDataRoot()).portable;
