# TV Remote — Quiet Signal

A personal native SwiftUI remote for Android TV, developed against a TCL Smart TV Pro running Android 11.

The iPhone connects directly to Android TV Remote Service v2 on the local network. Normal use requires no Mac server, ADB, Google account, cloud relay, or additional TV companion app.

## Development branch: mobile expansion

`feature/personalization-and-actions` contains the next mobile version (build 12). TV installation and live testing are deliberately deferred until the TV is available. The accepted baseline is build 11 on `main`.

| Area | Implemented on iPhone | TV requirements / remaining validation |
| --- | --- | --- |
| Remote | D-pad or swipe pad, keyboard, editable streaming count/order, press feedback | Live-test gestures and text fields; some TV apps reject remote text |
| TV Home | Offline drafts, 1–7 dock icons, reorder/hide, presets or photo wallpaper, profiles | Applying needs a future launcher editing adapter; it is not installed or included in this branch |
| Backup | Export/import versioned JSON with wallpaper, restore into a draft | Restore does not change the TV until Apply succeeds |
| Inputs | Named favorites and assignment UI; original TV input menu remains available | Sync real input IDs from the future adapter before assigning favorites |
| Actions | Editable command sequences and cancellation | Validate sequences against physical TV; commands are not transactional |
| Siri | Control TV and Run TV Quick Action intents; five suggested App Shortcuts | Requires pairing, local network, possibly unlock; physical Siri testing pending |
| Widgets | Configurable four-button Home Screen widget and iOS 18+ Control Center action | Uses the containing app’s background process and existing pairing; device validation pending |
| Sleep timer | Schedule/cancel UI and typed request | Requires a confirmed TV-owned timer in the future adapter; no phone background timer |
| Uninstall | Distinct destructive action with confirmation flow | Requires synced installed-app data and Android confirmation; system apps excluded |
| Settings | Haptics, automatic reconnect, paired connection diagnostic | Diagnostic performs a handshake without sending a control command |

Photo/video casting and an AirPlay receiver remain exploratory; the app does not advertise a working receiver. Automatic ad skipping is excluded. Title collection and its TV companion remain removed. The app indicator identifies the open streaming app, so the playback icon remains a neutral toggle rather than guessing playback state.

Home editing saves drafts atomically on the phone. Selecting a profile or wallpaper does not silently alter the TV. Photos are downsampled to at most 1920 pixels and compressed to at most 1 MB; the photo picker grants access only to selected images. Up to 20 recent backups are loaded into memory. Exported backups can contain the selected wallpaper but never pairing keys or viewing history.

The launcher editing contract is documented in [docs/launcher-editor-contract.md](docs/launcher-editor-contract.md). These mobile screens are ready for the next integration phase; their presence does not mean that TV-side features are operational yet.

## Existing controls

- D-pad with a 116-point OK target; Home, Back, playback toggle, inputs, power, volume, and mute.
- White SF Symbols, visible press feedback, and light haptics. D-pad and volume support holding and release on backgrounding.
- Two-column, logo-only streaming shortcuts: Netflix, YouTube, Prime Video, Disney+, HBO Max, and Crunchyroll.
- Current streaming app on the left of the header; connection dot, status text, and Settings on the right.
- Power and Input sit above the D-pad with separate touch areas and no overlap.
- Saved secure pairing and automatic reconnect.
- Standby wake on supported TCL firmware with the required TV standby settings.

## What’s on TV

The app name comes from the foreground package reported by the existing remote service. It updates over the same connection used for navigation and volume, with no extra TV process.

This identifies the open app, not whether a video is playing. The icon stays static and Play/Pause remains a neutral toggle. Titles, detailed HDMI device names, and playback-state collection are intentionally omitted. The entire app indicator is hidden on Home, inputs, unknown apps, standby, disconnection, or an empty app report. A streaming app being open does not prove active playback.

## Build and install

Requires Xcode with an iOS SDK and an iPhone running iOS 17 or newer.

1. Open `ios/TVRemote.xcodeproj` and select the TVRemote target.
2. Choose your signing Team for both TVRemote and TVRemoteWidgets, and matching available bundle identifiers (the extension must use the app identifier as its prefix). The repository contains no signing credentials or provisioning profiles.
3. Choose your iPhone and build/run. Wireless installation requires the phone to have been paired with Xcode first.
4. Open TV Remote, allow Local Network access, enter the TV’s IPv4 address in Connection settings, and tap Pair TV. Enter the six-character code displayed by the TV.

The shared Run scheme uses Release without debugger attachment. Personal Team development builds require periodic re-signing; the provisioning profile determines expiry. Ordinary app updates preserve the pairing identity in Keychain.

The TV must have Android TV Remote Service enabled. Control and pairing use TCP 6466 and 6467 respectively. Use the same trusted local network; do not forward these ports to the internet. Debugging is only needed for initial TV maintenance, not normal remote operation.

## Standby wake

On the tested TCL, Network Standby and Screenless Service were required to keep the built-in remote service reachable. Quick Start was already enabled.

Power refreshes the reported state, waits briefly for the TCL virtual input bridge, and sends one Power toggle only if the TV still reports standby. Wake expires after 30 seconds and cancels on backgrounding. A sent toggle is not automatically replayed. Overnight standby behavior and other TV models are not guaranteed.

## Tests

Run the shared core tests on macOS:

```sh
cd ios
swift test
```

Seventeen tests cover saved layouts, backup validation, command bounds, keyboard UTF-16 offsets, editor frame limits, fragmented/coalesced frames, malformed input, protobuf fields, certificate generation, pairing proofs, wake expiry/cancellation/single-use behavior, foreground app names, and explicit empty-app updates. The baseline controls and standby wake were tested on the physical TV and iPhone. New branch features still need device testing. The app and widget pass iOS SDK type checks. In the current restricted shell, the normal build reaches an actool/CoreSimulator runtime error; a separate local link verification reuses the unchanged baseline asset compilation. This is not a substitute for a normal signed device build.

## Privacy and security

Each iPhone generates its own RSA identity. Pairing proofs bind the TV code to both devices’ keys, and subsequent connections verify the saved TV certificate fingerprint. Private keys are stored in Keychain, not bundled in source.

There is no viewing-history storage, screenshot scanning, notification access, analytics, or separate metadata server. The Android playback companion has been removed. Commands are not queued while disconnected.

Do not commit private keys, pairing state, device logs, build products, or provisioning profiles. The included `.gitignore` excludes these common artifacts.

## References and assets

- [Android TV Remote v2 protocol reference](https://github.com/tronikos/androidtvremote2)
- [Google pairing schema](https://android.googlesource.com/platform/external/google-tv-pairing-protocol/+/refs/heads/master/proto/polo.proto)
- Netflix, YouTube, Prime Video, and Crunchyroll logos: [Simple Icons v11.15.0](https://github.com/simple-icons/simple-icons/tree/11.15.0/icons).
- Disney+ logo: [Disney-authored artwork on Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Disney_Plus_logo.svg).
- HBO Max logo: [official brand portal](https://brand.hbomax.com/logos).

Streaming marks belong to their respective owners. This personal project is not affiliated with those services, Apple, Google, or TCL. AirPlay, photo sharing, voice dictation, and automatic device discovery are not implemented. Keyboard input is implemented on this development branch, with TV compatibility testing pending.
