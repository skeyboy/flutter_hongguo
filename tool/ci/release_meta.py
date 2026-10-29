#!/usr/bin/env python3
"""Release metadata/checksums without third-party Python dependencies."""
import hashlib
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]


def version():
    values = []
    for path in (ROOT / 'pubspec.yaml', ROOT / 'packages/app/pubspec.yaml'):
        match = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$', path.read_text(), re.M)
        if not match:
            raise SystemExit(f'Invalid version in {path.name}')
        values.append(match.groups())
    if values[0] != values[1]:
        raise SystemExit('Root/app versions differ')
    # The running app reads its own version from one Dart constant; a release
    # whose constant lags the pubspec would tell users they are current while
    # the tag says otherwise.
    app_release = (ROOT / 'packages/app/lib/update/app_release.dart').read_text()
    for pattern, expected in (
        (r"static const version = '([^']+)';", values[0][0]),
        (r'static const build = (\d+);', values[0][1]),
    ):
        match = re.search(pattern, app_release)
        if match is None or match.group(1) != expected:
            raise SystemExit(f'app_release.dart must say {expected}')
    if json.loads((ROOT / '.fvmrc').read_text())['flutter'] != '3.47.4':
        raise SystemExit('Update the CI Flutter version when changing .fvmrc')
    tag = os.environ.get('GITHUB_REF', '')
    if tag.startswith('refs/tags/') and tag != f'refs/tags/v{values[0][0]}':
        raise SystemExit('Release tag must match pubspec version')
    return values[0]


def main():
    release, build = version()
    if len(sys.argv) == 1 or sys.argv[1] == 'version':
        print(release)
    elif sys.argv[1] == 'checksums':
        folder = Path(sys.argv[2])
        files = sorted(p for p in folder.iterdir() if p.is_file() and p.name not in ('SHA256SUMS.txt', 'release-manifest.json'))
        if not files:
            raise SystemExit('No release assets')
        records = []
        for path in files:
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            records.append({'name': path.name, 'bytes': path.stat().st_size, 'sha256': digest})
        manifest = folder / 'release-manifest.json'
        manifest.write_text(json.dumps({'version': release, 'build': build, 'commit': os.environ.get('GITHUB_SHA'), 'assets': records}, indent=2) + '\n')
        files.append(manifest)
        (folder / 'SHA256SUMS.txt').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in files))
    else:
        raise SystemExit('Usage: release_meta.py [version|checksums DIRECTORY]')


if __name__ == '__main__':
    main()
