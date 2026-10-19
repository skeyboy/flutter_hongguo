import 'dart:convert';
import 'dart:typed_data';

class TransportRequest {
  final Uri uri;
  final String method;
  final Map<String, String> headers;
  final Uint8List? body;
  const TransportRequest(
    this.uri, {
    this.method = 'GET',
    this.headers = const {},
    this.body,
  });
}

class TransportResponse {
  final int status;
  final Uint8List body;
  const TransportResponse(this.status, this.body);
  String get text => utf8.decode(body);
  Map<String, dynamic> json() {
    final value = jsonDecode(text);
    if (status < 200 || status >= 300)
      throw StateError(
        value is Map ? '${value['detail'] ?? 'HTTP $status'}' : 'HTTP $status',
      );
    if (value is! Map) throw FormatException('Expected JSON object');
    return Map<String, dynamic>.from(value);
  }
}

abstract interface class Transport {
  Future<TransportResponse> send(TransportRequest request);
}
