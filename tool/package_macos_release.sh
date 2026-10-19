#!/usr/bin/env bash
# Package a previously built main.dart Release App; no build or global settings.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_bundle="$PROJECT_ROOT/packages/app/build/macos/Build/Products/Release/hongguo_app.app"
[[ -d "$app_bundle" ]] || { echo 'Build the main.dart macOS Release first.' >&2; exit 1; }
mac_arch="$(uname -m)"
release_stamp="$(date +%Y%m%d-%H%M%S)"
release_dir="$PROJECT_ROOT/artifacts/macos/$release_stamp"
mkdir -p "$release_dir"
/usr/bin/ditto "$app_bundle" "$release_dir/Hongguo.app"
/usr/bin/codesign --verify --deep --strict "$release_dir/Hongguo.app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$release_dir/Hongguo.app" "$release_dir/Hongguo-macos-$mac_arch.zip"
/usr/bin/shasum -a 256 "$release_dir/Hongguo-macos-$mac_arch.zip" > "$release_dir/SHA256SUMS.txt"
printf '%s\n' "$release_dir" > "$PROJECT_ROOT/artifacts/macos/latest-release.txt"
printf 'Release App: %s\n' "$release_dir/Hongguo.app"
printf 'Archive: %s\n' "$release_dir/Hongguo-macos-$mac_arch.zip"
