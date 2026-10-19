#!/usr/bin/env python3
import base64
import os
from pathlib import Path

names = ['KEYSTORE', 'STORE_PASSWORD', 'KEY_PASSWORD', 'KEY_ALIAS']
if any(not os.environ.get(name) for name in names):
    raise SystemExit('Android release signing secrets are required; see docs/github-release.md')
path = Path(os.environ['RUNNER_TEMP']) / 'hongguo-release.jks'
path.write_bytes(base64.b64decode(os.environ['KEYSTORE'], validate=True))
path.chmod(0o600)
with open(os.environ['GITHUB_ENV'], 'a') as output:
    for target, source in [('ANDROID_KEYSTORE_PATH', None), ('ANDROID_STORE_PASSWORD', 'STORE_PASSWORD'),
                           ('ANDROID_KEY_PASSWORD', 'KEY_PASSWORD'), ('ANDROID_KEY_ALIAS', 'KEY_ALIAS')]:
        value = str(path) if source is None else os.environ[source]
        if '\n' in value or '\r' in value:
            raise SystemExit('Invalid signing secret')
        output.write(f'{target}={value}\n')
