#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_BIN="${HONGGUO_FLUTTER_BIN:-$PROJECT_ROOT/.fvm/flutter_sdk/bin}"
device_target="${1:-macos}"
mkdir -p "$PROJECT_ROOT/build/verification"
cd "$PROJECT_ROOT/packages/app"
"$SDK_BIN/flutter" test integration_test/offline_playback_test.dart -d "$device_target" \
  --no-pub --reporter expanded | tee "$PROJECT_ROOT/build/verification/native-playback-${device_target//[^a-zA-Z0-9]/_}.log"
