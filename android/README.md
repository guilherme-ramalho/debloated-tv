# Purio TV for Android phones

The Android version of the phone app (the iPhone app is in `ios/`). Kotlin + Jetpack Compose, minSdk 26
(Android 8), target 35.

- `core/`: plain Kotlin/JVM, no Android types, ported from `ios/Sources/Core`. Tests run on the Mac in seconds.
  - `Wire.kt`: protobuf subset, frame decoder, `Problem` codes (the app turns them into translated text).
  - `Keys.kt`: `TVKey`, `WakeRequest`, `PadInteraction`.
  - `Identity.kt`: pairing secret, RSA components, a self-signed certificate builder (for tests/tools).
  - `TVConnection.kt`, `TVSession.kt`: Android TV Remote v2 over TLS with the TV's certificate pinned.
  - `EditorCrypto.kt`, `LauncherClient.kt`, `Models.kt`: TV Home editor, `docs/launcher-editor-contract.md` v2.
- `app/`: the Compose app. `Platform.kt` holds the Keystore identity, saved state and TV discovery (NSD).

## Build and test

Gradle runs on Android Studio's JDK (Java 21; the code targets Java 17). In fish:

```fish
cd android
set -x JAVA_HOME "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew :core:test                 # protocol, crypto, loopback pairing against a fake TV
./gradlew :app:assembleDebug         # app/build/outputs/apk/debug/app-debug.apk ("Purio TV Dev", .dev ID)
./gradlew :app:lintDebug
```

`local.properties` (gitignored) points at the SDK: `sdk.dir=/Users/<you>/Library/Android/sdk`.

## Plan

1. **Remote (this branch, started).** Find TV (NSD `_androidtvremote2._tcp` while the picker is open, or type
   the address), pair with the code, D-pad, Back/Home, volume, power, inputs, settings, what's on. Done: core
   protocol and tests, first app screens. Next: swipe/hold pad (`PadInteraction`), app shortcuts row, typing on
   TV, wake request, reconnect on Wi-Fi changes, the six languages.
2. **TV Home editor.** `LauncherClient` is ported and tested against a fake TV Home. Next: the TV tab (dock
   order, hide, wallpaper presets/photo, look, weather, sleep timer), same rules as the iPhone (open a session
   only when Home is in front, else ask).
3. **Actions, widgets, quick settings tile**, the Android counterparts of the iPhone's actions/widgets/Siri.
4. **TV setup (debloat + launcher install)** last, after the remote is proven. It must reuse the tested
   profile lists and the recovery records format, never guesses.

Performance rules as in the root `CLAUDE.md`: nothing runs while the app is in the background (the session
closes in `onStop`, discovery only runs on the picker), no polling.

## Coordination with the iPhone release (until `release/1.1` is merged)

This work lives on `feature/android-app` in its own worktree, branched from `release/1.1` at `de16f91`. Until
1.1 is merged to `main`, Android changes stay inside `android/`: no edits to `CLAUDE.md`, `docs/TESTING.md`,
`.github/workflows/tests.yml`, `ios/`, `tv-launcher/` or the profiles. After the merge: rebase onto `main`,
move the cases below into `docs/TESTING.md`, add an Android job to CI, and add `android/` to the root
`CLAUDE.md` layout.

## Open decisions

- **Application ID** `com.guilhermeramalho.puriotv` (`.dev` for debug). It can't change after the first Play
  Store upload.
- **Release signing**: a Play upload key, kept like the launcher key (never in the repo).
- **Default app list**: `RemoteApp.known` leaves out Surfshark and AB Player, which the iPhone list has.

## Test cases (move to docs/TESTING.md after the 1.1 merge)

| ID | Case | How |
|---|---|---|
| AND-C01 | Wire varints, fields, frame decoder (split, coalesced, oversized) | `ProtocolTest` |
| AND-C02 | Key message bytes equal the iPhone's | `ProtocolTest.keyMessageBytesMatchTheIPhone` |
| AND-C03 | Pairing secret binds the code to both keys; wrong/invalid codes refused | `ProtocolTest` |
| AND-C04 | Certificates: valid self-signed, unique subject per install | `ProtocolTest` |
| AND-C05 | Pairing end to end with a fake TV (TLS client cert, code, pin) | `SessionLoopbackTest` |
| AND-C06 | Remote handshake and a key press with the pin | `SessionLoopbackTest` |
| AND-C07 | A TV whose certificate changed is refused (`IDENTITY_CHANGED`) | `SessionLoopbackTest` |
| AND-C08 | Editor HKDF/AES-GCM known answers equal the launcher and iPhone | `EditorTest` |
| AND-C09 | Editor frames must arrive in order and untouched | `EditorTest` |
| AND-C10 | Editor session with a fake TV Home: hello, key ID, snapshot | `EditorTest` |
| AND-C11 | Snapshot JSON from the iPhone schema decodes and validates | `EditorTest` |
| AND-R01 | Picker lists the TV on the Wi-Fi with its address; stops searching when left | Manual, phone + TV |
| AND-R02 | Pair with the TV code; a wrong code says so and lets you retype | Manual, real TV |
| AND-R03 | Each key works: D-pad, OK, Back, Home, volume, mute, power, inputs, settings | Manual, real TV |
| AND-R04 | App to background closes the connection; back to front reconnects | Manual |
| AND-R05 | TV reset / other app took the pairing: asks to pair again | Manual, real TV |
| AND-R06 | Keystore key works for TLS on Android 8, 10 (TLS 1.3) and 14+ | Manual / emulator against a real TV |
