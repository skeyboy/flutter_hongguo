#!/usr/bin/env python3
import os
from pathlib import Path
from release_meta import ROOT, version

release, _ = version()
folder = ROOT / 'dist'
from plan_build import selected_platforms
platforms = selected_platforms(os.environ.get('RELEASE_PLATFORMS', '["android","macos","windows","linux"]'))
assets = {
    'macos': ['macos-arm64.dmg', 'macos-arm64.zip'],
    'windows': ['windows-x64-setup.exe', 'windows-x64.zip'],
    'linux': ['linux-x64.deb', 'linux-x64.tar.gz'],
    'android-tv': ['android-tv-armeabi-v7a.apk', 'android-tv-arm64-v8a.apk', 'android-tv-x86_64.apk'],
    'android': ['android-armeabi-v7a.apk', 'android-arm64-v8a.apk', 'android-x86_64.apk'],
}
required = [suffix for platform in platforms for suffix in assets[platform]]
for suffix in required:
    file = folder / f'Hongguo-{release}-{suffix}'
    if not file.exists() or file.stat().st_size == 0:
        raise SystemExit(f'Missing installer: {file.name}')
signed = os.environ.get('IOS_SIGNED') == 'true'
if signed and not (folder / f'Hongguo-{release}-ios-arm64.ipa').is_file():
    raise SystemExit('Signed iOS job succeeded but IPA is missing')
ios = 'Signed IPA included; install only on devices covered by its provisioning profile.' if signed else 'iOS was not built in this run. Enable signed iOS explicitly to attach an installable IPA.'
(folder / 'iOS-signing-status.txt').write_text(ios + '\n')
notes = ROOT / 'build/release-notes.md'
notes.parent.mkdir(exist_ok=True)
notes.write_text(f'''Native Flutter / shared Dart release {release}.

- My library: favorites, per-episode watch history, resume playback and offline series.
- Episode downloads: select episodes and quality, manage tasks, retry and play offline.
- Manual downloads survive ordinary cache cleanup; resumed tasks keep independent recovery journals.
- Adaptive immersive player, unified episode/settings panel, auto_route navigation and cached images.
- Application names follow the system language (English, Simplified and Traditional Chinese).
- Only the selected platforms are built in this run; see the platform list below.
- Android APKs, when selected, use the repository's stable release key.
- {ios}
- macOS is ad-hoc signed, not Apple-notarized; Windows is not Authenticode-signed.

GitHub Actions analysis, shared Dart/core/API tests and Flutter widget tests passed before native builds.
Selected platform builds and installer completeness checks passed before publishing.
Device integration tests were not run in this release workflow; local platform validation limits are documented in the repository.
Platforms built in this run: {', '.join(platforms)}.
SHA256SUMS.txt and release-manifest.json describe the attached files.
''')
