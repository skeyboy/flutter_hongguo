// 常驻真网诊断：把「只有前几集能播」排查中散落的临时 probe 收敛成一条命令。
// 从仓库根运行，例如：
//   dart run tool/diagnose_episode.dart boundary 7710254424689495065
//   dart run tool/diagnose_episode.dart vid 7710256242693786648
//   dart run tool/diagnose_episode.dart redirect 7710256263719816254
//
// 只读探测，不写本地文件；失败常用 exit(0) 收尾，避免 Dio 长连接挂住进程。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:dio/dio.dart';
// ignore: depend_on_referenced_packages
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';

const _browserHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
  'Referer': 'https://hongguoduanju.com/',
};

final Dio _dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 10)));

/// 官网 /player/_/{vid} 的限免标记与 fallback 直链状态。
Future<void> probeWeb(String vid) async {
  try {
    final response = await _dio.get<String>(
      'https://hongguoduanju.com/player/_/$vid',
      options: Options(
        headers: _browserHeaders,
        responseType: ResponseType.plain,
        followRedirects: false,
      ),
    );
    final html = response.data ?? '';
    final flags = <String>[];
    for (final key in [
      'accessible_episode_cnt',
      'protectedPlayback',
      'main_url',
      'contentUrl',
    ]) {
      final match = RegExp('"$key"\\s*:\\s*([^,}\\]]+)').firstMatch(html);
      flags.add('$key=${match?.group(1) ?? 'ABSENT'}');
    }
    print('  web page: HTTP ${response.statusCode} ${flags.join(' ')}');
  } on DioException catch (error) {
    print('  web page: HTTP ${error.response?.statusCode} ${error.type}');
  }

  try {
    final response = await _dio.post<String>(
      'https://hongguoduanju.com/api/video/protected/fallback-play-info',
      data: jsonEncode({'item_id': vid}),
      options: Options(
        headers: {..._browserHeaders, 'Content-Type': 'application/json'},
        responseType: ResponseType.plain,
        followRedirects: false,
      ),
    );
    final body = response.data ?? '';
    print(
      '  web fallback: HTTP ${response.statusCode} bytes=${body.length}'
      ' ${body.substring(0, body.length.clamp(0, 80))}',
    );
  } on DioException catch (error) {
    print(
      '  web fallback: HTTP ${error.response?.statusCode}'
      ' bytes=${error.response?.data?.toString().length ?? 0}',
    );
  }
}

/// 官网直链优先 / App 优先两种取源的结果。
Future<void> probeTrack(String vid) async {
  for (final preferApp in [false, true]) {
    try {
      final track = await VideoModelClient(dio: _dio)
          .fetchTrack(vid, preferApp: preferApp);
      print(
        '  track(preferApp=$preferApp): fromWeb=${track.fromWeb}'
        ' host=${track.url.host} encrypted=${track.encrypted}',
      );
    } catch (error) {
      print(
        '  track(preferApp=$preferApp): FAILED'
        ' ${error.runtimeType}: ${error.toString().substring(0, error.toString().length.clamp(0, 120))}',
      );
    }
  }
}

/// App 旧接口 preload/v1 的原始字节数（区分「空包」和「业务码」）。
Future<void> probeLegacy(String vid) async {
  final builder = VideoRequestBuilder();
  final body = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'biz_param': {
          'detail_page_version': 0,
          'device_level': 3,
          'disable_digg_stat': false,
          'need_all_video_definition': true,
          'need_mp4_align': false,
          'use_os_player': false,
          'use_server_dns': false,
          'video_platform': 1024,
        },
        'dr_scene': 'preload',
        'mixed_video_id_map': {
          '1004': [vid],
        },
      }),
    ),
  );
  final url =
      'https://${builder.protocol.videoHost}'
      '/novel/player/multi_video_model/preload/v1/'
      '?_rticket=${builder.clockMillis()}';
  try {
    final response = await _dio.fetch<String>(
      Options(
        method: 'POST',
        headers: {
          'User-Agent': builder.playbackUA,
          'Accept': 'application/json; charset=utf-8,application/x-protobuf',
          'Content-Type': 'application/json; charset=UTF-8',
        },
        responseType: ResponseType.plain,
        followRedirects: false,
        sendTimeout: const Duration(seconds: 6),
        receiveTimeout: const Duration(seconds: 10),
      ).compose(_dio.options, url, data: Stream<Uint8List>.value(body)),
    );
    print(
      '  legacy preload: HTTP ${response.statusCode}'
      ' bytes=${response.data?.length}',
    );
  } on DioException catch (error) {
    print(
      '  legacy preload: HTTP ${error.response?.statusCode}'
      ' bytes=${error.response?.data?.toString().length ?? 0}',
    );
  }
}

/// App 层三台主机轮换，排除单台主机故障。
Future<void> probeHosts(String vid) async {
  for (final host in [
    'api5-normal-sinfonlineb.fqnovel.com',
    'api5-normal-sinfonlinea.fqnovel.com',
    'api5-normal-sinfonlinec.fqnovel.com',
  ]) {
    try {
      final client = VideoModelClient(
        dio: _dio,
        builder: VideoRequestBuilder(protocol: AppSettings(videoHost: host)),
      );
      final track = await client.fetchTrack(vid, preferApp: true);
      print('  host $host: OK fromWeb=${track.fromWeb}');
    } catch (error) {
      print('  host $host: FAILED ${error.runtimeType}');
    }
  }
}

/// 沿 CDN 302 逐跳检查 Location 与白名单归属。
Future<void> probeRedirect(String vid) async {
  final track = await VideoModelClient(dio: _dio).fetchTrack(vid);
  print('  track: fromWeb=${track.fromWeb} host=${track.url.host}');
  final domains = track.fromWeb
      ? const [
          'qznovelvod.com',
          'fqnovelvod.com',
          'douyinvod.com',
          'bytecdn.cn',
          'bytecdn.com',
          'ibytedtos.com',
          'bdcgslb.com',
        ]
      : const ['qznovelvod.com', 'fqnovelvod.com', 'douyinvod.com'];
  var url = track.url;
  for (var hop = 0; hop < 7; hop++) {
    try {
      final response = await _dio.get<List<int>>(
        url.toString(),
        options: Options(
          headers: {'Range': 'bytes=0-0', 'User-Agent': 'Mozilla/5.0'},
          responseType: ResponseType.bytes,
          followRedirects: false,
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      print(
        '  hop$hop: HTTP ${response.statusCode} ${url.host}'
        ' bytes=${response.data?.length}',
      );
      return;
    } on DioException catch (error) {
      final status = error.response?.statusCode ?? 0;
      final location = error.response?.headers.value('location');
      print(
        '  hop$hop: HTTP $status ${url.host} location=${location ?? 'NONE'}',
      );
      if (status != 302 || location == null) return;
      url = url.resolve(location);
      final allowed = domains.any(
        (d) => url.host == d || url.host.endsWith('.$d'),
      );
      print('          -> ${url.host} allowed=$allowed');
      if (!allowed) return;
    }
  }
  print('  超过 7 跳，停止');
}

Future<void> boundary(String seriesId) async {
  final detail = await CatalogClient(
    dio: _dio,
    deviceId: '1234567890123456789',
  ).detail(seriesId);
  final episodes = detail.episodes;
  final accessible = episodes.first.accessibleCount;
  print(
    'title=${detail.drama.title} episodes=${episodes.length}'
    ' accessible_episode_cnt=$accessible',
  );
  final samples = <int>{
    1,
    ?accessible,
    ?(accessible == null ? null : accessible + 1),
    10,
    episodes.length,
  }.where((i) => i > 0 && i <= episodes.length).toList()..sort();
  for (final index in samples) {
    final episode = episodes[index - 1];
    print(
      'EP${episode.index} vid=${episode.vid}'
      ' ${episode.beyondFree ? '限免外' : '限免内'}',
    );
    await probeWeb(episode.vid);
    await probeTrack(episode.vid);
  }
}

Future<void> vidProbe(String vid, {bool full = false}) async {
  print('VID $vid');
  await probeWeb(vid);
  await probeTrack(vid);
  if (full) {
    await probeLegacy(vid);
    await probeHosts(vid);
  }
  await probeRedirect(vid);
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      '用法：dart run tool/diagnose_episode.dart'
      ' <boundary SERIES_ID | vid VID | redirect VID | full VID>',
    );
    exit(2);
  }
  try {
    switch (args.first) {
      case 'boundary':
        await boundary(args[1]);
      case 'vid':
        await vidProbe(args[1]);
      case 'full':
        await vidProbe(args[1], full: true);
      case 'redirect':
        await probeRedirect(args[1]);
      default:
        stderr.writeln('未知子命令：${args.first}');
        exit(2);
    }
  } catch (error) {
    stderr.writeln('诊断失败 ${error.runtimeType}: $error');
    exit(1);
  } finally {
    _dio.close(force: true);
  }
  exit(0);
}
