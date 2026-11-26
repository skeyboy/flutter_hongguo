// 临时诊断探针：用应用同款配置对真实上游跑一遍取址路由梯，
// 打印每条路由的失败诊断。不影响应用行为。
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';

Future<void> main(List<String> args) async {
  final vid = args[0];
  final seriesId = args.length > 1 ? args[1] : null;
  final quality = args.length > 2 ? args[2] : 'best';

  final home = Platform.environment['HOME'];
  final raw = jsonDecode(
    File(
      '$home/Library/Application Support/com.example.hongguoApp/settings.json',
    ).readAsStringSync(),
  ) as Map<String, dynamic>;
  final settings = AppSettings.fromJson(
    Map<String, dynamic>.from(raw['preferences']),
  );
  // 命令行第 4 参传 extended 时启用扩展路由梯（v5 / 老单集 / 官网匿名）。
  final effective = args.contains('extended')
      ? settings.copyWith(playbackRouteSet: PlaybackRouteSet.extended)
      : settings;
  stdout.writeln(
    'settings: videoHost=${effective.videoHost} '
    'videoVersion=${effective.videoVersion}/${effective.videoVersionCode} '
    'routes=${effective.playbackRouteSet} identity=${effective.identityPolicy}',
  );

  final dio = Dio()
    ..options.connectTimeout = Duration(seconds: settings.timeoutSeconds)
    ..options.receiveTimeout = Duration(seconds: settings.timeoutSeconds);
  final devices = PlaybackDeviceRegistry(dio: dio);
  final model = VideoModelClient(
    dio: dio,
    devices: devices,
    builder: VideoRequestBuilder(protocol: effective),
    onRouteFailure: (route, kind) =>
        stdout.writeln('ROUTE-FAIL $route -> $kind'),
    onTiming: (t) =>
        stdout.writeln('TIMING ${t.operation} ${t.elapsed.inMilliseconds}ms'),
  );
  try {
    final track = await model.fetchTrack(
      vid,
      quality: quality,
      seriesId: seriesId,
    );
    stdout.writeln('OK  host=${track.url.host}');
    stdout.writeln('    definition=${track.definition} quality=$quality');
  } on Object catch (error) {
    stdout.writeln('FAILED ${error.runtimeType}');
  } finally {
    model.close();
    dio.close(force: true);
  }
  exit(0);
}
