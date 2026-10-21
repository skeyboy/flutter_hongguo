import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/platform/background/host_policy.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    test('$platform continues under occlusion without mobile opt in', () {
      debugDefaultTargetPlatformOverride = platform;
      expect(allowBackgroundPlayback(tv: false, enabled: false), isTrue);
      expect(allowBackgroundPreparation(tv: false, enabled: false), isTrue);
      expect(allowBackgroundPlayback(tv: true, enabled: true), isFalse);
    });
  }
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test('$platform retains explicit mobile policy', () {
      debugDefaultTargetPlatformOverride = platform;
      expect(allowBackgroundPlayback(tv: false, enabled: false), isFalse);
      expect(allowBackgroundPlayback(tv: false, enabled: true), isTrue);
      expect(allowBackgroundPreparation(tv: false, enabled: false), isFalse);
      expect(allowBackgroundPreparation(tv: false, enabled: true), isTrue);
      expect(allowBackgroundPlayback(tv: true, enabled: true), isFalse);
    });
  }
}
