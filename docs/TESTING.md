# Testing plan

How to test Purio TV before and after a release. Anyone should be able to follow it.
**Keep it current:** every new feature or bug fix adds or updates its cases here, in the same pull request.

## How to use it

1. Run the automated tests (below). They must all pass.
2. Work through the manual cases for what changed, then the **release checklist** at the end for every release.
3. Note failures as GitHub issues with the case ID (e.g. `DBL-07 fails on Sony …`).

Each case has an ID, what to do, what should happen, and how it's covered: **Auto** names the automated test,
**Manual** needs a person. Cases marked ⚠ change the TV: run them on the emulator or a TV you can restore.

## What you need

| Setup | Used for |
|---|---|
| iPhone with the **Debloated TV Dev** build (Xcode) or the TestFlight build | everything on the phone |
| A real Android TV / Google TV on the same Wi-Fi, ideally a supported model | remote, editor, setup on real hardware |
| The Android TV emulator (`scripts/tv-emulator.sh`, see `docs/emulator.md`) | setup and undo without risk |
| An unsupported Android TV, or the emulator with its dev profile removed | "not supported" paths |
| A TV in standby with network standby on | wake |

### Resetting a real test TV

Between setup runs, put the TV back to stock from a computer with `TV_HOST=<tv ip> scripts/tv-reset.sh
--keep-disabled <apps that were off from the factory>`. It shows the plan, asks, switches every other disabled app back
on, makes the stock launcher Home, uninstalls the new Home screen, then checks the result. Development only: users
undo a setup in the app (UND cases).

## Automated tests

| Suite | Command | Covers |
|---|---|---|
| Core unit tests (Swift) | `cd ios && swift test` | protocols, ADB, debloat engine, launcher install, profiles, recovery records, setup state, preferences |
| Live ADB test | `scripts/tv-emulator.sh test` (emulator running) | real ADB handshake, approval (accepted by the script), shell, push |
| Launcher unit tests (Java) | `cd tv-launcher/launcher && ./gradlew testReleaseUnitTest` | the TV Home screen: config, keys, editor backend, weather |
| UI smoke tests (simulator) | Xcode › Debloated TV Dev › Test, or `xcodebuild test … -only-testing:TVRemoteUITests/TVRemoteUITests` | tabs, TV tab states, setup entry, settings, licenses |
| End-to-end (simulator + emulator) | `scripts/e2e.sh` (emulator created once; about 10 minutes) | pairing, remote, setup, Home install, editor, undo, debugging off: the cases marked **E2E** below |

The core and launcher suites run on every push and pull request (`.github/workflows/tests.yml`). The UI suite runs
there too once its Xcode target exists. **One-time setup of the UI test target:** in Xcode, File › New › Target ›
UI Testing Bundle, name it `TVRemoteUITests`, target the TVRemote app (the tests live in `ios/TVRemoteUITests/`,
which Xcode picks up), then enable it in the Debloated TV Dev scheme's Test action. Already done in this repo.

### End-to-end suite

`scripts/e2e.sh` runs the app in the iOS Simulator against the Android TV emulator through the real protocols:
pairing and remote (6467/6466), ADB (5555), the Home editor (9764). The emulator's ports are forwarded to this Mac
with `adb forward` (its own port redirection doesn't reach the remote service), and `adb tcpip 5555` gives the app
an ADB entrance of its own, so adb on the Mac keeps working during setup. A small helper
(`scripts/e2e-helper.py`) does the TV side over adb: it reads the pairing code off the emulator's screen
(`uiautomator dump`), accepts "Allow USB debugging?", reports which app is in front, presses Home, reads the
launcher's `config.json`, and drops the ADB link to stand in for a TV that went idle. The test itself is
`ios/TVRemoteUITests/TVRemoteEndToEndTests.swift`, with two scenarios, each on a freshly reset emulator and
simulator from one build (`--only main|community` runs one):

- **main** (`testPairSetUpEditUndoAndSecure`), in the order a user goes through it: pair › remote › setup with the
  emulator's tested profile and the Home install › the restart check › edit › undo › a second setup › turn
  debugging off.
- **community** (`testCommunityListSetupAndUndo`), a TV without a tested profile, like most: the list picker, a
  "closest" list's confirmation, a debloat-only list made for this model, apply with the restart, undo. Two
  development-only lists stand in for cleanyourtv's (`Resources/Profiles/dev-community-*`, loaded only with the
  `-e2eCommunity` launch switch, never in release builds).

Each case is an activity in the result bundle and a live line in the terminal (▶ start, ✓/✗ with its time, failures
as they happen, and the TV side's events: prompts approved, restarts, forwards restored). The test skips unless the
script sets `E2E_HELPER`, so Xcode and CI never need the emulator. TV discovery is off during the run
(`-e2eNoDiscovery`), so it never opens a connection to a real TV on the network.

The script resets the emulator to its `clean` snapshot before each scenario and, at the end (also after a failure
or Ctrl+C), stops everything it used: the emulator (through its console, as the run ends with debugging off) and
its leftover crash reporters, the simulator, the Simulator app when nothing else is open in it, the helper and any
interrupted `xcodebuild`; `--keep` leaves the emulator and simulator running. It reboots the guest when its clock is stale, builds the app
signed (an unsigned simulator build has no Keychain entitlement and can't create the pairing identity), and erases
its own simulator ("Debloated TV E2E") so the app starts unpaired. Where the emulator differs from a TV: wake and
standby don't exist, the TV is reached as 127.0.0.1, and after debugging is switched off the forwarded port still
accepts a connection on the Mac before closing it, so DBL-16b checks the TV itself (adb lost, or `adb_enabled` 0)
rather than the message. **On the `android-tv` API 31 image the remote's control port closes every connection**
(docs/emulator.md), so the suite runs the remote and editor cases (REM, SET-10, EDT) only when the control channel
comes up after pairing, and attaches "Remote control channel: not available" to the run otherwise; those cases
then stay on the real-TV checklist. `scripts/release.sh --e2e` runs the suite as part of a release.

## 1. Pairing and connection (CON)

| ID | What to do | Expected | How |
|---|---|---|---|
| CON-01 | Fresh install, open the app with the TV on | Remote tab shows "Connect your TV" and lists the TV by name within a few seconds | Manual + Auto `testFirstLaunchGuidesToConnect…` |
| CON-01b | Tap the TV in the list | Pairing sheet: "Enter the code on your TV", the TV's name, six boxes; a code appears on the TV | Manual + E2E (typed address) |
| CON-01c | TV off, or on another network, for 8 s | "No TV found yet" with the four checks, Open Settings, Search again | Manual |
| CON-01d | Deny Local Network, open the app | Checklist shows at once; Open Settings goes to the app's page | Manual |
| CON-01e | "My TV isn't listed", type `192,168,0,13` | Becomes `192.168.0.13`, "Looks right", Connect enabled; invalid input explains the format | Auto: `testFirstLaunchGuides…`, `testTypedAddressesAcceptRegionalKeyboards`; E2E |
| CON-01f | Connection chip: connected / connecting / standby / offline | TV name with green dot / spinner / "Standby · Wake" wakes / "Offline · Retry" retries, second tap opens details | Manual |
| CON-02 | Type the code shown on the TV with the on-screen keypad | Sheet opens full height; numbers 0–9 and letters A–F on one keypad, no system keyboard; delete removes the last character; pairs as soon as the sixth character is in; remote works | Manual + E2E |
| CON-03 | Type a wrong code | Error in the sheet; Start pairing again works | Manual + E2E |
| CON-04 | Pair with the TV off or a wrong IP | Within ~35 s the sheet says the TV didn't answer, with Try again | Manual |
| CON-05 | Settings › Connection address field on a phone set to Spain or Brazil | Dot key available; commas become dots | Manual |
| CON-06 | Enter `999.1.1.1` or text | "Enter the TV's IPv4 address…" | Manual |
| CON-07 | Cancel the pairing sheet | Closes; app returns to "Pair your TV to get started" | Manual |
| CON-08 | Close and reopen the app | Reconnects without a code (saved pairing) | Manual + E2E |
| CON-09 | Put the phone to sleep for a minute, wake it | Remote reconnects by itself (with Reconnect automatically on) | Manual |
| CON-10 | Turn Reconnect automatically off, background and return | Stays disconnected until Reconnect is tapped | Manual |
| CON-11 | Pair again from Settings › Connection | New code accepted; old pairing replaced only after success | Manual |
| CON-12 | Test connection in Diagnostics | "The paired TV responded. No command was sent." | Manual |
| CON-13 | Deny Local Network permission, try to connect | Clear error; works after allowing it in iOS Settings | Manual |
| CON-15 | Pair a second phone, or a second app on the same phone (Dev and TestFlight), with the same TV, then use both | Both keep working; neither is signed out (each install has its own pairing name and certificate subject). A pairing the TV dropped says "no longer accepts this phone’s pairing" instead of retrying forever | Manual + Auto `testEachInstallPairsUnderItsOwnStableName`, `testEachInstallsCertificateHasItsOwnSubject` |
| CON-14 | Pairing secret, certificates, protocol framing | Correct bytes, split/coalesced frames, size limits | Auto: `ProtocolTests` |
| CON-16 | The Keychain refuses the pairing identity (seen on an unsigned simulator build: OSStatus -34018), then Pair | "Pairing identity unavailable" with the reason; no endless "Asking … to show a code" | Manual (the E2E suite builds signed so pairing works) |
| CON-17 | Connect screen with an Android TV, an LG / Samsung / Roku TV and a Chromecast on the network | One row per TV (a TV that announces several services shows once). Android TV: "Android TV · Remote, setup and Show on TV" (without Show on TV when Cast doesn't answer). LG webOS / Samsung / Roku: "· Remote and apps · Beta" (1.3: never tried on a real TV of those brands yet), tappable (pairing as REM-21..24); their TV tab notice says the remote is in beta and links "Report a problem". Chromecast: "· Not supported yet", dimmed. Speakers, Apple TVs, Macs and Cast groups never show | Auto: `TVKindTests`, `TvKindTest` (rules, merging), `testFoundTVsSayWhatTheyAreAndOnlyAndroidTVsPair` (labels fit on SE / Pro Max); Manual on a real network |
| CON-18 | "My TV isn't listed", type the address of an LG / Samsung / Roku TV, then of a Chromecast, Connect | "Checking…" for at most ~1.5 s; the LG / Samsung / Roku goes to its own pairing (REM-21..24). A Chromecast: "That's a Chromecast. Purio can't control it yet." in the sheet, no pairing. An Android TV, or an address where nothing answers, goes on to pairing as before (CON-04) | Manual |
| CON-19 | Port checks: what's touched | Only while the Connect screen is open (or after Connect in the address sheet): one TCP connect to 6466, 8009, 8060, 3000/3001, 8001/8002 per TV, closed at once, no data. Never 5555 (ADB). No TV shows a prompt | Auto: `testKnockFindsOpenAndClosedPorts`, `knockFindsOpenAndClosedPorts`; Manual (watch the TV) |
| CON-20 | Android app: same list and address check as CON-17/18 (NSD resolves one service at a time; all rows fill in) | As on iPhone | Auto: `TvKindTest`; Manual on the A53 |

## 2. Remote (REM)

| ID | What to do | Expected | How |
|---|---|---|---|
| REM-01 | Tap each arrow and OK | One move / one select per tap | Manual (gesture logic: Auto `PreferencesTests.testPadTap…`); E2E taps the arrows and Back |
| REM-02 | Swipe across the pad in each direction | One move in that direction; no extra OK | Manual + Auto `testSwipeDoesNotAlsoTap…` |
| REM-03 | Hold an arrow | Repeats while held; stops on release, also when the app is backgrounded mid-hold | Manual + Auto `testPadHold…`, `testPadCancellation…` |
| REM-04 | Home, Back, Play/Pause, Mute | Each acts once on the TV | Manual + E2E (Home, Back) |
| REM-05 | Hold Volume up | Volume rises continuously, stops on release | Manual; E2E checks a tap changes the volume the TV reports |
| REM-06 | Power while on | TV goes to standby; status "Standby" | Manual |
| REM-07 | Power while in standby (network standby on) | "Waking TV…", TV turns on, or a clear error after the timeout | Manual + Auto `testWakeIntentExpiresAndCannotReplay` |
| REM-08 | Keyboard: type in a TV search field, pause, keep typing, delete some, clear it, press Return | Text appears on the TV as you type (once per pause, no Send button), matches the phone exactly (no doubled text), clearing empties the TV field; Hide text while typing hides it on the phone | Manual + Auto `testKeyboardUsesUTF16…` |
| REM-09 | Input button / Open TV input menu | TV's input switcher opens | Manual |
| REM-10 | Streaming shortcuts (Netflix, YouTube…) | The app opens on the TV; the header shows the app in front | Manual + Auto `testForegroundNames…`; E2E (YouTube) |
| REM-11 | Shortcut for an app not installed on the TV | Clear message; nothing else happens | Manual |
| REM-12 | Settings › Remote shortcuts: hide, reorder | Remote reflects the change | Manual |
| REM-13 | Touch feedback off | No haptics on presses | Manual |
| REM-14 | Header (1.1): connected, standby, offline, then tap the TV name and the app line | Power, then the TV name with a green dot and the app on screen below it, then Keyboard and Inputs. Standby shows "Standby · Wake" (tap wakes), offline "Offline · Retry" (first tap retries, second opens connection settings); the name and app line open connection settings. Nothing clipped on a 4.7-inch iPhone | Manual; E2E reads "On TV: YouTube" |
| REM-15 | Second row (1.1): Rewind and Fast-forward in Netflix and YouTube while playing; Subtitles in a show with subtitles; TV settings from Home and from inside an app | Skips back/forward once per tap; subtitles toggle or their menu opens where the app supports it; the TV's settings menu opens. Note on the TCL which ones the firmware ignores | Manual (TCL first) |
| REM-16 | Type on TV: type "test", pause, type "ing"; then delete two letters, pause, type "ed" | The TV field reads "testing", then "testied" ("testi" after the two deletes, plus "ed"): only the change is sent each pause, never the whole text again | Auto `testTypingSendsOnlyTheChange` + Manual (TCL; 9 Nov 2026: was "testtesting") |
| REM-17 | Mute icon (1.2): mute from the app, then unmute with the TV's own remote, then reconnect while muted | Sound on: crossed-out speaker ("Mute"). Muted: plain speaker ("Unmute") and "Muted" in the middle. The icon follows the TV's own mute changes and is right again after reconnecting. Play/pause keeps its combined icon (the remote protocol doesn't report playback) | Manual (iPhone + Android, TCL); iPhone automated against the TCL: `TCLChecks` (passed 15 Nov 2026) |
| REM-18 | Settings › Reverse swipe direction (1.2) on, then off | On: swipe left on the pad moves right, swipe up moves down; the highlight shows the direction sent; taps and holds on an arrow unchanged. Off: back to normal. Survives an app restart; settings saved by 1.1 still load | Auto `testReversedSwipesGoTheOtherWay` / `reversedSwipesGoTheOtherWay`; iPhone against the TCL: `TCLChecks` (keys read on the TV with getevent; passed 15 Nov 2026) + Manual |
| REM-19 | Type on TV (1.2): open it from the remote's keyboard button | The text field is focused and the phone's keyboard is up without another tap; switching "Hide text while typing" on and off keeps it focused (iPhone; build 21 lost the focus on the switch, fixed after it) | iPhone: `TCLChecks` (TCL); Manual (Android) |
| REM-20 | Remote app buttons with a TV Home dock of 3 apps (1.3) | The remote's first 3 app buttons are the dock's, in its order; the other 3 follow Settings › Remote shortcuts (Netflix, YouTube, Prime Video, Disney+, HBO Max, Crunchyroll by default), no repeats; without a TV Home, the list alone | Auto `testRemoteShortcutsFollowTheDockThenTheList` + Manual |
| REM-21 | Roku: pick it on Connect (Control by mobile apps › Network access: Enabled) | Connects with no prompt; arrows, OK, Back, Home, play, rewind/forward, volume (hold repeats), mute, * (gear) work; no Subtitles or Inputs buttons; power turns it off and on; app buttons open the Roku's channels by name; Type on TV types and deletes; "On TV:" shows the channel after Home/Back/opening one. With Network access Limited/Disabled: the remote says how to allow it | Auto: `testRokuConnectsWithoutAPromptAndSendsKeysAppsAndText`, `testARokuLimitingMobileAppsIsExplained`, UI `testRokuRemoteShowsOnlyTheKeysARokuHas`, Android `rokuConnectsWithoutAPromptAndSendsKeysAppsAndText`; Manual (testers) |
| REM-22 | LG webOS: pick it on Connect | The TV asks to accept the remote; the phone says "Allow Purio on your TV"; after Accept the remote works: all keys (arrows/OK/Back/Home over the pointer socket, holds repeat), volume shows the TV's level and mute state, power turns it off, apps by name, typing and deleting in a TV text field, "On TV:" follows the app. Reopen the app: no prompt. Decline on the TV: the phone explains (LG Connect Apps) | Auto: `testLGAsksToAcceptThenKeepsTheKeyAndSendsButtons`, `testLGThatSaysNoIsExplained`; Android `BrandRemoteTest` (same cases, own WebSocket client); **Manual on a real LG before release, both apps** |
| REM-23 | Samsung (2016+): pick it on Connect | The TV asks to Allow; after Allow the remote works: keys (holds as Press/Release), power off, Subtitles, Source, apps by name (REST), typing replaces the TV's field; no volume level shown (Samsung doesn't report it). Deny: the phone says where to allow it | Auto: `testSamsungAsksToAllowThenSendsKeysAndOpensAppsOverREST`, Android `samsungAsksToAllowThenSendsKeysAndOpensAppsOverRest`; Manual (testers) |
| REM-24 | Roku / LG / Samsung: widgets, quick actions, Siri (Android: widgets, tiles, quick actions) | Keys and app steps work like on Android TV; an input step says favourite inputs need Purio's TV Home; a TV not yet allowed says to open Purio and allow it; the TV tab says setup and Home are Android TV features; no TV setup offer after pairing | Manual |
| REM-25 | 1.3 remote: D-pad / Numbers, then the keys between the pills | The slim switch swaps the round pad (swipes still work) for 1–9, Delete, 0, OK and back; numbers reach the TV (Live TV channel, a PIN field). Volume pill (hold + / − repeats, "VOL 14"), channel pill (up / down change channel in Live TV or on a set-top box), and nine round keys between them: Back, Home, TV settings / Rewind, Play-pause, Fast-forward / Subtitles, Mute, Inputs. A key the TV lacks leaves its place empty; a Roku shows no Numbers switch (no number keys) | Auto: UI `testNumberPadAndChannelPill`, `testRokuRemoteShowsOnlyTheKeysARokuHas`; Core key-name tests (both apps); **Manual on the TCL (TestFlight): channel and number keys in Live TV** |
| REM-26 | The app row and All apps | Five rounded-square app buttons in each app's colour with its logo (the TV Home dock's apps first), then All apps (nine coloured squares): a list of every app on the TV A to Z (Purio's Home's list on Android TV; the remote's own until Home connects; the TV's own on Roku, LG, Samsung); tap opens it on the TV | Auto: UI `testAllAppsListsTheTVsApps`; Manual on the TCL |
| REM-27 | Layout on SE and Pro Max | Pro Max: header, switch, full-size pad, pills and keys, app row all on one screen; SE: the app row is a short scroll away. The header no longer holds Inputs | Auto: UI header tests on both simulators; Manual |
| AST-01 | Settings › Remote preferences on an iPhone with Apple Intelligence (iOS 26) | "Assistant" switch, off by default. On an iPhone without Apple Intelligence (or iOS < 26) the row isn't there. With Apple Intelligence off: switching it on says to turn it on in iOS Settings; while the model downloads, says the button comes when ready | Manual (his iPhone 17 Pro; an SE / iPhone 14 for the hidden case) |
| AST-02 | Switch it on, back to the remote | A sparkles button between Show on TV and Type on TV; everything fits on the SE (smaller buttons) and Pro Max; switch off: the button goes | Auto: UI `testHeaderFitsTheAssistantButton` (SE + Pro Max); Manual |
| AST-03 | Ask Purio: "Pause", "a bit quieter", "open Netflix", "what's on the TV?", "go down three times and select", "turn it off", "abre o YouTube" | Each does it on the TV (keys, apps by name, power) and answers in one short sentence in the language asked; ~2 s each. A key the TV lacks (Roku subtitles) is said, not pressed. TV not connected: says so | Probe on the Mac's model with stand-in tools (17 Nov: 10/10 after the tool descriptions fix); Manual on the TCL |
| AST-04 | "Open YouTube and search for lofi music" | Opens YouTube and types into the TV's focused field. If the app's search isn't open, the text may go nowhere (v1: no in-app navigation) | Manual |
| AST-05 | Off-topic ("write me a poem"), a language Apple Intelligence doesn't speak, a long chat | One-line refusal; "doesn't understand this language yet"; after a very long chat it starts fresh and asks to repeat. Nothing leaves the phone (no network use besides the TV) | Auto: `AssistantCommandsTests` (vocabulary); Manual |
| KWT-01 | Home 14 on the TV (installed or updated from the app), watch a bit of a Netflix / Prime Video / HBO Max show, press Home, open the Remote tab (1.3; before 1.3 the TV tab) | Under the app buttons, "Keep watching on <TV>": the show first, with its poster, progress bar and "S2 · E5 · 23 min left"; at most 10, newest first, one card per show, finished and older shows included (Home 15). YouTube may not appear (it keeps no Continue watching row on the TCL, 17 Nov) | Auto: launcher `KeepWatchingTest`, Core `KeepWatchingTests`; **Manual on the TCL** |
| KWT-02 | Tap a card, Resume on TV | The app opens on the TV at that episode (its own link); the sheet closes | Auto: UI `testKeepWatchingStripOpensResume` (sheet only); **Manual on the TCL** |
| KWT-03 | Remove from Keep watching; then watch that show again | It leaves the strip at once; it comes back after it's watched again | Auto: `KeepWatchingTest.atMostTenAndARemovedShowComesBackWhenWatchedAgain`; Manual |
| KWT-04 | Home 13 (older) or the permission missing | No strip; with a Home that has the feature but no permission, "Keep watching needs the latest Home screen. Update Home screen to turn it on." | Manual |
| KWT-05 | Cost and privacy | Home reads the list only when the phone asks: when the Remote tab shows and the TV is on Purio Home, again at most every 5 minutes when Home comes back (no polling, never while an app is in front); posters come from each app's own artwork link, 6 s at most; the list goes only to the phone | Review |
| KWT-06 | Keep watching › See all | A full-screen list of every show Home sent (up to 50, Home 16), newest first: poster with progress, title, app · episode · time left; tap one: Resume on TV / Remove (the list follows a removal). The strip itself shows the newest 10 | Auto: UI `testKeepWatchingSeeAllListsEveryShow`; Manual |
| KWT-07 | The TV leaves Purio Home (an app opens), comes back; Settings › "Keep watching on the remote" off, then on | The row shows only while the TV is on Purio Home and goes away when an app opens; with the setting off it never shows and the phone doesn't ask the TV; on again, it's back | Auto: UI `testKeepWatchingSettingHidesTheRow`; Manual on the TCL |
| KWT-08 | Home 17: TV tab › "Keep watching on Home" on, with shows in the TV's Continue watching list; press Home | Above the dock, "Keep watching" with up to four cards (poster, app, title, "S2 · E5 · 23 min left", progress); with more than four, the fourth is "See all · N shows". The focused app's big name no longer shows above the dock while the row is there; the glow still follows the app. Off: Home as before | Auto: launcher `KeepWatchingTest.rowShowsFourOrThreeAndSeeAll`, `minutesLeftAndProgress`; **Manual on the TCL (TestFlight)** |
| KWT-09 | On the row: Up from the dock, Left/Right, OK; hold OK on a card; See all | Up from the dock reaches the row, Up again the top buttons, Down the dock; OK opens the show in its app; holding OK asks "Remove <title>?" and the card goes (back when watched again); See all opens the full list (grid of up to 50, OK resumes, hold OK removes, Back returns to Home) | **Manual on the TCL (TestFlight)** |
| KWT-10 | Cost | Nothing runs while Home is hidden; the list is read when Home comes back to the front (one background query); posters load once and stay in a 6 MB memory cache, dropped when the TV runs short of memory; Home stays as fast to open with the row on | Review + Manual (Home opens without delay on the TCL) |

## 3. TV tab and setup entry (SET)

| ID | What to do | Expected | How |
|---|---|---|---|
| SET-01 | TV without the new Home screen, open TV tab | "Make your TV faster" card, "Check if my TV is supported", greyed preview | Auto: `TVRemoteUITests.testFreshTVLeadsWithSetup` |
| SET-02 | Start setup | Setup flow opens | Auto: same |
| SET-03 | After a setup checked a supported model | Model name with "Supported" badge | Auto: `testSupportedTVShowsItsModel`, `TVSetupStateTests` |
| SET-04 | After a setup found no tested list | "This TV isn't supported for setup yet", model details, share/request button, no Start setup | Auto: `testUnsupportedTVExplainsAndOffersARequest` |
| SET-05 | Share this model's details | Share sheet with model and Android version only, no IP or personal data | Manual + Auto `testModelRequestCarriesOnlyModelDetails…` |
| SET-06 | TV with the new Home screen; press Home on the TV | TV tab switches to the editor with the green "Purio TV" strip | Manual (state: Auto `TVSetupStateTests`); E2E |
| SET-07 | TV already has the new Home (e.g. app reinstalled), TV playing something: "Already set up? Check my TV" | TV goes to Home; tab switches to the editor | Manual |
| SET-08 | Same button on a TV with its original Home | "This TV still has its original Home screen…"; setup card stays | Manual |
| SET-08b | Delete and reinstall the app | TVs that had the new Home still show the editor (state kept in this iPhone's Keychain) | Manual |
| SET-08c | TV marked set up by a build older than the Keychain copy: open the new build once, then delete and reinstall | Editor still shows after the reinstall (the old state is copied to the Keychain at launch) | Manual |
| SET-08d | TV restored outside the app (computer restore, factory reset), then open the app with the stock Home on screen | The TV tab offers setup again instead of the editor | Auto: `testAStockLauncherInFrontMeansTheTVWasPutBack` |
| SET-09 | Strip › Manage | Run setup again, Undo TV setup | Auto: `testInstalledTVShowsTheEditorAndManage`; E2E |
| SET-10 | New pairing with a TV not showing our Home | One-time sheet "Your TV can be a lot faster"; Set up my TV opens setup | Auto: `testOfferSheetOpensSetupOnce`, `testOfferAppearsOnceAfterPairing`; E2E |
| SET-11 | New pairing while the TV shows our Home | No sheet | Auto: `testNoOfferWhenTheTVAlreadyShowsTheNewHome` |
| SET-12 | Not now on the sheet; pair again later | Sheet doesn't come back | Auto: `testOfferAppearsOnceAfterPairing`; E2E (after a relaunch) |
| SET-13 | Two TVs (different IPs) | Each keeps its own state | Auto: `testStatePersistsPerTVAndUndoResetsIt` |
| SET-14 | Settings › TV setup links | Both open | Auto: `testSettingsKeepsTVSetupAndLicenses` |
| SET-20 | Every cleanyourtv list bundled (`scripts/import-tv-lists.py`) loads; Home screen offered only where the list ships a launcher config, never on Fire TV or CVTE | Pass | Auto: `testEveryCommunityListLoads` |
| SET-21 | TCL Smart TV Pro, the maintainer's firmware (BeyondTV4, G03_4K_GB, AR11, SDK 30) | The tested `tcl-43c645` profile is used with no picker; another product (G03_4K_US) or firmware (AR09) gets the picker; its list leaves `com.tcl.usercenter` and `com.tcl.keyhelp` on | Auto: `testBundledProfilesLoadAndMatchTheirTVs`, `testMatcherPrefersTheTestedProfileThenTheModel` |
| SET-22 | A TV whose model has its own list (e.g. Acer R3) | That list first, marked "Made for this model" | Auto: `testMatcherFindsTheModelsOwnList` |
| SET-23 | A model with no list, same brand as others | Closest lists of its brand, marked "Made for another model"; review warns to check each app | Auto: `testMatcherOffersTheClosestListForAnUnknownModel`; Manual (warning text) |
| SET-24 | A TV no list resembles | "None of cleanyourtv's lists fits this TV"; nothing changed | Auto: `testMatcherOffersNothingForAnUnrelatedTV` |
| SET-25 | Setup on a non-TCL TV: list picker | Model and device shown; best 3 lists, "Show N more"; picking one goes to Choose what stays with the list's testers' notes and "About this list" | E2E (community) |
| SET-26 | Close the list picker, open the TV tab | Setup card (not "isn't supported") | Auto: `testInspectionNamesTheTVWithoutRepeatingTheBrand` |
| SET-27 | Choose Home with a list that has no Home screen rule (Fire TV, CVTE board, debloat-only, custom launcher build, special procedure, no launcher config) | "The TV keeps its own Home screen" with the reason; no toggle; Test step asks for "The Home button opens the TV's Home screen" | E2E (community: debloat only); Manual (the other reasons) |
| SET-28 | "Made for this model" only from the list's own names: a shared board name (BeyondTV4, R3) needs the product too; another list mentioned in a header claims nothing | Pass | Auto: `testModelClaimsComeFromTheListsOwnNames`, `testMatcherFindsTheModelsOwnList` |
| SET-29 | Pick a "closest" list (made for another model) | Confirmation "Use a list made for another model?"; Cancel keeps the picker; a "closest" list never disables a CVTE stock launcher (`com.cvte.tv.launcher*`) | E2E (community: the confirmation); Manual (CVTE launcher) |
| SET-30 | Importer: `scripts/import-tv-lists.py` after a cleanyourtv fetch | Lists byte-identical to upstream; stops while a list's theme needs a helper its install command doesn't turn on (settle in `scripts/tv-list-overrides.json`); keep-stock lists get `keepStockLauncher`, custom-build and special lists no Home | Manual (run it); Auto checks the output: `testEveryCommunityListLoads` |

## 4. Debloat setup (DBL) ⚠

Run on the emulator first (`share setup`, address `<Mac>.local:15555`), then on a real supported TV.

| ID | What to do | Expected | How |
|---|---|---|---|
| DBL-01 | Overview without ticking "I understand the risks" | Continue disabled | E2E |
| DBL-02 | Connect with network debugging off | Clear error, nothing changed | Manual |
| DBL-03 | Connect, then don't answer the TV's "Allow debugging?" for 2 min | Times out with a message; Connect again works | Manual |
| DBL-04 | Connect and allow | "Recognised <model>. Recovery record saved." | Manual + Auto `testLiveTVWhenConfigured`; E2E |
| DBL-05 | Address with a port (`host:15555`), `.local` names, spaces | Accepted; bad ones rejected | Auto: `testTVAddressParsing`; E2E connects with a port |
| DBL-06 | Unsupported model | "Not supported" screen; nothing changed; TV tab shows SET-04 | Manual |
| DBL-07 | Choose: keep some apps on | Kept apps aren't in the review | E2E (the kept app stays enabled on the TV) |
| DBL-08 | Review shows skipped apps with reasons (Wi-Fi owner, Home, input drivers, Settings) | Each skipped app explains why | Auto: `DebloatTests`, `DebloatEdgeTests` |
| DBL-09 | Core Android packages can never be chosen or disabled, including `location.fused` | Never listed, never disabled | Auto: `testCorePackagesAreNeverDisabled`, `testNoProfileCanDisableCore…` |
| DBL-10 | Google TV setup wizard, TV on a cable (no Wi-Fi saved by the wizard) | Disabled with no question; Chromecast note shown if casting stays on | Auto: `testSetupWizardFollowsTheWifiCheck` |
| DBL-10b | Setup wizard owns the TV's Wi-Fi (network joined during first setup) | Review asks for each network's password; Continue waits for it; apply saves it again first, the TV stays (or comes back) online, then the wizard is disabled. Wrong password: stops before anything else changes, with how to rejoin on the TV | Auto: `testSetupWizardFollowsTheWifiCheck`, `testWifiParsingAndTheResaveCommand`; Manual on a Wi-Fi TV |
| DBL-10c | Setup wizard kept (unreadable Wi-Fi, enterprise network, no connect-network) with the new Home chosen | Choose Home says the new Home can't take over and Apply is off until the Home screen is switched off | Auto: `testSetupWizardFollowsTheWifiCheck` (setupKeepsHome) |
| DBL-10d | The wizard owns a network the parser can't read (SSID printed as hex) | The wizard stays (upstream's raw `cname=` check) | Auto: `testSetupWizardFollowsTheWifiCheck` |
| DBL-10e | Wizard-owned Wi-Fi: password typed twice | Continue stays off until both match; warning that a wrong password takes the TV off Wi-Fi; "Safer: do it on the TV" + Review again re-runs the checks | Manual |
| DBL-11 | Apply | Progress per group; then "Disabled N apps"; apps refused by the TV listed | Manual + Auto `testApplyReadsTheTVBack`; E2E |
| DBL-11b | The TV answers nothing when read back after disabling | "couldn't be checked", not "all disabled" | Auto: `testApplyRefusesAnEmptyReadback` |
| DBL-12 | Unplug network mid-apply | Stops, says which group; nothing after it changed | Manual + Auto `testApplyStopsWhenTheTVStopsAnswering` |
| DBL-13 | Run setup twice | Recovery record keeps the state from before the first run; the second run connects without a prompt | Auto: `testRecordKeepsTheStateBeforeTheFirstRun…`; E2E (second run) |
| DBL-14 | Open debugging port warning (`ro.adb.secure=0`) | Note shown in review | Auto: `testOpenDebuggingPortIsCalledOut` |
| DBL-15 | Test step: tick every check | "Everything works" enabled only when all ticked | E2E |
| DBL-16 | Finish: turn debugging off, check | App confirms the port refuses connections | Manual |
| DBL-16b | Finish: "Turn off network debugging now", also after leaving the TV idle on the test step for 10 min | Reconnects if needed without a prompt, switches debugging off, then shows "Debugging is off". On a TV that keeps the port open it says so | E2E (link dropped first; checks the TV's adb state) + Manual on a real TV |
| DBL-17 | Export recovery record | Share sheet with the JSON | Manual (E2E checks the button is there) |
| DBL-18 | End of apply | "The TV restarts once…" shown before Apply; TV syncs, restarts, the app reconnects (prompt if "Always allow" wasn't ticked), then the test step shows Home's state and any apps the firmware turned back on; a black Home (RecoveryActivity/FallbackHome) or the stock launcher taking Home back shows "Restore the TV now" | Auto: `testRestartCheckJudgesHomeAndReEnabledApps`; E2E (the helper restores the emulator's forwards after the reboot); Manual (real TV) |
| DBL-19 | The TV doesn't let the phone back in after the restart (network ADB closes at boot on some firmware) | Test step says it couldn't check and what to look at; nothing else fails | Manual |
| DBL-20 | "Choose what stays" footer with exactly 1 protected app or 1 already-off app (the emulator list has 1 already off) | Singular sentence ("1 listed app is already off or not installed"), in all six languages; other counts plural | Manual (emulator; iPhone + Android) |

## 5. New Home screen install (LCH) ⚠

| ID | What to do | Expected | How |
|---|---|---|---|
| LCH-01 | Install on a supported TV | New Home starts, then becomes Home; stock launcher disabled only after | Auto: `testInstallsStartsThenHandsHomeOver`; E2E; Manual on TV |
| LCH-02 | Press Home on the TV afterwards | New Home screen appears, also after a reboot | E2E (Home key); Manual (reboot) |
| LCH-03 | Handover fails (Home goes elsewhere) | Stock launcher put back, clear message | Auto: `testFailedHandoverPutsTheStockLauncherBack` |
| LCH-04 | Damaged upload | Nothing installed, file removed | Auto: `testDamagedUploadInstallsNothing` |
| LCH-05 | A differently signed build already on the TV | Explains uninstalling first; stock untouched | Auto: `testDifferentlySignedBuildIsExplained` |
| LCH-06 | Android older than 8.0 | Refused before any change | Auto: `testRefusesOldAndroid…` |
| LCH-07 | Setup wizard owns Home | Stops before any change | Auto: `testSetupWizardOwningHomeStops…` |
| LCH-08 | Home chooser with one stock launcher | Resolved to it | Auto: `testHomeChooserWithOneStockLauncher…` |
| LCH-09 | Remote's app buttons and Settings key (TCL: Netflix, YouTube, Prime, Settings), on Home and from inside another app (YouTube playing, press Netflix) | Open the right app/Settings once, from anywhere | Manual |
| LCH-10 | Volume tap on TCL | One step per tap (volume fix) | Manual |
| LCH-11 | Theme applied (dock from setup) | Dock shows the chosen apps | Manual + Auto `testThemeGetsTheChosenDock`, `testThemeMustBeAJSONObject…`; E2E reads the TV's config |
| LCH-12 | TV inputs and Live TV from the new Home | Inputs open, picture shows | Manual |
| LCH-13 | Install over a launcher that holds WRITE_SECURE_SETTINGS, with a profile that doesn't ask for it | The permission is taken back (`dumpsys package com.gathin.tvhome` shows granted=false); if the TV doesn't confirm, setup says so | Auto: `testSecureSettingsFollowTheProfile`; Manual on TV |
| LCH-14 | Launcher 3.3 on the TV: hold OK on a tile; move the focus across dock apps of different colours | App info opens (tile menu off, the phone arranges Home); on TCL the glow changes colour at once, without a fade | Manual + Auto `testThemeGetsTheChosenDock` |
| LCH-15 | Update Home screen (1.1): TV with the 1.0 launcher (versionCode 12) and TV Home connected; TV tab › Home screen update › turn on network debugging › Update | Card shows only when the app's launcher is newer than the TV's (never for the same or an older one, never before TV Home answers); the update installs with `pm install -r` and no theme, so dock, order, hidden apps, wallpaper, weather and look stay; remote helpers stay on; the TV reports the new version afterwards and the card goes away once TV Home reconnects; a TV already on that version installs nothing; then debugging is turned off | Auto: `testHomeUpdateIsOfferedOnlyForANewerBundledLauncher`, `testInstalledVersionComesFromDumpsys`, `testUpdateWithoutAThemeKeepsTheTVsLayout`; Manual on emulator, then TCL |
| LCH-16 | The TV has a newer launcher than the app carries (setup again or update) | Install refused with "newer Home screen… update Purio TV"; nothing else changed | Auto: `testNewerBuildOnTheTVIsExplained` |
| LCH-17 | Set up a model whose profile names no remote buttons, Settings key or Live TV app (the emulator profile) | config.json has empty `app_keys`, `settings_key_keycodes`, `hidden_apps` and `live_tv_package`: nothing from the launcher's built-in TCL defaults; a profile that names them keeps its own | Auto: `testOtherModelsDontInheritTheLaunchersTCLDefaults`, `testThemeGetsTheChosenDock`; E2E reads the TV's config |
| LCH-18 | Turn weather on and off from the phone (also with the date or lunar date lines) | The tops of Inputs, network and Settings and the day name line up with the top of the greeting ("Good evening"); date and weather run down beside the clock; nothing in the top bar moves. Also check `date_below_clock` and a header without greeting | Manual (TCL, 9 Nov 2026: pass) |
| LCH-19 | Install on a TV whose Home is a vendor launcher its list names (e.g. `com.xgimi.home`) | That launcher is disabled after the handover; an unnamed unknown Home still stops setup | Auto: `testListedVendorLauncherIsTreatedAsStock` |
| LCH-20 | Update Home screen from the TV tab on a TV set up with a community list; and after an Undo | Uses the list applied last in this TV's record (by `android_id`); after an Undo (stock Home again) it refuses with "nothing to update" and changes nothing; another phone gets "This phone didn't set up this TV's Home screen" | Manual |
| LCH-21 | Install with a list that keeps the stock launcher (`STOCK_LAUNCHER=none`) | Nothing disabled; the new Home started without claiming Home first, then made Home; if Home doesn't move, "The stock one was never turned off" | Auto: `testKeepStockLauncherDisablesNothing` |
| LCH-22 | Update Home screen interrupted: (a) switch to another tab mid-update and come back; (b) walk out of Wi-Fi range mid-install; (c) a TV that stops answering for 3 minutes | (a) the update carries on and the screen shows where it is, or done (the editor reconnects); (b) "Lost the connection to the TV…" within about 15 s (iPhone; Android after the 3-minute stall) instead of a frozen screen; (c) after 30 s "The TV is taking longer than usual", after 3 minutes the app reconnects and checks the TV. If the TV already has the new build, the last steps (Home, remote helpers, permissions) run again and it says done; else the error, and Try again checks first and finishes only what's missing (never installs twice once the TV has it) | Auto: `testFinishingACutOffUpdateRepeatsOnlyTheLastSteps` (both apps), `homeUpdateGuards`; Manual on TCL |

## 6. Undo (UND) ⚠

| ID | What to do | Expected | How |
|---|---|---|---|
| UND-01 | Undo TV setup with the saved record | Apps back on, stock Home back; "Restored and checked: … N apps stay disabled because they were already off before setup" | E2E + Manual on a real TV |
| UND-02 | Undo with a wrong address or debugging off | Clear error, nothing changed | E2E (closed port); Manual (debugging off) |
| UND-03 | After undo, TV tab | Setup card again | Auto: `testStatePersistsPerTVAndUndoResetsIt`; E2E |
| UND-04 | Records from upstream's recovery.py (and older scripts) | Restore the same way | Auto: `RecoveryCompatibilityTests` |
| UND-05 | A tampered record (shell text in names, Home or settings) | Ignored; valid entries still restore | Auto: `testRestoreNeverRuns…` |
| UND-06 | "Something's wrong: restore" during setup's test step | Restores immediately | Manual |
| UND-07 | Setup with list A, then again with list B (or setup again) | One record per TV; Undo returns to the state before A (stock Home, A's apps on), lists "A + B" | Auto: `testOneRecordPerTVAcrossLists` |
| UND-13 | After a setup, without restarting the app: Settings › Undo TV setup | The record from that setup is listed | E2E (community) |
| UND-08 | Records saved by builds before this one (one per list) | Folded into the TV's record at the next Apply, oldest state first; old files removed | Auto: `testOlderRecordsMergeOldestFirst` (merge); Manual (files) |
| UND-09 | Two TVs with the same dummy serial (0123456789ABCDEF) | Separate records (by `android_id`) | Auto: `testIdentityIgnoresDummySerials` |
| UND-10 | Restore a record on another TV | Refused before any command: "belongs to another TV" | Auto: `testRestoreRefusesAnotherTV` |
| UND-11 | Restore where an app doesn't come back or Home lands elsewhere | Says which apps and where Home is; TV tab not reset | Auto: `testRestoreChecksItsResult` |
| UND-12 | Restore after a setup that turned on HomeKeyService | Accessibility settings back to before setup, WRITE_SECURE_SETTINGS revoked; remote buttons go to the stock Home | Auto: `testRestorePutsTheHelpersBack`; Manual (real remote) |

## 7. TV Home editor (EDT)

| ID | What to do | Expected | How |
|---|---|---|---|
| EDT-01 | Open TV tab while Home is on the TV | Connects by itself, "Connected to TV Home" | E2E + Manual |
| EDT-02 | Open TV tab while a video plays | Asks first ("Connect now"); doesn't interrupt until tapped | E2E (YouTube in front) + Manual |
| EDT-03 | Switch tabs and back, background the app and return | Reconnects without Retry | E2E (background and return) + Manual |
| EDT-04 | Phone asleep for minutes, then edit | Reconnects (freshens the remote first) | Manual |
| EDT-05 | Dock icons 1–7, Apps & order (reorder, hide), wallpaper preset or photo | Each change reaches the TV by itself within about a second, with no Apply button; fast taps on the dock stepper become one update; reordering doesn't resend the photo | Manual + Auto `PreferencesTests`; E2E hides an app and reads the TV's config |
| EDT-06 | Wallpaper presets and a photo; Adjust photo framing | TV shows it as framed, without colour tint | Manual |
| EDT-07 | Very large photo (48 MP) | Downscaled; applies quickly | Manual |
| EDT-08 | Load current TV layout | Replaces the draft after a backup | E2E + Manual |
| EDT-09 | Profiles: create, switch, apply | Each keeps its own layout; switching (or restoring a backup) shows Apply to TV instead of changing the TV by itself | Manual + Auto `testDefaultPreferencesRoundTrip…`; E2E |
| EDT-10 | Uninstall from TV (non-system app) | TV asks to confirm ("Continue on TV"); system apps can't be uninstalled | Manual |
| EDT-11 | Editor protocol: wrong key, replayed or altered frames | Rejected | Auto: `EditorCipherTests` |
| EDT-12 | Weather on the TV in another TV language | Translated, correct city | Manual |
| EDT-13 | Editor link is not BROWSABLE: open the TV tab on the emulator and on a real TV | Connects as before (the TV Remote service starts the link without BROWSABLE) | E2E (emulator) + Manual on a real TV |

## 8. Actions, Siri and widgets (ACT)

| ID | What to do | Expected | How |
|---|---|---|---|
| ACT-01 | Create a quick action with several steps, Run | Steps run in order; progress shown; Cancel stops | Manual |
| ACT-02 | Invalid steps (empty, after Turn off TV) | Rejected with a message | Auto: `testQuickActionsRejectInvalidSteps…` |
| ACT-03 | Delete an action | Gone from the list and from Shortcuts | Manual |
| ACT-04 | Sleep timer (1.1, TV-owned): 1 min, 30 min, custom, cancel; disconnect the phone after setting it | The TV confirms the time; it goes to standby at the time with the phone away; Cancel clears it. Turning the TV off and on again drops it after a reboot only. With the remote-key helper off the TV refuses with a clear message | Manual (TCL first) + Auto `SleepTimerTest` |
| HOM-W1 | Weather on TV (1.1): TV tab › Weather on TV on, with TV Home in front | Home redraws with the weather by the clock within a minute; the row says "From the TV · <town>" (or "Location from the TV" until the TV names it); off removes it | Manual (TCL first) + Auto `TvLocationTest` |
| HOM-W2 | Weather on a TV that has no location yet (fresh TV, or location off in Android settings) | No weather line and no "Loading…" on Home; it appears on its own once the TV knows where it is | Manual |
| HOM-W3 | Older launcher (1.0) on the TV | No Weather row in the TV tab | Manual |
| HOM-L1 | Look (1.1): TV tab › Look › Calm, Glass, Gallery, then Cinema | Home redraws within seconds each time and matches the preset boards; apps, order and wallpaper unchanged; Cinema brings back today's Home exactly | Manual (TCL first) + Auto `HomeLooksTest` |
| HOM-L2 | Pick Calm, then apply a layout change (dock icons) from the phone | The look stays Calm after the layout applies | Manual |
| HOM-L3 | Cinema look, Netflix in focus: pick Aurora, then Dusk, then a photo on the phone | Each wallpaper is clearly visible behind Home; no red tint from the focused app; clock, app name and dock stay readable | Manual (TCL, 9 Nov 2026: pass) + Auto `aPhoneWallpaperIsSeenInEveryLook` |
| ACT-05 | Favorite inputs: add, rename, assign HDMI | Opens the right input | Manual |
| ACT-06 | Siri in each language: "Open Netflix with Purio TV" (en), "Abra a Netflix na minha TV" (pt-BR), "Abre Netflix en mi tele" (es), "Ouvre Netflix sur ma télé" (fr), "Apri Netflix sulla mia TV" (it), "Öffne Netflix mit Purio TV" (de); also "Ligue a minha TV" | Netflix opens on the TV; the alternative names (Purio, Purio Remote, My TV; Minha TV, Purio Controle; Mi tele, Mi televisor; Ma télé, Ma TV; Mia TV, Purio Telecomando; Mein Fernseher, Purio Fernbedienung) work too. Test on the TestFlight build alone: a Dev build on the same phone answers to the same names | Manual |
| ACT-07 | Shortcuts app: Control TV, Run TV Quick Action | Work without opening the app | Manual |
| ACT-08 | Home Screen widget, four chosen controls | Each control acts on the TV; no background polling | Manual |
| ACT-08b | TV controls widget (1.1, small 2×2 and medium one row): each of its four actions with the app closed and with the phone locked | Each tap acts once on the TV about 1.5–2 s later (it connects per tap, so it's for one-off actions; the D-pad widget was dropped for being too slow to navigate with); the app stays closed | Manual (TCL) |
| ACT-08c | TV action control (1.0, unchanged; iOS 18+) in Control Center and, if added, a Lock Screen corner: Wake, then TV power (on or off) | Runs without opening the app. In a Lock Screen corner it needs a press-and-hold (a tap does nothing, by iOS design). 1.1 adds no Lock Screen widget: one below the clock only opens the app on iPhone | Manual (TCL; hold verified 9 Nov 2026) |
| ACT-08d | Quick action widget (1.1, Home Screen small): choose Movie night, tap Run; then rename the action in the app | The action runs on the TV without opening the app; the widget shows the new name; with no actions it says how to create one | Manual (TCL) |
| ACT-08e | Power on the TV controls widget with the TV in standby, then with it on | From standby the TV wakes (a moment after the tap, like Wake); when on it goes to standby. The app doesn't open | Manual (TCL; 9 Nov 2026: pass) |
| ACT-09 | Control Center control (iOS 18+) | Sends its action | Manual |

## 9. Backups and settings (BAK)

| ID | What to do | Expected | How |
|---|---|---|---|
| BAK-01 | Create backup, Export, Import on another phone | Layout and wallpaper restored as a draft; no pairing keys inside | Manual + Auto `testBackupsRejectMissingPhoto…` |
| BAK-02 | Import a backup from a future version or with a missing photo | Rejected with a message | Auto: same |
| BAK-03 | Credits & licenses | Android robot credit and the cleanyourtv MIT license | Auto: `testSettingsKeepsTVSetupAndLicenses` |

## 10. Profiles for TV models (PRO)

| ID | What to do | Expected | How |
|---|---|---|---|
| PRO-01 | Every bundled profile loads and its id matches its folder | Pass | Auto: `testEveryProfileFolderLoads` |
| PRO-02 | No profile lists core packages or our own Home | Pass | Auto: `testNoProfileCanDisableCoreOrTheNewHome` |
| PRO-03 | Match rules are specific and don't overlap | Pass | Auto: `testManifestsAreComplete`, `testNoTwoProfilesClaimTheSameTV` |
| PRO-04 | Release builds don't show development profiles | Pass | Auto: `testReleaseBuildsHideDevelopmentProfiles` |
| PRO-05 | A new profile: setup on the real TV model, then undo | Everything in sections 4–6 passes on that TV | Manual |

## 11. Show on TV (CST, 1.3)

Photos and videos from the phone's library on the TV, through the TV's built-in Cast player (`docs/cast.md`).
The `android-tv` emulator image has no Cast player, so the end-to-end suite doesn't cover it: real TV only.

| ID | What to do | Expected | How |
|---|---|---|---|
| CST-01 | Remote header on a 4.7-inch iPhone SE and on a Pro Max | Show on TV, Type on TV and Inputs all on screen; the TV's name keeps its room (smaller round buttons on narrow phones) | Auto `testHeaderFitsShowOnTV` (UI, run on both sizes) |
| CST-02 | Media formats on the TV's player | JPEG shown (HEIC refused, so photos are converted); iPhone .mov in H.264, HEVC and 10-bit HDR play as is; a portrait video plays upright; HDR colours look right | Auto `testPhotoBecomesAnUprightJPEGAtMost4KWithoutLocation`; TCL 15 Nov 2026 (formats); Manual: portrait and HDR look on the TV |
| CST-03 | Swipe quickly through 20 photos, stop on one | The TV shows only the photo you stopped on, about a third of a second after you stop | Auto `testFastSwipesSendOnlyThePhotoYouStopOn` + Manual (TCL) |
| CST-04 | Open Show on TV, allow access, tap a photo with the TV unreachable | Library grid, newest at the bottom; the photo opens full screen at once; "Opening on …" banner; then "Couldn't reach the TV…" | Auto `testShowOnTVOpensAPhotoFullScreen` (UI; on GitHub CI it skips after the library opens, whose simulator shows no photos) |
| CST-05 | First photo on a Cast TV, then swipe on | Photo full screen on the phone at once; on the TV after the player opens (about 10 s the first time); then within a second per photo; pill says "On TV" | Auto `testLiveShowsAPhotoOnTheTVAndStops` (`CAST_TEST_HOST`) + Manual (TCL) |
| CST-06 | A video: play, pause, ±10 s, drag the position, TV volume | The TV plays it; the phone shows the still and the controls; the phone doesn't lock while it plays and may lock after | Manual (TCL) |
| CST-07 | Slideshow from an open photo, and from Select (3 photos) | The next photo every 5 s, videos skipped, stops at the end; Stop slideshow stops it | Manual |
| CST-08 | Tap "On TV" (pause), browse, tap again | Nothing reaches the TV while paused; resuming sends the open photo | Manual |
| CST-09 | Stop on TV; then press Home on the TV's remote while a photo is showing; then leave the library | Stop on TV: the TV returns to Home. Home on the TV: the pill goes back to the TV's name and the next photo opens the player again. Leaving the library closes everything | Auto `testStopClosesThePlayer`, `testPlayerClosedOnTheTVIsReportedAndTheNextLoadRelaunches` + Manual |
| CST-10 | Limited photo access, and access denied | Limited: only the chosen photos and "Choose more…". Denied: the explanation and Open Settings | Manual |
| CST-11 | A photo or video kept only in iCloud | "Downloading from iCloud… n%" then it shows | Manual |
| CST-12 | A TV without Chromecast built in | "This TV can't show photos from Purio…" | Auto `testConnectionFailuresAreExplained` |
| CST-13 | Memory: open the library, scroll through hundreds of photos, view 20 full screen, leave | Xcode's memory gauge stays under about 100 MB in the library and returns close to where it was after leaving | Manual (Xcode debug gauge) |
| CST-14 | Wire format and server | Frames, the session steps, byte ranges, only shared paths served, the TV's subnet picked | Auto `CastTests` |
| CST-15 | A 4K 60 fps HDR iPhone video, a 4K 30 fps one, a 1080p one | 4K plays smoothly after 2–4 s (converted to 1080p while it plays, normal colours); 1080p up to 20 Mbit/s goes as is; the log says which | Auto `VideoStreamTests` + Manual (TCL) |
| CST-16 | In a converted video: drag the position far ahead, then back to the start | Plays from there within a few seconds (conversion restarts there); back works too | Auto `testJumpAheadConvertsFromThere` + Manual |
| CST-17 | A video finishes on the TV; switch to another video before one starts | No "couldn't play" message (a LOAD_FAILED for a finished or replaced load is ignored) | Auto `testFailureOfAReplacedLoadIsIgnored` + Manual (TCL) |
| CST-18 | A portrait video | Upright at its own shape, black bars at the sides, never stretched (sent as a 16:9 frame) | Auto `testPortraitVideoIsCentredInA16By9Frame` + Manual (TCL) |
| CST-19 | Watch the position while a video plays, then drag it | The phone's bar and time follow the TV (moved on between the TV's reports, checked every 5 s); after a drag it doesn't jump back | Manual |
| CST-20 | A video playing on the TV, then paused | The phone shows the blurred still with rings going out from a TV and "Playing on …"; paused, it stops and says "Paused on …"; still with Reduce Motion | Manual |
| CST-21 | Swipe down on an open photo | It shrinks back into its grid cell (iOS 18+; a pull-down on iOS 17 and in a selection slideshow) | Manual |
| CST-22 | The On TV pill in the viewer | Flush right, mirroring the back button | Manual (screenshot) |
| CST-23 | Let a video play to the end, then tap Play again | The TV shows the video's first frame, not a black screen; the phone shows Play again, which plays it from the start (converted videos too) | Manual (TCL) |
| CST-24 | Scroll the library fast, up and down, through hundreds of items | No blank cells (a quick low-resolution picture first, then sharp); rows around the screen prepared ahead | Manual |
| CST-25 | Android: Show on TV on a phone against a Cast TV (CST-03 to CST-12, CST-17 to CST-24) | As on iPhone | **Not yet run** (built 16 Nov 2026, never on a phone) |
| CST-26 | Android: a 4K or 4K 60 fps video | Converted to 1080p while it plays, as on iPhone | **Missing**: Android sends heavy videos as they are (Media3 conversion planned: fragmented MP4 split into 6 s pieces) |
| CST-27 | Open Show on TV on a TV without Chromecast built in (or with it turned off in the TV's settings) | Within ~2 s a banner above the library: "This TV can't show photos from Purio. It needs Chromecast built in…" with Check again; the pill shows the warning. Turn Cast on, Check again: banner goes, photos go to the TV. A TV in standby or out of reach shows no banner (only a refusal counts) | Auto: `testARefusedPortIsToldApartFromASilentOne`, UI `testShowOnTVSaysAtOnceWhenTheTVHasNoChromecastBuiltIn`; Android: same (`castAnswerTellsRefusedFromSilent`); Manual |

## Release checklist

`scripts/release.sh` does the mechanical part: bundles the launcher, verifies its release key
(`scripts/launcher-key.sh verify`), runs the core, launcher and UI suites (`--e2e` adds the live ADB test and the
end-to-end suite), raises the build number and archives the **Debloated TV** scheme. It never uploads. Then:

- [ ] CI green on the release commit; `scripts/release.sh` finished without a warning.
- [ ] The launcher in the archive is the one the release notes describe (the script prints its version and signer).
- [ ] Build number committed.
- [ ] Release build: the emulator profile doesn't appear (PRO-04).
- [ ] `docs/manual-checklist.md` on the TestFlight build: at least the real-TV smoke (CON-01/02, REM-02/03/05/06,
      EDT-01/05, ACT-06, SET-06) and, if setup or launcher code changed, DBL-16b, LCH-09/10/12 and UND-01 on a real
      supported TV.
- [ ] No new background work on the TV or phone without a noted trade-off (performance principle).

## Updating this document

- New feature: add a section or rows with new IDs (never reuse an ID).
- Bug fix: add a row that reproduces the bug, ideally with an automated test named in the How column.
- Removed feature: delete its rows.
