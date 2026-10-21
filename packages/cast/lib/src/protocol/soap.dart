import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import '../upnp_exception.dart';

/// Sends one SOAP envelope and answers with the raw response body.
typedef SoapPoster = Future<String> Function(
  Uri controlUrl,
  Map<String, String> headers,
  String envelope,
);

class SoapService {
  SoapService({
    required this.serviceType,
    required this.controlUrl,
    SoapPoster? post,
    this.timeout = const Duration(seconds: 8),
  }) : _post = post ?? _httpPoster;

  final String serviceType;
  final Uri controlUrl;
  final Duration timeout;
  final SoapPoster _post;

  Future<Map<String, String>> call(
    String action, {
    Map<String, String> arguments = const {},
    Iterable<String> returns = const [],
  }) async {
    final envelope = buildEnvelope(
      serviceType: serviceType,
      action: action,
      arguments: arguments,
    );
    final body = await _post(controlUrl, {
      'content-type': 'text/xml; charset="utf-8"',
      'soapaction': '"$serviceType#$action"',
    }, envelope);
    return readResponse(body: body, action: action, returns: returns);
  }
}

String buildEnvelope({
  required String serviceType,
  required String action,
  Map<String, String> arguments = const {},
}) {
  final buffer = StringBuffer()
    ..write('<?xml version="1.0" encoding="utf-8"?>')
    ..write(
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">',
    )
    ..write('<s:Body><u:$action xmlns:u="$serviceType">');
  arguments.forEach((key, value) {
    buffer.write('<$key>${escape(value)}</$key>');
  });
  return (buffer..write('</u:$action></s:Body></s:Envelope>')).toString();
}

Map<String, String> readResponse({
  required String body,
  required String action,
  Iterable<String> returns = const [],
}) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(body);
  } catch (error) {
    throw UpnpException('$action answered with unreadable XML: $error');
  }
  for (final element in document.descendantElements) {
    if (element.name.local == 'Fault') {
      final detail = element.descendantElements
          .map((node) => node.innerText.trim())
          .where((text) => text.isNotEmpty)
          .join(' ');
      throw UpnpException(
        '$action failed: ${detail.isEmpty ? 'SOAP fault' : detail}',
      );
    }
  }
  final result = <String, String>{};
  for (final element in document.descendantElements) {
    if (element.name.local != '${action}Response') continue;
    for (final child in element.childElements) {
      if (returns.contains(child.name.local)) {
        result[child.name.local] = child.innerText.trim();
      }
    }
  }
  return result;
}

String escape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

Future<String> _httpPoster(
  Uri controlUrl,
  Map<String, String> headers,
  String envelope,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.postUrl(controlUrl);
    headers.forEach((key, value) => request.headers.set(key, value));
    request.write(envelope);
    final response = await request.close();
    // Renderers answer SOAP faults with 500; the body carries the reason.
    return await response.transform(utf8.decoder).join();
  } on SocketException catch (error) {
    throw UpnpException('Cannot reach $controlUrl: ${error.osError ?? error}');
  } finally {
    client.close(force: true);
  }
}
