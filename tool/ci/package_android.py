#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import subprocess
from release_meta import ROOT, version
from tv_package import badging_problems

flavor=os.environ.get('ANDROID_FLAVOR','mobile')
if flavor not in ('mobile','tv'):
    raise SystemExit('Unsupported Android flavor')
release, _ = version()
folder = ROOT / 'dist'
folder.mkdir(exist_ok=True)
sdk = Path(os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT'])
signers = sorted(sdk.glob('build-tools/*/apksigner'))
if not signers:
    raise SystemExit('Android SDK apksigner is missing')
dumpers = sorted(sdk.glob('build-tools/*/aapt2'))
if flavor == 'tv' and not dumpers:
    raise SystemExit('Android SDK aapt2 is missing, so the TV build cannot be verified')
for abi in ('armeabi-v7a', 'arm64-v8a', 'x86_64'):
    source = ROOT / f'packages/app/build/app/outputs/flutter-apk/app-{abi}-{flavor}-release.apk'
    subprocess.run([str(signers[-1]), 'verify', str(source)], check=True)
    if flavor == 'tv':
        badging = subprocess.run([str(dumpers[-1]), 'dump', 'badging', str(source)],
                                 check=True, capture_output=True, text=True).stdout
        problems = badging_problems(badging)
        if problems:
            raise SystemExit(f'{abi} TV APK is not publishable:\n- ' + '\n- '.join(problems))
    shutil.copy2(source, folder / f'Hongguo-{release}-android-{"tv-" if flavor == "tv" else ""}{abi}.apk')
