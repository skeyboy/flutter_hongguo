#!/usr/bin/env python3
"""Validate untrusted dispatch input before provisioning native runners."""
import json
import os

RUNNERS = {'android': 'ubuntu-24.04', 'linux': 'ubuntu-24.04',
           'windows': 'windows-2022', 'macos': 'macos-15'}


def selected_platforms(raw):
    try:
        values = json.loads(raw)
    except (ValueError, TypeError):
        raise SystemExit('Platforms must be a JSON array, for example ["android","macos"]')
    if not isinstance(values, list) or not values or any(not isinstance(p, str) or p not in RUNNERS for p in values):
        raise SystemExit('Choose one or more of android, macos, windows, linux; iOS signing is a separate switch')
    if len(set(values)) != len(values):
        raise SystemExit('Duplicate platforms are not allowed')
    return values


if __name__ == '__main__':
    platforms = selected_platforms(os.environ['PLATFORMS'])
    matrix = {'include': [{'platform': p, 'os': RUNNERS[p]} for p in platforms]}
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'matrix={json.dumps(matrix)}\n')
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
        output.write('## Selected installer builds\n\n' + ', '.join(platforms) + '\n\nNo device integration tests, unsigned iOS build, or duplicate main/tag build.\n')
