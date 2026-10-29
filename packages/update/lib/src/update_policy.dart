import 'release_feed.dart';
import 'release_version.dart';

/// What a check left the user with.
enum UpdateOutcome {
  /// Already on the newest published version.
  upToDate,

  /// The feed answered 304: nothing changed since the last check.
  unchanged,

  /// A newer release the user has not dismissed.
  available,

  /// A newer release whose exact tag was dismissed with 忽略本次更新.
  ignored,

  /// The feed could not be read; automatic checks stay quiet about this.
  unavailable,
}

/// When to ask, and what an answer means. Deliberately free of platform and
/// widget knowledge so the prompt's whole decision table is unit-testable.
class UpdatePolicy {
  /// Automatic checks (startup, resumed) cost one request per this interval at
  /// most; the settings row is not throttled.
  final Duration throttle;

  const UpdatePolicy({this.throttle = const Duration(hours: 24)});

  bool shouldCheck({
    required bool automatic,
    required bool enabled,
    required DateTime? lastCheckAt,
    required DateTime now,
  }) {
    if (!automatic) return true;
    if (!enabled) return false;
    final last = lastCheckAt;
    if (last == null) return true;
    final since = now.difference(last);
    // A clock that moved backwards must not silence updates forever.
    if (since.isNegative) return true;
    return since >= throttle;
  }

  UpdateOutcome classify({
    required ReleaseVersion current,
    required ReleaseFeedResult feed,
    String ignoredTag = '',
  }) {
    switch (feed.status) {
      case ReleaseFeedStatus.unavailable:
        return UpdateOutcome.unavailable;
      case ReleaseFeedStatus.notModified:
        return UpdateOutcome.unchanged;
      case ReleaseFeedStatus.available:
        final release = feed.release;
        if (release == null || release.prerelease) {
          return UpdateOutcome.upToDate;
        }
        if (!release.version.isNewerThan(current)) {
          return UpdateOutcome.upToDate;
        }
        return ignoredTag == release.tag
            ? UpdateOutcome.ignored
            : UpdateOutcome.available;
    }
  }
}
