// A post-publish read of the live feed through the shipped kernel: does the
// release that is actually published look like an offer, an ignore or nothing,
// and does every platform get the file its device can install?
//
// This is not part of `dart test` or `tool/verify_all.sh` -- it needs the
// network, and its answer is only true for the release published right now.
// Run it after pushing a tag, passing the version the installed app reports:
//   (cd packages/update && dart run tool/live_feed_check.dart 0.3.13)
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hongguo_update/hongguo_update.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: live_feed_check.dart <installed-version> [more...]');
    exitCode = 64;
    return;
  }
  final feed = ReleaseFeed(
    dio: Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
      ),
    ),
  );
  final result = await feed.latest();
  final release = result.release;
  if (release == null) {
    stderr.writeln('status=${result.status} (no release parsed)');
    exitCode = 1;
    return;
  }
  const policy = UpdatePolicy();
  print(
    'status=${result.status} tag=${release.tag} '
    'prerelease=${release.prerelease} published=${release.publishedAt} '
    'notes=${release.notes.length} assets=${release.assets.length} '
    'etag=${result.etag}',
  );
  for (final version in args) {
    final current = ReleaseVersion.tryParse(version);
    if (current == null) {
      stderr.writeln('unparseable version: $version');
      exitCode = 1;
      continue;
    }
    print(
      'viewer on v$version -> ${policy.classify(current: current, feed: result)}'
      ' | ignoring ${release.tag} -> '
      '${policy.classify(current: current, feed: result, ignoredTag: release.tag)}',
    );
  }
  const targets = {
    'macos': UpdateTarget(platform: ReleasePlatform.macOS, arch: 'arm64'),
    'windows': UpdateTarget(platform: ReleasePlatform.windows, arch: 'x64'),
    'linux': UpdateTarget(platform: ReleasePlatform.linux, arch: 'x64'),
    'android': UpdateTarget(platform: ReleasePlatform.android),
    'ios': UpdateTarget(platform: ReleasePlatform.iOS),
  };
  targets.forEach((name, target) {
    final asset = target.installer(release);
    print(
      '$name -> ${asset?.name ?? 'NONE'} bytes=${asset?.bytes ?? 0} '
      'digest=${asset?.sha256 ?? 'NONE'} '
      'host=${asset == null ? '-' : Uri.parse(asset.downloadUrl).host}',
    );
  });
  print(
    'SHA256SUMS.txt=${release.assetNamed('SHA256SUMS.txt') != null} '
    'release-manifest.json=${release.assetNamed('release-manifest.json') != null}',
  );
}
