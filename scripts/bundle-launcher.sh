#!/usr/bin/env bash
# Builds the TV launcher (tv-launcher/) and puts its APK into the iPhone app's resources, where the in-app setup
# installs it from. Run before building the app; update-tv-home-editor.sh phone runs it for you.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [ -z "${JAVA_HOME:-}" ]; then
  for j in /opt/homebrew/opt/openjdk@17 "/Applications/Android Studio.app/Contents/jbr/Contents/Home"; do
    [ -x "$j/bin/java" ] && { export JAVA_HOME="$j"; break; }
  done
fi
cd "$ROOT/tv-launcher/launcher"
[ -f local.properties ] || echo "sdk.dir=$ANDROID_HOME" > local.properties
./gradlew -q --console=plain assembleRelease
cp app/build/outputs/apk/release/app-release.apk "$ROOT/ios/Resources/Launcher/tvhome.apk"
echo "Bundled $(du -h "$ROOT/ios/Resources/Launcher/tvhome.apk" | cut -f1) launcher into ios/Resources/Launcher/tvhome.apk"
# The APK's own versionCode, for the app's "Update Home screen" check (LauncherVersion in LauncherInstall.swift).
# Read from the APK, not build.gradle, so the number always matches the file the app installs.
aapt2="$(ls -d "$ANDROID_HOME"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -n 1 || true)"
[ -n "$aapt2" ] || { echo "aapt2 not found under $ANDROID_HOME/build-tools: can't read the launcher's version." >&2; exit 1; }
code="$("$aapt2" dump badging "$ROOT/ios/Resources/Launcher/tvhome.apk" | sed -n "s/^package: .*versionCode='\([0-9]*\)'.*$/\1/p")"
[ -n "$code" ] || { echo "Couldn't read the launcher's versionCode from the APK." >&2; exit 1; }
printf '{"versionCode": %s}\n' "$code" > "$ROOT/ios/Resources/Launcher/tvhome.json"
echo "Launcher versionCode $code (ios/Resources/Launcher/tvhome.json)"
# Which key signed it: a TV only accepts an update signed with the same key as the launcher it already has.
signer="$(ls -d "$ANDROID_HOME"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -n 1 || true)"
if [ -n "$signer" ]; then
  dn="$("$signer" verify --print-certs "$ROOT/ios/Resources/Launcher/tvhome.apk" 2>/dev/null | sed -n 's/^Signer #1 certificate DN: //p' || true)"
  echo "Signed by: $dn"
  case "$dn" in *"Android Debug"*) echo "Note: debug key (no tvhomeStoreFile in ~/.gradle/gradle.properties). Fine for development; see docs/launcher-signing.md for releases." ;; esac
fi
