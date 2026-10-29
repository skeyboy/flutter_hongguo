import 'dart:convert';
import 'dart:io';

import 'package:hongguo_update/hongguo_update.dart';

/// The v0.3.13 release as GitHub actually answered for it -- 15 attachments,
/// the rolling release note, digests included. Every test that cares about
/// "which file does this device install" reads this instead of inventing a
/// shape the feed may never send.
ReleaseInfo pinnedRelease([Map<String, dynamic> overrides = const {}]) {
  final json =
      (jsonDecode(
            File('test/fixtures/github_release_latest.json').readAsStringSync(),
          ) as Map<String, dynamic>)['response']
          as Map<String, dynamic>;
  return ReleaseInfo.fromJson({...json, ...overrides});
}

/// A release built from nothing but a name list, for the selection rules.
ReleaseInfo releaseWith(List<String> names, {String tag = 'v0.4.0'}) =>
    ReleaseInfo.fromJson({
      'tag_name': tag,
      'name': tag,
      'body': 'note',
      'prerelease': false,
      'assets': [
        for (final name in names)
          {
            'name': name,
            'size': 1024,
            'browser_download_url':
                'https://github.com/o/r/releases/download/$tag/$name',
          },
      ],
    });
