# Purio TV

**Make your Android TV fast again, from your iPhone.** Purio TV switches off the apps your TV doesn't need, puts a
clean Home screen with no ads on it, and is a full remote. Free, no ads, no account, no tracking.

[**Download on the App Store**](https://apps.apple.com/app/apple-store/id6828204875?pt=129696627&ct=github-readme&mt=8)
· iPhone, iOS 17 or later · English, Português, Español, Français, Deutsch, Italiano

## What it does

**Clean up the TV (TV setup)**
- Finds your model among 450+ Android TV and Google TV lists made by the
  [cleanyourtv](https://github.com/Gathin23/cleanyourtv) community, and switches off the preinstalled apps that
  slow the TV down. Nothing is uninstalled, and you choose what stays.
- Installs Purio Home, a fast Home screen with no ads or sponsored rows: your apps in a dock, your wallpaper,
  weather, a sleep timer.
- Saves a recovery record first, so **Undo** puts the TV back as it was.
- No computer needed. You turn on the TV's network debugging for a few minutes; the app walks you through it and
  helps you turn it off again at the end.

**Remote**
- D-pad with swipes, volume, play/pause, power, rewind, fast-forward, subtitles and TV settings.
- Type on the TV with the iPhone keyboard; your favourite apps one tap away.
- Home Screen, Lock Screen and Control Center widgets, quick actions and Siri.
- Wakes the TV from standby on supported models.

**Show on TV**
- Browse your iPhone's photos and videos and open them on the TV through its Chromecast built in. Swipe and the TV
  follows; heavy 4K and HDR videos are converted on the fly so they play smoothly.

**Arrange the TV's Home screen from the phone**
- Dock, app order, hidden apps, wallpaper, look and weather, edited on the iPhone and applied in one tap.

## Coming next

On the development branch, not yet in the App Store:
- The Connect screen tells you what kind of TV it found.
- A remote for Roku, LG (webOS) and Samsung (Tizen) TVs, straight from the phone.
- **Ask Purio**, an optional on-device assistant on iPhones with Apple Intelligence ("open Netflix", "volume up 5").
  It runs on the iPhone; nothing goes to a server.
- **Keep watching**: the shows you left halfway, from the TV's own Continue watching list; tap to resume on the TV.
- The Android app (in `android/`), not yet on Google Play.

## Which TVs

- **Remote:** Android TV and Google TV sets and boxes with Google's TV remote service (most of them).
- **TV setup and Purio Home:** Android TV and Google TV with Android 8 or later. The app picks the list for your
  model; models without a tested list get the closest one only after you confirm.
- **Show on TV:** TVs with Chromecast built in.

Tested on real TVs and on the Android TV emulator before each release. Reports from other models are welcome:
open an issue with your TV's brand and model.

## Privacy

Purio TV talks only to your TV, on your home network. It has no account, no ads, no analytics and no servers;
settings, pairing keys and recovery records stay on your iPhone. Details in [PRIVACY.md](PRIVACY.md).

## Safety

Every change to a TV goes through guarded steps: only apps on a tested list are switched off (never system
essentials), a recovery record is saved before anything changes, and every change can be undone from the app. The
Home screen is switched only after the new one has started, and the old one comes back if anything goes wrong.

## Support

Questions and TV reports: [SUPPORT.md](SUPPORT.md). Security issues: [SECURITY.md](SECURITY.md).

---

## For developers

| Folder | What's in it |
| --- | --- |
| `ios/` | The iPhone app (SwiftUI, `TVRemote.xcodeproj`) and a Swift package with the core and its tests |
| `android/` | The Android app (Kotlin, Jetpack Compose) and its core |
| `tv-launcher/` | Purio Home, the TV Home screen (a fork of cleanyourtv's launcher, MIT; merges in `UPSTREAM.md`) |
| `scripts/` | Emulator, end-to-end tests, launcher bundling, release and store screenshots |
| `docs/` | Design decisions, test cases (`TESTING.md`), protocols and the phone ↔ TV Home editor contract |

**Build**
1. `scripts/bundle-launcher.sh` builds Purio Home and bundles it into the iPhone app (Java 17, Android SDK).
2. Open `ios/TVRemote.xcodeproj`, pick the **Debloated TV Dev** scheme, set your signing team, and run on an iPhone.
   A launcher you install is tied to the key that signed it; see [docs/launcher-signing.md](docs/launcher-signing.md).

**Test**
- iPhone core: `cd ios && swift test`
- Purio Home: `cd tv-launcher/launcher && ./gradlew testReleaseUnitTest`
- Android core: `cd android && ./gradlew :core:test`
- End to end against a disposable Android TV emulator: `scripts/e2e.sh` (see [docs/emulator.md](docs/emulator.md))

Test cases and their IDs are in [docs/TESTING.md](docs/TESTING.md).

## Credits

- [cleanyourtv](https://github.com/Gathin23/cleanyourtv) by Gathin (MIT): the per-model debloat lists and the
  launcher Purio Home is built on.
- [androidtvremote2](https://github.com/tronikos/androidtvremote2): the Android TV Remote v2 protocol reference.
- [couch-tv](https://github.com/Seagey/couch-tv) (MIT) and [aiowebostv](https://github.com/home-assistant-libs/aiowebostv)
  (Apache 2.0): references for the Roku, LG and Samsung remotes; see [docs/tv-brands.md](docs/tv-brands.md).
- Streaming logos from [Simple Icons](https://github.com/simple-icons/simple-icons); Disney+ and HBO Max marks from
  their owners' brand pages. Marks belong to their owners.

Purio TV is an independent project, not affiliated with Google, Apple, or any TV maker or streaming service. The
Android robot is reproduced or modified from work created and shared by Google and used according to the
[Creative Commons 3.0 Attribution License](https://creativecommons.org/licenses/by/3.0/).
