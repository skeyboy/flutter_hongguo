import 'release_info.dart';

/// The builds this app ships, and therefore the ones an update can be planned
/// for. `packages/app` maps `dart:io`'s operating-system name onto it.
///
/// `androidTV` is distinct from `android` because the two flavors ship under
/// different application ids and are packaged under different asset names
/// (`android-tv-<abi>.apk` vs `android-<abi>.apk`). Collapsing them -- mapping a
/// television onto plain android -- is how a TV ends up installing the phone
/// build and loses its television-only behavior.
enum ReleasePlatform { windows, macOS, linux, android, androidTV, iOS }

/// Which attachment belongs to this device.
///
/// Asset names are the interface (`tool/ci/package_desktop.py` and
/// `tool/ci/validate_release.py` write the same ones): every file a release
/// carries is `Hongguo-<version>-<platform>-<arch><suffix>`, so a candidate is
/// the platform-and-arch tail and nothing more.
class UpdateTarget {
  final ReleasePlatform platform;

  /// `arm64` or `x64` for the desktop builds; empty means arm64, which is the
  /// only desktop image `tool/ci/package_desktop.py` produces. Ignored on
  /// Android, where [abis] decides.
  final String arch;

  /// Android ABIs in the order the device itself prefers them.
  final List<String> abis;

  const UpdateTarget({
    required this.platform,
    this.arch = '',
    this.abis = const [],
  });

  /// iOS gets no attachment at all: nothing outside the store can install a
  /// build, so the release page is the whole answer there.
  bool get hasInstallableAsset => platform != ReleasePlatform.iOS;

  List<String> get _candidates {
    // Desktop candidates stay on the detected architecture: this repository
    // ships macOS arm64 only, so handing an Intel machine an arm64 image would
    // announce an update it cannot install.
    final desktopArch = arch.isEmpty ? 'arm64' : arch;
    switch (platform) {
      case ReleasePlatform.iOS:
        return const [];
      case ReleasePlatform.windows:
        return const ['windows-x64-setup.exe', 'windows-x64.zip'];
      case ReleasePlatform.macOS:
        return ['macos-$desktopArch.dmg', 'macos-$desktopArch.zip'];
      case ReleasePlatform.linux:
        return const ['linux-x64.deb', 'linux-x64.tar.gz'];
      case ReleasePlatform.android:
        return [
          for (final abi in abis) 'android-$abi.apk',
          'android-arm64-v8a.apk',
          'android-x86_64.apk',
          'android-armeabi-v7a.apk',
        ];
      case ReleasePlatform.androidTV:
        return [
          for (final abi in abis) 'android-tv-$abi.apk',
          'android-tv-arm64-v8a.apk',
          'android-tv-x86_64.apk',
          'android-tv-armeabi-v7a.apk',
        ];
    }
  }

  /// The one file to fetch, or null when the release carries nothing this
  /// device could install.
  ReleaseAsset? installer(ReleaseInfo release) {
    final stem = 'Hongguo-${release.version.versionText}-';
    for (final candidate in _candidates) {
      final exact = release.assetNamed('$stem$candidate');
      if (exact != null) return exact;
    }
    for (final candidate in _candidates) {
      for (final asset in release.assets) {
        if (asset.name.endsWith(candidate)) return asset;
      }
    }
    return null;
  }
}
