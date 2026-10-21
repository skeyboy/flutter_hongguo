import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/cast/cast_controller.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_cast/hongguo_cast.dart';
import 'package:xml/xml.dart';

const avType = 'urn:schemas-upnp-org:service:AVTransport:1';
const rcType = 'urn:schemas-upnp-org:service:RenderingControl:1';

/// A SOAP-speaking television that never leaves the process.
class RendererSpy {
  RendererSpy({this.failOn = const {}});

  /// Actions the television refuses, e.g. `{'SetAVTransportURI'}`. Mutable so a
  /// test can make the same television fail after it was built.
  Set<String> failOn;
  final List<String> actions = [];
  final Map<String, Map<String, String>> arguments = {};

  UpnpDevice get device => UpnpDevice(
    location: Uri.parse('http://192.168.1.40:49152/desc.xml'),
    udn: 'uuid:tv-1',
    friendlyName: '客厅电视',
    modelName: 'KT-55',
    services: [
      UpnpService(
        serviceType: avType,
        serviceId: 'urn:upnp-org:serviceId:AVTransport',
        controlUrl: Uri.parse('http://192.168.1.40:49152/upnp/control/avt'),
        eventUrl: Uri.parse('http://192.168.1.40:49152/upnp/event/avt'),
      ),
      UpnpService(
        serviceType: rcType,
        serviceId: 'urn:upnp-org:serviceId:RenderingControl',
        controlUrl: Uri.parse('http://192.168.1.40:49152/upnp/control/rc'),
        eventUrl: Uri.parse('http://192.168.1.40:49152/upnp/event/rc'),
      ),
    ],
  );

  SoapPoster get post => (url, headers, envelope) async {
    final body = XmlDocument.parse(envelope).descendantElements
        .firstWhere((node) => node.name.local == 'Body');
    final element = body.childElements.first;
    final action = element.name.local;
    actions.add(action);
    arguments[action] = {
      for (final child in element.childElements)
        child.name.local: child.innerText,
    };
    if (failOn.contains(action)) {
      throw const UpnpException('电视拒绝了该指令');
    }
    return switch (action) {
      'GetPositionInfo' => _reply({
        'RelTime': '0:00:12.000',
        'TrackDuration': '0:45:00.000',
      }),
      'GetTransportInfo' => _reply({'TransportState': 'PLAYING'}),
      'GetVolume' => _reply({'CurrentVolume': '30'}),
      _ => _reply(const {}),
    };
  };

  static String _reply(Map<String, String> values) =>
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
      '<s:Body><u:Response xmlns:u="$avType">'
      '${values.entries.map((e) => '<${e.key}>${e.value}</${e.key}>').join()}'
      '</u:Response></s:Body></s:Envelope>';
}

class FakeJob implements PlaybackJob {
  FakeJob(this.owner, this.path);

  final FakeLocalRuntime owner;
  final String? path;

  @override
  Future<String> get source => path == null
      ? Future.error(StateError('本地缓存已失效，请返回列表重新下载。'))
      : Future.value(File(path!).uri.toString());

  @override
  void cancel() => owner.cancels++;
  @override
  void release() => owner.releases++;
}

class FakeLocalRuntime implements AppRuntime, LocalMediaRuntime {
  String? path;
  int pins = 0, releases = 0, cancels = 0;

  @override
  CatalogRepository get catalog => throw UnimplementedError();
  @override
  PlaybackJob prepare(
    String vid, {
    String quality = 'best',
    void Function(PreparationProgress)? onProgress,
    bool background = false,
  }) => throw UnimplementedError();
  @override
  PlaybackJob prepareLocal(String vid, {String quality = 'best'}) {
    pins++;
    return FakeJob(this, path);
  }

  @override
  Future<List<LocalEpisode>> localEpisodes() async => const [];
  @override
  Future<void> evict(String vid, {String quality = 'best'}) async {}
  @override
  Future<int> cacheBytes() async => 0;
  @override
  Future<void> clearCache() async {}
  @override
  Future<void> dispose() async {}
}

class FakePlainRuntime implements AppRuntime {
  @override
  CatalogRepository get catalog => throw UnimplementedError();
  @override
  PlaybackJob prepare(
    String vid, {
    String quality = 'best',
    void Function(PreparationProgress)? onProgress,
    bool background = false,
  }) => throw UnimplementedError();
  @override
  Future<void> evict(String vid, {String quality = 'best'}) async {}
  @override
  Future<int> cacheBytes() async => 0;
  @override
  Future<void> clearCache() async {}
  @override
  Future<void> dispose() async {}
}

KnownRenderer knownRenderer(UpnpDevice device) => KnownRenderer(
  device: device,
  expiresAt: DateTime.now().add(const Duration(minutes: 1)),
  lastSeenAt: DateTime.now(),
);

/// flutter_test reports `TargetPlatform.android`, so a controller under test
/// really does call the multicast platform channel. Nothing would answer it
/// otherwise, so every cast test gets this reply.
void stubMulticastChannel() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('hongguo/multicast'),
        (call) async => true,
      );
}

/// One place to build a casting stack under test: a spy television and a real
/// loopback media server, with no position polling (the poll loop belongs to the
/// cast package's own tests).
///
/// The server is bound in [start], which runs outside the fake-async zone of a
/// widget test. Binding lazily from inside `start()` would complete the socket
/// on the real event loop, and a session released later in the fake zone would
/// never get its cancel back.
class CastHarness {
  CastHarness({Set<String> failOn = const {}})
    : spy = RendererSpy(failOn: failOn);

  final RendererSpy spy;
  final FakeLocalRuntime runtime = FakeLocalRuntime();
  late final SsdpHit advertisement = SsdpHit(
    usn: 'uuid:tv-1::urn:schemas-upnp-org:device:MediaRenderer:1',
    location: Uri.parse('http://192.168.1.40:49152/desc.xml'),
    searchTarget: mediaRendererTarget,
    cacheSeconds: 60,
  );

  late Directory root;
  late String episode;
  late LanMediaServer server;

  Future<void> start() async {
    stubMulticastChannel();
    root = await Directory.systemTemp.createTemp('hongguo-cast');
    episode = '${root.path}/1.mp4';
    await File(episode).writeAsBytes(List.generate(64, (index) => index));
    runtime.path = episode;
    server = await LanMediaServer.bind(
      host: InternetAddress.loopbackIPv4.address,
      address: InternetAddress.loopbackIPv4,
    );
  }

  /// Closing the server belongs to the controller under test.
  Future<void> finish() => root.delete(recursive: true);

  CastController controller({
    List<SsdpHit>? hits,
    Future<LanMediaServer> Function()? bindServer,
  }) => CastController(
    runtime: runtime,
    browser: DeviceBrowser(
      scan: (target) async => hits ?? [advertisement],
      describe: (location) async => spy.device,
    ),
    bindServer: bindServer ?? (() async => server),
    openSession: (device) => CastSession(
      device: device,
      post: spy.post,
      pollInterval: const Duration(minutes: 5),
    ),
  );

  Future<void> cast(CastController subject, {String vid = '1'}) =>
      subject.start(
        renderer: knownRenderer(spy.device),
        vid: vid,
        episodeTitle: '大时代 · 第 $vid 集',
        expectedDuration: const Duration(minutes: 45),
      );
}

/// flutter_test intercepts `HttpClient`; the media server is a real loopback
/// socket, so probes go under the interception to show what a television that
/// has not committed to the URL yet receives.
class Reply {
  final int status;
  final String headers;
  final int bodyBytes;
  Reply(this.status, this.headers, this.bodyBytes);
}

Future<Reply> probe(Uri url, {String? range}) async {
  final socket = await Socket.connect(url.host, url.port);
  try {
    socket.write(
      'GET ${url.path} HTTP/1.1\r\n'
      'Host: ${url.host}\r\n'
      '${range == null ? '' : 'Range: bytes=$range\r\n'}'
      'Connection: close\r\n\r\n',
    );
    final received = <int>[];
    await for (final chunk in socket) {
      received.addAll(chunk);
    }
    final text = String.fromCharCodes(received);
    final head = text.split('\r\n\r\n').first;
    return Reply(
      int.parse(RegExp(r'HTTP/1\.\d (\d{3})').firstMatch(head)!.group(1)!),
      head.toLowerCase(),
      received.length - head.length - 4,
    );
  } finally {
    socket.destroy();
  }
}
