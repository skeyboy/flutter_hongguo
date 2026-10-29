import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_update/hongguo_update.dart';
import 'package:test/test.dart';

/// Answers the feed with a pinned body and records what was asked for.
class FeedAdapter implements HttpClientAdapter {
  FeedAdapter({this.status = 200, List<int> body = const [], this.etag})
    : bytes = Uint8List.fromList(body);

  final int status;
  final Uint8List bytes;
  final String? etag;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromBytes(
      bytes,
      status,
      headers: {
        Headers.contentLengthHeader: ['${bytes.length}'],
        if (etag != null) 'etag': [etag!],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  /// The live `GET /repos/skeyboy/flutter_hongguo/releases/latest` body of the
  /// v0.3.13 release, reduced only by per-asset noise keys.
  final fixture =
      (jsonDecode(
            File('test/fixtures/github_release_latest.json').readAsStringSync(),
          ) as Map<String, dynamic>)['response']
          as Map<String, dynamic>;
  final fixtureBytes = Uint8List.fromList(utf8Encode(fixture));

  ReleaseFeed withBody(List<int> body, {int status = 200, String? etag}) {
    final adapter = FeedAdapter(status: status, body: body, etag: etag);
    final dio = Dio()..httpClientAdapter = adapter;
    return ReleaseFeed(dio: dio);
  }

  test('the pinned release parses down to the asset digests', () async {
    final feed = withBody(
      fixtureBytes,
      etag: 'W/"22def166e68d1558954905f76f11cf741f06a788b54f20dda279d63cfa5b9d88"',
    );
    final result = await feed.latest();
    expect(result.status, ReleaseFeedStatus.available);
    final release = result.release!;
    expect(release.tag, 'v0.3.13');
    expect(release.version.versionText, '0.3.13');
    expect(release.prerelease, isFalse);
    expect(release.publishedAt, DateTime.utc(2026, 10, 29, 8, 5, 54));
    expect(release.assets.length, 15);
    // The note really is this long, which is why the dialog has to scroll.
    expect(release.notes.length, 12357);
    expect(
      release.assetNamed('Hongguo-0.3.13-android-arm64-v8a.apk')!.sha256,
      'd0850120f0549656ce2e51eee7dd6cecab39e27f2639797cc041956d29d15294',
    );
    expect(
      release.assetNamed('Hongguo-0.3.13-android-arm64-v8a.apk')!.bytes,
      36447668,
    );
    expect(result.etag, startsWith('W/'));
  });

  test(
    'a stored etag goes back as If-None-Match and a 304 stays cheap',
    () async {
      final adapter = FeedAdapter(status: 304, etag: 'W/"same"');
      final feed = ReleaseFeed(dio: Dio()..httpClientAdapter = adapter);
      final result = await feed.latest(ifNoneMatch: 'W/"same"');
      expect(adapter.requests.single.headers['If-None-Match'], 'W/"same"');
      expect(result.status, ReleaseFeedStatus.notModified);
      expect(result.release, isNull);
      expect(result.etag, 'W/"same"');
    },
  );

  test(
    'the anonymous quota answer reads as a wait, not a failure to update',
    () async {
      final feed = withBody(
        utf8Encode({'message': 'API rate limit exceeded'}),
        status: 403,
      );
      final result = await feed.latest();
      expect(result.status, ReleaseFeedStatus.unavailable);
      expect(result.message, contains('限流'));
    },
  );

  test(
    'an unreadable answer is unavailable, never "already current"',
    () async {
      expect(
        (await withBody(utf8Encode({'assets': 'none'})).latest()).status,
        ReleaseFeedStatus.unavailable,
      );
      expect(
        (await withBody(const <int>[]).latest()).status,
        ReleaseFeedStatus.unavailable,
      );
    },
  );

  test('the token only ever rides along to api.github.com', () async {
    final adapter = FeedAdapter(body: fixtureBytes);
    final feed = ReleaseFeed(
      dio: Dio()..httpClientAdapter = adapter,
      token: 't',
    );
    expect(feed.endpoint.host, 'api.github.com');
    await feed.latest();
    expect(adapter.requests.single.headers['Authorization'], 'Bearer t');
  });
}

List<int> utf8Encode(Object value) => utf8.encode(jsonEncode(value));
