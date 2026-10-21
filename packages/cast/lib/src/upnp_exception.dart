/// Failure while talking UPnP: transport error, bad XML or a SOAP fault.
class UpnpException implements Exception {
  const UpnpException(this.message);

  final String message;

  @override
  String toString() => message;
}
