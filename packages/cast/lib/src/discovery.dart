import 'dart:async';

import 'protocol/description.dart';
import 'protocol/ssdp.dart';
import 'upnp_exception.dart';

/// A renderer we have both heard from and successfully described.
class KnownRenderer {
  const KnownRenderer({
    required this.device,
    required this.expiresAt,
    required this.lastSeenAt,
  });

  final UpnpDevice device;

  /// When the last SSDP `CACHE-CONTROL` allowance runs out. An answer inside
  /// this window means the device is still present, so we do not need to
  /// describe it again.
  final DateTime expiresAt;
  final DateTime lastSeenAt;

  String get udn => device.udn;
  String get friendlyName => device.friendlyName;
  bool get isControllable => device.isControllable;
}

typedef SsdpScan = Future<List<SsdpHit>> Function(String searchTarget);
typedef DescriptionFetcher = Future<UpnpDevice> Function(Uri location);

/// Keeps a live list of renderers on the LAN.
///
/// Split from the socket plumbing so tests can drive discovery with canned SSDP
/// answers, and so the app can reuse one browser across pages.
class DeviceBrowser {
  DeviceBrowser({
    SsdpScan? scan,
    DescriptionFetcher? describe,
    DateTime Function()? clock,
    this.searchTarget = mediaRendererTarget,
    this.maxAgeGraceSeconds = 5,
  }) : _scan = scan ?? _defaultScan,
       _describe = describe ?? fetchDeviceDescription,
       _clock = clock ?? DateTime.now;

  static Future<List<SsdpHit>> _defaultScan(String target) =>
      SsdpExplorer().discover(searchTarget: target);

  final SsdpScan _scan;
  final DescriptionFetcher _describe;
  final DateTime Function() _clock;
  final String searchTarget;

  /// Devices keep answering until their advertisement expires; a small grace
  /// period avoids flapping when clocks on the TV and phone disagree.
  final int maxAgeGraceSeconds;

  final Map<String, _Advertisement> _advertisements = {};
  final Map<String, KnownRenderer> _known = {};

  List<KnownRenderer> get devices {
    final list = _known.values.toList()
      ..sort((a, b) => a.friendlyName.compareTo(b.friendlyName));
    return List.unmodifiable(list);
  }

  /// One SSDP round trip: merge answers, describe what changed, drop expired.
  Future<List<KnownRenderer>> refresh() async {
    final now = _clock();
    List<SsdpHit> hits;
    try {
      hits = await _scan(searchTarget);
    } on UpnpException {
      // A silent network is a normal state on guest Wi-Fi with AP isolation.
      hits = const [];
    }
    for (final hit in hits) {
      _advertisements[hit.location.toString()] = _Advertisement(
        hit: hit,
        seenAt: now,
      );
    }
    _prune(now);
    for (final entry in _advertisements.entries) {
      final hit = entry.value.hit;
      final cached = _known[_udnOf(hit)];
      if (cached != null && cached.expiresAt.isAfter(now)) continue;
      try {
        final device = await _describe(hit.location);
        _known[device.udn] = KnownRenderer(
          device: device,
          expiresAt: now.add(
            Duration(seconds: hit.cacheSeconds + maxAgeGraceSeconds),
          ),
          lastSeenAt: entry.value.seenAt,
        );
      } on UpnpException {
        // A device that stops answering its own description is dropped for
        // this round; the next refresh either re-adds or prunes it.
        _known.removeWhere((_, value) => value.device.location == hit.location);
      }
    }
    return devices;
  }

  /// Stops tracking a device that the user unpaired or that has gone quiet.
  void forget(String udn) {
    _known.remove(udn);
    _advertisements.removeWhere(
      (_, advertisement) => advertisement.hit.usn.contains(udn),
    );
  }

  void clear() {
    _known.clear();
    _advertisements.clear();
  }

  void _prune(DateTime now) {
    _advertisements.removeWhere(
      (_, advertisement) =>
          now.difference(advertisement.seenAt).inSeconds >
          advertisement.hit.cacheSeconds + maxAgeGraceSeconds,
    );
    final locations = _advertisements.values
        .map((advertisement) => advertisement.hit.location.toString())
        .toSet();
    _known.removeWhere(
      (_, renderer) => !locations.contains(renderer.device.location.toString()),
    );
  }
}

class _Advertisement {
  const _Advertisement({required this.hit, required this.seenAt});
  final SsdpHit hit;
  final DateTime seenAt;
}

/// SSDP advertisements key on USN (`udn::searchTarget`), the only stable device
/// identity available before the description has been fetched.
String _udnOf(SsdpHit hit) =>
    hit.usn.isEmpty ? hit.location.toString() : hit.usn.split('::').first;
