#!/usr/bin/env bash
# Live on-device evidence for the theme rail: runs the real app through
# integration_test/theme_rail_live_test.dart, records the screen while it
# enters 分类 and walks 题材 -> 题材 -> back, and pulls one still per marked
# state into docs/evidence/theme-rail/.
#
# HONGGUO_RAIL_DEVICE selects the target: macos (default) or an iOS simulator
# UDID/name. macOS cannot record a single window, so that clip is full-screen
# and every still is cropped to the window rect the fixture reports; a
# simulator recording is already exactly the device screen.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_BIN="${HONGGUO_FLUTTER_BIN:-$PROJECT_ROOT/.fvm/flutter_sdk/bin}"
BUILD="$PROJECT_ROOT/build/verification/theme-rail"
EVIDENCE="$PROJECT_ROOT/docs/evidence/theme-rail"
LOG="$BUILD/run.log"
DEVICE="${HONGGUO_RAIL_DEVICE:-macos}"
RECORD_SECONDS="${HONGGUO_RAIL_SECONDS:-30}"
[[ "$(uname -s)" == Darwin ]] || { echo 'This acceptance script targets macOS.' >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo 'ffmpeg is needed to cut the clip.' >&2; exit 1; }
if [[ "$DEVICE" == macos ]]; then
  CLIP="$BUILD/clip.mov"
  command -v screencapture >/dev/null || { echo 'screencapture not found.' >&2; exit 1; }
else
  # simctl's recorder is an AVFoundation writer and is denied the project volume,
  # so the clip is staged in the scratch directory and only its stills are kept.
  CLIP="${TMPDIR:-/tmp}/hongguo-theme-rail-clip.mp4"
  command -v xcrun >/dev/null || { echo 'xcrun is needed to record the simulator.' >&2; exit 1; }
fi
rm -rf "$BUILD"; mkdir -p "$BUILD" "$EVIDENCE"

cd "$PROJECT_ROOT/packages/app"
"$SDK_BIN/flutter" test integration_test/theme_rail_live_test.dart \
  -d "$DEVICE" --no-pub --reporter expanded > "$LOG" 2>&1 &
TEST_PID=$!

echo 'Waiting for the live rail to arm (first run builds the app)...'
while kill -0 "$TEST_PID" 2>/dev/null; do
  grep -q 'ev=armed' "$LOG" && break
  sleep 1
done
grep -q 'ev=armed' "$LOG" || { echo 'The fixture never armed:'; tail -30 "$LOG"; exit 1; }
ARMED_T=$(sed -n 's/.*HGRAIL t=\([0-9]*\) ev=armed.*/\1/p' "$LOG" | head -1)

# The clip starts here; the fixture waits 4s after arming, which is the
# recorder's head start.
RECORD_T0=$(python3 -c "import time; print(int(time.time() * 1000))")
if [[ "$DEVICE" == macos ]]; then
  screencapture -V "$RECORD_SECONDS" -x "$CLIP" &
else
  xcrun simctl io "$DEVICE" recordVideo --codec=h264 --mask=ignored --force "$CLIP" &
fi
RECORD_PID=$!

set +e
wait "$TEST_PID"
TEST_STATUS=$?
set -e
if [[ "$DEVICE" != macos ]]; then
  # simctl records until told to stop; SIGINT is what flushes the file to disk.
  kill -INT "$RECORD_PID" 2>/dev/null || true
  sleep 2
fi
wait "$RECORD_PID" 2>/dev/null || true
if [[ "$TEST_STATUS" != 0 ]]; then echo 'The fixture failed:'; tail -40 "$LOG"; exit "$TEST_STATUS"; fi
grep -E '^HGWIN|^HGRAIL' "$LOG"

python3 - "$LOG" "$CLIP" "$EVIDENCE" "$RECORD_T0" "$([[ $DEVICE == macos ]] && echo '' || echo 'ios-')" <<'PY'
import os, re, subprocess, sys

log, clip, evidence, record_t0, tag = sys.argv[1:6]
record_t0 = int(record_t0)
text = open(log, encoding='utf-8', errors='replace').read()

clip_w, clip_h = map(int, subprocess.check_output(
    ['ffprobe', '-v', 'error', '-select_streams', 'v:0',
     '-show_entries', 'stream=width,height', '-of', 'csv=p=0:s=x', clip]
).decode().split('x'))
window = re.search(
    r'HGWIN x=(-?\d+) y=(-?\d+) w=(\d+) h=(\d+).*display=(\d+)x(\d+)', text)
if window:
    x, y, w, h, disp_w, _ = map(int, window.groups())
    # The fixture reports logical window coordinates; the clip is in physical px.
    scale = clip_w / disp_w
    crop = f'crop={int(w * scale)}:{int(h * scale)}:{int(x * scale)}:{int(y * scale)}'
else:
    crop = ''
print(f'clip={clip_w}x{clip_h} window_crop={crop or "none"}')

# +0.25s: the marker is printed as the state is requested, so let the frame
# that actually shows it land before grabbing it.
for when, name in re.findall(r'HGRAIL t=(\d+) ev=shot=([\w-]+)', text):
    at = max((int(when) - record_t0) / 1000 + 0.25, 0.0)
    out = f'{evidence}/{tag}{name}.png'
    subprocess.run(
        ['ffmpeg', '-y', '-v', 'error', '-ss', f'{at:.3f}', '-i', clip,
         *( ['-vf', crop] if crop else []), '-frames:v', '1', out], check=True)
    print(f'{name}: frame at {at:.2f}s -> {out}')
PY

# The raw clip is a full screen recording; only the stills are kept.
rm -f "$CLIP"
