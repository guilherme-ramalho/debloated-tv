#!/usr/bin/env bash
# App Store screenshots, automated: the release build in two simulators (6.9" iPhone 17 Pro Max, 1320 x 2868, and
# 6.3" iPhone 17 Pro, 1206 x 2622), each paired with a real TV on this Mac's network, driven by the StoreScreenshots
# UI test in every language. Shot 08 (widgets) stays manual: scripts/store-shots.sh.
#
#   scripts/store-shots-auto.sh                  all six languages, both sizes
#   scripts/store-shots-auto.sh --langs en,de    only these languages
#   scripts/store-shots-auto.sh --only 03        only shot 03 (setup review)
#   scripts/store-shots-auto.sh --pair           open both simulators to pair them with the TV first (once)

#
# Output: ios/build/store-shots-auto/<size>/<lang>/NN-name.png, and JPEG copies without alpha (App Store Connect
# refuses an alpha channel) in ios/build/store-shots-auto/upload/<size>/<lang>/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LANGS="en,de,es,fr,it,pt-BR"; PAIR=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --langs) LANGS="$2"; shift ;;
    --only) ONLY="$2"; shift ;;
    --pair) PAIR=1 ;;
    *) sed -n '2,14p' "$0"; exit 1 ;;
  esac
  shift
done
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31mStopped:\033[0m %s\n' "$*" >&2; exit 1; }
OUT="$ROOT/ios/build/store-shots-auto"; mkdir -p "$OUT"
BUNDLE_ID="com.guilhermeramalho.TVRemote"

sim() {   # name, device type → udid (created once, never erased, so its pairing survives)
  local udid
  udid="$(xcrun simctl list devices -j | python3 -c 'import json,sys; d=[x for r in json.load(sys.stdin)["devices"].values() for x in r if x["name"]=="'"$1"'" and x["isAvailable"]]; print(d[0]["udid"] if d else "")')"
  [ -n "$udid" ] || udid="$(xcrun simctl create "$1" "$2")" || die "No '$2' simulator type."
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  echo "$udid"
}
say "Simulators…"
BIG="$(sim "Debloated Store Shots" "iPhone 17 Pro Max")"      # the 1.0 shots' simulator, already paired then
SMALL="$(sim "Purio Store Shots 6.3" "iPhone 17 Pro")"

say "Building the release app for the simulator…"
DD="$ROOT/ios/build/store-shots-dd"
(cd "$ROOT/ios" && xcodebuild build -project TVRemote.xcodeproj -scheme "Debloated TV" -configuration Release \
  -destination "generic/platform=iOS Simulator" -derivedDataPath "$DD" -quiet) || die "Build failed."
APP="$(find "$DD/Build/Products/Release-iphonesimulator" -maxdepth 1 -name '*.app' | head -n 1)"
for udid in "$BIG" "$SMALL"; do xcrun simctl install "$udid" "$APP"; done

if [ "$PAIR" = 1 ]; then
  open -a Simulator
  for udid in "$BIG" "$SMALL"; do xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null; done
  say "In each simulator: connect to the TV and enter the code it shows. Put the TV on its Home screen. Then press Enter."
  read -r _
fi

shoot() {   # udid, size label
  say "Screenshots on the $2 simulator ($LANGS)…"
  (cd "$ROOT/ios" && TEST_RUNNER_STORE_SHOTS_DIR="$OUT/$2" TEST_RUNNER_STORE_SHOTS_LANGS="$LANGS" TEST_RUNNER_STORE_SHOTS_ONLY="$ONLY" \
    xcodebuild test -project TVRemote.xcodeproj -scheme "Debloated TV Dev" -destination "id=$1" \
    -only-testing:TVRemoteUITests/StoreScreenshots -parallel-testing-enabled NO -derivedDataPath "$ROOT/ios/build/store-shots-test-dd" 2>&1 \
    | grep -E "STORE-SHOTS|error:|failed|\*\* TEST" || true)
}
shoot "$BIG" 6.9
shoot "$SMALL" 6.3

say "JPEG copies for upload…"
find "$OUT/6.9" "$OUT/6.3" -name '*.png' 2>/dev/null | while read -r png; do
  rel="${png#$OUT/}"; jpg="$OUT/upload/${rel%.png}.jpg"; mkdir -p "$(dirname "$jpg")"
  sips -s format jpeg -s formatOptions best "$png" --out "$jpg" >/dev/null
done
for udid in "$BIG" "$SMALL"; do xcrun simctl status_bar "$udid" clear; done
say "Done: $(find "$OUT/upload" -name '*.jpg' | wc -l | tr -d ' ') screenshots in $OUT/upload (08: scripts/store-shots.sh)."
