import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/playback/capability_preferences.dart';
import 'package:hongguo_core/hongguo_core.dart';

void main() {
  test('offers one capability per return, respects cooldown and remembers declines after restart', () {
    var clock = DateTime(2026, 10, 20);
    final policy = PlaybackReturnRecommendations(now: () => clock);
    var settings = const AppSettings();
    expect(policy.next(settings), PlaybackCapability.backgroundPlayback);
    settings = policy.markAsked(
      settings,
      PlaybackCapability.backgroundPlayback,
    );
    expect(settings.backgroundPlayback, isFalse);
    expect(policy.next(settings), isNull);
    clock = clock.add(const Duration(seconds: 59));
    expect(policy.next(settings), isNull);
    clock = clock.add(const Duration(seconds: 2));
    expect(policy.next(settings), PlaybackCapability.floatingPlayback);
    settings = policy.markAsked(settings, PlaybackCapability.floatingPlayback);
    final restored = AppSettings.fromJson(settings.toJson());
    expect(PlaybackReturnRecommendations().next(restored), isNull);
    expect(restored.protocolJson(), const AppSettings().protocolJson());
  });
  test(
    'manual off is a decision and enabled features are never recommended',
    () {
      final policy = PlaybackReturnRecommendations();
      final enabled = const AppSettings(
        backgroundPlayback: true,
        floatingPlayback: true,
      );
      expect(policy.next(enabled), isNull);
      final off = PlaybackCapability.floatingPlayback.apply(
        PlaybackCapability.backgroundPlayback.apply(enabled, false),
        false,
      );
      expect(policy.next(off), isNull);
      expect(off.backgroundPlayback, isFalse);
      expect(off.floatingPlayback, isFalse);
    },
  );
}
