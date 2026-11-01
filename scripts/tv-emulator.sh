#!/usr/bin/env bash
# A disposable Android TV emulator for developing the in-app debloat and launcher install without touching the real TV.
#   scripts/tv-emulator.sh create   one time: download an Android TV image (Android 11 when available) and create the AVD
#   scripts/tv-emulator.sh start    boot it (first boot: finish setup, then run "save")
#   scripts/tv-emulator.sh save     save the current state as the clean snapshot
#   scripts/tv-emulator.sh reset    go back to the clean snapshot (undo a test debloat)
#   scripts/tv-emulator.sh test     run the iPhone app's ADB tests against it (accept the debugging prompt on screen)
#   scripts/tv-emulator.sh share    let the iPhone's remote reach it at <this Mac's IP>
#   scripts/tv-emulator.sh share setup   let the app's TV setup reach it at <this Mac's IP>:15555
set -euo pipefail
AVD=DebloatedTV
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
AVDMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"
EMULATOR="$ANDROID_HOME/emulator/emulator"
ADB="$ANDROID_HOME/platform-tools/adb"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# sdkmanager and avdmanager need Java 17 or newer: use Android Studio's bundled runtime unless JAVA_HOME is set.
if [ -z "${JAVA_HOME:-}" ]; then
  for j in "/Applications/Android Studio.app/Contents/jbr/Contents/Home" /opt/homebrew/opt/openjdk@17 /opt/homebrew/opt/openjdk; do
    [ -x "$j/bin/java" ] && { export JAVA_HOME="$j"; break; }
  done
fi
[ -n "${JAVA_HOME:-}" ] && export PATH="$JAVA_HOME/bin:$PATH"

need() { [ -x "$1" ] || { echo "Missing $1. In Android Studio: Settings > Languages & Frameworks > Android SDK > SDK Tools, install '$2'." >&2; exit 1; }; }

case "${1:-}" in
  create)
    need "$SDKMANAGER" "Android SDK Command-line Tools"
    need "$EMULATOR" "Android Emulator"
    ARCH=arm64-v8a; [ "$(uname -m)" = arm64 ] || ARCH=x86_64
    LIST="$("$SDKMANAGER" --list 2>/dev/null)"
    IMAGE=""
    # Android 11 first, like the TCL; newer TV images as fallbacks.
    for c in "android-30;android-tv" "android-31;android-tv" "android-33;android-tv" "android-33;google-tv" "android-34;google-tv" "android-34;android-tv"; do
      if printf '%s\n' "$LIST" | grep -q "system-images;$c;$ARCH"; then IMAGE="system-images;$c;$ARCH"; break; fi
    done
    [ -n "$IMAGE" ] || { echo "No Android TV image for $ARCH. Available TV images:" >&2; printf '%s\n' "$LIST" | grep -i -E 'android-tv|google-tv' >&2; exit 1; }
    echo "Using $IMAGE"
    yes | "$SDKMANAGER" --licenses >/dev/null || true
    "$SDKMANAGER" "$IMAGE" "platform-tools"
    echo no | "$AVDMANAGER" create avd -n "$AVD" -k "$IMAGE" -d tv_1080p --force
    echo "Created $AVD. Next: scripts/tv-emulator.sh start"
    ;;
  start)
    need "$EMULATOR" "Android Emulator"
    "$EMULATOR" -avd "$AVD" -port 5554 -no-boot-anim >/tmp/debloated-tv-emulator.log 2>&1 &
    "$ADB" wait-for-device
    until [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 2; done
    echo "Booted. Its debugging port is 127.0.0.1:5555."
    ;;
  save)  "$ADB" emu avd snapshot save clean && echo "Saved snapshot 'clean'." ;;
  reset) "$ADB" emu avd snapshot load clean && echo "Back to the clean snapshot." ;;
  test)
    # The emulator's debugging port takes one client: stop the Mac's adb server so the app's client can connect.
    "$ADB" kill-server || true
    cd "$ROOT/ios"
    ADB_TEST_HOST=127.0.0.1 ADB_TEST_PORT=5555 swift test --filter AdbTests
    ;;
  share)
    # Lets the iPhone reach the emulator over Wi-Fi, one way at a time:
    #   share          the remote: enter <this Mac's IP> in the app, as with a real TV (pairing 6467, control 6466)
    #   share setup    TV setup: enter <this Mac's IP>:15555 in Settings > Debloat & new Home
    # They can't run together: the remote goes through adb on this Mac (the emulator's own port mapping doesn't reach
    # the remote service on Android 11+ images), while TV setup needs the emulator's debugging port, which takes one client.
    MODE="${2:-remote}"
    case "$MODE" in remote|setup) ;; *) echo "Usage: $0 share [setup]" >&2; exit 1 ;; esac
    # The address on the interface that carries the default route (Wi-Fi or Ethernet, whichever is in use), plus the
    # Mac's Bonjour name, which keeps working when the router hands out a new address.
    IFACE="$(route -n get default 2>/dev/null | awk '/interface:/ { print $2 }')"
    IP="$( { [ -n "$IFACE" ] && ipconfig getifaddr "$IFACE"; } 2>/dev/null || ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '<this Mac'"'"'s IP>')"
    NAME="$(scutil --get LocalHostName 2>/dev/null || true)"
    HOST="$IP"; [ -n "$NAME" ] && HOST="$NAME.local"
    if [ "$MODE" = remote ]; then
      # adb restarts slowly after an earlier share stopped it: wait for the emulator before asking it anything.
      "$ADB" start-server >/dev/null 2>&1 || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do "$ADB" devices | grep -q 'emulator-5554[[:space:]]*device' && break; sleep 1; done
      "$ADB" devices | grep -q 'emulator-5554[[:space:]]*device' || { echo "adb can't see the emulator. Is it running (scripts/tv-emulator.sh start)?" >&2; exit 1; }
      PACKAGES="$("$ADB" -s emulator-5554 shell pm list packages 2>/dev/null || true)"
      printf '%s\n' "$PACKAGES" | grep -q 'com.google.android.tv.remote.service' || { echo "This emulator image has no Android TV Remote Service, so the remote can't pair with it. TV setup still works: $0 share setup" >&2; exit 1; }
      # Drop the emulator-level mappings an earlier version of this script made; they hold the same Mac ports.
      "$ADB" -s emulator-5554 emu redir del tcp:16466 >/dev/null 2>&1 || true
      "$ADB" -s emulator-5554 emu redir del tcp:16467 >/dev/null 2>&1 || true
      # Pairing (6467) works this way; the emulator's remote service hangs up on control (6466), see docs/emulator.md.
      "$ADB" -s emulator-5554 forward tcp:16466 tcp:6466 >/dev/null
      "$ADB" -s emulator-5554 forward tcp:16467 tcp:6467 >/dev/null
      # Check that both ports answer a TLS hello before telling the user to pair.
      python3 - <<'CHECK'
import socket, ssl
def answers(port):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    out = ssl.MemoryBIO(); tls = ctx.wrap_bio(ssl.MemoryBIO(), out)
    try: tls.do_handshake()
    except ssl.SSLWantReadError: pass
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=4) as s:
            s.sendall(out.read()); return len(s.recv(4096)) > 0
    except OSError: return False
for port, name in ((16467, "pairing (6467)"), (16466, "control (6466)")):
    print(("  answers: " if answers(port) else "  NO ANSWER: ") + name, flush=True)
CHECK
      echo "Remote: in the app's TV address, enter $IP"
      echo "For TV setup afterwards: Ctrl-C, then $0 share setup"
    else
      # The emulator's debugging port takes one client: stop the Mac's adb server so the app can connect.
      "$ADB" kill-server >/dev/null 2>&1 || true
      echo "TV setup: in Settings > Debloat & new Home, enter $HOST:15555 (or $IP:15555)"
      echo "While sharing, adb on this Mac can't reach the emulator."
    fi
    echo "Press Ctrl-C to stop sharing."
    exec python3 -u - "$MODE" <<'PY'
import asyncio, sys, time
def log(text): print(time.strftime("%H:%M:%S ") + text, flush=True)
async def pipe(r, w, count):
    try:
        while data := await r.read(65536):
            count[0] += len(data); w.write(data); await w.drain()
    except ConnectionError: pass
    finally: w.close()
def forward(port, target):
    async def handle(cr, cw):
        peer = (cw.get_extra_info("peername") or ("?",))[0]
        log(f"{peer} connected to {port}")
        try: er, ew = await asyncio.open_connection("127.0.0.1", target)
        except OSError as e: log(f"  the emulator refused {port}: {e}"); cw.close(); return
        up, down = [0], [0]
        await asyncio.gather(pipe(cr, ew, up), pipe(er, cw, down))
        log(f"  {port} closed: {up[0]} bytes to the emulator, {down[0]} back")
    return handle
async def main():
    # 15555, not 5565: adb on this Mac scans 5555-5585 for emulators and would grab the forwarder as a second one.
    ports = {15555: 5555} if sys.argv[1] == "setup" else {6466: 16466, 6467: 16467}
    servers = [await asyncio.start_server(forward(p, t), "0.0.0.0", p) for p, t in ports.items()]
    print("Sharing ports " + ", ".join(str(p) for p in ports) + ". Waiting for the iPhone…", flush=True)
    await asyncio.gather(*(s.serve_forever() for s in servers))
try: asyncio.run(main())
except KeyboardInterrupt: print("Stopped sharing.")
PY
    ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
