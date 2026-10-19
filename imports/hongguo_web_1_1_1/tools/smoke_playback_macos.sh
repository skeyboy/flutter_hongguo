#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -x "$project_root/../../.fvm/flutter_sdk/bin/flutter" ]]; then
  export PATH="$project_root/../../.fvm/flutter_sdk/bin:$PATH"
fi
smoke_config="$(mktemp -t hongguo-playback).json"
trap 'rm -f "$smoke_config"' EXIT
node - "$project_root" "$smoke_config" <<'JS'
const fs=require('node:fs'),path=require('node:path');
const [root,out]=process.argv.slice(2),fixtures=path.join(root,'packages/hongguo_core/test/fixtures');
const truth=JSON.parse(fs.readFileSync(path.join(fixtures,'spade.json')));
fs.writeFileSync(out,JSON.stringify({HONGGUO_SMOKE_FIXTURE:fs.readFileSync(path.join(fixtures,'playable-encrypted.mp4')).toString('base64'),HONGGUO_SMOKE_SPADE:Buffer.from(truth[0][0],'hex').toString('base64')}));
JS
cd "$project_root/apps/hongguo_flutter"
flutter build macos --release --target=tool/playback_smoke_app.dart --dart-define-from-file="$smoke_config"
./build/macos/Build/Products/Release/hongguo_flutter.app/Contents/MacOS/hongguo_flutter
