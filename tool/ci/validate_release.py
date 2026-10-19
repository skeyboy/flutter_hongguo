#!/usr/bin/env python3
import os
from pathlib import Path
from release_meta import ROOT, version

release, _ = version()
folder = ROOT / 'dist'
required = ['macos-arm64.dmg', 'macos-arm64.zip', 'windows-x64-setup.exe', 'windows-x64.zip',
            'linux-x64.deb', 'linux-x64.tar.gz', 'android-armeabi-v7a.apk', 'android-arm64-v8a.apk', 'android-x86_64.apk']
for suffix in required:
    file = folder / f'Hongguo-{release}-{suffix}'
    if not file.exists() or file.stat().st_size == 0:
        raise SystemExit(f'Missing installer: {file.name}')
signed = os.environ.get('IOS_SIGNED') == 'true'
if signed and not (folder / f'Hongguo-{release}-ios-arm64.ipa').is_file():
    raise SystemExit('Signed iOS job succeeded but IPA is missing')
ios = 'Signed IPA included; install only on devices covered by its provisioning profile.' if signed else 'iOS device compilation passed. Apple signing is not configured, so no installable IPA is included.'
(folder / 'iOS-signing-status.txt').write_text(ios + '\n')
notes = ROOT / 'build/release-notes.md'
notes.parent.mkdir(exist_ok=True)
notes.write_text(f'''Native Flutter / shared Dart release {release}.

- Horizontal filter panel, immediate switching and cached catalog refresh.
- Local series library, offline episode autoplay and 3–5 episode prefetch.
- Android APKs use the repository's stable release key.
- Windows x64 installer/portable ZIP; Linux x64 DEB/tar; macOS arm64 DMG/ZIP.
- {ios}
- macOS is ad-hoc signed, not Apple-notarized; Windows is not Authenticode-signed.

All platform builds and offline workspace verification passed before publishing.
SHA256SUMS.txt and release-manifest.json describe the attached files.
''')
