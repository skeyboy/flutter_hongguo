import 'package:hongguo_cast/hongguo_cast.dart';

/// Prints one representative DIDL-Lite document for a strict external parser.
///
/// Dart's own XML reader tolerates undeclared namespace prefixes, which is how
/// a broken DIDL document once passed the unit tests. The output is piped to
/// `tool/verify_didl_namespaces.py`, a strict parser that does not tolerate
/// them, so the metadata element names stay the way the UPnP and DLNA
/// standards fix them.
void main() {
  print(
    buildDidl(
      DidlItem(
        uri: Uri.parse('http://192.168.1.9:8123/media/m1?token=a&b=2'),
        mimeType: 'video/mp4',
        title: '大时代 & 第一集 "抬头"',
        sizeBytes: 4096,
        duration: const Duration(minutes: 45, seconds: 6, milliseconds: 700),
      ),
    ),
  );
}
