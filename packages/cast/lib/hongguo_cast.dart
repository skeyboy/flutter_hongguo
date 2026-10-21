/// LAN casting for Hongguo: discover a DLNA MediaRenderer, serve already
/// cached plain files over the Wi-Fi network, and drive playback with SOAP.
///
/// Deliberately pure Dart with no Flutter import, so the whole protocol stack
/// runs under `dart test` on a 1x Linux runner.
library;

export 'src/discovery.dart' show DeviceBrowser, KnownRenderer;
export 'src/protocol/description.dart'
    show
        UpnpDevice,
        UpnpService,
        fetchDeviceDescription,
        parseDeviceDescription;
export 'src/protocol/didl.dart' show DidlItem, buildDidl, didlNamespace;
export 'src/protocol/soap.dart'
    show SoapPoster, SoapService, buildEnvelope, readResponse;
export 'src/protocol/ssdp.dart'
    show
        SsdpExplorer,
        SsdpHit,
        mediaRendererTarget,
        parseSsdpResponse,
        searchRequest;
export 'src/protocol/time.dart' show formatUpnpTime, parseUpnpTime;
export 'src/session/cast_session.dart'
    show CastPhase, CastSession, CastSnapshot;
export 'src/source/media_source.dart'
    show LanMediaServer, MediaLease, isPrivateIpv4, lanAddress;
export 'src/upnp_exception.dart' show UpnpException;
