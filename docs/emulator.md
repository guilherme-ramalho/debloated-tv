# Android TV emulator

`scripts/tv-emulator.sh` runs a disposable Android TV emulator for rehearsing TV setup without touching a real TV.

| Command | What it does |
|---|---|
| `create` | One time: downloads an Android TV image and creates the AVD `DebloatedTV` |
| `start` | Boots it. After the first boot, finish the TV's setup and run `save` |
| `save` / `reset` | Saves the clean snapshot / goes back to it (undo a test run) |
| `test` | Runs the app's live ADB tests against it |
| `share setup` | Lets the iPhone's TV setup reach it at `<Mac>:15555` |
| `share` | Lets the iPhone's remote reach it at `<Mac>` (pairing works; see limits) |

## Things that behave differently from a real TV

- **One ADB client at a time.** The emulator's ADB port takes a single client, so `share setup` stops the Mac's adb
  server. Don't run adb commands while it's sharing, or adb takes the port back and the phone can't connect.
- **Port 15555, not 5565.** adb scans ports 5555–5585 for emulators and would grab a forwarder there as a second
  device ("more than one device/emulator").
- **The remote can pair but not control.** Over adb forwarding, the emulator's Android TV Remote Service accepts
  pairing (6467) but hangs up on the control port (6466) for every client, with nothing in the log. The emulator's
  own port mapping doesn't reach the service at all on Android 11+ images. Test the remote on a real TV.
- **The Mac's address changes** with DHCP. `share` prints the current one and the Mac's `.local` name, which keeps
  working.
- **Home key:** the toolbar button may not send it; use Cmd+Shift+H, or `adb shell input keyevent KEYCODE_HOME`.
- **No inputs, weather or wallpaper** after setup: the emulator reports no HDMI inputs (so the Inputs menu hides),
  weather is off until a city is set, and a fresh install has no wallpaper. All expected.
- The development profile (`dev-android-tv-emulator`) appears only in Debug builds (the Dev scheme).
