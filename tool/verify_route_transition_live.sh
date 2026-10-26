#!/usr/bin/env bash
# Live on-device evidence for the push/pop transition: runs the real app
# through integration_test/route_transition_live_test.dart, records the screen
# while it walks catalog -> detail -> catalog, and cuts the clip into one frame
# strip per transition under docs/evidence/route-transition/.
#
# HONGGUO_TRANSITION_DEVICE selects the target: macos (default) or an iOS
# simulator UDID/name. macOS cannot record a single window, so that clip is
# full-screen and every committed frame is cropped to the window rect the
# fixture reports; a simulator recording is already exactly the device screen.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_BIN="${HONGGUO_FLUTTER_BIN:-$PROJECT_ROOT/.fvm/flutter_sdk/bin}"
BUILD="$PROJECT_ROOT/build/verification/route-transition"
EVIDENCE="$PROJECT_ROOT/docs/evidence/route-transition"
LOG="$BUILD/run.log"
DEVICE="${HONGGUO_TRANSITION_DEVICE:-macos}"
CYCLES="${HONGGUO_TRANSITION_CYCLES:-4}"
RECORD_SECONDS=$((CYCLES * 3 + 10))
[[ "$(uname -s)" == Darwin ]] || { echo 'This acceptance script targets macOS.' >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo 'ffmpeg is needed to cut the clip.' >&2; exit 1; }
if [[ "$DEVICE" == macos ]]; then
  CLIP="$BUILD/clip.mov"
  command -v screencapture >/dev/null || { echo 'screencapture not found.' >&2; exit 1; }
else
  # simctl's recorder is an AVFoundation writer and is denied the project volume,
  # so the clip is staged in the scratch directory and only its frames are kept.
  CLIP="${TMPDIR:-/tmp}/hongguo-route-transition-clip.mp4"
  command -v xcrun >/dev/null || { echo 'xcrun is needed to record the simulator.' >&2; exit 1; }
fi
rm -rf "$BUILD"; mkdir -p "$BUILD" "$EVIDENCE"

cd "$PROJECT_ROOT/packages/app"
"$SDK_BIN/flutter" test integration_test/route_transition_live_test.dart \
  -d "$DEVICE" --no-pub --reporter expanded > "$LOG" 2>&1 &
TEST_PID=$!

echo 'Waiting for the live catalog to render (first run builds the app)...'
while kill -0 "$TEST_PID" 2>/dev/null; do
  grep -q 'ev=armed' "$LOG" && break
  sleep 1
done
grep -q 'ev=armed' "$LOG" || { echo 'The fixture never armed:'; tail -30 "$LOG"; exit 1; }
ARMED_T=$(sed -n 's/.*HGTRANS t=\([0-9]*\) ev=armed.*/\1/p' "$LOG" | head -1)

# The clip starts here; the fixture waits 4s after arming, which is the
# recorder's head start.
RECORD_T0=$(python3 -c 'import time; print(int(time.time() * 1000))')
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
grep -E '^HGWIN|^HGTRANS' "$LOG"

python3 - "$LOG" "$CLIP" "$BUILD" "$EVIDENCE" "$ARMED_T" "$RECORD_T0" "$([[ $DEVICE == macos ]] && echo '' || echo 'ios-')" <<'PY'
import os, re, subprocess, sys

log, clip, build, evidence, armed_t, record_t0, tag = sys.argv[1:8]
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
    # Simulator recording: the clip is already the device screen.
    crop = ''

plan = sorted(((int(t), ev) for t, ev in re.findall(r'HGTRANS t=(\d+) ev=(\w+)', text)
               if ev in ('push', 'pop')), key=lambda entry: entry[0])
# A phone clip is tall, so fewer frames per row keeps the strip readable.
portrait = clip_h > clip_w
frame_w, per_row = (300, 4) if portrait else (440, 6)
print(f'clip={clip_w}x{clip_h} window_crop={crop or "none"}')
for index, (when, kind) in enumerate(plan, start=1):
    out = f'{build}/{kind}{index}'
    os.makedirs(out, exist_ok=True)
    vf = ','.join(filter(None, [crop, "select='gt(scene,0.02)'", f'scale={frame_w}:-1']))
    subprocess.run(
        ['ffmpeg', '-y', '-v', 'error', '-i', clip,
         '-ss', f'{max((when - record_t0) / 1000 - 0.1, 0.0):.3f}', '-t', '0.7',
         '-vf', vf, '-fps_mode', 'vfr',
         f'{out}/%02d.png'], check=True)
    frames = sorted(name for name in os.listdir(out) if name.endswith('.png'))
    if not frames:
        print(f'{kind}{index}: no frames', file=sys.stderr)
        continue
    cols, rows = min(len(frames), per_row), -(-len(frames) // per_row)
    strip = f'{out}/strip.png'
    subprocess.run(
        ['ffmpeg', '-y', '-v', 'error', '-start_number', '1', '-i', f'{out}/%02d.png',
         '-vf', f'tile={cols}x{rows}:padding=8:color=0x101014ff', '-frames:v', '1',
         strip], check=True)
    evidence_copy = f'{evidence}/{tag}{kind}-{index}.png'
    subprocess.run(['cp', strip, evidence_copy], check=True)
    print(f'{kind}{index}: {len(frames)} frames -> {evidence_copy}')
PY

# The raw clip is a full screen recording; only the frame strips are kept.
rm -f "$CLIP"
