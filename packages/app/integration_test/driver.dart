// Host-side driver for `flutter drive` running the on-device target
// mobile_episode_swipe_test.dart. The `flutter test` integration path cannot
// resolve this app's applicationId because the base AndroidManifest.xml uses an
// AGP `namespace` with no `package=` attribute and no launcher (the launcher is
// contributed only by the `mobile`/`tv` flavor manifests), so the tool aborts in
// ~0s with "No application found for TargetPlatform.android_arm64" before gradle
// even runs. `flutter drive` launches the built/installed APK like `flutter run`
// and is not affected. See findings.md.
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(timeout: const Duration(minutes: 15));
