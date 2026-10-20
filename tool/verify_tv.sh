#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_BIN="${HONGGUO_FLUTTER_BIN:-$PROJECT_ROOT/.fvm/flutter_sdk/bin}"
cd "$PROJECT_ROOT"
"$SDK_BIN/flutter" pub get
"$SDK_BIN/dart" analyze --fatal-infos
(cd packages/tv && "$SDK_BIN/flutter" test --no-pub --reporter expanded)
(cd packages/app && "$SDK_BIN/flutter" test --no-pub --reporter expanded)
(cd packages/app && "$SDK_BIN/flutter" test test/tv_settings_test.dart --no-pub --dart-define=HONGGUO_TV=true --reporter expanded)
python3 -m unittest discover -s tool/ci/tests -v
if [[ -n "${1:-}" ]]; then
  cd packages/app
  "$SDK_BIN/flutter" test integration_test/tv_remote_test.dart --flavor tv -d "$1" --reporter expanded
fi
