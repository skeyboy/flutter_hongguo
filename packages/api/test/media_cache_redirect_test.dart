import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_api/hongguo_native_api.dart';
import 'package:test/test.dart';

/// CDN 模拟：首次应答 302，后续应答正片字节。
///
/// 官网直链常态就是这个形状——`v11-hgweb.qznovelvod.com` 先回 302 把请求
/// 甩到另一台边缘机，直接下载不跟随就会拿到一个空 302。
class RedirectingAdapter implements HttpClientAdapter {
  RedirectingAdapter({required this.bytes, this.location});
  final Uint8List bytes;

  /// 首次应答的 Location；null 表示不跳转，直接回字节。
  final String? location;
  final List<String> urls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async {
    urls.add(options.uri.toString());
    if (location != null && urls.length == 1) {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': [location!],
        },
      );
    }
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        Headers.contentLengthHeader: ['${bytes.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Uint8List clear;

  setUpAll(() {
    clear = File('../core/test/fixtures/media/clear.mp4').readAsBytesSync();
  });

  MediaCache cacheWith(Dio dio, Directory temp, VideoTrack track) =>
      MediaCache(directory: temp, dio: dio, resolve: (_, _) async => track);

  VideoTrack webTrack(String url) => VideoTrack(
    url: Uri.parse(url),
    spadeA: '',
    definition: '360p',
    size: 0,
    userAgent: 'Mozilla/5.0 hongguo-desktop',
    referer: 'https://hongguoduanju.com/',
    fromWeb: true,
  );

  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('hongguo-redirect-');
  });
  tearDown(() {
    // 下载线程收尾可能比测试体晚一拍，Windows 不允许删除仍被占用的目录。
    for (var attempt = 0; attempt < 50; attempt++) {
      try {
        temp.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        sleep(const Duration(milliseconds: 20));
      }
    }
  });

  test('官网直链 302 到另一台边缘机时跟随并落盘', () async {
    final adapter = RedirectingAdapter(
      bytes: clear,
      location:
          'https://v3-hgweb.qznovelvod.com/redirected.mp4?br=350&sign=abc',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final cache = cacheWith(
      dio,
      temp,
      webTrack('https://v11-hgweb.qznovelvod.com/play.mp4'),
    );
    addTearDown(() {
      cache.close();
      dio.close(force: true);
    });

    final lease = cache.prepare('123', quality: 'best');
    final file = await lease.result;
    expect(File(file).lengthSync(), clear.length);
    expect(adapter.urls, hasLength(2));
    expect(adapter.urls.last, contains('v3-hgweb.qznovelvod.com'));
    cache.release(lease);
  });

  test('跳转目标不在白名单时拒绝下载，不把任意主机当上游', () async {
    final adapter = RedirectingAdapter(
      bytes: clear,
      location: 'https://evil.example.com/payload.mp4',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final cache = cacheWith(
      dio,
      temp,
      webTrack('https://v11-hgweb.qznovelvod.com/play.mp4'),
    );
    addTearDown(() {
      cache.close();
      dio.close(force: true);
    });

    final lease = cache.prepare('124', quality: 'best');
    await expectLater(lease.result, throwsA(isA<Object>()));
    // 只打了首跳，第二跳在发请求前就被白名单拦下。
    expect(adapter.urls, hasLength(1));
  });

  test('官网层走宽表：bytecdn 这类 CDN 只对 fromWeb 放行', () async {
    final adapter = RedirectingAdapter(bytes: clear);
    final dio = Dio()..httpClientAdapter = adapter;
    final web = cacheWith(
      dio,
      temp,
      webTrack('https://v11-hgweb.bytecdn.cn/play.mp4'),
    );
    addTearDown(() {
      web.close();
      dio.close(force: true);
    });
    final lease = web.prepare('125', quality: 'best');
    expect(File(await lease.result).lengthSync(), clear.length);
    web.release(lease);

    // 同样的域名来自 App 层签名取址就必须拒绝：窄表不放宽。
    final appTemp = Directory.systemTemp.createTempSync('hongguo-redirect-');
    addTearDown(() {
      try {
        appTemp.deleteSync(recursive: true);
      } on FileSystemException {
        /* 收尾竞争，忽略 */
      }
    });
    final app = cacheWith(
      dio,
      appTemp,
      VideoTrack(
        url: Uri.parse('https://v11-hgweb.bytecdn.cn/play.mp4'),
        spadeA: '',
        definition: '720p',
        size: 0,
      ),
    );
    addTearDown(app.close);
    await expectLater(
      app.prepare('126', quality: 'best').result,
      throwsA(isA<Object>()),
    );
  });
}
