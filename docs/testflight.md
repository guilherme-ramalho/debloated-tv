# Manual TestFlight setup

This beta is Debloated TV, version 1.0, build 15. App Store Connect creation and upload are performed manually by the account owner. No public release is authorized or performed by this workflow.

## Create the app record

Use a paid Apple Developer Program membership; a free Xcode Personal Team does not support TestFlight. In the developer account, register/select the explicit iOS app identifier `com.guilhermeramalho.TVRemote` and the widget identifier `com.guilhermeramalho.TVRemote.Widgets` under the same paid team.

In App Store Connect → Apps → + → New App, choose iOS and enter:

- Name: Debloated TV
- Primary language: English
- Bundle ID: com.guilhermeramalho.TVRemote
- SKU: DEBLOATED-TV

Set the subtitle to `Android TV Remote & Control` in the localized app information. If the name or identifier is unavailable, resolve that before uploading; the bundle ID must match the signed build.

## Archive and upload

1. Open `ios/TVRemote.xcodeproj` from this repository, on branch `feature/personalization-and-actions`.
2. Select your paid development team for **both** TVRemote and TVRemoteWidgets, with automatic signing. Signing team values are intentionally blank in the repository. Keep the existing bundle IDs unless you intentionally want a separate app installation.
3. Verify version 1.0 and a build number not already uploaded (currently 15).
4. Choose Any iOS Device (arm64), then Product → Archive.
5. In Organizer, select the new archive and choose Distribute App → App Store Connect / TestFlight & App Store → Upload. Keep symbol uploads and automatic signing enabled.
6. Wait for Apple processing, then open the app’s TestFlight tab.
7. Complete export-compliance information accurately. This app uses encrypted TLS connections, certificate/key APIs and native cryptographic APIs; do not claim that it uses no encryption. Classification/documentation decisions remain with the account owner.
8. Add What to Test and an internal group, select the build, then install using TestFlight. Internal testers need appropriate App Store Connect access. Family/friends without that access use an external group, which requires beta review. An internal-only distribution archive cannot be used for external testing or release.

## Suggested beta notes

Native local-network remote for Android TV. Pair on the TV using its on-screen code. Check reconnect, navigation taps and holds, directional swipes without duplicate input, volume, mute, power/standby wake, input menu, six streaming shortcuts, keyboard, Siri and widgets on supported TVs.

TV layout drafts can be edited offline. Applying layouts, syncing inputs, uninstalling apps and scheduling TV-owned sleep timers require the future launcher editing adapter and are not operational in this beta. Photos/video receiving and automatic ad skipping are not included. Do not describe those as working release features.

Artwork: flat Android robot above the TV’s left corner, navy/cyan palette. Launch screen: background, icon, app name and subtitle only. Screenshots/marketing refinement waits until TV testing is finished.

## Apple references

- https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/
- https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds/
