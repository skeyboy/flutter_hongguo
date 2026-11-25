#!/usr/bin/env bash
# Start the hongguo Android TV AVD and expose its adb bridge on the host LAN.
# Test-host tooling only; never part of the Flutter application.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
EMULATOR="$SDK/emulator/emulator"
ADB="$SDK/platform-tools/adb"
AVD="${HONGGUO_TV_AVD:-hongguo_tv_api34}"
NIC="${HONGGUO_TV_LAN_NIC:-en1}"
CONSOLE_PORT="${HONGGUO_TV_CONSOLE_PORT:-5554}"
ADB_PORT="${HONGGUO_TV_ADB_PORT:-5555}"
LAN_IP="$(ipconfig getifaddr "$NIC" || true)"

if [[ -z "$LAN_IP" ]]; then
  echo "No LAN IP on $NIC; set HONGGUO_TV_LAN_NIC to the active interface" >&2
  exit 1
fi

if ! "$ADB" devices | awk '{print $1}' | grep -qx "emulator-$CONSOLE_PORT"; then
  echo "Starting $AVD ..."
  "$EMULATOR" -avd "$AVD" -ports "$CONSOLE_PORT,$ADB_PORT" &
fi

"$ADB" -s "emulator-$CONSOLE_PORT" wait-for-device
while [[ "$("$ADB" -s "emulator-$CONSOLE_PORT" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')" != "1" ]]; do
  sleep 2
done

if ! lsof -nP -iTCP:"$ADB_PORT" -sTCP:LISTEN 2>/dev/null | grep -q "\*:$ADB_PORT"; then
  LOG_DIR="$PROJECT_ROOT/build/verification"
  mkdir -p "$LOG_DIR"
  nohup python3 "$PROJECT_ROOT/tool/lan_tcp_relay.py" \
    "$ADB_PORT:127.0.0.1:$ADB_PORT" > "$LOG_DIR/lan-relay.log" 2>&1 &
  echo $! > "$LOG_DIR/lan-relay.pid"
fi

echo "PASS: $AVD booted"
echo "LAN adb:   adb connect $LAN_IP:$ADB_PORT"
echo "Local adb: emulator-$CONSOLE_PORT"
echo "Guest IP:  10.0.2.15 (NAT; LAN-out verified through 10.0.2.2)"
