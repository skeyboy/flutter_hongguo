#!/usr/bin/env python3
"""Offline upstream protocol drift check. Does not fetch, modify pins or run code."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def check(reference, manifest, oracle):
    changed = []
    for name, expected in manifest['files'].items():
        path = reference / name
        actual = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
        if actual != expected:
            changed.append(name)
    signer = reference / 'server/src/core/pure-sign.js'
    matches_oracle = signer.is_file() and hashlib.sha256(signer.read_bytes()).hexdigest() == oracle.get('sourceSha256')
    revision = subprocess.check_output(['git', '-C', str(reference), 'rev-parse', 'HEAD'], text=True).strip()
    return {
        'pinnedRevision': manifest['revision'],
        'referenceRevision': revision,
        'revisionChanged': revision != manifest['revision'],
        'changedProtocolFiles': changed,
        'signerMatchesDartOracle': matches_oracle,
        'status': 'review_required' if changed or not matches_oracle else 'baseline_matches',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, default=ROOT / 'references/hongguo-web')
    args = parser.parse_args()
    manifest = json.loads((ROOT / 'tool/upstream_protocol.json').read_text())
    oracle = json.loads((ROOT / 'packages/core/test/fixtures/node_oracle.json').read_text())
    result = check(args.reference, manifest, oracle)
    print(json.dumps(result, indent=2))
    return 1 if result['status'] != 'baseline_matches' else 0


if __name__ == '__main__':
    sys.exit(main())
