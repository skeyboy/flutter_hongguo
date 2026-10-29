import 'package:hongguo_update/hongguo_update.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  const policy = UpdatePolicy();
  final current = ReleaseVersion.tryParse('0.3.12')!;
  final release = pinnedRelease();

  ReleaseFeedResult found(ReleaseInfo info) =>
      ReleaseFeedResult(status: ReleaseFeedStatus.available, release: info);
  const stale = ReleaseFeedResult(status: ReleaseFeedStatus.unavailable);
  const cached = ReleaseFeedResult(status: ReleaseFeedStatus.notModified);

  UpdateOutcome classify({String ignoredTag = '', ReleaseInfo? offer}) =>
      policy.classify(
        current: current,
        feed: found(offer ?? release),
        ignoredTag: ignoredTag,
      );

  group('when to ask', () {
    final now = DateTime.utc(2026, 10, 29, 12);
    test('the settings row always checks', () {
      expect(
        policy.shouldCheck(
          automatic: false,
          enabled: false,
          lastCheckAt: now,
          now: now,
        ),
        isTrue,
      );
    });
    test('a switch off means no background traffic at all', () {
      expect(
        policy.shouldCheck(
          automatic: true,
          enabled: false,
          lastCheckAt: null,
          now: now,
        ),
        isFalse,
      );
    });
    test('the first run checks, an hour later does not, a day later does', () {
      expect(
        policy.shouldCheck(
          automatic: true,
          enabled: true,
          lastCheckAt: null,
          now: now,
        ),
        isTrue,
      );
      expect(
        policy.shouldCheck(
          automatic: true,
          enabled: true,
          lastCheckAt: now.subtract(const Duration(hours: 23, minutes: 59)),
          now: now,
        ),
        isFalse,
      );
      expect(
        policy.shouldCheck(
          automatic: true,
          enabled: true,
          lastCheckAt: now.subtract(const Duration(hours: 24)),
          now: now,
        ),
        isTrue,
      );
    });
    test('a clock moved backwards re-checks instead of never checking', () {
      expect(
        policy.shouldCheck(
          automatic: true,
          enabled: true,
          lastCheckAt: now.add(const Duration(days: 5)),
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('what an answer means', () {
    test('newer than this build, so say so', () {
      expect(classify(), UpdateOutcome.available);
    });
    test('this exact version is not an update', () {
      expect(
        classify(ignoredTag: '', offer: pinnedRelease({'tag_name': 'v0.3.12'})),
        UpdateOutcome.upToDate,
      );
    });
    test('忽略本次更新 silences one tag and only that tag', () {
      expect(classify(ignoredTag: 'v0.3.13'), UpdateOutcome.ignored);
      expect(
        classify(
          ignoredTag: 'v0.3.13',
          offer: pinnedRelease({'tag_name': 'v0.4.0'}),
        ),
        UpdateOutcome.available,
      );
      expect(classify(ignoredTag: '0.3.13'), UpdateOutcome.available);
    });
    test('a draft of the next version is not an offer', () {
      expect(
        classify(offer: pinnedRelease({'prerelease': true})),
        UpdateOutcome.upToDate,
      );
    });
    test('304 and a refused feed stay apart', () {
      expect(
        policy.classify(current: current, feed: cached),
        UpdateOutcome.unchanged,
      );
      expect(
        policy.classify(current: current, feed: stale),
        UpdateOutcome.unavailable,
      );
    });
  });
}
