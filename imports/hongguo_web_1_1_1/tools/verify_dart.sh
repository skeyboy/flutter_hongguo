#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -x "$project_root/../../.fvm/flutter_sdk/bin/flutter" ]]; then
  export PATH="$project_root/../../.fvm/flutter_sdk/bin:$PATH"
fi
cd "$project_root"
# Enforce the boundary independently of the UI/backend tests.
if rg -n "^import ['\"](dart:(io|isolate)|package:flutter/)" packages/hongguo_core/lib; then
  echo 'Core must not import platform implementations or Flutter.' >&2
  exit 1
fi
cd "$project_root/packages/hongguo_core"
dart pub get
dart format --output=none --set-exit-if-changed lib test
dart analyze
dart test --reporter expanded
cd "$project_root/apps/hongguo_flutter"
flutter pub get
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test --reporter expanded
