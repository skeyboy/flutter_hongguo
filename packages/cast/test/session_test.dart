import 'package:hongguo_cast/hongguo_cast.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

const avType = 'urn:schemas-upnp-org:service:AVTransport:1';
const rcType = 'urn:schemas-upnp-org:service:RenderingControl:1';

class _Renderer {
  _Renderer({
    this.failOn = const {},
    this.positions = const ['0:00:10.000', '0:00:20.000', '0:00:30.000'],
    this.transportState = 'PLAYING',
  });

  final Set<String> failOn;
  final List<String> positions;
  final String transportState;

  final List<String> actions = [];
  final Map<String, Map<String, String>> arguments = {};
  final Map<String, String> envelopes = {};
  int _polls = 0;

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
    envelopes[action] = envelope;
    arguments[action] = {
      for (final child in element.childElements)
        child.name.local: child.innerText,
    };
    if (failOn.contains(action)) {
      throw const UpnpException('电视拒绝了该指令');
    }
    return switch (action) {
      'GetPositionInfo' => _reply(action, {
        'RelTime': positions[(_polls++) % positions.length],
        'TrackDuration': '0:45:00.000',
      }),
      'GetTransportInfo' => _reply(action, {'TransportState': transportState}),
      'GetVolume' => _reply(action, {'CurrentVolume': '30'}),
      _ => _reply(action, const {}),
    };
  };

  static String _reply(String action, Map<String, String> values) =>
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
      '<s:Body><u:${action}Response xmlns:u="$avType">'
      '${values.entries.map((e) => '<${e.key}>${e.value}</${e.key}>').join()}'
      '</u:${action}Response></s:Body></s:Envelope>';
}

DidlItem _item() => DidlItem(
  uri: Uri.parse('http://192.168.1.9:8000/media/m1'),
  mimeType: 'video/mp4',
  title: '大时代',
  sizeBytes: 4096,
  duration: const Duration(minutes: 45),
);

void main() {
  group('cast session', () {
    late _Renderer renderer;
    late CastSession session;
    late List<CastPhase> phases;

    setUp(() {
      renderer = _Renderer();
      session = CastSession(
        device: renderer.device,
        post: renderer.post,
        pollInterval: const Duration(milliseconds: 20),
      );
      phases = [];
      session.updates.listen((snapshot) => phases.add(snapshot.phase));
    });

    tearDown(() => session.dispose());

    test('hands over the url then starts playback', () async {
      await session.cast(_item());
      expect(renderer.actions.take(2), ['SetAVTransportURI', 'Play']);
      final handed = renderer.arguments['SetAVTransportURI']!;
      expect(handed['CurrentURI'], 'http://192.168.1.9:8000/media/m1');
      expect(handed['CurrentURIMetaData'], contains('DLNA.ORG_OP=01'));
      // The DIDL document is XML inside XML, so the envelope carries it
      // escaped and parsing the argument back yields the original markup.
      expect(
        renderer.envelopes['SetAVTransportURI'],
        contains('&lt;DIDL-Lite'),
      );
      expect(
        handed['CurrentURIMetaData'],
        contains('<DIDL-Lite xmlns="$didlNamespace"'),
      );
      expect(phases.first, CastPhase.preparing);
      expect(session.snapshot.phase, CastPhase.streaming);
      expect(session.snapshot.duration, const Duration(minutes: 45));
    });

    test('polls position and keeps the reported playhead', () async {
      await session.cast(_item());
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(renderer.actions, contains('GetPositionInfo'));
      expect(session.snapshot.position, isNot(Duration.zero));
      expect(session.snapshot.duration, const Duration(minutes: 45));
    });

    test(
      'keeps the last playhead when the renderer says not implemented',
      () async {
        final fixed = _Renderer(positions: ['0:01:02.000', 'NOT_IMPLEMENTED']);
        final tracking = CastSession(
          device: fixed.device,
          post: fixed.post,
          pollInterval: const Duration(milliseconds: 20),
        );
        addTearDown(tracking.dispose);
        await tracking.cast(_item());
        await Future<void>.delayed(const Duration(milliseconds: 90));
        expect(
          tracking.snapshot.position,
          const Duration(minutes: 1, seconds: 2),
        );
      },
    );

    test('reflects a pause reported by the renderer', () async {
      renderer = _Renderer(transportState: 'PAUSED_PLAYBACK');
      await session.dispose();
      session = CastSession(
        device: renderer.device,
        post: renderer.post,
        pollInterval: const Duration(milliseconds: 20),
      );
      await session.cast(_item());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(session.snapshot.phase, CastPhase.paused);
    });

    test('a refused hand-over ends in failed, not in an exception', () async {
      final broken = _Renderer(failOn: {'SetAVTransportURI'});
      final failing = CastSession(
        device: broken.device,
        post: broken.post,
        pollInterval: const Duration(seconds: 5),
      );
      addTearDown(failing.dispose);
      await failing.cast(_item());
      expect(failing.snapshot.phase, CastPhase.failed);
      expect(failing.snapshot.error, '电视拒绝了该指令');
      expect(broken.actions, ['SetAVTransportURI']);
      expect(failing.snapshot.item?.title, '大时代');
    });

    test('seeks in relative time', () async {
      await session.seek(const Duration(minutes: 12, seconds: 30));
      expect(renderer.arguments['Seek']!['Unit'], 'REL_TIME');
      expect(renderer.arguments['Seek']!['Target'], '00:12:30.000');
      expect(
        session.snapshot.position,
        const Duration(minutes: 12, seconds: 30),
      );
    });

    test('pause then resume sends both transport commands', () async {
      await session.pause();
      await session.resume();
      expect(renderer.actions, containsAllInOrder(['Pause', 'Play']));
      expect(renderer.arguments['Play']!['TransportSpeed'], '1');
    });

    test('stop ends the session and stops polling', () async {
      await session.cast(_item());
      final pollsBefore = renderer.actions
          .where((a) => a == 'GetPositionInfo')
          .length;
      await session.stop();
      expect(session.snapshot.phase, CastPhase.stopped);
      expect(session.snapshot.position, Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final pollsAfter = renderer.actions
          .where((a) => a == 'GetPositionInfo')
          .length;
      expect(pollsAfter, lessThanOrEqualTo(pollsBefore + 1));
    });

    test('volume goes to the rendering control service', () async {
      await session.setVolume(65);
      expect(renderer.arguments['SetVolume']!['DesiredVolume'], '65');
      expect(renderer.arguments['SetVolume']!['Channel'], 'Master');
      expect(session.snapshot.volumePercent, 65);
    });

    test(
      'a renderer that goes quiet three times over is reported failed',
      () async {
        final flaky = _Renderer(
          failOn: {'GetPositionInfo', 'GetTransportInfo'},
        );
        final quiet = CastSession(
          device: flaky.device,
          post: (url, headers, envelope) async {
            final action = XmlDocument.parse(envelope).descendantElements
                .firstWhere((node) => node.name.local == 'Body')
                .childElements
                .first
                .name
                .local;
            if (action == 'SetAVTransportURI' || action == 'Play') {
              return _Renderer._reply(action, const {});
            }
            throw const UpnpException('no answer');
          },
          pollInterval: const Duration(milliseconds: 10),
          maxMissedPolls: 3,
        );
        addTearDown(quiet.dispose);
        await quiet.cast(_item());
        expect(quiet.snapshot.phase, CastPhase.streaming);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(quiet.snapshot.phase, CastPhase.failed);
        expect(quiet.snapshot.error, '电视已无响应');
      },
    );

    test('a device without avtransport cannot be cast to', () async {
      final bare = UpnpDevice(
        location: Uri.parse('http://10.0.0.5/d.xml'),
        udn: 'uuid:speaker',
        friendlyName: '音箱',
        modelName: 'SP',
        services: [
          UpnpService(
            serviceType: rcType,
            serviceId: 'urn:upnp-org:serviceId:RenderingControl',
            controlUrl: Uri.parse('http://10.0.0.5/rc'),
            eventUrl: Uri.parse('http://10.0.0.5/rc'),
          ),
        ],
      );
      final speaker = CastSession(
        device: bare,
        post: (url, headers, envelope) async => '',
      );
      addTearDown(speaker.dispose);
      await speaker.cast(_item());
      expect(speaker.snapshot.phase, CastPhase.failed);
      expect(speaker.snapshot.error, contains('AVTransport'));
      await speaker.setVolume(10);
      expect(speaker.snapshot.volumePercent, isNull);
    });
  });

  group('snapshot', () {
    test('clearError drops a stale failure after a retry', () {
      const failed = CastSnapshot(phase: CastPhase.failed, error: 'gone');
      expect(
        failed.copyWith(phase: CastPhase.preparing, clearError: true).error,
        isNull,
      );
      expect(failed.copyWith(phase: CastPhase.preparing).error, 'gone');
    });

    test('active covers the phases a remote should be shown for', () {
      for (final phase in [
        CastPhase.preparing,
        CastPhase.streaming,
        CastPhase.paused,
      ]) {
        expect(CastSnapshot(phase: phase).isActive, isTrue);
      }
      for (final phase in [
        CastPhase.idle,
        CastPhase.stopped,
        CastPhase.failed,
      ]) {
        expect(CastSnapshot(phase: phase).isActive, isFalse);
      }
    });
  });

  test('soap service keeps its own timeout', () {
    final service = SoapService(
      serviceType: avType,
      controlUrl: Uri.parse('http://127.0.0.1:1/x'),
      timeout: const Duration(seconds: 3),
    );
    expect(service.timeout, const Duration(seconds: 3));
  });
}
