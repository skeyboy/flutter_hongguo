import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import '../upnp_exception.dart';

/// A control endpoint advertised by a renderer.
class UpnpService {
  const UpnpService({
    required this.serviceType,
    required this.serviceId,
    required this.controlUrl,
    required this.eventUrl,
  });

  final String serviceType;
  final String serviceId;
  final Uri controlUrl;
  final Uri eventUrl;

  bool get isAvTransport => serviceType.endsWith(':AVTransport:1');
  bool get isRenderingControl => serviceType.contains(':RenderingControl:');
}

/// A media renderer discovered on the LAN.
class UpnpDevice {
  const UpnpDevice({
    required this.location,
    required this.udn,
    required this.friendlyName,
    required this.modelName,
    required this.services,
  });

  final Uri location;
  final String udn;
  final String friendlyName;
  final String modelName;
  final List<UpnpService> services;

  UpnpService? get avTransport =>
      _first(services.where((service) => service.isAvTransport));

  UpnpService? get renderingControl =>
      _first(services.where((service) => service.isRenderingControl));

  bool get isControllable => avTransport != null;

  @override
  String toString() => 'UpnpDevice($friendlyName, $location)';
}

UpnpService? _first(Iterable<UpnpService> services) =>
    services.isEmpty ? null : services.first;

/// Reads the device description at [location]. [fetch] is injectable so tests
/// and alternative transports can supply the document.
Future<UpnpDevice> fetchDeviceDescription(
  Uri location, {
  Future<String> Function(Uri url)? fetch,
}) async => parseDeviceDescription(
  await (fetch ?? _readDocument)(location),
  location: location,
);

UpnpDevice parseDeviceDescription(String body, {required Uri location}) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(body);
  } catch (error) {
    throw UpnpException('Malformed device description at $location: $error');
  }
  final device = _child(document.rootElement, 'device');
  if (device == null) {
    throw UpnpException('Device description at $location has no <device>');
  }
  final base = Uri(
    scheme: location.scheme,
    host: location.host,
    port: location.port,
  );
  final services = <UpnpService>[];
  for (final node
      in _child(device, 'serviceList')?.childElements ?? const <XmlElement>[]) {
    final type = _text(node, 'serviceType');
    final control = _text(node, 'controlURL');
    if (node.name.local != 'service' || type == null || control == null) {
      continue;
    }
    services.add(
      UpnpService(
        serviceType: type,
        serviceId: _text(node, 'serviceId') ?? '',
        controlUrl: _resolve(base, control),
        eventUrl: _resolve(
          base,
          _text(node, 'eventURL') ?? _text(node, 'eventSUBURL') ?? control,
        ),
      ),
    );
  }
  return UpnpDevice(
    location: location,
    udn: _text(device, 'UDN') ?? location.toString(),
    friendlyName: _text(device, 'friendlyName') ?? '未知设备',
    modelName: _text(device, 'modelName') ?? '',
    services: services,
  );
}

Uri _resolve(Uri base, String value) {
  final uri = Uri.tryParse(value);
  if (uri == null) return base;
  return uri.hasScheme ? uri : base.resolve(value);
}

XmlElement? _child(XmlElement parent, String localName) {
  for (final child in parent.childElements) {
    if (child.name.local == localName) return child;
  }
  return null;
}

String? _text(XmlElement parent, String localName) {
  final value = _child(parent, localName)?.innerText.trim();
  return value == null || value.isEmpty ? null : value;
}

Future<String> _readDocument(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.getUrl(url);
    final response = await request.close();
    if (response.statusCode != 200) {
      throw UpnpException('Description $url answered ${response.statusCode}');
    }
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}
