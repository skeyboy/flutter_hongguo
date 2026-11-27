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
(folder / 'iOS-signing-status.txt').write_text(ios + '\n', encoding='utf-8')

notes_template = (ROOT / 'docs/release-notes.md').read_text(encoding='utf-8')
for heading in ('## 修改了什么', '## 修复了什么', '## 增加了什么'):
    if heading not in notes_template:
        raise SystemExit(f'Release notes must contain {heading}')
# 模板没有占位符时会生成写死版本号的发布说明，而且不会报错——发布门禁要在
# 写文件之前就把这件事挡下来。
if '$VERSION' not in notes_template:
    raise SystemExit('Release notes must contain the $VERSION placeholder')
notes = ROOT / 'build/release-notes.md'
notes.parent.mkdir(exist_ok=True)
notes.write_text(notes_template.replace('$VERSION', release), encoding='utf-8')
