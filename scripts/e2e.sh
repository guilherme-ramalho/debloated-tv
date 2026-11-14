#!/usr/bin/env bash
# End-to-end suite: the iPhone app in the iOS Simulator against the Android TV emulator, driven by XCUITest
# (ios/TVRemoteUITests/TVRemoteEndToEndTests.swift) with scripts/e2e-helper.py looking at the TV side over adb.
# Covers the pairing, remote, setup, Home install, editor and undo cases that TESTING.md lists as manual
# ("End-to-end suite" there). Nothing touches a real TV: only the emulator (reset to its clean snapshot before and after).
#
# Two scenarios, each on a freshly reset emulator and simulator, from one build:
#   main        pair, remote, setup with the emulator's tested profile and the new Home, editor, undo, debugging off
#   community   a TV without a tested profile: the list picker, a "closest" list, a debloat-only list, undo
#
#   scripts/e2e.sh                     reset the emulator, run both scenarios, then stop everything it used
#   scripts/e2e.sh --only community    one scenario (main or community)
#   scripts/e2e.sh --no-reset          keep the emulator as it is before the first scenario (faster while debugging)
#   scripts/e2e.sh --keep              leave the emulator and the simulator running as the run left them (to look at them)
#   scripts/e2e.sh --device NAME       a simulator device type other than "iPhone 17 Pro"
#
# Needs: the emulator created once (scripts/tv-emulator.sh create/start/save), Xcode with an iOS simulator runtime,
# and the launcher APK bundled (scripts/bundle-launcher.sh). Takes about 15 minutes; the steps show up live.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$ANDROID_HOME/platform-tools/adb"
SERIAL=emulator-5554
HELPER_PORT=17555
SIM_NAME="Debloated TV E2E"
DEVICE_TYPE="iPhone 17 Pro"
RESET=1; KEEP=0; ONLY=""
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31mStopped:\033[0m %s\n' "$*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --no-reset) RESET=0 ;;
    --keep) KEEP=1 ;;
    --device) DEVICE_TYPE="$2"; shift ;;
    --only) ONLY="$2"; shift ;;
    *) sed -n '2,18p' "$0"; exit 1 ;;
  esac
  shift
done
case "$ONLY" in ""|main|community) ;; *) die "--only takes main or community" ;; esac

[ -x "$ADB" ] || die "No adb at $ADB (Android SDK platform-tools)."
[ -f "$ROOT/ios/Resources/Launcher/tvhome.apk" ] || die "No launcher APK bundled. Run scripts/bundle-launcher.sh first."
OUT="$ROOT/ios/build/e2e"; mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$OUT/e2e-$STAMP.log"

# --- the emulator ---------------------------------------------------------------------------------------------------
booted() { [ "$("$ADB" -s $SERIAL shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; }
# Started here: straight from the clean snapshot, saving nothing on exit. Stopping an emulator otherwise writes its
# quick-boot state, and switching from that state to 'clean' after a cold start crashed the emulator's graphics
# restore (12 Nov 2026). An emulator already running (yours, or a --keep run) is used and reset with the snapshot.
STARTED_EMULATOR=0
if ! "$ADB" devices | grep -q "^$SERIAL[[:space:]]*device"; then
  say "Starting the Android TV emulator from its clean snapshot…"
  "$ANDROID_HOME/emulator/emulator" -avd DebloatedTV -port 5554 -no-boot-anim -snapshot clean -no-snapshot-save \
    >"$OUT/emulator-$STAMP.log" 2>&1 &
  disown $!
  STARTED_EMULATOR=1
  "$ADB" -s $SERIAL wait-for-device
  until booted; do sleep 2; done
fi
for port in 15555 6466 6467 9764; do
  if lsof -nP -iTCP:$port -sTCP:LISTEN 2>/dev/null | grep -qv '^COMMAND\|adb'; then die "Port $port on this Mac is in use by something other than adb."; fi
done

# The TV for one scenario: the clean snapshot (unless $1 is 0), the right clock, adbd in TCP mode and the forwards.
prepare_tv() {
  if [ "$1" = 1 ]; then
    say "Resetting the emulator to its clean snapshot…"
    python3 "$ROOT/scripts/e2e-helper.py" console "avd snapshot load clean" >/dev/null || die "Couldn't load the 'clean' snapshot (scripts/tv-emulator.sh save)."
    "$ADB" -s $SERIAL wait-for-device
    until booted; do sleep 2; done
  fi
  # No app updates during the run: about a minute after a boot from the clean snapshot (31 Oct), the Play Store
  # updates itself and then Google Play services, and Android force-stops everything bound to it, the TV's remote
  # service included. That dropped the pairing session in CON-02 (14 Nov 2026). The snapshot load brings it back.
  "$ADB" -s $SERIAL shell pm disable-user --user 0 com.android.vending >/dev/null 2>&1 || true
  # A loaded snapshot keeps the clock it was saved with, and the TV then refuses the phone's certificate as not yet
  # valid: pairing works but the control port hangs up. A guest reboot takes the time from the host again.
  local skew=$(( $(date +%s) - $("$ADB" -s $SERIAL shell date +%s | tr -d '\r') ))
  if [ "${skew#-}" -gt 300 ]; then
    say "The emulator's clock is off by ${skew}s: rebooting it to pick up the host's time…"
    "$ADB" -s $SERIAL reboot; sleep 8
    "$ADB" -s $SERIAL wait-for-device
    until booted; do sleep 2; done
    sleep 3
  fi
  # A second entrance to the emulator's adbd, so the app connects through a forward while adb on this Mac keeps
  # working (the emulator's own 5555 takes one client). `adb tcpip` restarts adbd a moment after it returns, which
  # drops the transport and every forward on it: wait for the new adbd before adding them (scripts/e2e-helper.py).
  python3 "$ROOT/scripts/e2e-helper.py" forward --serial $SERIAL >/dev/null || die "Couldn't set up the emulator's port forwards."
  # Home on the emulator so the TV reports a launcher in front (the setup offer after pairing depends on it).
  "$ADB" -s $SERIAL shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
}

# --- the helper ------------------------------------------------------------------------------------------------------
# Live progress: the UI test reports each step to the helper, which writes it here with the TV side's events.
PROGRESS="$OUT/progress-$STAMP.txt"; : >"$PROGRESS"; TAIL_PID=""
python3 "$ROOT/scripts/e2e-helper.py" serve --port $HELPER_PORT --serial $SERIAL --progress "$PROGRESS" 2>"$OUT/helper-$STAMP.log" &
HELPER_PID=$!; disown $HELPER_PID   # no "Terminated" line when it's stopped at the end
# At the end, also after a failure or Ctrl+C: nothing the run started keeps running (unless --keep). The adb server
# stays: Android Studio shares it.
cleanup() {
  [ -n "$TAIL_PID" ] && kill $TAIL_PID 2>/dev/null || true
  kill $HELPER_PID 2>/dev/null || true
  [ -n "${UDID:-}" ] && pkill -f "xcodebuild .*$UDID" 2>/dev/null || true   # an interrupted test run
  for port in 15555 6466 6467 9764; do "$ADB" -s $SERIAL forward --remove tcp:$port >/dev/null 2>&1 || true; done
  if [ "$KEEP" = 1 ]; then echo "Left the emulator and the simulator running (--keep)."; return; fi
  # The emulator: shut down through its console (the main scenario ends with debugging off), then the crash
  # reporters it leaves behind. Its next start comes from the clean snapshot anyway (prepare_tv).
  if [ "$STARTED_EMULATOR" = 1 ]; then
    # Started with -no-snapshot-save: a console kill writes nothing.
    python3 "$ROOT/scripts/e2e-helper.py" console "kill" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do pgrep -f "qemu-system.*-avd DebloatedTV" >/dev/null || break; sleep 1; done
  fi
  # One that was already running would save its quick-boot state on a console kill: stop it without saving.
  pkill -9 -f "qemu-system.*-avd DebloatedTV" 2>/dev/null || true
  # Only orphans (parent gone): an emulator started from Android Studio keeps its own.
  ps -eo pid=,ppid=,command= | awk '$2 == 1 && $3 ~ /Android\/sdk\/emulator\/(crashpad_handler|netsimd)/ {print $1}' | xargs kill 2>/dev/null || true
  # The simulator, and the Simulator app if it's showing nothing else.
  [ -n "${UDID:-}" ] && xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  if [ "$(xcrun simctl list devices booted 2>/dev/null | grep -c Booted)" = 0 ]; then osascript -e 'quit app "Simulator"' >/dev/null 2>&1 || true; fi
  echo "Stopped the emulator, the simulator and the helper."
}
trap cleanup EXIT
for _ in $(seq 1 20); do curl -fs "http://127.0.0.1:$HELPER_PORT/ping" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$HELPER_PORT/ping" >/dev/null || die "The helper didn't start (see $OUT/helper-$STAMP.log)."

# --- the simulator: a device of its own, erased before every scenario so the app starts unpaired -----------------------
UDID="$(xcrun simctl list devices -j | python3 -c 'import json,sys; devs=[d for r in json.load(sys.stdin)["devices"].values() for d in r if d["name"]=="'"$SIM_NAME"'" and d["isAvailable"]]; print(devs[0]["udid"] if devs else "")')"
if [ -z "$UDID" ]; then
  say "Creating the simulator '$SIM_NAME' ($DEVICE_TYPE)…"
  UDID="$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE")" || die "Couldn't create a '$DEVICE_TYPE' simulator; pass --device with a type from 'xcrun simctl list devicetypes'."
fi
fresh_simulator() {
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  xcrun simctl erase "$UDID"
  xcrun simctl boot "$UDID"
  xcrun simctl bootstatus "$UDID" -b >/dev/null
}

# --- the build, once --------------------------------------------------------------------------------------------------
# Signed, unlike the smoke tests in CI: without entitlements the simulator's Keychain refuses to create the pairing
# identity (SecKeyCreateRandomKey -34018) and the app can't pair.
cd "$ROOT/ios"
fresh_simulator
say "Building the app and the tests (2–3 minutes; log: $LOG)…"
xcodebuild build-for-testing -project TVRemote.xcodeproj -scheme "Debloated TV Dev" \
  -destination "platform=iOS Simulator,id=$UDID" >"$LOG" 2>&1 || { grep -E "error:" "$LOG" | head -20; die "The build failed. Log: $LOG"; }

tail -n +1 -f "$PROGRESS" &
TAIL_PID=$!; disown $TAIL_PID
STATUS=0
# One scenario: $1 its name, $2 the test method, $3 whether to reset the emulator and the simulator first.
scenario() {
  echo "[$1] ───────── preparing the TV and the iPhone ─────────" >>"$PROGRESS"
  prepare_tv "$3" >>"$OUT/prepare-$STAMP.log" 2>&1
  [ "$3" = 0 ] || fresh_simulator
  local status attempt
  for attempt in 1 2; do
    local before; before=$(wc -l <"$LOG")
    rm -rf "$OUT/e2e-$STAMP-$1.xcresult"
    set +e
    TEST_RUNNER_E2E_HELPER="http://127.0.0.1:$HELPER_PORT" TEST_RUNNER_E2E_TV_HOST=127.0.0.1 TEST_RUNNER_E2E_ADB_ADDRESS=127.0.0.1:15555 \
      xcodebuild test-without-building -project TVRemote.xcodeproj -scheme "Debloated TV Dev" \
        -destination "platform=iOS Simulator,id=$UDID" -only-testing:"TVRemoteUITests/TVRemoteEndToEndTests/$2" \
        -parallel-testing-enabled NO -resultBundlePath "$OUT/e2e-$STAMP-$1.xcresult" >>"$LOG" 2>&1
    status=$?
    set -e
    # The simulator sometimes fails to install the test runner right after an erase ("Failed to locate promise"):
    # nothing ran yet, so boot a fresh simulator and try once more.
    if [ $status -ne 0 ] && [ $attempt = 1 ] && tail -n +"$before" "$LOG" | grep -q "Failed to install or launch the test runner"; then
      echo "[$1] the simulator didn't install the test runner; trying again on a fresh one" >>"$PROGRESS"
      fresh_simulator
      continue
    fi
    break
  done
  sleep 1
  if [ $status -ne 0 ]; then STATUS=$status; echo "[$1] FAILED (result bundle: $OUT/e2e-$STAMP-$1.xcresult)" >>"$PROGRESS"; fi
}
FIRST=$RESET
[ "$STARTED_EMULATOR" = 1 ] && FIRST=0   # it already came up clean
if [ -z "$ONLY" ] || [ "$ONLY" = main ]; then scenario main testPairSetUpEditUndoAndSecure "$FIRST"; FIRST=1; fi
# The main scenario leaves debugging off and the app paired: the community one then starts from a clean emulator.
if [ -z "$ONLY" ] || [ "$ONLY" = community ]; then scenario community testCommunityListSetupAndUndo "$FIRST"; fi
sleep 1; kill $TAIL_PID 2>/dev/null || true; TAIL_PID=""

PASSED=$(grep -c "✓" "$PROGRESS" || true); FAILED=$(grep -c "✗" "$PROGRESS" || true); SKIPPED=$(grep -c "– " "$PROGRESS" || true)
echo; echo "Steps: $PASSED passed, $FAILED failed, $SKIPPED skipped."
# Errors from outside the steps (a crash, a test that couldn't start) are only in xcodebuild's log.
grep -E "error:|\*\* TEST" "$LOG" | sed 's/^ *//' | tail -n 15
if [ $STATUS -eq 0 ]; then say "End-to-end suite passed. Result bundles: $OUT/e2e-$STAMP-*.xcresult"; else say "End-to-end suite FAILED (exit $STATUS). Log: $LOG"; fi
exit $STATUS
