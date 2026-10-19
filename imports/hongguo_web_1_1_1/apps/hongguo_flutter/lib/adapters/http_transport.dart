import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:hongguo_core/hongguo_core.dart';

class HttpTransport implements Transport {
  final http.Client _client = http.Client();
  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final r = http.Request(request.method, request.uri)
      ..followRedirects = false;
    r.headers.addAll(request.headers);
    if (request.body != null) r.bodyBytes = request.body!;
    return (() async {
      final response = await _client.send(r);
      final builder = BytesBuilder();
      await for (final chunk in response.stream) {
        if (builder.length + chunk.length > 8 * 1024 * 1024) {
          throw StateError('元数据响应超过 8 MiB');
        }
        builder.add(chunk);
      }
      return TransportResponse(response.statusCode, builder.takeBytes());
    })().timeout(const Duration(seconds: 30));
  }

  void close() => _client.close();
}
