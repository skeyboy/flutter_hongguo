#!/usr/bin/env bash
# One live measurement of 同时下载数量 on a device the operator owns: it drives
# integration_test/download_concurrency_live_test.dart and keeps the raw log.
# The fixture only ever adds and removes its own download tasks.
#
#   ./tool/verify_download_concurrency_live.sh <device-id> <series-id> <limit> <log-path> [flavor]
#
# Limit is the 档位 under test (3 or 5). Series must have at least limit+1
# episodes this device has never downloaded; the fixture refuses to run if not.
# Android devices need the flavor the manifest declares (mobile or tv); omit it
# on desktop, where a flavor is not part of the build.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_BIN="${HONGGUO_FLUTTER_BIN:-$PROJECT_ROOT/.fvm/flutter_sdk/bin}"
device="${1:-}"
series_id="${2:-}"
limit="${3:-}"
log="${4:-}"
flavor="${5:-}"
[[ "$device" != '' && "$log" != '' ]] || { echo 'Device and log path are required' >&2; exit 1; }
case "$limit" in 3 | 5) ;; *) echo 'Limit must be 3 or 5' >&2; exit 1;; esac
case "$flavor" in '' | mobile | tv) ;; *) echo 'Flavor must be mobile or tv' >&2; exit 1;; esac
[[ "$series_id" =~ ^[0-9]{1,30}$ ]] || {
  echo 'Usage: ./tool/verify_download_concurrency_live.sh DEVICE SERIES_ID LIMIT LOG [FLAVOR]' >&2
  exit 1
}
extra=()
[[ "$flavor" == '' ]] || extra=(--flavor "$flavor")
mkdir -p "$(dirname "$log")"
cd "$PROJECT_ROOT/packages/app"
"$SDK_BIN/flutter" test integration_test/download_concurrency_live_test.dart \
  -d "$device" --no-pub ${extra[@]+"${extra[@]}"} \
  --dart-define="HONGGUO_POC_SERIES_ID=$series_id" \
  --dart-define="HONGGUO_DOWNLOAD_CONCURRENT=$limit" \
  --reporter expanded 2>&1 | tee "$log"
