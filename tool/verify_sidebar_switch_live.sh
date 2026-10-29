#!/usr/bin/env bash
# Live on-device evidence for the sidebar switch: runs the real app through
# integration_test/sidebar_switch_live_test.dart, records the screen while it
# clicks the sidebar (a jump on the desktop host) and a 类型 chip (still a slide,
# the control inside the same clip), and cuts the clip into one frame strip per
# switch under docs/evidence/sidebar-switch/.
#
# macOS cannot record a single window, so the clip is full-screen and every
# committed frame is cropped to the window rect the fixture reports.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_BIN="${HONGGUO_FLUTTER_BIN:-$PROJECT_ROOT/.fvm/flutter_sdk/bin}"
BUILD="$PROJECT_ROOT/build/verification/sidebar-switch"
EVIDENCE="$PROJECT_ROOT/docs/evidence/sidebar-switch"
LOG="$BUILD/run.log"
CYCLES="${HONGGUO_SIDEBAR_CYCLES:-4}"
RECORD_SECONDS=$((CYCLES * 4 + 12))
[[ "$(uname -s)" == Darwin ]] || { echo 'This acceptance script targets macOS.' >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo 'ffmpeg is needed to cut the clip.' >&2; exit 1; }
command -v screencapture >/dev/null || { echo 'screencapture not found.' >&2; exit 1; }
CLIP="$BUILD/clip.mov"
rm -rf "$BUILD"; mkdir -p "$BUILD" "$EVIDENCE"

cd "$PROJECT_ROOT/packages/app"
"$SDK_BIN/flutter" test integration_test/sidebar_switch_live_test.dart \
  -d macos --no-pub --reporter expanded > "$LOG" 2>&1 &
TEST_PID=$!

echo 'Waiting for the live catalog to render (first run builds the app)...'
while kill -0 "$TEST_PID" 2>/dev/null; do
  grep -q 'ev=armed' "$LOG" && break
  sleep 1
done
grep -q 'ev=armed' "$LOG" || { echo 'The fixture never armed:'; tail -30 "$LOG"; exit 1; }

# The clip starts here; the fixture waits 4s after arming, which is the
# recorder's head start.
RECORD_T0=$(python3 -c 'import time; print(int(time.time() * 1000))')
screencapture -V "$RECORD_SECONDS" -x "$CLIP" &
RECORD_PID=$!

set +e
wait "$TEST_PID"
TEST_STATUS=$?
set -e
wait "$RECORD_PID" 2>/dev/null || true
if [[ "$TEST_STATUS" != 0 ]]; then echo 'The fixture failed:'; tail -40 "$LOG"; exit "$TEST_STATUS"; fi
grep -E '^HGWIN|^HGSIDE' "$LOG"

python3 - "$LOG" "$CLIP" "$BUILD" "$EVIDENCE" "$RECORD_T0" <<'PY'
import os, re, subprocess, sys

log, clip, build, evidence, record_t0 = sys.argv[1:6]
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

plan = sorted(((int(t), ev) for t, ev in re.findall(r'HGSIDE t=(\d+) ev=([\w-]+)', text)
               if ev in ('jump-in', 'jump-out', 'slide', 'slide-back')),
              key=lambda entry: entry[0])
frame_w, per_row = 440, 6
print(f'clip={clip_w}x{clip_h} window_crop={crop or "none"}')
for index, (when, kind) in enumerate(plan, start=1):
    out = f'{build}/{kind}{index}'
    os.makedirs(out, exist_ok=True)
    seek = f'{max((when - record_t0) / 1000 - 0.1, 0.0):.3f}'
    # Every frame the recorder captured in this window, and the subset that
    # differs from the one before it by more than 2%. A jump has to be 1 of n:
    # the pager is on the next page in the first frame after the click, so there
    # is nothing left to show in between. A slide is several of n.
    all_frames = f'{out}/all'
    os.makedirs(all_frames, exist_ok=True)
    subprocess.run(
        ['ffmpeg', '-y', '-v', 'error', '-i', clip, '-ss', seek, '-t', '0.7',
         '-vf', ','.join(filter(None, [crop, f'scale={frame_w}:-1'])),
         '-fps_mode', 'passthrough', f'{all_frames}/%02d.png'], check=True)
    total = len([n for n in os.listdir(all_frames) if n.endswith('.png')])
    vf = ','.join(filter(None, [crop, "select='gt(scene,0.02)'", f'scale={frame_w}:-1']))
    subprocess.run(
        ['ffmpeg', '-y', '-v', 'error', '-i', clip,
         '-ss', seek, '-t', '0.7',
         '-vf', vf, '-fps_mode', 'vfr',
         f'{out}/%02d.png'], check=True)
    frames = sorted(name for name in os.listdir(out) if name.endswith('.png'))
    if not frames:
        print(f'{kind}{index}: no changed frames of {total}', file=sys.stderr)
        continue
    cols, rows = min(len(frames), per_row), -(-len(frames) // per_row)
    strip = f'{out}/strip.png'
    subprocess.run(
        ['ffmpeg', '-y', '-v', 'error', '-start_number', '1', '-i', f'{out}/%02d.png',
         '-vf', f'tile={cols}x{rows}:padding=8:color=0x101014ff', '-frames:v', '1',
         strip], check=True)
    subprocess.run(['cp', strip, f'{evidence}/{kind}-{index}.png'], check=True)
    print(f'{kind}{index}: {len(frames)} changed of {total} frames -> {evidence}/{kind}-{index}.png')
PY

# The raw clip is a full screen recording; only the frame strips are kept.
rm -f "$CLIP"
