#!/usr/bin/env bash
# Prepares a release of the iPhone app, up to the archive. Nothing is uploaded and no TV is touched.
#
#   scripts/release.sh                 bundle the launcher, verify its key, run the tests, raise the build number, archive
#   scripts/release.sh --build 17      use this build number instead of the next one
#   scripts/release.sh --e2e           also run the live ADB test and the end-to-end suite (needs the emulator)
#   scripts/release.sh --skip-tests    only bundle, verify, bump and archive (for a rebuild of a tested commit)
#   scripts/release.sh --no-archive    everything but the archive
#
# Afterwards: commit the build number, then upload the archive from Xcode's Organizer (it opens at the end) or with
# xcodebuild -exportArchive. docs/TESTING.md has the release checklist, docs/manual-checklist.md what stays manual.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBXPROJ="$ROOT/ios/TVRemote.xcodeproj/project.pbxproj"
SCHEME="Debloated TV"
BUILD=""; TESTS=1; E2E=0; ARCHIVE=1; ALLOW_DEBUG_KEY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --build) BUILD="$2"; shift ;;
    --e2e) E2E=1 ;;
    --skip-tests) TESTS=0 ;;
    --no-archive) ARCHIVE=0 ;;
    --allow-debug-launcher-key) ALLOW_DEBUG_KEY=1 ;;   # a build nobody will install over a released launcher
    *) sed -n '2,11p' "$0"; exit 1 ;;
  esac
  shift
done
say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31mStopped:\033[0m %s\n' "$*" >&2; exit 1; }
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [ -z "${JAVA_HOME:-}" ]; then
  for j in /opt/homebrew/opt/openjdk@17 "/Applications/Android Studio.app/Contents/jbr/Contents/Home"; do
    [ -x "$j/bin/java" ] && { export JAVA_HOME="$j"; break; }
  done
fi
OUT="$ROOT/ios/build/release"; mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"

say "Release preflight"
cd "$ROOT"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"; HEAD_SHA="$(git rev-parse --short HEAD)"
echo "  Branch $BRANCH at $HEAD_SHA"
if [ -n "$(git status --porcelain)" ]; then warn "The working tree has uncommitted changes. The archive will include them; commit first for a traceable release."; else ok "Working tree clean."; fi
CURRENT="$(sed -n 's/^.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*$/\1/p' "$PBXPROJ" | sort -n | tail -n 1)"
[ -n "$CURRENT" ] || die "Couldn't read CURRENT_PROJECT_VERSION from the project."
NEXT="${BUILD:-$((CURRENT + 1))}"
[ "$NEXT" -gt "$CURRENT" ] 2>/dev/null || die "Build $NEXT is not higher than the current build $CURRENT. App Store Connect refuses a reused build number."
echo "  Build $CURRENT → $NEXT (applied after the tests pass)"

say "1/5  Launcher: build and bundle"
BUNDLE_OUT="$(bash "$ROOT/scripts/bundle-launcher.sh" 2>&1 | tee /dev/stderr)" || die "scripts/bundle-launcher.sh failed."
case "$BUNDLE_OUT" in
  *"CN=Debloated TV launcher"*) ok "Signed with the release key." ;;
  *"Android Debug"*|*"debug key"*)
    [ "$ALLOW_DEBUG_KEY" = 1 ] || die "The launcher is signed with the debug key. A TV with the released launcher can't update from it. Run scripts/launcher-key.sh verify, or pass --allow-debug-launcher-key for a build that will never ship." ;;
  *) warn "Couldn't tell which key signed the launcher (no apksigner?). Check with scripts/launcher-key.sh verify." ;;
esac
LAUNCHER_VERSION="$(sed -n 's/^ *versionName *\(.*\)$/\1/p' "$ROOT/tv-launcher/launcher/app/build.gradle" | tr -d "'\"")"
LAUNCHER_CODE="$(sed -n 's/^ *versionCode *\([0-9]*\).*$/\1/p' "$ROOT/tv-launcher/launcher/app/build.gradle")"
echo "  Launcher $LAUNCHER_VERSION (versionCode $LAUNCHER_CODE). If the launcher changed since the last release, versionCode must be higher than the released one."

say "2/5  Launcher key"
if [ "$ALLOW_DEBUG_KEY" = 1 ] && ! [ -f "${TVHOME_KEYSTORE:-$HOME/.android-release/tvhome-release.jks}" ]; then
  warn "No release key on this Mac; skipped (debug-key build allowed)."
else
  bash "$ROOT/scripts/launcher-key.sh" verify || die "scripts/launcher-key.sh verify failed."
fi

if [ "$TESTS" = 1 ]; then
  say "3/5  Tests"
  echo "  Core (swift test)…"
  (cd "$ROOT/ios" && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|failed" | tail -n 3) || true
  (cd "$ROOT/ios" && swift test >/dev/null 2>&1) || die "swift test failed. Run: cd ios && swift test"
  ok "Core tests pass."
  echo "  Launcher (gradle testReleaseUnitTest)…"
  (cd "$ROOT/tv-launcher/launcher" && ./gradlew -q --no-daemon --console=plain testReleaseUnitTest >/dev/null 2>&1) || die "Launcher tests failed. Run: cd tv-launcher/launcher && ./gradlew testReleaseUnitTest"
  ok "Launcher tests pass."
  echo "  UI smoke tests (simulator)…"
  # The newest iOS runtime (the UI test target's deployment target follows the installed SDK), an iPhone on it.
  UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys, re
def version(runtime): return tuple(int(v) for v in re.findall(r"[0-9]+", runtime.rsplit(".", 1)[-1]))
rows = [(version(runtime), d) for runtime, devs in json.load(sys.stdin)["devices"].items() if "iOS" in runtime
        for d in devs if d["isAvailable"] and d["name"].startswith("iPhone")]
newest = max((v for v, _ in rows), default=None)
candidates = [d for v, d in rows if v == newest]
pick = next((d for d in candidates if d["name"] == "iPhone 17 Pro"), candidates[0] if candidates else None)
print(pick["udid"] if pick else "")')"
  [ -n "$UDID" ] || die "No iPhone simulator available (Xcode › Settings › Components)."
  UI_LOG="$OUT/ui-tests-$STAMP.log"
  (cd "$ROOT/ios" && xcodebuild test -project TVRemote.xcodeproj -scheme "Debloated TV Dev" -destination "platform=iOS Simulator,id=$UDID" \
      -only-testing:TVRemoteUITests/TVRemoteUITests CODE_SIGNING_ALLOWED=NO >"$UI_LOG" 2>&1) || die "UI smoke tests failed. Log: $UI_LOG"
  ok "UI smoke tests pass ($(grep -ciE "Test case .*passed" "$UI_LOG") cases)."
  if [ "$E2E" = 1 ]; then
    echo "  Live ADB test (emulator)…"
    bash "$ROOT/scripts/tv-emulator.sh" test >"$OUT/adb-live-$STAMP.log" 2>&1 || die "The live ADB test failed. Log: $OUT/adb-live-$STAMP.log"
    ok "Live ADB test passes."
    echo "  End-to-end suite (simulator + emulator, about 10 minutes)…"
    bash "$ROOT/scripts/e2e.sh" >"$OUT/e2e-$STAMP.log" 2>&1 || die "The end-to-end suite failed. Log: $OUT/e2e-$STAMP.log"
    ok "End-to-end suite passes."
  else
    warn "Skipped the live ADB test and the end-to-end suite (pass --e2e with the emulator running)."
  fi
else
  say "3/5  Tests skipped (--skip-tests)"
fi

say "4/5  Build number"
# The app and widget targets share the number; the UI test target keeps its own (1).
sed -i '' "s/CURRENT_PROJECT_VERSION = $CURRENT;/CURRENT_PROJECT_VERSION = $NEXT;/g" "$PBXPROJ"
grep -q "CURRENT_PROJECT_VERSION = $NEXT;" "$PBXPROJ" || die "Couldn't update the build number in the project."
ok "Build number is now $NEXT (ios/TVRemote.xcodeproj/project.pbxproj). Commit it."

if [ "$ARCHIVE" = 1 ]; then
  say "5/5  Archive ($SCHEME, Release)"
  ARCHIVE_PATH="$OUT/DebloatedTV-build$NEXT.xcarchive"
  ARCHIVE_LOG="$OUT/archive-build$NEXT.log"
  rm -rf "$ARCHIVE_PATH"
  (cd "$ROOT/ios" && xcodebuild archive -project TVRemote.xcodeproj -scheme "$SCHEME" -configuration Release \
      -destination "generic/platform=iOS" -archivePath "$ARCHIVE_PATH" -allowProvisioningUpdates >"$ARCHIVE_LOG" 2>&1) \
    || die "The archive failed. Log: $ARCHIVE_LOG (signing: open ios/TVRemote.xcodeproj in Xcode once and let it fix provisioning)."
  APP="$(ls -d "$ARCHIVE_PATH"/Products/Applications/*.app | head -n 1)"
  BUNDLED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")"
  BUNDLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"
  [ "$BUNDLED_BUILD" = "$NEXT" ] || die "The archive carries build $BUNDLED_BUILD, not $NEXT."
  [ -f "$APP/Launcher/tvhome.apk" ] || die "The archive has no Launcher/tvhome.apk inside the app."
  SIGNER="$(ls -d "$ANDROID_HOME"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -n 1 || true)"
  if [ -n "$SIGNER" ]; then
    DN="$("$SIGNER" verify --print-certs "$APP/Launcher/tvhome.apk" 2>/dev/null | sed -n 's/^Signer #1 certificate DN: //p')"
    case "$DN" in *"Debloated TV launcher"*) ok "The archived launcher is signed with the release key." ;; *) [ "$ALLOW_DEBUG_KEY" = 1 ] || die "The archived launcher is signed by '$DN', not the release key." ;; esac
  fi
  ok "Archived $(basename "$APP") $BUNDLED_VERSION ($BUNDLED_BUILD): $ARCHIVE_PATH"
  echo
  echo "  Next, by hand (not done here):"
  echo "  1. git add ios/TVRemote.xcodeproj/project.pbxproj && git commit -m \"Build $NEXT\""
  echo "  2. Upload: open \"$ARCHIVE_PATH\" (Xcode Organizer) › Distribute App › TestFlight & App Store."
  echo "  3. docs/manual-checklist.md on the TestFlight build, on a real iPhone and TV."
  open "$ARCHIVE_PATH" 2>/dev/null || true
else
  say "5/5  Archive skipped (--no-archive)"
fi
