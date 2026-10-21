import 'dart:convert';
import 'dart:io';

import 'package:hongguo_cast/hongguo_cast.dart';
import 'package:test/test.dart';

void main() {
  group('lan media server', () {
    late Directory root;
    late File media;
    late LanMediaServer server;
    late HttpClient client;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('hongguo-cast');
      media = File('${root.path}/episode.mp4');
      await media.writeAsBytes(
        utf8.encode('0123456789abcdefghijklmnopqrstuvwxyz'),
      );
      server = await LanMediaServer.bind(
        host: InternetAddress.loopbackIPv4.address,
        address: InternetAddress.loopbackIPv4,
      );
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.close();
      await root.delete(recursive: true);
    });

    Future<HttpClientResponse> send(
      String path, {
      String method = 'GET',
      Map<String, String>? headers,
    }) async {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${server.port}$path'),
      );
      headers?.forEach((key, value) => request.headers.set(key, value));
      return request.close();
    }

    test('publishes a cached file under a loopback url', () async {
      final lease = await server.publish(media, title: '第一集');
      expect(
        lease.uri.toString(),
        'http://127.0.0.1:${server.port}/media/${lease.id}',
      );
      expect(lease.sizeBytes, 36);
      expect(lease.title, '第一集');
    });

    test('refuses a file that is not on disk', () async {
      await expectLater(
        server.publish(File('${root.path}/missing.mp4')),
        throwsA(isA<UpnpException>()),
      );
    });

    test('serves the whole body with range support advertised', () async {
      final lease = await server.publish(media);
      final response = await send(lease.uri.path);
      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
      expect(response.headers.contentType?.mimeType, 'video/mp4');
      expect(await response.transform(utf8.decoder).join(), startsWith('0123'));
    });

    test('answers a byte window so a tv can seek', () async {
      final lease = await server.publish(media);
      final response = await send(
        lease.uri.path,
        headers: {'range': 'bytes=10-19'},
      );
      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 10-19/36',
      );
      expect(response.contentLength, 10);
      final body = await response.transform(utf8.decoder).join();
      expect(body, 'abcdefghij');
    });

    test('serves an open-ended window to the end of the file', () async {
      final lease = await server.publish(media);
      final response = await send(
        lease.uri.path,
        headers: {'range': 'bytes=30-'},
      );
      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.contentLength, 6);
      expect(await response.transform(utf8.decoder).join(), 'uvwxyz');
    });

    test('clamps a window that runs past the end', () async {
      final lease = await server.publish(media);
      final response = await send(
        lease.uri.path,
        headers: {'range': 'bytes=33-9999'},
      );
      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 33-35/36',
      );
      expect(await response.transform(utf8.decoder).join(), 'xyz');
    });

    test('rejects a start beyond the file', () async {
      final lease = await server.publish(media);
      final response = await send(
        lease.uri.path,
        headers: {'range': 'bytes=100-200'},
      );
      expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
      expect(response.headers.value(HttpHeaders.contentRangeHeader), '*/36');
      await response.drain<void>();
    });

    test('answers head with length only', () async {
      final lease = await server.publish(media);
      final response = await send(lease.uri.path, method: 'HEAD');
      expect(response.statusCode, HttpStatus.ok);
      expect(response.contentLength, 36);
      await response.drain<void>();
    });

    test('treats an unparsable range as a full read', () async {
      final lease = await server.publish(media);
      final response = await send(
        lease.uri.path,
        headers: {'range': 'bytes=abc'},
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(response.contentLength, 36);
      await response.drain<void>();
    });

    test('revoking a lease 404s immediately', () async {
      final lease = await server.publish(media);
      server.revoke(lease.id);
      final response = await send(lease.uri.path);
      expect(response.statusCode, HttpStatus.notFound);
      await response.drain<void>();
    });

    test('404s when the file is evicted from the cache', () async {
      final lease = await server.publish(media);
      await media.delete();
      final response = await send(lease.uri.path);
      expect(response.statusCode, HttpStatus.notFound);
      await response.drain<void>();
    });

    test('404s an unknown path', () async {
      final response = await send('/media/nope');
      expect(response.statusCode, HttpStatus.notFound);
      await response.drain<void>();
    });
  });
}
