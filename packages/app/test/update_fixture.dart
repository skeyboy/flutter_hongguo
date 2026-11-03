import 'dart:typed_data';

import 'package:hongguo_update/hongguo_update.dart';

/// The installer bytes a fake release is made of, and the digest its feed
/// advertises for them.
///
/// `fixtureDigest` is `sha256` of `fixturePayload`, spelled as a literal so the
/// app's suites hash nothing themselves: the lanes under test hash whatever they
/// find on disk, and a payload that stopped matching its digest must fail loudly
/// rather than be quietly re-hashed here.
final Uint8List fixturePayload = Uint8List.fromList(
  List.generate(2048, (i) => i % 199),
);
final Uint8List fixtureWrongPayload = Uint8List.fromList(List.filled(2048, 3));
const fixtureDigest =
    '3b5bfef47dd9cee334031bceee9c908f65ee06b60b184a1d224851fd1f2f83e3';

const fixtureApkName = 'Hongguo-9.9.9-android-arm64-v8a.apk';
const fixtureDownloadUrl =
    'https://github.com/o/r/releases/download/v9.9.9/$fixtureApkName';

ReleaseAsset fixtureAsset({
  String name = fixtureApkName,
  String downloadUrl = fixtureDownloadUrl,
  String? sha256 = fixtureDigest,
  int bytes = 2048,
}) => ReleaseAsset(
  name: name,
  bytes: bytes,
  sha256: sha256,
  downloadUrl: downloadUrl,
  contentType: 'application/vnd.android.package-archive',
);

/// A release carrying every build this repository ships, so whichever host runs
/// the suite finds its own installer and no assertion depends on the machine.
ReleaseInfo fixtureRelease({
  String tag = 'v9.9.9',
  List<String> names = const [
    'Hongguo-9.9.9-macos-arm64.dmg',
    'Hongguo-9.9.9-macos-x64.dmg',
    'Hongguo-9.9.9-windows-x64-setup.exe',
    'Hongguo-9.9.9-linux-x64.deb',
    fixtureApkName,
  ],
}) => ReleaseInfo(
  tag: tag,
  version: ReleaseVersion.tryParse(tag)!,
  title: tag,
  notes: 'note',
  prerelease: false,
  htmlUrl: 'https://github.com/o/r/releases/tag/$tag',
  publishedAt: DateTime.utc(2026, 11, 1),
  assets: [
    for (final name in names)
      fixtureAsset(
        name: name,
        downloadUrl: 'https://github.com/o/r/releases/download/$tag/$name',
      ),
  ],
);
