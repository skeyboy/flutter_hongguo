/// The app's own release identity, and the only place it is written down.
///
/// `tool/ci/release_meta.py:version()` refuses a release where these two
/// values disagree with either pubspec, so cutting a version means editing all
/// three -- which is what keeps the update prompt from telling a user they are
/// current while the tag says otherwise.
class AppRelease {
  static const version = '0.3.17';
  static const build = 29;

  /// The published releases of this repository are the update feed.
  static const repository = 'skeyboy/flutter_hongguo';
}
