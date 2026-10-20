import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('hongguo/tv-device');
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test('Native TV facts preserve low-RAM and leanback independently', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => {
            'television': true,
            'leanback': true,
            'lowRam': true,
          },
        );
    final profile = await TvDeviceProfile.read();
    expect(profile.television, isTrue);
    expect(profile.lowRam, isTrue);
  });
  test(
    'Missing native bridge reports unknown instead of assuming a television',
    () async {
      final profile = await TvDeviceProfile.read();
      expect(profile.television, isNull);
      expect(profile.leanback, isNull);
    },
  );
}
