import 'dart:async';
import 'dart:convert';
import 'dart:io';

const mediaRendererTarget = 'urn:schemas-upnp-org:device:MediaRenderer:1';

/// One device answer to an SSDP search, keyed by its description location.
class SsdpHit {
  const SsdpHit({
    required this.usn,
    required this.location,
    required this.searchTarget,
    required this.cacheSeconds,
  });

  final String usn;
  final Uri location;
  final String searchTarget;
  final int cacheSeconds;

  @override
  String toString() =>
      'SsdpHit($location, $searchTarget, ttl=${cacheSeconds}s)';
}

/// Parses an SSDP HTTP response. Returns null for anything that is not a
/// well-formed advertisement, including our own outbound M-SEARCH.
SsdpHit? parseSsdpResponse(String message) {
  final headers = <String, String>{};
  var isFirstLine = true;
  for (final line in const LineSplitter().convert(message)) {
    if (isFirstLine) {
      if (!line.startsWith('HTTP/1.')) return null;
      isFirstLine = false;
      continue;
    }
    final separator = line.indexOf(':');
    if (separator <= 0) continue;
    headers[line.substring(0, separator).trim().toLowerCase()] = line
        .substring(separator + 1)
        .trim();
  }
  final raw = headers['location'];
  if (raw == null || raw.isEmpty) return null;
  Uri location;
  try {
    location = Uri.parse(raw);
  } on FormatException {
    return null;
  }
  // Relative or non-HTTP answers appear on some firmwares; they cannot be
  // fetched, so treat them as noise rather than a device.
  if (location.scheme != 'http' || location.host.isEmpty) return null;
  final maxAge = RegExp(r'max-age\s*=\s*(\d+)')
      .firstMatch(headers['cache-control'] ?? '')
      ?.group(1);
  return SsdpHit(
    usn: headers['usn'] ?? '',
    location: location,
    searchTarget: headers['st'] ?? '',
    cacheSeconds: int.tryParse(maxAge ?? '') ?? 1800,
  );
}

String searchRequest({
  required InternetAddress destination,
  required int port,
  required String searchTarget,
  int maxWaitSeconds = 3,
}) =>
    'M-SEARCH * HTTP/1.1\r\n'
    'HOST: ${destination.address}:$port\r\n'
    'MAN: "ssdp:discover"\r\n'
    'MX: $maxWaitSeconds\r\n'
    'ST: $searchTarget\r\n'
    '\r\n';

/// Sends M-SEARCH and collects the answers heard within [timeout].
class SsdpExplorer {
  SsdpExplorer({
    this.timeout = const Duration(seconds: 8),
    this.repeats = 3,
    this.repeatInterval = const Duration(milliseconds: 400),
    this.port = 1900,
    InternetAddress? destination,
  }) : destination = destination ?? InternetAddress('239.255.255.250');

  final Duration timeout;
  final int repeats;
  final Duration repeatInterval;
  final int port;
  final InternetAddress destination;

  Future<List<SsdpHit>> discover({
    String searchTarget = mediaRendererTarget,
  }) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final found = <String, SsdpHit>{};
    final done = Completer<List<SsdpHit>>();
    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final hit = parseSsdpResponse(latin1.decode(datagram.data));
      if (hit != null) found[hit.location.toString()] = hit;
    });
    final timer = Timer(timeout, () {
      if (!done.isCompleted) done.complete(found.values.toList());
    });
    try {
      final request = utf8.encode(
        searchRequest(
          destination: destination,
          port: port,
          searchTarget: searchTarget,
        ),
      );
      for (var attempt = 0; attempt < repeats; attempt++) {
        socket.send(request, destination, port);
        if (attempt + 1 < repeats) {
          await Future<void>.delayed(repeatInterval);
        }
      }
      return await done.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
      socket.close();
    }
  }
}
