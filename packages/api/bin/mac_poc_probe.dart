/// Explicit, opt-in live single-episode POC. Never run by verify_all.sh.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_api/hongguo_native_api.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    throw ArgumentError(
      'Pass an output directory; add --prepare for one episode',
    );
  }
  final root = Directory(args.first).absolute;
  await root.create(recursive: true);
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'nativeDart': true,
    'localServerUsed': false,
    'steps': <Map<String, dynamic>>[],
  };
  final steps = report['steps'] as List<Map<String, dynamic>>;
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15)));
  final identity = File('${root.path}/device-id.txt');
  var id = identity.existsSync() ? identity.readAsStringSync().trim() : '';
  if (!RegExp(r'^\d{10,20}$').hasMatch(id)) {
    id = newCatalogDeviceId();
    identity.writeAsStringSync(id);
  }
  final catalog = CatalogClient(dio: dio, deviceId: id);
  String stage = 'catalog';
  try {
    var page = await catalog.browse();
    steps.add({'stage': 'catalog', 'items': page.items.length});
    if (page.items.isEmpty) {
      stage = 'search';
      page = await catalog.search('重生');
      steps.add({'stage': 'search', 'items': page.items.length});
    }
    if (page.items.isEmpty) {
      throw StateError('No real series available from catalog/search');
    }
    final drama = page.items.first;
    stage = 'episodes';
    final detail = await catalog.detail(drama.id);
    if (detail.episodes.isEmpty) throw StateError('No episodes');
    final episode = detail.episodes.first;
    report['selection'] = {
      'seriesId': drama.id,
      'title': drama.title,
      'vid': episode.vid,
      'index': episode.index,
    };
    steps.add({'stage': 'episodes', 'count': detail.episodes.length});
    stage = 'video_model';
    final track = await VideoModelClient(dio: dio).fetchTrack(episode.vid);
    steps.add({
      'stage': 'video_model',
      // 三层取源里到底哪一层答的，是这次切换最需要现场确认的事：
      // fromWeb=true 说明官网直链层生效（明文 MP4 + 桌面 UA），
      // false 说明退到了 App 签名层或旧接口，encrypted 再细分后两者。
      'fromWeb': track.fromWeb,
      'encrypted': track.encrypted,
      'host': track.url.host,
      'scheme': track.url.scheme,
      'definition': track.definition,
      'size': track.size,
      'hasUserAgent': track.userAgent.isNotEmpty,
      'hasReferer': track.referer.isNotEmpty,
    });
    if (args.contains('--prepare')) {
      stage = 'prepare';
      final cache = MediaCache(
        directory: Directory('${root.path}/media'),
        dio: dio,
        resolve: (_, _) async => track,
      );
      String? last;
      final lease = cache.prepare(
        episode.vid,
        onProgress: (p) {
          if (last != p.stage.name) {
            last = p.stage.name;
            stdout.writeln('stage=$last');
          }
        },
      );
      final file = await lease.result;
      report['localFile'] = file;
      steps.add({'stage': 'prepare', 'bytes': File(file).lengthSync()});
      cache.release(lease);
    }
    report['ok'] = true;
  } catch (e) {
    report['ok'] = false;
    report['failedStage'] = stage;
    report['error'] = e is DioException ? '${e.type.name}: ${e.message}' : '$e';
    exitCode = 1;
  } finally {
    dio.close(force: true);
    File('${root.path}/live-probe.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(report)}\n',
    );
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  }
}
