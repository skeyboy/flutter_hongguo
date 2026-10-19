#!/usr/bin/env python3
"""Create a stable ignored keystore; optionally upload it to GitHub secrets."""
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
from release_meta import ROOT

folder = ROOT / 'artifacts/signing/android'
folder.mkdir(parents=True, exist_ok=True)
folder.chmod(0o700)
metadata = folder / 'signing.json'
store = folder / 'release.jks'
if not metadata.exists():
    if store.exists():
        raise SystemExit('Keystore exists without metadata; do not overwrite it')
    password = secrets.token_urlsafe(32)
    data = {'alias': 'hongguo', 'storePassword': password, 'keyPassword': password}
    env = dict(os.environ, HONGGUO_SIGNING_PASSWORD=password)
    subprocess.run(['keytool', '-genkeypair', '-keystore', str(store), '-storetype', 'JKS',
                    '-alias', data['alias'], '-keyalg', 'RSA', '-keysize', '3072',
                    '-validity', '10000', '-dname', 'CN=Hongguo',
                    '-storepass:env', 'HONGGUO_SIGNING_PASSWORD',
                    '-keypass:env', 'HONGGUO_SIGNING_PASSWORD'], env=env, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    store.chmod(0o600)
    metadata.write_text(json.dumps(data))
    metadata.chmod(0o600)
print('Stable Android keystore is ready in ignored artifacts/signing/android; back it up.')
if '--upload' in sys.argv:
    repo = sys.argv[sys.argv.index('--repo') + 1]
    subprocess.run(['gh', 'auth', 'status'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    data = json.loads(metadata.read_text())
    values = {'ANDROID_KEYSTORE_BASE64': base64.b64encode(store.read_bytes()).decode(),
              'ANDROID_STORE_PASSWORD': data['storePassword'], 'ANDROID_KEY_PASSWORD': data['keyPassword'],
              'ANDROID_KEY_ALIAS': data['alias']}
    for name, value in values.items():
        subprocess.run(['gh', 'secret', 'set', name, '--repo', repo], input=value.encode(), check=True)
    print('Android signing secrets configured.')
