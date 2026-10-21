#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
SDK_BIN="${HONGGUO_FLUTTER_BIN:-$PROJECT_ROOT/.fvm/flutter_sdk/bin}"
if [[ ! -x "$SDK_BIN/dart" || ! -x "$SDK_BIN/flutter" ]]; then
  echo 'Set HONGGUO_FLUTTER_BIN to the Flutter 3.47.4 bin directory, or run fvm install.' >&2
  exit 1
fi
mkdir -p build/verification
"$SDK_BIN/flutter" pub get > build/verification/pub.log 2>&1
"$SDK_BIN/dart" format --output=none --set-exit-if-changed packages tool
"$SDK_BIN/dart" analyze --fatal-infos | tee build/verification/analyze.log
(cd packages/core && "$SDK_BIN/dart" test --reporter expanded) | tee build/verification/core-tests.log
(cd packages/api && "$SDK_BIN/dart" test --reporter expanded) | tee build/verification/api-tests.log
(cd packages/cast && "$SDK_BIN/dart" test --reporter expanded) | tee build/verification/cast-tests.log
# Dart's XML reader tolerates undeclared namespace prefixes; a strict parser does not.
"$SDK_BIN/dart" run tool/verify_cast_didl.dart \
  | python3 tool/verify_didl_namespaces.py | tee build/verification/cast-didl.log
(cd packages/tv && "$SDK_BIN/flutter" test --no-pub --reporter expanded) | tee build/verification/tv-tests.log
(cd packages/app && "$SDK_BIN/flutter" test --no-pub --reporter expanded) | tee build/verification/widget-tests.log
"$SDK_BIN/dart" compile exe tool/verify_portable.dart -o build/verification/native_oracle
./build/verification/native_oracle | tee build/verification/aot.log
"$SDK_BIN/dart" compile js -O2 tool/verify_portable.dart -o build/verification/web_oracle.js
# Node is an execution host for dart2js output here; it is not an app dependency.
node -e 'globalThis.self=globalThis; require(process.argv[1]);' \
  "$PROJECT_ROOT/build/verification/web_oracle.js" | tee build/verification/js.log

"$SDK_BIN/dart" run tool/verify_media.dart | tee build/verification/media.log
if command -v ffprobe >/dev/null 2>&1 && command -v ffmpeg >/dev/null 2>&1; then
  ffprobe -v error -show_entries stream=codec_name,codec_type,width,height -of json \
    build/verification/offline-decrypted.mp4 > build/verification/ffprobe-media.json
  ffmpeg -hide_banner -v error -i build/verification/offline-decrypted.mp4 -f null - \
    > build/verification/ffmpeg-decode.log 2>&1
fi
