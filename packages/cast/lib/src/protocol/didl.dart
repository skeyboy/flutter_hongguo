import 'soap.dart' show escape;
import 'time.dart' show formatUpnpTime;

/// The namespace values are fixed by the UPnP MediaServer and DLNA metadata
/// standards; a renderer that validates metadata rejects anything else.
const didlNamespace = 'urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/';
const dcNamespace = 'http://purl.org/dc/elements/1.1/';
const upnpNamespace = 'urn:schemas-upnp-org:metadata-1-0/upnp/';
const dlnaMetadataNamespace = 'urn:schemas-dlna-org:metadata-1-0/';

/// DLNA recommends advertising ranged seeks (ORG_SEEK=1) and metadata parsing
/// (ORG_PARSING=1); the flag field is 128 hex digits of reserved bits.
const dlnaOperateFlags = '01700000000000000000000000000000';

class DidlItem {
  const DidlItem({
    required this.uri,
    required this.mimeType,
    this.title,
    this.sizeBytes,
    this.duration,
    this.resProtocol = 'http-get',
    this.extraProtocolInfo = const {},
  });

  final Uri uri;
  final String mimeType;
  final String? title;
  final int? sizeBytes;
  final Duration? duration;
  final String resProtocol;
  final Map<String, String> extraProtocolInfo;

  String get protocolInfo {
    final parts = <String>[
      '$resProtocol:*:$mimeType',
      'DLNA.ORG_OP=01',
      'DLNA.ORG_FLAGS=$dlnaOperateFlags',
      ...extraProtocolInfo.entries.map((e) => '${e.key}=${e.value}'),
    ];
    return parts.join(';');
  }

  /// `HH:MM:SS.mmm`, which is what AVTransport's `TrackDuration` expects.
  String? get durationText =>
      duration == null ? null : formatUpnpTime(duration!);
}

/// Builds the `<DIDL-Lite>` document handed to `AVTransport.SetAVTransportURI`.
///
/// The result is itself XML, so the SOAP layer escapes it once more before it
/// is placed inside the envelope; that double escaping is required by UPnP.
String buildDidl(DidlItem item) {
  // `dc:` and `upnp:` are used below, so they must be declared on the root;
  // `dlna:` is declared too because that is the set shipped renderers expect.
  final buffer = StringBuffer()
    ..write(
      '<DIDL-Lite xmlns="$didlNamespace" '
      'xmlns:dc="$dcNamespace" '
      'xmlns:upnp="$upnpNamespace" '
      'xmlns:dlna="$dlnaMetadataNamespace">',
    )
    ..write('<item id="0" parentID="0" restricted="1">');
  final title = item.title;
  if (title != null && title.isNotEmpty) {
    buffer.write('<dc:title>${escape(title)}</dc:title>');
  }
  buffer
    ..write('<upnp:class>object.item.videoItem.movie</upnp:class>')
    ..write('<res protocolInfo="${escape(item.protocolInfo)}"');
  final size = item.sizeBytes;
  if (size != null && size >= 0) buffer.write(' size="$size"');
  final duration = item.durationText;
  if (duration != null) buffer.write(' duration="$duration"');
  return (buffer
        ..write('>')
        ..write(escape(item.uri.toString()))
        ..write('</res></item></DIDL-Lite>'))
      .toString();
}
