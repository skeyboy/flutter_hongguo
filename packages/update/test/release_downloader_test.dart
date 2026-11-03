import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:hongguo_update/hongguo_update.dart';
import 'package:test/test.dart';

/// Serves exactly the URLs a release names and remembers the order they were
/// asked for, so "we never fetched it" is an assertion and not a hope.
class Routed implements HttpClientAdapter {
  Routed(this.routes);
  final Map<String, Uint8List> routes;
  final requested = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri.toString());
    final body = routes[options.uri.toString()];
    if (body == null) return ResponseBody.fromBytes(Uint8List(0), 404);
    return ResponseBody.fromBytes(
      body,
      200,
      headers: {
        Headers.contentLengthHeader: ['${body.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory destination;
  const name = 'Hongguo-0.4.0-linux-x64.deb';
  const url = 'https://github.com/o/r/releases/download/v0.4.0/$name';
  const sumsUrl =
      'https://github.com/o/r/releases/download/v0.4.0/SHA256SUMS.txt';
  final payload = Uint8List.fromList(List.generate(4096, (i) => i % 251));
  final payloadHash = sha256.convert(payload).toString();

  ReleaseAsset asset({
    String? sha256Value,
    String fileName = name,
    String fileUrl = url,
  }) => ReleaseAsset(
    name: fileName,
    bytes: payload.length,
    sha256: sha256Value,
    downloadUrl: fileUrl,
    contentType: 'application/octet-stream',
  );

  ReleaseInfo release({ReleaseAsset? sums}) => ReleaseInfo(
    tag: 'v0.4.0',
    version: ReleaseVersion.tryParse('v0.4.0')!,
    title: 'v0.4.0',
    notes: 'note',
    prerelease: false,
    htmlUrl: 'https://github.com/o/r/releases/tag/v0.4.0',
    publishedAt: DateTime.utc(2026, 10, 29),
    assets: [?sums],
  );

  setUp(
    () => destination = Directory.systemTemp.createTempSync('hongguo-update-'),
  );
  tearDown(() => destination.deleteSync(recursive: true));

  ReleaseDownloader fetcher(Map<String, Uint8List> routes) => ReleaseDownloader(
    dio: Dio()..httpClientAdapter = Routed(routes),
    destination: destination,
  );

  test('a matching hash lands the file and reports what it is', () async {
    final downloader = fetcher({url: payload});
    final progress = <int>[];
    final downloaded = await downloader.fetch(
      asset(sha256Value: payloadHash),
      release(),
      onProgress: (received, total) => progress.add(total),
    );
    expect(downloaded.path, '${destination.path}/$name');
    expect(downloaded.bytes, payload.length);
    expect(downloaded.sha256, payloadHash);
    expect(File(downloaded.path).readAsBytesSync(), payload);
    expect(progress, isNotEmpty);
    expect(
      File('${destination.path}/$name.part').existsSync(),
      isFalse,
      reason: 'the working file must not survive a completed download',
    );
  });

  test('a hash that does not match is deleted, not installed', () async {
    final downloader = fetcher({url: payload});
    await expectLater(
      downloader.fetch(asset(sha256Value: 'f' * 64), release()),
      throwsA(
        isA<UpdateFailure>().having(
          (e) => e.message,
          'message',
          contains('校验值'),
        ),
      ),
    );
    expect(destination.listSync(), isEmpty);
  });

  test('no digest means the release checksums decide', () async {
    final sumsText = utf8.encode('$payloadHash  $name\n');
    final downloader = fetcher({
      url: payload,
      sumsUrl: Uint8List.fromList(sumsText),
    });
    final downloaded = await downloader.fetch(
      asset(),
      release(
        sums: asset(
          fileName: 'SHA256SUMS.txt',
          fileUrl: sumsUrl,
          sha256Value: payloadHash,
        ),
      ),
    );
    expect(downloaded.sha256, payloadHash);
  });

  test('nothing to check against stops before downloading', () async {
    final adapter = Routed({url: payload});
    final downloader = ReleaseDownloader(
      dio: Dio()..httpClientAdapter = adapter,
      destination: destination,
    );
    await expectLater(
      downloader.fetch(asset(), release()),
      throwsA(
        isA<UpdateFailure>().having(
          (e) => e.message,
          'message',
          contains('没有可对照的校验值'),
        ),
      ),
    );
    expect(adapter.requested, isEmpty);
  });

  test('an address off GitHub is not fetched', () async {
    final adapter = Routed({url: payload});
    final downloader = ReleaseDownloader(
      dio: Dio()..httpClientAdapter = adapter,
      destination: destination,
    );
    await expectLater(
      downloader.fetch(
        asset(
          sha256Value: payloadHash,
          fileUrl: 'https://mirror.example.com/$name',
        ),
        release(),
      ),
      throwsA(
        isA<UpdateFailure>().having(
          (e) => e.message,
          'message',
          contains('不是 GitHub'),
        ),
      ),
    );
    expect(adapter.requested, isEmpty);
  });

  test('a name that escapes the folder is refused', () async {
    final downloader = fetcher({url: payload});
    for (final fileName in ['../../.bashrc', r'..\evil.deb', '']) {
      await expectLater(
        downloader.fetch(
          asset(sha256Value: payloadHash, fileName: fileName),
          release(),
        ),
        throwsA(isA<UpdateFailure>()),
        reason: fileName,
      );
    }
    expect(destination.listSync(), isEmpty);
  });

  test('a broken transfer leaves no half file behind', () async {
    final downloader = fetcher({});
    await expectLater(
      downloader.fetch(asset(sha256Value: payloadHash), release()),
      throwsA(
        isA<UpdateFailure>().having(
          (e) => e.message,
          'message',
          contains('没下载完'),
        ),
      ),
    );
    expect(destination.listSync(), isEmpty);
  });

  test(
    'a second publish of the same file replaces the first cleanly',
    () async {
      final downloader = fetcher({url: payload});
      final first = await downloader.fetch(
        asset(sha256Value: payloadHash),
        release(),
      );
      final second = await downloader.fetch(
        asset(sha256Value: payloadHash),
        release(),
      );
      expect(second.path, first.path);
      expect(File(second.path).readAsBytesSync(), payload);
    },
  );

  test('bytes already verified on disk are not fetched again', () async {
    // The duplicate download this guards: press 立即更新, close the app, press
    // again -- the 36 MB was already on the device and checked.
    await fetcher({url: payload})
        .fetch(asset(sha256Value: payloadHash), release());
    final adapter = Routed({url: payload});
    final downloaded = await ReleaseDownloader(
      dio: Dio()..httpClientAdapter = adapter,
      destination: destination,
    ).fetch(asset(sha256Value: payloadHash), release());
    expect(adapter.requested, isEmpty);
    expect(downloaded.reused, isTrue);
    expect(downloaded.sha256, payloadHash);
  });

  test('a truncated leftover is fetched again, not trusted', () async {
    File('${destination.path}/$name')
      ..createSync()
      ..writeAsBytesSync(payload.sublist(0, payload.length - 1));
    final adapter = Routed({url: payload});
    final downloaded = await ReleaseDownloader(
      dio: Dio()..httpClientAdapter = adapter,
      destination: destination,
    ).fetch(asset(sha256Value: payloadHash), release());
    expect(adapter.requested, [url]);
    expect(downloaded.reused, isFalse);
  });

  test('two presses in one frame share a single transfer', () async {
    final downloader = fetcher({url: payload});
    final first = downloader.fetch(asset(sha256Value: payloadHash), release());
    final second = downloader.fetch(asset(sha256Value: payloadHash), release());
    final pair = await Future.wait([first, second]);
    expect(pair[0].path, pair[1].path);
    expect(pair[1].bytes, payload.length);
    final progress = <int>[];
    await downloader.fetch(
      asset(sha256Value: payloadHash),
      release(),
      onProgress: (received, total) => progress.add(received),
    );
    expect(progress, [
      payload.length,
    ], reason: 'a reused file still reports 100%');
  });

  test(
    'a finished transfer leaves nothing in flight for the next press',
    () async {
      final downloader = fetcher({url: payload});
      await expectLater(
        downloader.fetch(asset(sha256Value: 'f' * 64), release()),
        throwsA(isA<UpdateFailure>()),
      );
      final adapter = Routed({url: payload});
      final downloaded = await ReleaseDownloader(
        dio: Dio()..httpClientAdapter = adapter,
        destination: destination,
      ).fetch(asset(sha256Value: payloadHash), release());
      expect(adapter.requested, [url]);
      expect(downloaded.bytes, payload.length);
    },
  );
}
