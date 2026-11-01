#!/usr/bin/env bash
# End-to-end suite: the iPhone app in the iOS Simulator against the Android TV emulator, driven by XCUITest
# (ios/TVRemoteUITests/TVRemoteEndToEndTests.swift) with scripts/e2e-helper.py looking at the TV side over adb.
# Covers the pairing, remote, setup, Home install, editor and undo cases that TESTING.md lists as manual
# ("End-to-end suite" there). Nothing touches a real TV: only the emulator (reset to its clean snapshot before and after).
#
#   scripts/e2e.sh                 reset the emulator, run everything, reset again
#   scripts/e2e.sh --no-reset      keep the emulator as it is before the run (faster while debugging the suite)
#   scripts/e2e.sh --keep          leave the emulator as the run left it (to look at it)
#   scripts/e2e.sh --device NAME   a simulator device type other than "iPhone 17 Pro"
#
# Needs: the emulator created once (scripts/tv-emulator.sh create/start/save), Xcode with an iOS simulator runtime,
# and the launcher APK bundled (scripts/bundle-launcher.sh). Takes about 10 minutes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$ANDROID_HOME/platform-tools/adb"
SERIAL=emulator-5554
HELPER_PORT=17555
SIM_NAME="Debloated TV E2E"
DEVICE_TYPE="iPhone 17 Pro"
RESET=1; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-reset) RESET=0 ;;
    --keep) KEEP=1 ;;
    --device) DEVICE_TYPE="$2"; shift ;;
    *) sed -n '2,13p' "$0"; exit 1 ;;
  esac
  shift
done
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31mStopped:\033[0m %s\n' "$*" >&2; exit 1; }

[ -x "$ADB" ] || die "No adb at $ADB (Android SDK platform-tools)."
[ -f "$ROOT/ios/Resources/Launcher/tvhome.apk" ] || die "No launcher APK bundled. Run scripts/bundle-launcher.sh first."
OUT="$ROOT/ios/build/e2e"; mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$OUT/e2e-$STAMP.log"; RESULT="$OUT/e2e-$STAMP.xcresult"

# --- the emulator ---------------------------------------------------------------------------------------------------
booted() { [ "$("$ADB" -s $SERIAL shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; }
if ! "$ADB" devices | grep -q "^$SERIAL[[:space:]]*device"; then
  say "Starting the Android TV emulator…"
  "$ROOT/scripts/tv-emulator.sh" start
fi
if [ "$RESET" = 1 ]; then
  say "Resetting the emulator to its clean snapshot…"
  python3 "$ROOT/scripts/e2e-helper.py" console "avd snapshot load clean" >/dev/null || die "Couldn't load the 'clean' snapshot (scripts/tv-emulator.sh save)."
  "$ADB" -s $SERIAL wait-for-device
  until booted; do sleep 2; done
fi
# A loaded snapshot keeps the clock it was saved with, and the TV then refuses the phone's certificate as not yet
# valid: pairing works but the control port hangs up. A guest reboot takes the time from the host again.
SKEW=$(( $(date +%s) - $("$ADB" -s $SERIAL shell date +%s | tr -d '\r') ))
if [ "${SKEW#-}" -gt 300 ]; then
  say "The emulator's clock is off by ${SKEW}s: rebooting it to pick up the host's time…"
  "$ADB" -s $SERIAL reboot; sleep 8
  "$ADB" -s $SERIAL wait-for-device
  until booted; do sleep 2; done
  sleep 3
fi
# A second entrance to the emulator's adbd, so the app connects through a forward while adb on this Mac keeps
# working (the emulator's own 5555 takes one client). `adb tcpip` restarts adbd a moment after it returns, which
# drops the transport and every forward on it: wait for the new adbd before adding them (scripts/e2e-helper.py).
for port in 15555 6466 6467 9764; do
  if lsof -nP -iTCP:$port -sTCP:LISTEN 2>/dev/null | grep -qv '^COMMAND\|adb'; then die "Port $port on this Mac is in use by something other than adb."; fi
done
python3 "$ROOT/scripts/e2e-helper.py" forward --serial $SERIAL || die "Couldn't set up the emulator's port forwards."
# Home on the emulator so the TV reports a launcher in front (the setup offer after pairing depends on it).
"$ADB" -s $SERIAL shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true

# --- the helper ------------------------------------------------------------------------------------------------------
python3 "$ROOT/scripts/e2e-helper.py" serve --port $HELPER_PORT --serial $SERIAL 2>"$OUT/helper-$STAMP.log" &
HELPER_PID=$!
cleanup() {
  kill $HELPER_PID 2>/dev/null || true
  for port in 15555 6466 6467 9764; do "$ADB" -s $SERIAL forward --remove tcp:$port >/dev/null 2>&1 || true; done
  if [ "$KEEP" = 0 ]; then
    # The run ends with debugging switched off on the TV, so this goes through the console, not adb.
    python3 "$ROOT/scripts/e2e-helper.py" console "avd snapshot load clean" >/dev/null 2>&1 && echo "Emulator back on its clean snapshot." || echo "Couldn't reset the emulator; run scripts/tv-emulator.sh reset."
  fi
}
trap cleanup EXIT
for _ in $(seq 1 20); do curl -fs "http://127.0.0.1:$HELPER_PORT/ping" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$HELPER_PORT/ping" >/dev/null || die "The helper didn't start (see $OUT/helper-$STAMP.log)."

# --- the simulator: a device of its own, erased before every run so the app starts unpaired ---------------------------
UDID="$(xcrun simctl list devices -j | python3 -c 'import json,sys; devs=[d for r in json.load(sys.stdin)["devices"].values() for d in r if d["name"]=="'"$SIM_NAME"'" and d["isAvailable"]]; print(devs[0]["udid"] if devs else "")')"
if [ -z "$UDID" ]; then
  say "Creating the simulator '$SIM_NAME' ($DEVICE_TYPE)…"
  UDID="$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE")" || die "Couldn't create a '$DEVICE_TYPE' simulator; pass --device with a type from 'xcrun simctl list devicetypes'."
fi
xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
xcrun simctl erase "$UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null

# --- the run ----------------------------------------------------------------------------------------------------------
# Signed, unlike the smoke tests in CI: without entitlements the simulator's Keychain refuses to create the pairing
# identity (SecKeyCreateRandomKey -34018) and the app can't pair.
say "Running the end-to-end suite (log: $LOG)…"
cd "$ROOT/ios"
set +e
TEST_RUNNER_E2E_HELPER="http://127.0.0.1:$HELPER_PORT" TEST_RUNNER_E2E_TV_HOST=127.0.0.1 TEST_RUNNER_E2E_ADB_ADDRESS=127.0.0.1:15555 \
  xcodebuild test -project TVRemote.xcodeproj -scheme "Debloated TV Dev" \
    -destination "platform=iOS Simulator,id=$UDID" -only-testing:TVRemoteUITests/TVRemoteEndToEndTests \
    -parallel-testing-enabled NO -resultBundlePath "$RESULT" >"$LOG" 2>&1
STATUS=$?
set -e
grep -E "^\s*t = |Test case|Test Suite|error:|\*\* TEST" "$LOG" | grep -vE "^\s*t = .*(Wait for|Checking|Find|Tap|Type|Get|Synthesize|Press|Activate|Open|Dismiss|Scroll|Swipe|Capture|Waiting|Set up|Tear down|Launch|Start Test|Requesting)" | sed 's/^ *//' | tail -n 60
if [ $STATUS -eq 0 ]; then say "End-to-end suite passed. Result bundle: $RESULT"; else say "End-to-end suite FAILED (exit $STATUS). Log: $LOG  Result bundle: $RESULT"; fi
exit $STATUS
