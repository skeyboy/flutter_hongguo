#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_BIN="${HONGGUO_FLUTTER_BIN:-$PROJECT_ROOT/.fvm/flutter_sdk/bin}"
device_target="${1:-macos}"
mkdir -p "$PROJECT_ROOT/build/verification"
platform="$("$SDK_BIN/flutter" devices --machine | python3 -c 'import json,sys; target=sys.argv[1]; print(next((d.get("targetPlatform", "") for d in json.load(sys.stdin) if d.get("id")==target or d.get("name")==target), ""))' "$device_target")"
flavor_args=()
if [[ "$platform" == android* ]]; then flavor_args=(--flavor mobile); fi
cd "$PROJECT_ROOT/packages/app"
"$SDK_BIN/flutter" test integration_test/offline_playback_test.dart "${flavor_args[@]}" -d "$device_target" \
  --no-pub --reporter expanded | tee "$PROJECT_ROOT/build/verification/native-playback-${device_target//[^a-zA-Z0-9]/_}.log"
