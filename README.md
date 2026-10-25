# TV Remote — Quiet Signal

A personal SwiftUI remote for Android TV, with a navy interface, white controls, streaming shortcuts, and a separate **On TV** screen for playback information. Developed against a TCL Smart TV Pro running Android 11.

The iPhone connects directly to the TV over the local network. Normal use needs no Mac server, ADB connection, Google account, cloud relay, or analytics service.

## Features

- D-pad with a large OK target; Home, Back, inputs, mute, volume, and power.
- Press feedback and light haptics. D-pad and volume support holding; release is sent when the gesture ends or the app backgrounds.
- Six logo-only streaming tiles: Netflix, YouTube, Prime Video, Disney+, HBO Max, and Crunchyroll.
- Automatic reconnect and certificate-bound pairing, with private identity stored in the iPhone Keychain.
- Playback-aware Play/Pause icon and a separate On TV screen for app, title, playback state, and HDMI device labels.
- Standby wake on supported TCL firmware with Network Standby and Screenless Service enabled.

## Project layout

| Directory | Purpose |
| --- | --- |
| `ios` | iPhone app, shared protocol core, Xcode project, bundled assets, Swift tests |
| `android-playback` | Small read-only TV companion for media-session and input information |

The main remote uses Android TV Remote Service v2 (TCP 6466 control, 6467 pairing). Playback information uses an independent mutually authenticated TLS connection to the companion on TCP 9765. Failure of the metadata connection does not disable remote control. Devices must be on the same trusted local network; do not forward these ports to the internet.

## Build the iPhone app

Requires Xcode with an iOS SDK and an iPhone running iOS 17 or newer.

1. Open `ios/TVRemote.xcodeproj` and select the `TVRemote` target.
2. Choose your own signing Team and a bundle identifier available to that team. The repository contains no developer credentials or provisioning profiles.
3. Select your iPhone and build/run. Wireless installation requires the phone to have been paired with Xcode first.
4. Open the app, allow Local Network access, enter the TV's IPv4 address in Connection settings, and tap **Pair TV**. Enter the six-character code displayed by the TV.

The shared run scheme uses Release without debugger attachment. Personal Team development builds require periodic re-signing; the provisioning profile determines expiry. Pairing identities persist in Keychain across ordinary updates.

Run the protocol tests on macOS:

```sh
cd ios
swift test
```

## Build and set up playback information

Requires JDK 17 and Android SDK 34. The project includes a Gradle 8.9 wrapper and uses Android Gradle Plugin 8.5.2, with no third-party runtime dependencies.

```sh
cd android-playback
export JAVA_HOME=/path/to/jdk-17
export ANDROID_HOME=/path/to/Android/sdk
./gradlew assembleDebug testDebugUnitTest lintDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

1. Open **TV Playback** on the TV.
2. Choose **Enable playback access** and explicitly approve Android's Notification access permission for this companion. This framework permission allows access to media sessions; the companion does not read notification contents. Revoking it stops metadata access.
3. Choose **Connect iPhone** on the TV. This opens a two-minute pairing window.
4. In the iPhone app, open **On TV → Connect playback information** and enter the code displayed on the TV. This pairing is separate from remote-control pairing.

Some Android TV builds omit the Notification access settings screen. After the owner explicitly approves this permission, initial setup can use ADB:

```sh
adb shell cmd notification allow_listener com.guilhermeramalho.tvplayback/.PlaybackListener
```

To revoke it:

```sh
adb shell cmd notification disallow_listener com.guilhermeramalho.tvplayback/.PlaybackListener
```

ADB is only needed for installation/setup on these TVs. The system-bound notification listener keeps the metadata service available. Disable debugging again after setup. To reset paired playback clients, clear TV Playback's app data; then pair again. Clearing app data also regenerates its TLS identity.

## Behavior and limitations

Titles and playback state come from Android media sessions. A streaming app may omit either; the interface displays **Title unavailable** or an unknown playback state rather than guessing. The companion filters media sessions using the foreground package reported by the remote service. It does not scrape screenshots or store viewing history.

HDMI names come from Android TV input labels and HDMI-CEC. A console must advertise a name, or the input must be named manually. The selected-input property is TCL-specific (`persist.sys.curInput`); other manufacturers may require an adapter. Unknown devices remain generic inputs.

Standby wake depends on the TV keeping its remote service reachable. On the tested TCL, Network Standby and Screenless Service were required. Wake refreshes power state, waits briefly for the virtual input bridge, then sends at most one Power toggle if the TV still reports standby. It expires and cancels on backgrounding; stale commands are not replayed. Overnight standby behavior and other TV models are not guaranteed.

The app has no AirPlay receiver, photo sharing, discovery, voice input, or text keyboard. The remote's IME protocol feature is enabled only to obtain the foreground app; it does not replace the TV keyboard.

## Security and privacy

Each iPhone generates its own RSA identity. Pairing proofs bind the TV code to both devices' keys, and subsequent connections pin the TV certificate. The companion stores its private key in AndroidKeyStore and trusts only explicitly paired phone certificates outside the short pairing window. No private keys, pairing state, device logs, viewing titles, build products, or signing profiles belong in this repository.

The companion uses bounded frames, limited simultaneous clients, pairing attempt limits, and background socket writes. Media callbacks deliver changes; TCL input polling runs only while an authenticated phone is viewing input information. No screenshots, microphone, location, cloud API, or notification-body processing is used.

## Validation

The source currently passes 10 Swift core tests, three Android protocol tests, Android debug assembly and lint, and an iOS device-target UI build. Companion startup has been checked on the TCL. End-to-end playback pairing and the new On TV screen still need physical-device validation. Existing remote control and standby wake were previously confirmed on the iPhone; those checks should be repeated after this update.

## References and assets

- [Android TV Remote v2 protocol reference](https://github.com/tronikos/androidtvremote2)
- [Google pairing schema](https://android.googlesource.com/platform/external/google-tv-pairing-protocol/+/refs/heads/master/proto/polo.proto)
- Netflix, YouTube, Prime Video, and Crunchyroll logos: [Simple Icons v11.15.0](https://github.com/simple-icons/simple-icons/tree/11.15.0/icons).
- Disney+ logo: [Disney-authored artwork on Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Disney_Plus_logo.svg).
- HBO Max logo: [official brand portal](https://brand.hbomax.com/logos).

Streaming marks belong to their respective owners. This personal project is not affiliated with those services, Apple, Google, or TCL. The Gradle wrapper is distributed by the Gradle project under its applicable license; see [Gradle licensing](https://github.com/gradle/gradle/blob/master/LICENSE).
