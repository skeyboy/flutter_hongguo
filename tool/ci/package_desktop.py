#!/usr/bin/env python3
"""Package the complete native bundle, including player libraries."""
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import zipfile
from release_meta import ROOT, version

RELEASE, _ = version()
APP = ROOT / 'packages/app'
DIST = ROOT / 'dist'
DIST.mkdir(exist_ok=True)


def macos():
    bundle = APP / 'build/macos/Build/Products/Release/hongguo_app.app'
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    if info['CFBundleShortVersionString'] != RELEASE:
        raise SystemExit('The macOS bundle version does not match pubspec')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
    stage = DIST / 'macos-stage'
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir()
    shutil.copytree(bundle, stage / 'Hongguo.app', dirs_exist_ok=True, symlinks=True)
    (stage / 'Applications').symlink_to('/Applications', target_is_directory=True)
    prefix = DIST / f'Hongguo-{RELEASE}-macos-arm64'
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(stage / 'Hongguo.app'), f'{prefix}.zip'], check=True)
    subprocess.run(['hdiutil', 'create', '-volname', 'Hongguo', '-srcfolder', str(stage), '-ov', '-format', 'UDZO', f'{prefix}.dmg'], check=True)
    shutil.rmtree(stage)


def windows():
    bundle = APP / 'build/windows/x64/runner/Release'
    if not (bundle / 'hongguo_app.exe').exists():
        raise SystemExit('Missing Windows bundle')
    # Ship the app-local VC runtime so a clean Windows machine can launch it.
    locator = Path(os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)')) / 'Microsoft Visual Studio/Installer/vswhere.exe'
    installation = subprocess.check_output([str(locator), '-latest', '-products', '*', '-property', 'installationPath'], text=True).strip()
    candidates = sorted(Path(installation).glob('VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT'))
    if not candidates:
        raise SystemExit('Visual C++ redistributable runtime is missing')
    for library in candidates[-1].glob('*.dll'):
        shutil.copy2(library, bundle / library.name)
    archive = DIST / f'Hongguo-{RELEASE}-windows-x64.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as output:
        for path in sorted(bundle.rglob('*')):
            if path.is_file():
                output.write(path, Path('Hongguo') / path.relative_to(bundle))
    compiler = shutil.which('iscc') or r'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
    subprocess.run([compiler, f'/DAppVersion={RELEASE}', f'/DSourceDir={bundle}', f'/DOutputDir={DIST}', str(ROOT / 'tool/ci/windows-installer.iss')], check=True)


def linux():
    bundle = APP / 'build/linux/x64/release/bundle'
    if not (bundle / 'hongguo_app').exists():
        raise SystemExit('Missing Linux bundle')
    with tarfile.open(DIST / f'Hongguo-{RELEASE}-linux-x64.tar.gz', 'w:gz') as output:
        output.add(bundle, arcname='Hongguo')
    stage = DIST / 'deb-stage'
    if stage.exists():
        shutil.rmtree(stage)
    (stage / 'DEBIAN').mkdir(parents=True)
    shutil.copytree(bundle, stage / 'opt/hongguo', symlinks=True, dirs_exist_ok=True)
    control = f'''Package: hongguo
Version: {RELEASE}
Architecture: amd64
Maintainer: Hongguo contributors
Depends: libgtk-3-0t64 | libgtk-3-0, libsecret-1-0, libmpv2, libasound2t64 | libasound2
Section: video
Priority: optional
Description: Hongguo Flutter native video client
'''
    (stage / 'DEBIAN/control').write_text(control)
    launcher = stage / 'usr/bin/hongguo'
    launcher.parent.mkdir(parents=True, exist_ok=True)
    launcher.write_text('#!/bin/sh\nexec /opt/hongguo/hongguo_app "$@"\n')
    launcher.chmod(0o755)
    desktop = stage / 'usr/share/applications/hongguo.desktop'
    desktop.parent.mkdir(parents=True, exist_ok=True)
    desktop.write_text('[Desktop Entry]\nType=Application\nName=Hongguo\nExec=hongguo\nIcon=hongguo\nTerminal=false\nCategories=AudioVideo;Video;\n')
    icon = stage / 'usr/share/icons/hicolor/256x256/apps/hongguo.png'
    icon.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(APP / 'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png', icon)
    subprocess.run(['dpkg-deb', '--root-owner-group', '--build', str(stage), str(DIST / f'Hongguo-{RELEASE}-linux-x64.deb')], check=True)
    shutil.rmtree(stage)


if __name__ == '__main__':
    {'macos': macos, 'windows': windows, 'linux': linux}[sys.argv[1]]()
