import 'package:hongguo_update/hongguo_update.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  const desktop = UpdateTarget(platform: ReleasePlatform.macOS);

  test('every build installs the one file named for it', () {
    final release = pinnedRelease();
    const cases = {
      UpdateTarget(platform: ReleasePlatform.windows, arch: 'x64'):
          'Hongguo-0.3.13-windows-x64-setup.exe',
      UpdateTarget(platform: ReleasePlatform.macOS, arch: 'arm64'):
          'Hongguo-0.3.13-macos-arm64.dmg',
      UpdateTarget(platform: ReleasePlatform.linux, arch: 'x64'):
          'Hongguo-0.3.13-linux-x64.deb',
      UpdateTarget(platform: ReleasePlatform.android, abis: ['x86_64']):
          'Hongguo-0.3.13-android-x86_64.apk',
      UpdateTarget(platform: ReleasePlatform.android):
          'Hongguo-0.3.13-android-arm64-v8a.apk',
    };
    for (final entry in cases.entries) {
      expect(entry.key.installer(release)!.name, entry.value);
    }
    // The empty desktop arch is the one image this repository ships.
    expect(desktop.installer(release)!.name, 'Hongguo-0.3.13-macos-arm64.dmg');
  });

  test('iOS gets no attachment and says so', () {
    const ios = UpdateTarget(platform: ReleasePlatform.iOS);
    expect(ios.hasInstallableAsset, isFalse);
    expect(ios.installer(pinnedRelease()), isNull);
  });

  test('an image for another architecture is not offered', () {
    // Only arm64 macOS images exist; promising an Intel machine an update it
    // cannot run would be worse than staying quiet.
    const intel = UpdateTarget(platform: ReleasePlatform.macOS, arch: 'x64');
    expect(intel.installer(pinnedRelease()), isNull);
  });

  test('a phone never picks a television APK', () {
    final tvOnly = releaseWith([
      'Hongguo-0.4.0-android-tv-arm64-v8a.apk',
      'SHA256SUMS.txt',
    ]);
    expect(
      const UpdateTarget(platform: ReleasePlatform.android).installer(tvOnly),
      isNull,
    );
    final both = releaseWith([
      'Hongguo-0.4.0-android-tv-arm64-v8a.apk',
      'Hongguo-0.4.0-android-arm64-v8a.apk',
    ]);
    expect(
      const UpdateTarget(platform: ReleasePlatform.android)
          .installer(both)!
          .name,
      'Hongguo-0.4.0-android-arm64-v8a.apk',
    );
  });

  test('the setup program wins over the portable archive', () {
    final release = releaseWith([
      'Hongguo-0.4.0-windows-x64.zip',
      'Hongguo-0.4.0-windows-x64-setup.exe',
    ]);
    expect(
      const UpdateTarget(
        platform: ReleasePlatform.windows,
        arch: 'x64',
      ).installer(release)!.name,
      'Hongguo-0.4.0-windows-x64-setup.exe',
    );
  });

  test('an exact-name hit is preferred over the suffix scan', () {
    // Two versions of one tag re-published: the current tag's file is chosen,
    // not whichever row happens to end the same way.
    final release = releaseWith([
      'Hongguo-0.3.9-linux-x64.deb',
      'Hongguo-0.4.0-linux-x64.deb',
    ]);
    expect(
      const UpdateTarget(
        platform: ReleasePlatform.linux,
        arch: 'x64',
      ).installer(release)!.name,
      'Hongguo-0.4.0-linux-x64.deb',
    );
  });
}
