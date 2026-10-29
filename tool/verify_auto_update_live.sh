#!/usr/bin/env bash
# Live on-device evidence for the in-app update chain: runs the shipping app
# through integration_test/auto_update_live_test.dart against the real GitHub
# release feed, takes a full-screen still at each HGUPD marker the fixture
# prints, and crops it to the window rect from the HGWIN line. Committed frames
# land in docs/evidence/auto-update/.
#
# The run needs AppRelease.version (packages/app/lib/update/app_release.dart) to
# sit behind the published tag, otherwise there is nothing to update to; the
# script refuses to capture against a build that cannot show the prompt.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_BIN="${HONGGUO_FLUTTER_BIN:-$PROJECT_ROOT/.fvm/flutter_sdk/bin}"
BUILD="$PROJECT_ROOT/build/verification/auto-update"
EVIDENCE="$PROJECT_ROOT/docs/evidence/auto-update"
LOG="$BUILD/run.log"
[[ "$(uname -s)" == Darwin ]] || { echo 'This acceptance script targets macOS.' >&2; exit 1; }
command -v screencapture >/dev/null || { echo 'screencapture not found.' >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo 'ffmpeg is needed to crop the stills.' >&2; exit 1; }

# The feed is the published releases, so the running build has to be older than
# its own tag for anything to prompt.
LATEST_TAG=$(git -C "$PROJECT_ROOT" describe --tags --abbrev=0)
RUNNING=$(sed -nE "s/.*static const version = '([^']+)'.*/\1/p" \
  "$PROJECT_ROOT/packages/app/lib/update/app_release.dart")
if [[ "$RUNNING" == "${LATEST_TAG#v}" ]]; then
  echo "$LATEST_TAG is already the newest release: lower AppRelease.version in packages/app/lib/update/app_release.dart by one patch number for this run, and put it back afterwards." >&2
  exit 1
fi

rm -rf "$BUILD"; mkdir -p "$BUILD" "$EVIDENCE"
cd "$PROJECT_ROOT/packages/app"
"$SDK_BIN/flutter" test integration_test/auto_update_live_test.dart \
  -d macos --no-pub --reporter expanded > "$LOG" 2>&1 &
TEST_PID=$!

echo 'Waiting for the live app to arm (first run builds it)...'
while kill -0 "$TEST_PID" 2>/dev/null; do
  grep -q 'ev=armed' "$LOG" && break
  sleep 1
done
grep -q 'ev=armed' "$LOG" || { echo 'The fixture never armed:'; tail -30 "$LOG"; exit 1; }

# One still per named moment. The fixture holds each one idle for two seconds,
# which is the window this loop polls.
SEEN=''
while kill -0 "$TEST_PID" 2>/dev/null; do
  for NAME in dialog-prompt dialog-scrolled downloading settings-handoff \
              settings-check done; do
    case "$SEEN" in *"|$NAME|"*) continue ;; esac
    if grep -q "ev=$NAME" "$LOG"; then
      SEEN="$SEEN|$NAME|"
      [[ "$NAME" == done ]] && continue
      screencapture -x -t png "$BUILD/raw-$NAME.png"
      echo "captured $NAME"
    fi
  done
  sleep 0.1
done
set +e
wait "$TEST_PID"
TEST_STATUS=$?
set -e
grep -E '^HGWIN|^HGUPD' "$LOG"
if [[ "$TEST_STATUS" != 0 ]]; then echo 'The fixture failed:'; tail -40 "$LOG"; exit "$TEST_STATUS"; fi

python3 - "$LOG" "$BUILD" "$EVIDENCE" <<'PY'
import os, re, subprocess, sys

log, build, evidence = sys.argv[1:4]
text = open(log, encoding='utf-8', errors='replace').read()
window = re.search(
    r'HGWIN x=(-?\d+) y=(-?\d+) w=(\d+) h=(\d+).*display=(\d+)x(\d+)', text)
if not window:
    raise SystemExit('no HGWIN line in the fixture log')
x, y, w, h, disp_w, _ = map(int, window.groups())

for name in ('dialog-prompt', 'dialog-scrolled', 'downloading',
             'settings-handoff', 'settings-check'):
    raw = f'{build}/raw-{name}.png'
    if not os.path.exists(raw):
        print(f'{name}: no still captured', file=sys.stderr)
        continue
    pixels = subprocess.check_output(
        ['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', raw]).decode()
    size = {k: int(v) for k, v in
            (line.split(':', 1) for line in pixels.splitlines() if ':' in line)}
    scale = size['pixelWidth'] / disp_w
    out = f'{evidence}/{name}.png'
    subprocess.run(
        ['ffmpeg', '-y', '-v', 'error', '-i', raw,
         '-vf', f'crop={int(w * scale)}:{int(h * scale)}:{int(x * scale)}:{int(y * scale)}',
         out], check=True)
    print(f'{name} -> {out} ({int(w * scale)}x{int(h * scale)})')
PY

# The full-screen stills are not committed; only the window crops are.
rm -f "$BUILD"/raw-*.png
