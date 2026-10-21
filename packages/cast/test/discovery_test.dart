import 'dart:convert';
import 'dart:io';

import 'package:hongguo_cast/hongguo_cast.dart';
import 'package:test/test.dart';

UpnpDevice _device(String name, String host) => UpnpDevice(
  location: Uri.parse('http://$host/desc.xml'),
  // The USN the fake scan advertises is derived from the same host, which is
  // how a real renderer identifies itself before and after description.
  udn: 'uuid:${host.split('.').last}',
  friendlyName: name,
  modelName: 'M1',
  services: [
    UpnpService(
      serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
      serviceId: 'urn:upnp-org:serviceId:AVTransport',
      controlUrl: Uri.parse('http://$host/upnp/control/avt'),
      eventUrl: Uri.parse('http://$host/upnp/event/avt'),
    ),
  ],
);

SsdpHit _hit(String host, {int ttl = 100}) => SsdpHit(
  usn:
      'uuid:${host.split('.').last}::urn:schemas-upnp-org:device:MediaRenderer:1',
  location: Uri.parse('http://$host/desc.xml'),
  searchTarget: mediaRendererTarget,
  cacheSeconds: ttl,
);

void main() {
  group('device browser', () {
    test('describes what it hears and keeps it while the ttl holds', () async {
      var clock = DateTime(2026, 10, 21, 12);
      final described = <Uri>[];
      final browser = DeviceBrowser(
        scan: (target) async => [_hit('192.168.1.40')],
        describe: (location) async {
          described.add(location);
          return _device('客厅电视', location.host);
        },
        clock: () => clock,
      );

      final first = await browser.refresh();
      expect(first.map((renderer) => renderer.friendlyName), ['客厅电视']);
      expect(first.single.isControllable, isTrue);

      // A second scan one second later must not re-fetch the description.
      clock = clock.add(const Duration(seconds: 1));
      await browser.refresh();
      expect(described, hasLength(1));
    });

    test('drops a renderer once its advertisement stops arriving', () async {
      var clock = DateTime(2026, 10, 21, 12);
      var scans = 0;
      final browser = DeviceBrowser(
        scan: (target) async {
          scans++;
          return scans == 1 ? [_hit('192.168.1.40', ttl: 10)] : const [];
        },
        describe: (location) async => _device('电视', location.host),
        clock: () => clock,
        maxAgeGraceSeconds: 0,
      );
      expect(await browser.refresh(), hasLength(1));
      // Still inside the ttl, so silence from the network is not yet proof.
      clock = clock.add(const Duration(seconds: 5));
      expect(await browser.refresh(), hasLength(1));

      clock = clock.add(const Duration(seconds: 10));
      expect(await browser.refresh(), isEmpty);
    });

    test('survives a network that answers nothing', () async {
      final browser = DeviceBrowser(
        scan: (target) async => throw const UpnpException('no route'),
        describe: (location) async => _device('电视', location.host),
      );
      expect(await browser.refresh(), isEmpty);
    });

    test('ignores a renderer whose description stops answering', () async {
      final browser = DeviceBrowser(
        scan: (target) async => [_hit('192.168.1.40'), _hit('192.168.1.41')],
        describe: (location) async {
          if (location.host.endsWith('41')) {
            throw const UpnpException('timeout');
          }
          return _device('电视 ${location.host}', location.host);
        },
      );
      final result = await browser.refresh();
      expect(result, hasLength(1));
      expect(result.single.device.location.host, '192.168.1.40');
    });

    test('deduplicates two advertisements of one device', () async {
      final browser = DeviceBrowser(
        scan: (target) async => [_hit('192.168.1.40'), _hit('192.168.1.40')],
        describe: (location) async => _device('电视', location.host),
      );
      expect(await browser.refresh(), hasLength(1));
    });

    test('forget removes the device and its advertisement', () async {
      final browser = DeviceBrowser(
        scan: (target) async => [_hit('192.168.1.40')],
        describe: (location) async => _device('电视', location.host),
      );
      await browser.refresh();
      browser.forget('uuid:40');
      expect(browser.devices, isEmpty);
    });

    test('sorted by name for the picker', () async {
      final browser = DeviceBrowser(
        scan: (target) async => [_hit('10.0.0.2'), _hit('10.0.0.3')],
        describe: (location) async => _device(
          location.host.substring(location.host.length - 1),
          location.host,
        ),
      );
      final devices = await browser.refresh();
      expect(devices.map((renderer) => renderer.friendlyName), ['2', '3']);
    });
  });

  group('ssdp explorer over loopback', () {
    test('collects answers and deduplicates by location', () async {
      const port = 19000;
      final responder = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
      );
      final seen = <String>[];
      responder.listen((event) {
        final datagram = responder.receive();
        if (datagram == null) return;
        seen.add(latin1.decode(datagram.data));
        final answer = utf8.encode(
          'HTTP/1.1 200 OK\r\n'
          'CACHE-CONTROL: max-age=60\r\n'
          'LOCATION: http://127.0.0.1:$port/desc.xml\r\n'
          'ST: $mediaRendererTarget\r\n'
          'USN: uuid:fake::urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          '\r\n',
        );
        responder.send(answer, datagram.address, datagram.port);
      });

      final explorer = SsdpExplorer(
        timeout: const Duration(milliseconds: 600),
        repeats: 2,
        repeatInterval: const Duration(milliseconds: 50),
        port: port,
        destination: InternetAddress.loopbackIPv4,
      );
      final hits = await explorer.discover();
      responder.close();

      expect(hits, hasLength(1));
      expect(hits.single.cacheSeconds, 60);
      expect(seen, hasLength(2));
      expect(seen.first, startsWith('M-SEARCH * HTTP/1.1'));
    });
  });
}
