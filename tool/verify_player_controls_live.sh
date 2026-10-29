#!/usr/bin/env bash
# Live evidence for the playback control bar: runs integration_test/
# player_controls_live_test.dart on a real window (macOS), the iOS simulator, or
# a connected Android device, and saves one screenshot per state marker the
# fixture prints.
#
# macOS has no single-window capture, so the still is a region grab of the window
# rectangle the fixture reports (HGWIN). The simulator path goes through
# `simctl io screenshot`, which refuses to write on this volume: it lands in
# TMPDIR first and is copied back. Android goes through `adb exec-out screencap`,
# which writes to stdout, so the redirect lands it straight in the evidence
# directory.
#
#   HONGGUO_PLAYER_TAG=before ./tool/verify_player_controls_live.sh
#   HONGGUO_PLAYER_DEVICE=<ios-udid> HONGGUO_PLAYER_TAG=after ./tool/verify_player_controls_live.sh
#   HONGGUO_PLAYER_DEVICE=<adb-serial> HONGGUO_PLAYER_TAG=after-android ./tool/verify_player_controls_live.sh
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_BIN="${HONGGUO_FLUTTER_BIN:-$PROJECT_ROOT/.fvm/flutter_sdk/bin}"
DEVICE="${HONGGUO_PLAYER_DEVICE:-macos}"
TAG="${HONGGUO_PLAYER_TAG:-run}"
EVIDENCE="$PROJECT_ROOT/docs/evidence/player-controls"
BUILD="$PROJECT_ROOT/build/verification/player-controls/$TAG"
LOG="$BUILD/run.log"
[[ "$(uname -s)" == Darwin ]] || { echo 'This acceptance script targets macOS.' >&2; exit 1; }
command -v screencapture >/dev/null || { echo 'screencapture not found.' >&2; exit 1; }
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/hongguo-player-controls.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
rm -rf "$BUILD"; mkdir -p "$BUILD" "$EVIDENCE"

# A 36-character id is a simulator UDID, `macos` is the desktop host, and
# anything else has to be a serial adb actually knows about; guessing wrong here
# would send `flutter test` at an unknown device.
if [[ "$DEVICE" == macos ]]; then
  PLATFORM=mac
elif [[ ${#DEVICE} == 36 ]]; then
  PLATFORM=sim
else
  PLATFORM=android
  command -v adb >/dev/null || { echo 'adb not found.' >&2; exit 1; }
  adb devices | sed -n '2,$p' | grep -q "^$DEVICE[[:space:]]*device" || {
    echo "$DEVICE is not an authorized adb device:" >&2
    adb devices >&2
    exit 1
  }
  # A failed install makes flutter fall back to `adb uninstall`, which on a shared
  # phone removes the user's own build. Compare versions before starting instead.
  APP_ID=$(grep -m1 'applicationId = ' \
    "$PROJECT_ROOT/packages/app/android/app/build.gradle.kts" | cut -d'"' -f2)
  LOCAL_BUILD=$(grep -m1 '^version: ' "$PROJECT_ROOT/packages/app/pubspec.yaml" \
    | sed -E 's/.*\+([0-9]+).*/\1/')
  INSTALLED=$(adb -s "$DEVICE" shell dumpsys package "$APP_ID" 2>/dev/null \
    | tr -d '\r' | grep -m1 versionCode | sed -E 's/.*versionCode=([0-9]+).*/\1/' || true)
  if [[ -n "$INSTALLED" && "$INSTALLED" -gt "$LOCAL_BUILD" &&
        "${HONGGUO_ANDROID_ALLOW_DOWNGRADE:-}" != 1 ]]; then
    echo "$APP_ID is installed at versionCode=$INSTALLED; this run builds $LOCAL_BUILD." >&2
    echo 'A debug install would be a downgrade, and the fallback uninstall takes the' >&2
    echo "user's own app with it. Uninstall it on the phone first, or set" >&2
    echo 'HONGGUO_ANDROID_ALLOW_DOWNGRADE=1 once that is settled.' >&2
    exit 1
  fi
  echo "adb target: $DEVICE, $APP_ID installed=${INSTALLED:-nothing}, this build=$LOCAL_BUILD"
fi

cd "$PROJECT_ROOT/packages/app"
"$SDK_BIN/flutter" test integration_test/player_controls_live_test.dart \
  -d "$DEVICE" --no-pub --reporter expanded > "$LOG" 2>&1 &
TEST_PID=$!

echo 'Waiting for the live episode to start (first run builds the app)...'
while kill -0 "$TEST_PID" 2>/dev/null; do
  grep -q 'ev=armed' "$LOG" && break
  sleep 1
done
if ! grep -q 'ev=armed' "$LOG"; then
  echo 'The fixture never armed:'; tail -40 "$LOG"; exit 1
fi

rect_of() {
  # HGWIN reports logical points, which is the unit screencapture -R wants. The
  # fixture re-announces it after every resize, so the newest line wins.
  grep -o 'HGWIN x=-\?[0-9]* y=-\?[0-9]* w=[0-9]* h=[0-9]*' "$LOG" | tail -1 \
    | sed -E 's/HGWIN x=(-?[0-9]+) y=(-?[0-9]+) w=([0-9]+) h=([0-9]+)/\1,\2,\3,\4/'
}

seen=''
while kill -0 "$TEST_PID" 2>/dev/null; do
  marker=$(grep -o 'HGCTRL t=[0-9]* ev=[a-z-]*' "$LOG" | tail -1 || true)
  event=${marker##*ev=}
  if [[ -n "$event" && "$event" != done && ! " $seen " =~ " $event " ]]; then
    seen="$seen $event"
    out="$EVIDENCE/$TAG-$event.png"
    case "$PLATFORM" in
      sim)
        # simctl refuses to write on this volume, so the still stages in TMPDIR
        # and is copied back afterwards.
        stage="$STAGE/$event.png"
        xcrun simctl io "$DEVICE" screenshot "$stage" >/dev/null 2>&1 ||
          echo "  capture failed: $event"
        cp "$stage" "$out" 2>/dev/null || true
        ;;
      android)
        # screencap writes to stdout, so the redirect is what chooses the volume.
        adb -s "$DEVICE" exec-out screencap -p > "$out" 2>/dev/null ||
          echo "  capture failed: $event"
        ;;
      *)
        RECT=$(rect_of)
        [[ -n "$RECT" ]] || { echo 'The fixture printed no window rect.'; exit 1; }
        screencapture -x -R"$RECT" "$out"
        ;;
    esac
    [[ -s "$out" ]] && echo "captured $out ($PLATFORM)" || rm -f "$out"
  fi
  sleep 0.2
done

set +e
wait "$TEST_PID"
TEST_STATUS=$?
set -e
grep -E '^HGWIN|^HGPLAYER|^HGCTRL' "$LOG" || true
if [[ "$TEST_STATUS" != 0 ]]; then echo 'The fixture failed:'; tail -40 "$LOG"; exit "$TEST_STATUS"; fi
frames=$(ls -1 "$EVIDENCE" | grep -c "^$TAG-" || true)
echo "$frames frame(s) under $EVIDENCE for tag $TAG."
[[ "$frames" != 0 ]] || { echo 'No frame was captured.' >&2; exit 1; }
