/// The update kernel: what is published, whether it is newer, which attachment
/// belongs to this device, and whether the bytes we got are the bytes they
/// shipped. No Flutter, no platform channels -- `packages/app` supplies the
/// transport, the platform and the UI.
library;

export 'src/release_downloader.dart';
export 'src/release_feed.dart';
export 'src/release_info.dart';
export 'src/release_version.dart';
export 'src/update_policy.dart';
export 'src/update_target.dart';
