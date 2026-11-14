# Android TV emulator

`scripts/tv-emulator.sh` runs a disposable Android TV emulator for rehearsing TV setup without touching a real TV.

| Command | What it does |
|---|---|
| `create` | One time: downloads an Android TV image and creates the AVD `DebloatedTV` |
| `start` | Boots it. After the first boot, finish the TV's setup and run `save` |
| `save` / `reset` | Saves the clean snapshot / goes back to it (undo a test run) |
| `test` | Runs the app's live ADB tests against it (accepts the debugging prompt itself) |
| `share setup` | Lets the iPhone's TV setup reach it at `<Mac>:15555` |
| `share` | Lets the iPhone's remote reach it at `<Mac>` (pairing works; see limits) |

`scripts/e2e.sh` runs the whole app against it from the iOS Simulator (docs/TESTING.md, "End-to-end suite").

## Things that behave differently from a real TV

- **One ADB client at a time** on the emulator's own port (5555 on this Mac), so `share setup` stops the Mac's adb
  server. Don't run adb commands while it's sharing, or adb takes the port back and the phone can't connect.
  The way around it, used by `test` and `scripts/e2e.sh`: `adb tcpip 5555` restarts the emulator's adbd listening
  on TCP inside the guest, and `adb forward tcp:15555 tcp:5555` reaches that listener through the adb server, which
  stays up. The app connects to 127.0.0.1:15555 while adb on the Mac keeps working, and can even accept the
  "Allow USB debugging?" prompt for the app (`scripts/e2e-helper.py approve`).
- **A reboot takes the forwards with it.** Setup restarts the TV at the end of apply (TESTING.md DBL-18); the
  reboot ends adb's transport, drops every forward and brings adbd back in USB mode. The helper's `watch-reboot`
  endpoint waits for the boot to finish, runs `adb tcpip 5555` again and re-adds the forwards, so the app reconnects
  as it would to a real TV.
- **App updates restart the remote service.** About a minute after a boot from the clean snapshot (saved 31 Oct
  2026) the Play Store updates itself and then Google Play services; Android force-stops everything bound to Play
  services while it installs, the TV Remote Service included, which drops a pairing in progress (CON-02 failed this
  way on 14 Nov 2026: "Force stopping com.google.android.gms … installPackageLI", then the remote service "has
  died"). Fixed for good on 15 Nov 2026: the clean snapshot was re-saved after
  a boot on the host's clock let every pending update finish (Play Store, Play services, TV Remote Service 5.2 → 7.00,
  stock launcher, YouTube, WebView, keyboard, TalkBack, TTS, Cast), with the Play Store then disabled so nothing
  updates during a run. `scripts/e2e.sh` also disables it as it prepares the TV, in case a snapshot is saved without
  that. The 31 Oct snapshot is backed up in `~/.android/avd/DebloatedTV-snapshot-backups/clean-2026-10-31`.
- **Port 15555, not 5565.** adb scans ports 5555–5585 for emulators and would grab a forwarder there as a second
  device ("more than one device/emulator").
- **The remote can pair but not control.** The Android TV Remote Service on the `android-tv` API 31 image accepts
  pairing (6467) but closes every control connection (6466) at the TLS hello, from the Mac and from inside the
  guest alike, with nothing in its log even at verbose; at start it logs "inputProviderService is null, can't open
  remote input bridge", which the control channel needs. So the remote, the foreground app the TV reports (the
  setup offer after pairing) and the phone editor (its link travels over the remote) can't be tested on this image.
  `scripts/e2e.sh` notices and skips those cases, and says so in the result. A newer image (`google-tv` API 33/34)
  may have the bridge; untested. The emulator's own port mapping (`redir`) doesn't reach the service at all on
  Android 11+ images: use `adb forward`.
- **"Always allow from this computer" doesn't stick.** The image can't save approved ADB keys
  (`AdbDebuggingManager: Error writing key … /data/misc/adb/adb_keys … EACCES`), so every new ADB connection shows
  "Allow USB debugging?" again. `scripts/tv-emulator.sh test` and `scripts/e2e.sh` answer the prompts themselves and
  the suite notes how many came; on a real TV the approved key reconnects with none (DBL-16b, UND).
- **The clock stops at the snapshot.** Loading a snapshot (`reset`, and `start` through the quick-boot snapshot)
  brings back the time it was saved with, hours or days behind. The phone's pairing certificate is dated a day
  before it was made, so to the TV it isn't valid yet. `scripts/tv-emulator.sh start`/`reset` and `scripts/e2e.sh`
  reboot the guest (`adb reboot`, which takes the host's time again) when the clock is more than five minutes off.
- **The Mac's address changes** with DHCP. `share` prints the current one and the Mac's `.local` name, which keeps
  working.
- **Home key:** the toolbar button may not send it; use Cmd+Shift+H, or `adb shell input keyevent KEYCODE_HOME`.
- **No inputs, weather or wallpaper** after setup: the emulator reports no HDMI inputs (so the Inputs menu hides),
  weather is off until a city is set, and a fresh install has no wallpaper. All expected.
- The development profile (`dev-android-tv-emulator`) appears only in Debug builds (the Dev scheme).
