#!/usr/bin/env bash
# Sets up and checks the TV launcher's release signing key on a maintainer's Mac (docs/launcher-signing.md).
#
#   scripts/launcher-key.sh setup     create the key, point Gradle at it, back it up, check a build (run once)
#   scripts/launcher-key.sh verify    check the key, the Gradle settings, a backup image and the last built APK
#
# The key and its password stay on this Mac and in your backups. Nothing here is committed or uploaded.
# Override the defaults with environment variables: TVHOME_KEYSTORE, TVHOME_BACKUP, TVHOME_KEY_NAME.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYSTORE="${TVHOME_KEYSTORE:-$HOME/.android-release/tvhome-release.jks}"
BACKUP="${TVHOME_BACKUP:-$HOME/Desktop/tvhome-key-backup.dmg}"
KEY_NAME="${TVHOME_KEY_NAME:-Debloated TV launcher}"
ALIAS="tvhome"
PROPS="$HOME/.gradle/gradle.properties"
APK="$ROOT/ios/Resources/Launcher/tvhome.apk"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31mStopped:\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {   # confirm "question" word: waits until the user types the word
    local answer=""
    while [ "$answer" != "$2" ]; do read -r -p "  $1 Type '$2' to continue: " answer; done
}

find_keytool() {
    local candidate
    for candidate in "${JAVA_HOME:+$JAVA_HOME/bin/keytool}" "$(command -v keytool 2>/dev/null || true)" \
        "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool" \
        /opt/homebrew/opt/openjdk@17/bin/keytool /opt/homebrew/opt/openjdk/bin/keytool; do
        # /usr/bin/keytool on a Mac without Java is a stub that only prints an install prompt.
        if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" -help 2>&1 | grep -q -- -genkeypair; then KEYTOOL="$candidate"; return; fi
    done
    die "No Java keytool found. Install Android Studio (it includes Java) or 'brew install openjdk@17', then run this again."
}

find_apksigner() {
    APKSIGNER="$(ls -d "$ANDROID_HOME"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -n 1 || true)"
}

prop() {   # prop name: a value from ~/.gradle/gradle.properties
    [ -f "$PROPS" ] || return 0
    sed -n "s/^$1=//p" "$PROPS" | tail -n 1
}

# The key's SHA-256 certificate fingerprint, lowercase hex without colons (the format apksigner prints).
key_fingerprint() {   # key_fingerprint keystore (password in $TVHOME_PW)
    "$KEYTOOL" -list -v -keystore "$1" -storepass:env TVHOME_PW -alias "$ALIAS" 2>/dev/null \
        | sed -n 's/^[[:space:]]*SHA256: //p' | head -n 1 | tr -d ':' | tr 'A-F' 'a-f'
}

apk_fingerprint() {
    [ -n "$APKSIGNER" ] && [ -f "$APK" ] || return 0
    "$APKSIGNER" verify --print-certs "$APK" 2>/dev/null | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -n 1
}

# Mounts the encrypted backup image, prints the fingerprint of the key inside it, unmounts it.
backup_fingerprint() {
    local mount fp=""
    mount="$(mktemp -d)"
    if printf '%s' "$TVHOME_PW" | hdiutil attach -stdinpass -nobrowse -readonly -mountpoint "$mount" "$BACKUP" >/dev/null 2>&1; then
        [ -f "$mount/$(basename "$KEYSTORE")" ] && fp="$(key_fingerprint "$mount/$(basename "$KEYSTORE")")"
        hdiutil detach "$mount" >/dev/null 2>&1 || hdiutil detach -force "$mount" >/dev/null 2>&1 || true
    fi
    rmdir "$mount" 2>/dev/null || true
    printf '%s' "$fp"
}

build_and_compare() {   # build_and_compare expected-fingerprint
    find_apksigner
    if [ ! -d "$ANDROID_HOME" ]; then warn "No Android SDK at $ANDROID_HOME: skipped the test build. Run scripts/bundle-launcher.sh later."; return; fi
    say "Building the launcher to check it's signed with the release key…"
    bash "$ROOT/scripts/bundle-launcher.sh"
    local built; built="$(apk_fingerprint)"
    if [ -z "$built" ]; then warn "Couldn't read the APK's signature (no apksigner in $ANDROID_HOME/build-tools)."
    elif [ "$built" = "$1" ]; then ok "The launcher APK is signed with the release key."
    else die "The APK is signed with a different key ($built). Check $PROPS."
    fi
}

setup() {
    find_keytool
    [ "$(uname)" = "Darwin" ] || die "This script is for macOS (it uses hdiutil and the clipboard)."
    if [ -e "$KEYSTORE" ]; then
        die "$KEYSTORE already exists. It is never overwritten: every TV is tied to it. Run '$0 verify' to check it."
    fi
    if [ -n "$(prop tvhomeStoreFile)" ]; then
        die "$PROPS already names a launcher key ($(prop tvhomeStoreFile)). Remove those tvhome lines first if that key is gone for good."
    fi

    say "1/6  Password"
    TVHOME_PW="$(openssl rand -base64 30 | tr -d '\n')"
    export TVHOME_PW
    printf '%s' "$TVHOME_PW" | pbcopy
    ok "Generated a random password and copied it to the clipboard."
    echo "  Create an item called \"$KEY_NAME signing key\" in your password manager and paste it as the password."
    confirm "Saved?" saved
    pbcopy </dev/null

    say "2/6  Key"
    mkdir -p "$(dirname "$KEYSTORE")"
    chmod 700 "$(dirname "$KEYSTORE")"
    "$KEYTOOL" -genkeypair -keystore "$KEYSTORE" -storetype PKCS12 -alias "$ALIAS" -keyalg RSA -keysize 4096 \
        -validity 36500 -dname "CN=$KEY_NAME" -storepass:env TVHOME_PW -keypass:env TVHOME_PW >/dev/null 2>&1 \
        || die "keytool couldn't create the key."
    chmod 600 "$KEYSTORE"
    local fp; fp="$(key_fingerprint "$KEYSTORE")"
    [ -n "$fp" ] || die "Created the key but couldn't read it back."
    ok "Created $KEYSTORE"
    echo "  Fingerprint (SHA-256): $fp"
    printf '%s' "$fp" | pbcopy
    echo "  Copied to the clipboard: add it to the same password manager item (it isn't secret; it identifies the key)."
    confirm "Added?" added

    say "3/6  Gradle"
    mkdir -p "$(dirname "$PROPS")"
    touch "$PROPS"
    chmod 600 "$PROPS"
    # A file that doesn't end with a newline would glue the first line onto its last one.
    [ -s "$PROPS" ] && [ "$(tail -c 1 "$PROPS")" != "" ] && echo >>"$PROPS"
    {
        echo "# Debloated TV launcher release key (scripts/launcher-key.sh). Never commit this file."
        echo "tvhomeStoreFile=$KEYSTORE"
        echo "tvhomeStorePassword=$TVHOME_PW"
        echo "tvhomeKeyAlias=$ALIAS"
        echo "tvhomeKeyPassword=$TVHOME_PW"
    } >>"$PROPS"
    ok "Added the key to $PROPS (readable only by you)."

    say "4/6  Backup in the password manager"
    base64 -i "$KEYSTORE" | pbcopy
    echo "  The key file is on the clipboard as text. Paste it into the item's notes."
    echo "  (If your password manager takes attachments, you can attach $KEYSTORE instead.)"
    echo "  To restore it later: copy that text, then run: pbpaste | base64 -d > \"$KEYSTORE\""
    confirm "Pasted?" pasted
    pbcopy </dev/null

    say "5/6  Encrypted backup image"
    [ -e "$BACKUP" ] && die "$BACKUP already exists; move it away or set TVHOME_BACKUP to another path."
    printf '%s' "$TVHOME_PW" | hdiutil create -size 20m -fs HFS+ -encryption AES-256 -stdinpass \
        -volname TVHomeKey "$BACKUP" >/dev/null || die "hdiutil couldn't create the backup image."
    local mount; mount="$(mktemp -d)"
    printf '%s' "$TVHOME_PW" | hdiutil attach -stdinpass -nobrowse -mountpoint "$mount" "$BACKUP" >/dev/null \
        || die "Couldn't open the new backup image."
    cp "$KEYSTORE" "$mount/"
    hdiutil detach "$mount" >/dev/null || hdiutil detach -force "$mount" >/dev/null
    rmdir "$mount" 2>/dev/null || true
    [ "$(backup_fingerprint)" = "$fp" ] || die "The backup image doesn't open to the same key. Delete $BACKUP and run setup again after removing the key."
    ok "Created $BACKUP (same password) and checked it opens to the same key."
    echo "  Move it to a USB stick or iCloud Drive now, somewhere that survives losing this Mac."

    unset TVHOME_PW
    say "6/6  Check"
    build_and_compare "$fp"

    say "Done"
    echo "  Release builds of the launcher are now signed with this key. Check any time with: $0 verify"
    echo "  Never commit or upload $KEYSTORE or $PROPS."
}

verify() {
    find_keytool
    find_apksigner
    say "Key"
    [ -f "$KEYSTORE" ] || die "No key at $KEYSTORE. Restore it from a backup, or run '$0 setup' if there never was one."
    local store; store="$(prop tvhomeStoreFile)"
    [ -n "$store" ] || die "$PROPS doesn't name the key. Add the four tvhome lines (docs/launcher-signing.md)."
    [ "$store" = "$KEYSTORE" ] || warn "Gradle uses $store, not $KEYSTORE."
    TVHOME_PW="$(prop tvhomeStorePassword)"
    export TVHOME_PW
    local fp; fp="$(key_fingerprint "$store")"
    [ -n "$fp" ] || die "Gradle's password doesn't open $store."
    ok "Gradle's settings open the key."
    echo "  Fingerprint (SHA-256): $fp  (compare with the one in your password manager)"
    [ "$(stat -f '%Lp' "$PROPS" 2>/dev/null || echo 600)" = "600" ] || warn "$PROPS is readable by others: chmod 600 \"$PROPS\""

    say "Backup image"
    if [ -f "$BACKUP" ]; then
        if [ "$(backup_fingerprint)" = "$fp" ]; then ok "$BACKUP opens to the same key."
        else warn "$BACKUP doesn't open to this key with this password."; fi
    else
        echo "  Not at $BACKUP (fine if you moved it). To check it, plug it in and run:"
        echo "  TVHOME_BACKUP=/path/to/tvhome-key-backup.dmg $0 verify"
    fi

    say "Last built launcher"
    local built; built="$(apk_fingerprint)"
    if [ -z "$built" ]; then echo "  None yet (or no apksigner). Build it with scripts/bundle-launcher.sh."
    elif [ "$built" = "$fp" ]; then ok "$APK is signed with the release key."
    else warn "$APK is signed with another key ($built): rebuild with scripts/bundle-launcher.sh before releasing."
    fi
    unset TVHOME_PW
}

case "${1:-}" in
    setup) setup ;;
    verify) verify ;;
    *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 64 ;;
esac
