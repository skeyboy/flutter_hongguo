#!/usr/bin/env bash
# Compatibility entry point: dispatch only. All builds/uploads run in Actions.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
platforms='["android","android-tv","macos","windows","linux"]'
if [[ $# -gt 0 ]]; then platforms="$1"; fi
gh workflow run release.yml --ref main -f "platforms=$platforms" -f ios=false
printf '%s\n' 'Release workflow dispatched. Follow progress in GitHub Actions.'
