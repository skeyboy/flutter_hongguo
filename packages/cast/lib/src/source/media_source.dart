import 'dart:io';

import '../upnp_exception.dart';

/// A cached file exposed to renderers under an opaque path token.
class MediaLease {
  const MediaLease({
    required this.id,
    required this.file,
    required this.uri,
    required this.mimeType,
    required this.sizeBytes,
    this.title,
  });

  final String id;
  final File file;
  final Uri uri;
  final String mimeType;
  final int sizeBytes;
  final String? title;
}

/// Serves already-downloaded plain files to devices on the same LAN.
///
/// A renderer fetches the media itself, so the phone has to become the origin.
/// HEAD and `Range` are not optional: TVs probe the length before buffering and
/// seek by re-requesting a byte window rather than by using `ByteRange`.
class LanMediaServer {
  LanMediaServer._(this._server, this._host);

  final HttpServer _server;
  final String _host;
  final Map<String, MediaLease> _leases = {};
  String? _lastError;
  int _sequence = 0;

  int get port => _server.port;

  /// Set when the request stream itself failed, e.g. a renderer hung up
  /// mid-buffer. Responses to individual clients are unaffected.
  String? get lastError => _lastError;

  static Future<LanMediaServer> bind({
    String? host,
    int port = 0,
    InternetAddress? address,
  }) async {
    final server = await HttpServer.bind(
      address ?? InternetAddress.anyIPv4,
      port,
    );
    final instance = LanMediaServer._(server, host ?? await lanAddress());
    server.listen(
      instance._handleRequest,
      onError: (Object error) => instance._lastError = 'Media server: $error',
      cancelOnError: false,
    );
    return instance;
  }

  Future<MediaLease> publish(
    File file, {
    String mimeType = 'video/mp4',
    String? title,
  }) async {
    if (!file.existsSync()) {
      throw UpnpException('Nothing cached at ${file.path}');
    }
    final id = 'm${++_sequence}';
    final lease = MediaLease(
      id: id,
      file: file,
      uri: Uri(
        scheme: 'http',
        host: _host,
        port: _server.port,
        path: '/media/$id',
      ),
      mimeType: mimeType,
      sizeBytes: file.lengthSync(),
      title: title,
    );
    _leases[id] = lease;
    return lease;
  }

  void revoke(String id) => _leases.remove(id);

  Future<void> close() async {
    _leases.clear();
    await _server.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    final lease = _leaseFor(request.uri.path);
    if (lease == null || !lease.file.existsSync()) {
      response
        ..contentLength = 0
        ..statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final length = lease.file.lengthSync();
    final range = _parseRange(
      request.headers.value(HttpHeaders.rangeHeader),
      length,
    );
    if (range.rejected) {
      response
        ..contentLength = 0
        ..headers.set(HttpHeaders.contentRangeHeader, '*/$length')
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await response.close();
      return;
    }
    response
      ..headers.contentType = ContentType.parse(lease.mimeType)
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..contentLength = range.end - range.start + 1
      ..statusCode = range.isWholeFile(length)
          ? HttpStatus.ok
          : HttpStatus.partialContent;
    if (response.statusCode == HttpStatus.partialContent) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${range.start}-${range.end}/$length',
      );
    }
    if (request.method == 'HEAD' || length == 0) {
      await response.close();
      return;
    }
    await response.addStream(lease.file.openRead(range.start, range.end + 1));
    await response.close();
  }

  MediaLease? _leaseFor(String path) {
    const prefix = '/media/';
    if (!path.startsWith(prefix)) return null;
    return _leases[path.substring(prefix.length)];
  }
}

/// The address a renderer on the same Wi-Fi network can reach us on.
///
/// Loopback and link-local answers are useless — the TV is another host — so
/// only private site-local IPv4 addresses qualify.
Future<String> lanAddress() async {
  for (final interface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLinkLocal: false,
    includeLoopback: false,
  )) {
    for (final address in interface.addresses) {
      if (isPrivateIpv4(address.address)) return address.address;
    }
  }
  throw UpnpException('No private Wi-Fi address; is the device on a LAN?');
}

bool isPrivateIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return false;
  final parsed = parts.map(int.tryParse).toList();
  if (parsed.any((part) => part == null)) return false;
  final octets = parsed.cast<int>();
  if (octets[0] == 10) return true;
  if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) return true;
  return octets[0] == 192 && octets[1] == 168;
}

class _Range {
  const _Range(this.start, this.end) : rejected = false;
  const _Range.reject() : start = 0, end = 0, rejected = true;

  final int start;
  final int end;
  final bool rejected;

  bool isWholeFile(int length) => start == 0 && end == length - 1;
}

/// A header we cannot make sense of is served as a full body rather than a
/// 416, which is what RFC 7233 asks of a recipient-side parse failure.
_Range _parseRange(String? header, int length) {
  final whole = _Range(0, length - 1);
  if (header == null || header.isEmpty) return whole;
  const prefix = 'bytes=';
  if (!header.startsWith(prefix)) return whole;
  final clause = header.substring(prefix.length).split(',').first.trim();
  final dash = clause.indexOf('-');
  if (dash < 0) return whole;
  final rawStart = clause.substring(0, dash).trim();
  final rawEnd = clause.substring(dash + 1).trim();
  if (rawStart.isEmpty) {
    final suffix = int.tryParse(rawEnd);
    if (suffix == null || suffix <= 0 || length == 0) {
      return const _Range.reject();
    }
    return _Range(suffix > length ? 0 : length - suffix, length - 1);
  }
  final start = int.tryParse(rawStart);
  if (start == null || length == 0) return const _Range.reject();
  var end = rawEnd.isEmpty ? length - 1 : (int.tryParse(rawEnd) ?? length - 1);
  if (end >= length) end = length - 1;
  if (start >= length || start > end) return const _Range.reject();
  return _Range(start, end);
}
