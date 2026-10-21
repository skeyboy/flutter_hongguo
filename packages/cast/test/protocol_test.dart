import 'dart:io';

import 'package:hongguo_cast/hongguo_cast.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

const avType = 'urn:schemas-upnp-org:service:AVTransport:1';

void main() {
  group('ssdp parsing', () {
    test('reads a renderer answer', () {
      final hit = parseSsdpResponse(
        'HTTP/1.1 200 OK\r\n'
        'CACHE-CONTROL: max-age=1800\r\n'
        'LOCATION: http://192.168.1.40:49152/desc.xml\r\n'
        'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
        'USN: uuid:tv-1::urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
        '\r\n',
      );
      expect(hit, isNotNull);
      expect(hit!.cacheSeconds, 1800);
      expect(hit.location.host, '192.168.1.40');
      expect(hit.searchTarget, mediaRendererTarget);
    });

    test('defaults the ttl when the header is missing', () {
      final hit = parseSsdpResponse(
        'HTTP/1.1 200 OK\r\nLOCATION: http://10.0.0.2/d\r\n\r\n',
      );
      expect(hit?.cacheSeconds, 1800);
    });

    test('ignores our own outbound search and malformed answers', () {
      expect(
        parseSsdpResponse('M-SEARCH * HTTP/1.1\r\nST: ssdp:all\r\n\r\n'),
        isNull,
      );
      expect(
        parseSsdpResponse('HTTP/1.1 200 OK\r\nST: ssdp:all\r\n\r\n'),
        isNull,
      );
      expect(
        parseSsdpResponse('HTTP/1.1 200 OK\r\nLOCATION: not a uri\r\n\r\n'),
        isNull,
      );
    });

    test('builds a request that names the target', () {
      final request = searchRequest(
        destination: InternetAddress('239.255.255.250'),
        port: 1900,
        searchTarget: mediaRendererTarget,
      );
      expect(request, contains('MAN: "ssdp:discover"'));
      expect(request, contains('HOST: 239.255.255.250:1900'));
      expect(request, contains('ST: $mediaRendererTarget'));
      expect(request, endsWith('\r\n\r\n'));
    });
  });

  group('device description', () {
    const body =
        '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>1</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>客厅电视</friendlyName>
    <modelName>KT-55</modelName>
    <UDN>uuid:tv-1</UDN>
    <serviceList>
      <service>
        <serviceType>$avType</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/upnp/control/avtransport</controlURL>
        <eventURL>/upnp/event/avtransport</eventURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>http://192.168.1.40:49152/upnp/control/rc</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <controlURL>/upnp/control/cm</controlURL>
      </service>
    </serviceList>
  </device>
</root>
''';

    test('resolves relative control urls against the description host', () {
      final device = parseDeviceDescription(
        body,
        location: Uri.parse('http://192.168.1.40:49152/desc.xml'),
      );
      expect(device.udn, 'uuid:tv-1');
      expect(device.friendlyName, '客厅电视');
      expect(device.isControllable, isTrue);
      expect(
        device.avTransport!.controlUrl.toString(),
        'http://192.168.1.40:49152/upnp/control/avtransport',
      );
      expect(
        device.renderingControl!.controlUrl.toString(),
        'http://192.168.1.40:49152/upnp/control/rc',
      );
      expect(device.services.length, 3);
    });

    test('rejects a document without a device', () {
      expect(
        () => parseDeviceDescription(
          '<root xmlns="urn:schemas-upnp-org:device-1-0"/>',
          location: Uri.parse('http://10.0.0.9/d.xml'),
        ),
        throwsA(isA<UpnpException>()),
      );
    });

    test('reports truncated xml instead of throwing a format error', () {
      expect(
        () => parseDeviceDescription(
          '<root><device>',
          location: Uri.parse('http://h/d'),
        ),
        throwsA(isA<UpnpException>()),
      );
    });
  });

  group('soap', () {
    test('escapes argument values once', () {
      final envelope = buildEnvelope(
        serviceType: avType,
        action: 'SetAVTransportURI',
        arguments: const {
          'CurrentURI': 'http://10.0.0.1/a.mp4',
          'CurrentURIMetaData': '<a b="c">&</a>',
        },
      );
      expect(envelope, contains('&lt;a b=&quot;c&quot;&gt;&amp;&lt;/a&gt;'));
      expect(envelope, contains('<u:SetAVTransportURI xmlns:u="$avType">'));
    });

    test('reads returned arguments', () {
      final result = readResponse(
        body:
            '<s:Envelope xmlns:s="x"><s:Body><u:GetPositionInfoResponse '
            'xmlns:u="$avType"><RelTime>0:12:30.500</RelTime>'
            '<TrackDuration>0:45:00.000</TrackDuration>'
            '<IgnoreMe>no</IgnoreMe></u:GetPositionInfoResponse></s:Body></s:Envelope>',
        action: 'GetPositionInfo',
        returns: const ['RelTime', 'TrackDuration'],
      );
      expect(result['RelTime'], '0:12:30.500');
      expect(result['TrackDuration'], '0:45:00.000');
      expect(result.containsKey('IgnoreMe'), isFalse);
    });

    test('surfaces a fault as an upnp exception', () {
      expect(
        () => readResponse(
          body:
              '<s:Envelope xmlns:s="x"><s:Body><s:Fault><faultstring>UPnPError'
              '</faultstring><detail><UPnPError xmlns="x">'
              '<errorCode>701</errorCode><errorDescription>Transition not Available'
              '</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>',
          action: 'Play',
        ),
        throwsA(
          isA<UpnpException>().having(
            (e) => e.message,
            'message',
            contains('Transition not Available'),
          ),
        ),
      );
    });

    test('sends the soapaction header the service type requires', () async {
      final captured = <String, String>{};
      final service = SoapService(
        serviceType: avType,
        controlUrl: Uri.parse('http://127.0.0.1:1/ctrl'),
        post: (url, headers, envelope) async {
          captured.addAll(headers);
          final body = XmlDocument.parse(envelope).descendantElements
              .firstWhere((node) => node.name.local == 'Body');
          final action = body.childElements.first.name.local;
          return '<s:Envelope xmlns:s="x"><s:Body><u:${action}Response '
              'xmlns:u="$avType"><Volume>42</Volume></u:${action}Response>'
              '</s:Body></s:Envelope>';
        },
      );
      final result = await service.call(
        'GetVolume',
        arguments: const {'InstanceID': '0', 'Channel': 'Master'},
        returns: const ['Volume'],
      );
      expect(result['Volume'], '42');
      expect(captured['soapaction'], '"$avType#GetVolume"');
      expect(captured['content-type'], contains('text/xml'));
    });
  });

  group('didl', () {
    test('describes a ranged mp4 with a human title', () {
      final didl = buildDidl(
        DidlItem(
          uri: Uri.parse('http://10.0.0.1:8080/media/m1'),
          mimeType: 'video/mp4',
          title: '大时代 & 第一集',
          sizeBytes: 1234,
          duration: const Duration(minutes: 45, seconds: 6, milliseconds: 700),
        ),
      );
      expect(didl, contains('<DIDL-Lite xmlns="$didlNamespace"'));
      expect(didl, contains('size="1234"'));
      expect(didl, contains('duration="00:45:06.700"'));
      expect(didl, contains('DLNA.ORG_OP=01'));
      expect(didl, contains('大时代 &amp; 第一集'));
    });

    test('declares every prefix it uses, under the standard namespaces', () {
      final didl = buildDidl(
        DidlItem(
          uri: Uri.parse('http://10.0.0.1:8080/media/m1'),
          mimeType: 'video/mp4',
          title: '大时代 & 第一集',
          sizeBytes: 1234,
        ),
      );
      final document = XmlDocument.parse(didl);
      expect(document.rootElement.name.namespaceUri, didlNamespace);
      // An undeclared prefix would resolve to no namespace at all, so these
      // lookups are what prove the declarations exist.
      expect(
        document
            .findAllElements('title', namespaceUri: dcNamespace)
            .map((node) => node.innerText),
        ['大时代 & 第一集'],
      );
      expect(
        document
            .findAllElements('class', namespaceUri: upnpNamespace)
            .map((node) => node.innerText),
        ['object.item.videoItem.movie'],
      );
      final res = document
          .findAllElements('res', namespaceUri: didlNamespace)
          .single;
      expect(
        res.getAttribute('protocolInfo'),
        startsWith('http-get:*:video/mp4'),
      );
      expect(res.innerText, 'http://10.0.0.1:8080/media/m1');
    });

    test('survives the soap envelope round trip', () {
      final item = DidlItem(
        uri: Uri.parse('http://10.0.0.1:8080/media/m1?a=1&b=2'),
        mimeType: 'video/mp4',
        title: '第一集 "抬头"',
      );
      final envelope = buildEnvelope(
        serviceType: avType,
        action: 'SetAVTransportURI',
        arguments: {
          'CurrentURI': item.uri.toString(),
          'CurrentURIMetaData': buildDidl(item),
        },
      );
      final metadata = XmlDocument.parse(envelope).descendantElements
          .firstWhere((node) => node.name.local == 'CurrentURIMetaData')
          .innerText;
      final document = XmlDocument.parse(metadata);
      expect(document.rootElement.name.namespaceUri, didlNamespace);
      expect(
        document
            .findAllElements('title', namespaceUri: dcNamespace)
            .single
            .innerText,
        '第一集 "抬头"',
      );
      expect(
        document
            .findAllElements('res', namespaceUri: didlNamespace)
            .single
            .innerText,
        'http://10.0.0.1:8080/media/m1?a=1&b=2',
      );
    });

    test('omits metadata the caller does not know', () {
      final didl = buildDidl(
        DidlItem(uri: Uri.parse('http://10.0.0.1/m'), mimeType: 'video/mp4'),
      );
      expect(didl, isNot(contains('size=')));
      expect(didl, isNot(contains('duration=')));
      expect(didl, isNot(contains('dc:title')));
    });
  });

  group('upnp time', () {
    test('round-trips through the wire format', () {
      final value = const Duration(
        hours: 1,
        minutes: 2,
        seconds: 3,
        milliseconds: 40,
      );
      final text = formatUpnpTime(value);
      expect(text, '01:02:03.040');
      expect(parseUpnpTime(text), value);
    });

    test('accepts the one-digit hours some renderers send', () {
      expect(parseUpnpTime('0:05:30'), const Duration(minutes: 5, seconds: 30));
      expect(parseUpnpTime('NOT_IMPLEMENTED'), isNull);
      expect(parseUpnpTime(null), isNull);
    });
  });

  group('lan address', () {
    test('accepts the private ranges a home router hands out', () {
      expect(isPrivateIpv4('192.168.1.7'), isTrue);
      expect(isPrivateIpv4('10.20.30.40'), isTrue);
      expect(isPrivateIpv4('172.16.0.1'), isTrue);
      expect(isPrivateIpv4('172.32.0.1'), isFalse);
      expect(isPrivateIpv4('169.254.1.1'), isFalse);
      expect(isPrivateIpv4('8.8.8.8'), isFalse);
      expect(isPrivateIpv4('192.168.1'), isFalse);
    });
  });
}
