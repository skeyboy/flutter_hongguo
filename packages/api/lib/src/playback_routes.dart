/// Ordered playback route descriptors.
///
/// Route IDs are the only thing allowed into diagnostics: they never carry a
/// URL, hostname with credentials, cookie, signature header or body.
library;

import 'package:hongguo_core/hongguo_core.dart';

enum PlaybackRouteId {
  webPublic('web-public'),
  appVideoTabV5('app-v5-video-tab'),
  appPlayerV5('app-v5-player'),
  appSingleV1('app-single-v1'),
  appMultiV1('app-multi-v1'),
  appMultiV1Hl('app-multi-v1-hl'),
  legacyPreload('legacy-preload'),
  webAnonymous('web-anonymous');

  const PlaybackRouteId(this.label);
  final String label;
}

class PlaybackRoute {
  const PlaybackRoute(
    this.id, {
    this.host,
    this.extendedOnly = false,
    this.needsSeriesId = false,
  });

  final PlaybackRouteId id;

  /// Overrides the signed request host. Changing a host always forces a
  /// re-sign; a frozen [VideoRequest] is never reused across hosts.
  final String? host;
  final bool extendedOnly;
  final bool needsSeriesId;

  @override
  String toString() => id.label;
}

/// The three routes Flutter has always used, in the same order as before.
const currentPlaybackRoutes = <PlaybackRoute>[
  PlaybackRoute(PlaybackRouteId.webPublic),
  PlaybackRoute(PlaybackRouteId.appMultiV1),
  PlaybackRoute(PlaybackRouteId.legacyPreload),
];

/// Android's full ladder: v5 first, then the legacy single-episode hop, then
/// the existing signed hop (plus a host swap), then the unsigned fallbacks.
const extendedPlaybackRoutes = <PlaybackRoute>[
  PlaybackRoute(PlaybackRouteId.webPublic, extendedOnly: true),
  PlaybackRoute(PlaybackRouteId.appVideoTabV5, extendedOnly: true),
  PlaybackRoute(PlaybackRouteId.appPlayerV5, extendedOnly: true),
  PlaybackRoute(PlaybackRouteId.appSingleV1, extendedOnly: true),
  PlaybackRoute(PlaybackRouteId.appMultiV1, extendedOnly: true),
  PlaybackRoute(
    PlaybackRouteId.appMultiV1Hl,
    host: 'api5-normal-hl.fqnovel.com',
    extendedOnly: true,
  ),
  PlaybackRoute(PlaybackRouteId.legacyPreload, extendedOnly: true),
  PlaybackRoute(
    PlaybackRouteId.webAnonymous,
    extendedOnly: true,
    needsSeriesId: true,
  ),
];

/// [webFirst] keeps the historical "web answer first" ordering for `best` and
/// `auto`. App-first callers (progressive playback, explicit quality) put the
/// web route after the App ladder.
List<PlaybackRoute> playbackRoutes({
  required bool webFirst,
  required PlaybackRouteSet set,
}) {
  final routes = set == PlaybackRouteSet.extended
      ? List<PlaybackRoute>.from(extendedPlaybackRoutes)
      : List<PlaybackRoute>.from(currentPlaybackRoutes);
  if (webFirst) return routes;
  final web = routes
      .where((route) => route.id == PlaybackRouteId.webPublic)
      .toList();
  return [...routes.where((r) => r.id != PlaybackRouteId.webPublic), ...web];
}
