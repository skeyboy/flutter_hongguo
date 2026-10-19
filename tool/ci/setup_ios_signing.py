#!/usr/bin/env python3
"""Ephemeral signing setup. Never print decoded profiles or passwords."""
import base64
import os
from pathlib import Path
import plistlib
import secrets
import subprocess
from release_meta import ROOT


def run(args, **kwargs):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
    if result.returncode:
        raise SystemExit(f'iOS signing command failed: {args[0]}; verify signing secrets')
    return result.stdout


folder = Path(os.environ['RUNNER_TEMP'])
for name in ('IOS_CERTIFICATE_BASE64', 'IOS_CERTIFICATE_PASSWORD', 'IOS_PROVISION_PROFILE_BASE64', 'IOS_EXPORT_OPTIONS_BASE64'):
    if not os.environ.get(name):
        raise SystemExit(f'Missing {name}')
cert = folder / 'signing.p12'
profile = folder / 'app.mobileprovision'
options = folder / 'ExportOptions.plist'
for path, source in [(cert, 'IOS_CERTIFICATE_BASE64'), (profile, 'IOS_PROVISION_PROFILE_BASE64'), (options, 'IOS_EXPORT_OPTIONS_BASE64')]:
    path.write_bytes(base64.b64decode(os.environ[source], validate=True))
    path.chmod(0o600)
export = plistlib.loads(options.read_bytes())
if export.get('method') not in ('release-testing', 'ad-hoc', 'enterprise'):
    raise SystemExit('Use device-installable release-testing/ad-hoc/enterprise export options')
record = plistlib.loads(run(['security', 'cms', '-D', '-i', str(profile)]))
profiles = Path.home() / 'Library/MobileDevice/Provisioning Profiles'
profiles.mkdir(parents=True, exist_ok=True)
(profiles / f'{record["UUID"]}.mobileprovision').write_bytes(profile.read_bytes())
keychain = folder / 'hongguo-signing.keychain-db'
password = secrets.token_urlsafe(32)
run(['security', 'create-keychain', '-p', password, str(keychain)])
run(['security', 'set-keychain-settings', '-lut', '21600', str(keychain)])
run(['security', 'unlock-keychain', '-p', password, str(keychain)])
run(['security', 'import', str(cert), '-P', os.environ['IOS_CERTIFICATE_PASSWORD'], '-A', '-t', 'cert', '-f', 'pkcs12', '-k', str(keychain)])
run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-k', password, str(keychain)])
run(['security', 'list-keychains', '-d', 'user', '-s', str(keychain)])
env = dict(os.environ, IOS_TEAM_ID=record['TeamIdentifier'][0], IOS_PROFILE_NAME=record['Name'])
run(['ruby', str(ROOT / 'tool/ci/configure_ios_project.rb')], env=env)
print('Ephemeral iOS signing configured.')
