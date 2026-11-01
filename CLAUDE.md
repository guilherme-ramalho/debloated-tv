# Debloated TV

An iPhone app (SwiftUI, `ios/`) that remotes, customizes and debloats Android TVs, plus the TV Home screen it
installs (`tv-launcher/`, a fork of cleanyourtv by Gathin, MIT). Design decisions and their reasons are in
`docs/decisions.md`; emulator workflow and findings in `docs/emulator.md`.

## Principles

- **Performance comes first.** The point of debloating is a faster TV. Don't add anything that makes the TV or the
  app slower, heavier or busier in the background (polling, background services, extra network calls, bigger
  wallpapers…) without flagging the trade-off to the maintainer first.
- **TV safety.** Every change to a TV goes through the guarded code paths (`Debloater`, `LauncherInstaller` in Swift;
  the upstream scripts in `tv-launcher/tools`). Only disable packages from a tested profile list, never guesses.
  Save a recovery record before changing anything, and keep every change undoable. Don't run commands against a
  real TV without the owner's explicit go-ahead.
- **Never commit secrets or build output:** `tv-launcher/tools/adbkey/` (ADB private key), `tv-launcher/tools/venv/`,
  `ios/Resources/Launcher/*.apk`, keystores, recovery records. They are gitignored; keep it that way.
- **Tests travel with features.** Every new feature or fix updates `docs/TESTING.md` (cases with IDs) and adds
  automated tests where possible; CI (`.github/workflows/tests.yml`) must stay green.
- Keep upstream files unchanged where the design says so (profiles' `debloat.txt` / `tv.json`), and record merges in
  `tv-launcher/UPSTREAM.md`.

## Layout

- `ios/` — Xcode project `TVRemote.xcodeproj` and a Swift package (`Package.swift`) for the tests.
  - `Sources/Core` — Android TV Remote v2 (`TVSession`, `TVConnection`, `Wire`), ADB client (`Adb.swift`), debloat
    engine (`Debloat.swift`), launcher install (`LauncherInstall.swift`), profiles (`Profiles.swift`), Home editor
    client (`LauncherClient.swift`).
  - `Sources/App` — SwiftUI app. TV setup flow: `DebloatFlow.swift`, `DebloatViews.swift`.
  - `Resources/Profiles/<id>/` — one folder per supported TV (see its README). `dev-android-tv-emulator` is
    development-only.
  - `Resources/Launcher/` — `tvhome.apk` (built by `scripts/bundle-launcher.sh`, not committed) and the license
    shown in the app.
- `tv-launcher/` — launcher source (`launcher/`), upstream tools (`tools/`), `UPSTREAM.md`.
- `scripts/tv-emulator.sh` — disposable Android TV emulator (create/start/save/reset/test/share).
- `docs/launcher-editor-contract.md` — phone ↔ TV Home editor protocol.

## Build and test

- Swift tests: `cd ios && swift test`. The live ADB test runs only when `ADB_TEST_HOST` / `ADB_TEST_PORT` are set
  (`scripts/tv-emulator.sh test`).
- Launcher tests: `cd tv-launcher/launcher && ./gradlew testReleaseUnitTest` (Java 17).
- Launcher APK for the app: `scripts/bundle-launcher.sh` (run before building the app).
- Schemes: **Debloated TV Dev** (Debug, `DEBUG` flag, separate dev app: bundle ID suffix `.dev`, name suffix
  " Dev") for development; **Debloated TV** (Release) for distribution. Driven by the project-level build settings
  `BUNDLE_ID_SUFFIX` and `APP_NAME_SUFFIX`. Development-only features (like the emulator profile) use `#if DEBUG`.
- Launcher signing: whoever installs a launcher build on a TV ties that TV to the signing key; a build signed with
  another key can't update it (uninstall first). Contributors sign with their own Android debug key for their own
  TVs; the APK bundled in published app releases is signed by the maintainer's private key, which is never in the
  repo.

## Adding a TV model

Copy the model's `debloat.txt` and `tv.json` unchanged from cleanyourtv's `examples/<model>/` into
`ios/Resources/Profiles/<id>/` and write its `profile.json` (format in `ios/Resources/Profiles/README.md`). Add a
test in `ios/Tests/ProfileTests.swift`, rehearse on the emulator where possible, and test on the real TV before
shipping.
