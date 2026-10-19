#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import subprocess
from release_meta import ROOT, version

release, _ = version()
folder = ROOT / 'dist'
folder.mkdir(exist_ok=True)
sdk = Path(os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT'])
signers = sorted(sdk.glob('build-tools/*/apksigner'))
if not signers:
    raise SystemExit('Android SDK apksigner is missing')
for abi in ('armeabi-v7a', 'arm64-v8a', 'x86_64'):
    source = ROOT / f'packages/app/build/app/outputs/flutter-apk/app-{abi}-release.apk'
    subprocess.run([str(signers[-1]), 'verify', str(source)], check=True)
    shutil.copy2(source, folder / f'Hongguo-{release}-android-{abi}.apk')
