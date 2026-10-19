#!/usr/bin/env bash
# Explicitly opt in to one selected episode, optionally with 3–5 cached successors.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_BIN="${HONGGUO_FLUTTER_BIN:-$PROJECT_ROOT/.fvm/flutter_sdk/bin}"
series_id="${1:-}"
episode_vid="${2:-}"
prefetch_count="${3:-0}"
case "$prefetch_count" in 0|3|4|5) ;; *) echo "Prefetch count must be 0, 3, 4 or 5" >&2; exit 1;; esac
mac_poc_log=macos-live-playback.log
if [[ "$prefetch_count" != 0 ]]; then mac_poc_log=macos-live-prefetch.log; fi
[[ "$(uname -s)" == Darwin ]] || { echo 'This acceptance script targets macOS.' >&2; exit 1; }
[[ "$series_id" =~ ^[0-9]{1,30}$ && "$episode_vid" =~ ^[0-9]{1,30}$ ]] || {
  echo 'Usage: ./tool/verify_mac_live.sh SERIES_ID FIRST_EPISODE_VID [PREFETCH_COUNT]' >&2; exit 1;
}
mkdir -p "$PROJECT_ROOT/build/verification"
cd "$PROJECT_ROOT/packages/app"
"$SDK_BIN/flutter" test integration_test/macos_live_poc_test.dart -d macos --no-pub \
  --dart-define="HONGGUO_POC_SERIES_ID=$series_id" \
  --dart-define="HONGGUO_POC_VID=$episode_vid" --dart-define="HONGGUO_POC_PREFETCH=$prefetch_count" --reporter expanded \
  | tee "$PROJECT_ROOT/build/verification/$mac_poc_log"
