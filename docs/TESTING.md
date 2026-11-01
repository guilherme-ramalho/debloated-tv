# Testing plan

How to test Debloated TV before and after a release. Anyone should be able to follow it.
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
`ios/TVRemoteUITests/TVRemoteEndToEndTests.swift`, one run in the order a user goes through it (pair › remote › setup
and Home install › edit › undo › a second setup › turn debugging off), each case an activity in the result bundle. It
skips unless the script sets `E2E_HELPER`, so Xcode and CI never need the emulator.

The script resets the emulator to its `clean` snapshot before and after (the run ends with debugging off on the
TV, so the reset goes through the emulator console), reboots the guest when its clock is stale, builds the app
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

## 3. TV tab and setup entry (SET)

| ID | What to do | Expected | How |
|---|---|---|---|
| SET-01 | TV without the new Home screen, open TV tab | "Make your TV faster" card, "Check if my TV is supported", greyed preview | Auto: `TVRemoteUITests.testFreshTVLeadsWithSetup` |
| SET-02 | Start setup | Setup flow opens | Auto: same |
| SET-03 | After a setup checked a supported model | Model name with "Supported" badge | Auto: `testSupportedTVShowsItsModel`, `TVSetupStateTests` |
| SET-04 | After a setup found no tested list | "This TV isn't supported for setup yet", model details, share/request button, no Start setup | Auto: `testUnsupportedTVExplainsAndOffersARequest` |
| SET-05 | Share this model's details | Share sheet with model and Android version only, no IP or personal data | Manual + Auto `testModelRequestCarriesOnlyModelDetails…` |
| SET-06 | TV with the new Home screen; press Home on the TV | TV tab switches to the editor with the green "Debloated" strip | Manual (state: Auto `TVSetupStateTests`); E2E |
| SET-07 | TV already has the new Home (e.g. app reinstalled), TV playing something: "Already set up? Check my TV" | TV goes to Home; tab switches to the editor | Manual |
| SET-08 | Same button on a TV with its original Home | "This TV still has its original Home screen…"; setup card stays | Manual |
| SET-08b | Delete and reinstall the app | TVs that had the new Home still show the editor (state kept in this iPhone's Keychain) | Manual |
| SET-08c | TV marked set up by a build older than the Keychain copy: open the new build once, then delete and reinstall | Editor still shows after the reinstall (the old state is copied to the Keychain at launch) | Manual |
| SET-09 | Strip › Manage | Run setup again, Undo TV setup | Auto: `testInstalledTVShowsTheEditorAndManage`; E2E |
| SET-10 | New pairing with a TV not showing our Home | One-time sheet "Your TV can be a lot faster"; Set up my TV opens setup | Auto: `testOfferSheetOpensSetupOnce`, `testOfferAppearsOnceAfterPairing`; E2E |
| SET-11 | New pairing while the TV shows our Home | No sheet | Auto: `testNoOfferWhenTheTVAlreadyShowsTheNewHome` |
| SET-12 | Not now on the sheet; pair again later | Sheet doesn't come back | Auto: `testOfferAppearsOnceAfterPairing`; E2E (after a relaunch) |
| SET-13 | Two TVs (different IPs) | Each keeps its own state | Auto: `testStatePersistsPerTVAndUndoResetsIt` |
| SET-14 | Settings › TV setup links | Both open | Auto: `testSettingsKeepsTVSetupAndLicenses` |

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
| DBL-10 | Setup wizard on a Wi-Fi TV | Skipped with the forget-and-rejoin explanation; Ethernet override allows it | Auto: `testSetupWizardNeedsTheWifiCheck…` |
| DBL-11 | Apply | Progress per group; then "Disabled N apps"; apps refused by the TV listed | Manual + Auto `testApplyReadsTheTVBack`; E2E |
| DBL-12 | Unplug network mid-apply | Stops, says which group; nothing after it changed | Manual + Auto `testApplyStopsWhenTheTVStopsAnswering` |
| DBL-13 | Run setup twice | Recovery record keeps the state from before the first run; the second run connects without a prompt | Auto: `testRecordKeepsTheStateBeforeTheFirstRun…`; E2E (second run) |
| DBL-14 | Open debugging port warning (`ro.adb.secure=0`) | Note shown in review | Auto: `testOpenDebuggingPortIsCalledOut` |
| DBL-15 | Test step: tick every check | "Everything works" enabled only when all ticked | E2E |
| DBL-16 | Finish: turn debugging off, check | App confirms the port refuses connections | Manual |
| DBL-16b | Finish: "Turn off network debugging now", also after leaving the TV idle on the test step for 10 min | Reconnects if needed without a prompt, switches debugging off, then shows "Debugging is off". On a TV that keeps the port open it says so | E2E (link dropped first; checks the TV's adb state) + Manual on a real TV |
| DBL-17 | Export recovery record | Share sheet with the JSON | Manual (E2E checks the button is there) |

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
| LCH-09 | Remote's app buttons and Settings key (TCL: Netflix, YouTube, Prime, Settings) | Open the right app/Settings | Manual |
| LCH-10 | Volume tap on TCL | One step per tap (volume fix) | Manual |
| LCH-11 | Theme applied (dock from setup) | Dock shows the chosen apps | Manual + Auto `testThemeGetsTheChosenDock`, `testThemeMustBeAJSONObject…`; E2E reads the TV's config |
| LCH-12 | TV inputs and Live TV from the new Home | Inputs open, picture shows | Manual |

## 6. Undo (UND) ⚠

| ID | What to do | Expected | How |
|---|---|---|---|
| UND-01 | Undo TV setup with the saved record | Apps back on, stock Home back; "N apps stay disabled because they were off before" | E2E + Manual on a real TV |
| UND-02 | Undo with a wrong address or debugging off | Clear error, nothing changed | E2E (closed port); Manual (debugging off) |
| UND-03 | After undo, TV tab | Setup card again | Auto: `testStatePersistsPerTVAndUndoResetsIt`; E2E |
| UND-04 | Records from upstream's recovery.py (and older scripts) | Restore the same way | Auto: `RecoveryCompatibilityTests` |
| UND-05 | A tampered record (shell text in names, Home or settings) | Ignored; valid entries still restore | Auto: `testRestoreNeverRuns…` |
| UND-06 | "Something's wrong: restore" during setup's test step | Restores immediately | Manual |

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
| ACT-04 | Sleep timer: 30 min, custom, cancel | TV turns off at the time; cancel works | Manual |
| ACT-05 | Favorite inputs: add, rename, assign HDMI | Opens the right input | Manual |
| ACT-06 | Siri: "Open Netflix with Debloated TV" | Netflix opens on the TV | Manual |
| ACT-07 | Shortcuts app: Control TV, Run TV Quick Action | Work without opening the app | Manual |
| ACT-08 | Home Screen widget, four chosen controls | Each control acts on the TV; no background polling | Manual |
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
