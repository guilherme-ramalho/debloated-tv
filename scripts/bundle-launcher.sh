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
