# Signing the TV launcher

Android only installs an update over an app signed with the same key. The iPhone app installs the TV launcher
(`ios/Resources/Launcher/tvhome.apk`, built by `scripts/bundle-launcher.sh`), so every launcher a release ships must
be signed with the same release key, for as long as the project exists.

## Without a release key (contributors, CI)

Nothing to set up. Release builds fall back to your machine's debug key (`~/.android/debug.keystore`). They work on
your own TV and emulator, but can't update a launcher installed from an official release: the app explains that the
other build has to be uninstalled first.

## With the release key (maintainers)

`scripts/launcher-key.sh setup` does all of the steps below on a Mac, including the backups, and
`scripts/launcher-key.sh verify` checks the key, Gradle's settings, a backup image and the last built APK. The manual
steps are here for reference and other systems.

The key and its password live outside the repository. Never commit them, attach them to issues, or put them in CI
logs. `.gitignore` excludes `*.jks` and `*.keystore` as a safety net.

1. Create the key once (any JDK's `keytool`, for example Android Studio's in
   `/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin`):

   ```sh
   mkdir -p ~/.android-release
   keytool -genkeypair -v -keystore ~/.android-release/tvhome-release.jks -storetype PKCS12 \
     -alias tvhome -keyalg RSA -keysize 4096 -validity 36500 -dname "CN=Debloated TV launcher"
   ```

   Choose a long password. PKCS12 uses one password for the store and the key.

2. Tell Gradle where it is, in `~/.gradle/gradle.properties` (your home folder, not the project):

   ```properties
   tvhomeStoreFile=/Users/YOU/.android-release/tvhome-release.jks
   tvhomeStorePassword=THE_PASSWORD
   tvhomeKeyAlias=tvhome
   tvhomeKeyPassword=THE_PASSWORD
   ```

   Then `chmod 600 ~/.gradle/gradle.properties`.

3. Back up the `.jks` file and the password together, somewhere that survives losing the computer (a password
   manager entry with the file attached works). Losing the key means every user has to uninstall the launcher before
   they can get an update.

4. Build with `scripts/bundle-launcher.sh`. It prints which key signed the APK; `CN=Debloated TV launcher` is the
   release key, `CN=Android Debug` means Gradle didn't find the properties.

## Releasing

The key never leaves the maintainer's computer: only the signed APK ships, inside the iPhone app.

1. If the launcher changed since the last release, raise `versionCode` (and `versionName`) in
   `tv-launcher/launcher/app/build.gradle`. A TV refuses to install a lower `versionCode` over a higher one.
2. Run `scripts/bundle-launcher.sh` and check it prints `Signed by: CN=Debloated TV launcher` (not `Android Debug`).
   The APK lands in `ios/Resources/Launcher/tvhome.apk`, which git ignores.
3. Archive the **Debloated TV** scheme in Xcode and upload it as usual. The APK is part of the app bundle.

CI doesn't need the key: it only runs tests. If a release pipeline ever signs in CI, the key goes into the CI's
encrypted secrets, never into the repository.

## Switching a TV from a debug-signed launcher

A TV that has a debug-signed launcher (a development TV or emulator) can't take the release-signed one as an update.
Restore the TV to its stock Home first (Settings › Undo TV setup), uninstall the old launcher
(`adb shell pm uninstall com.gathin.tvhome`), then run the setup again. Its Home layout and wallpaper start fresh.
