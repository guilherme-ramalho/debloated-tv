#!/usr/bin/env bash
# App Store screenshots at 1320 x 2868: the release build in an iPhone 17 Pro Max simulator, paired with a TV on this
# Mac's network, with a clean status bar. You move through the app in the Simulator; the script takes one shot per
# Enter and names it. The simulator is kept between runs, so pairing is needed only the first time.
#
#   scripts/store-shots.sh                 English shots in ios/build/store-shots/en
#   scripts/store-shots.sh --lang pt-BR    the same shots in another language (de, es, fr, it, pt-BR)
#   scripts/store-shots.sh --no-build      reuse the app already installed in the simulator
#
# The Android TV emulator can't stand in for the TV here: its remote channel closes at the TLS hello
# (TVRemoteEndToEndTests), so the remote and the editor would show as disconnected.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM_NAME="Debloated Store Shots"
DEVICE_TYPE="iPhone 17 Pro Max"
BUNDLE_ID="com.guilhermeramalho.TVRemote"
LANG_CODE=en; BUILD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --lang) LANG_CODE="$2"; shift ;;
    --no-build) BUILD=0 ;;
    *) sed -n '2,12p' "$0"; exit 1 ;;
  esac
  shift
done
case "$LANG_CODE" in en|de|es|fr|it|pt-BR) ;; *) echo "Unknown language '$LANG_CODE' (en, de, es, fr, it, pt-BR)"; exit 1 ;; esac
LOCALE="${LANG_CODE/-/_}"; [ "$LANG_CODE" = en ] && LOCALE=en_US
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31mStopped:\033[0m %s\n' "$*" >&2; exit 1; }
OUT="$ROOT/ios/build/store-shots/$LANG_CODE"; mkdir -p "$OUT"

# --- the simulator: its own device, never erased, so the pairing survives -------------------------------------------
UDID="$(xcrun simctl list devices -j | python3 -c 'import json,sys; d=[x for r in json.load(sys.stdin)["devices"].values() for x in r if x["name"]=="'"$SIM_NAME"'" and x["isAvailable"]]; print(d[0]["udid"] if d else "")')"
if [ -z "$UDID" ]; then
  say "Creating the simulator '$SIM_NAME' ($DEVICE_TYPE)…"
  UDID="$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE")" || die "No '$DEVICE_TYPE' simulator type; install an iOS simulator runtime in Xcode › Settings › Components."
fi
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
open -a Simulator --args -CurrentDeviceUDID "$UDID"
xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

# --- the app: release configuration, so no "Dev" anywhere -------------------------------------------------------------
if [ "$BUILD" = 1 ]; then
  say "Building the release configuration for the simulator…"
  DD="$ROOT/ios/build/store-shots-dd"
  (cd "$ROOT/ios" && xcodebuild build -project TVRemote.xcodeproj -scheme "Debloated TV" -configuration Release \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DD" -quiet) || die "Build failed."
  APP="$(find "$DD/Build/Products/Release-iphonesimulator" -maxdepth 1 -name '*.app' | head -n 1)"
  [ -n "$APP" ] || die "No .app in $DD/Build/Products/Release-iphonesimulator."
  xcrun simctl install "$UDID" "$APP"
fi
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -AppleLanguages "($LANG_CODE)" -AppleLocale "$LOCALE" >/dev/null \
  || die "Couldn't launch $BUNDLE_ID (run without --no-build first)."

say "In the Simulator: pair with the TV if it asks (first run only). Then set up each screen and press Enter."
echo "Type s + Enter to skip a shot. Keep Wi-Fi names and passwords out of frame."
shot() {
  local name="$1" what="$2" answer
  printf '\n\033[1m%s\033[0m  %s\n  Enter = take it, s = skip: ' "$name" "$what"
  read -r answer
  [ "$answer" = s ] && { echo "  skipped"; return; }
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1
  # The simulator's PNGs carry an alpha channel, which App Store Connect refuses: the upload copy is a JPEG without one.
  mkdir -p "$OUT-upload"
  sips -s format jpeg -s formatOptions best "$OUT/$name.png" --out "$OUT-upload/$name.jpg" >/dev/null
  local size; size="$(sips -g pixelWidth -g pixelHeight "$OUT-upload/$name.jpg" | awk '/pixel/ {printf "%s ", $2}')"
  echo "  saved $OUT-upload/$name.jpg ($size)"
}
shot 01-remote "Remote tab, connected, with the app shortcuts row."
shot 02-tv-home "TV tab: the Debloated strip and the Home editor (dock and wallpaper)."
shot 03-setup-review "Settings › Debloat & new Home, up to 'Choose what stays' (network debugging on). Don't press Apply."
shot 04-type "Remote with Type on TV open and a few words typed."
shot 05-actions "Actions tab with a quick action or two."
shot 06-action-steps "A quick action opened, showing its steps."
xcrun simctl status_bar "$UDID" clear
say "Done. Upload the files in $OUT-upload"
