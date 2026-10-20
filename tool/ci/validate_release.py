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

- Horizontal filter panel, immediate switching and cached catalog refresh.
- Local series library, offline episode autoplay and 3–5 episode prefetch.
- Only the selected platforms are built in this run; see the platform list below.
- Android APKs, when selected, use the repository's stable release key.
- {ios}
- macOS is ad-hoc signed, not Apple-notarized; Windows is not Authenticode-signed.

Selected platform builds and installer completeness checks passed before publishing.
No device integration tests or full offline workspace verification were run in this packaging workflow.
Platforms built in this run: {', '.join(platforms)}.
SHA256SUMS.txt and release-manifest.json describe the attached files.
''')
