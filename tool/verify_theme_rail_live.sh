#!/usr/bin/env bash
# Live on-device evidence for the theme rail: runs the real app through
# integration_test/theme_rail_live_test.dart, records the screen while it
# enters 分类 and walks 题材 -> 题材 -> back, and pulls one still per marked
# state into docs/evidence/theme-rail/.
#
# HONGGUO_RAIL_DEVICE selects the target: macos (default), an Android serial
# (a phone needs its release installed first -- see docs/design/pc-mobile-theme-rail.md),
# or an iOS simulator UDID/name. macOS cannot record a single window, so that
# clip is full-screen and every still is cropped to the window rect the
# fixture reports; a simulator recording is already exactly the device screen.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_BIN="${HONGGUO_FLUTTER_BIN:-$PROJECT_ROOT/.fvm/flutter_sdk/bin}"
BUILD="$PROJECT_ROOT/build/verification/theme-rail"
EVIDENCE="$PROJECT_ROOT/docs/evidence/theme-rail"
LOG="$BUILD/run.log"
DEVICE="${HONGGUO_RAIL_DEVICE:-macos}"
RECORD_SECONDS="${HONGGUO_RAIL_SECONDS:-30}"
[[ "$(uname -s)" == Darwin ]] || { echo 'This acceptance script targets macOS.' >&2; exit 1; }
# macos and the iOS simulator are recorded and cut afterwards; a phone is
# captured straight from adb the moment each state marker is printed, so it
# needs no clip, no cropping and no ffmpeg.
MODE=ios
if [[ "$DEVICE" == macos ]]; then MODE=macos
elif adb -s "$DEVICE" get-state 2>/dev/null | grep -q device; then MODE=android
fi
if [[ "$MODE" != android ]]; then
  command -v ffmpeg >/dev/null || { echo 'ffmpeg is needed to cut the clip.' >&2; exit 1; }
fi
if [[ "$MODE" == macos ]]; then
  CLIP="$BUILD/clip.mov"
  command -v screencapture >/dev/null || { echo 'screencapture not found.' >&2; exit 1; }
elif [[ "$MODE" == ios ]]; then
  # simctl's recorder is an AVFoundation writer and is denied the project volume,
  # so the clip is staged in the scratch directory and only its stills are kept.
  CLIP="${TMPDIR:-/tmp}/hongguo-theme-rail-clip.mp4"
  command -v xcrun >/dev/null || { echo 'xcrun is needed to record the simulator.' >&2; exit 1; }
fi
rm -rf "$BUILD"; mkdir -p "$BUILD" "$EVIDENCE"

# A phone build is flavored and its launcher lives in the flavor's overlay
# manifest, which the test tool only discovers from an existing apk: build the
# apk first or the run dies while loading the fixture.
FLAVOR=''
[[ "$MODE" == android ]] && FLAVOR="${HONGGUO_RAIL_FLAVOR:-mobile}"
flavor_args=()
[[ "$FLAVOR" == '' ]] || flavor_args=(--flavor "$FLAVOR")

cd "$PROJECT_ROOT/packages/app"
if [[ "$FLAVOR" != '' ]]; then
  echo "== prebuilding $FLAVOR debug apk"
  "$SDK_BIN/flutter" build apk --debug --flavor "$FLAVOR" \
    --target-platform android-arm64 > "$BUILD/prebuild.log" 2>&1 || {
      echo 'The apk prebuild failed:'; tail -20 "$BUILD/prebuild.log"; exit 1;
    }
fi
"$SDK_BIN/flutter" test integration_test/theme_rail_live_test.dart \
  -d "$DEVICE" --no-pub ${flavor_args[@]+"${flavor_args[@]}"} --reporter expanded > "$LOG" 2>&1 &
TEST_PID=$!

echo 'Waiting for the live rail to arm (first run builds the app)...'
while kill -0 "$TEST_PID" 2>/dev/null; do
  # The log only appears once the test tool stops building and starts running.
  if [[ -f "$LOG" ]] && grep -q 'ev=armed' "$LOG"; then break; fi
  sleep 1
done
grep -q 'ev=armed' "$LOG" || { echo 'The fixture never armed:'; tail -30 "$LOG"; exit 1; }
ARMED_T=$(sed -n 's/.*HGRAIL t=\([0-9]*\) ev=armed.*/\1/p' "$LOG" | head -1)

# The clip starts here; the fixture waits 4s after arming, which is the
# recorder's head start.
RECORD_T0=$(python3 -c "import time; print(int(time.time() * 1000))")
if [[ "$MODE" == macos ]]; then
  screencapture -V "$RECORD_SECONDS" -x "$CLIP" &
elif [[ "$MODE" == ios ]]; then
  xcrun simctl io "$DEVICE" recordVideo --codec=h264 --mask=ignored --force "$CLIP" &
else
  # A phone needs no clip: every state is screenshotted the moment its marker
  # reaches the log, which lands inside the window the fixture holds it up.
  (
    captured=''
    while :; do
      for name in $(sed -n 's/.*HGRAIL [0-9]* ev=shot=\([A-Za-z0-9_-]*\).*/\1/p' "$LOG"); do
        case " $captured " in *" $name "*) continue ;; esac
        captured="$captured $name"
        adb -s "$DEVICE" exec-out screencap -p > "$EVIDENCE/android-$name.png"
        echo "android-$name: screencap -> $EVIDENCE/android-$name.png"
      done
      kill -0 "$TEST_PID" 2>/dev/null || break
      sleep 0.2
    done
  ) &
fi
RECORD_PID=$!

set +e
wait "$TEST_PID"
TEST_STATUS=$?
set -e
if [[ "$MODE" == ios ]]; then
  # simctl records until told to stop; SIGINT is what flushes the file to disk.
  kill -INT "$RECORD_PID" 2>/dev/null || true
  sleep 2
fi
wait "$RECORD_PID" 2>/dev/null || true
if [[ "$TEST_STATUS" != 0 ]]; then echo 'The fixture failed:'; tail -40 "$LOG"; exit "$TEST_STATUS"; fi
grep -E '^HGWIN|^HGRAIL' "$LOG"

if [[ "$MODE" == android ]]; then
  echo 'The phone stills are already on disk; there is no clip to cut.'
  exit 0
fi

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
