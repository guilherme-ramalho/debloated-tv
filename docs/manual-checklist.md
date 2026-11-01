# Manual checklist

What still needs a person after the automated suites pass (`docs/TESTING.md` has every case in full; IDs below
point there). Run it on the TestFlight build, on a real iPhone, with a real TV. Tick, and note failures as issues
with the case ID.

The automation already covers: protocols, engines and profiles (`swift test`, gradle), the app's screens without a
TV (UI smoke tests), and pairing, remote keys, setup, Home install, the editor, undo and switching debugging off
against the Android TV emulator (`scripts/e2e.sh`). Everything here is what an emulator or a simulator can't do:
real hardware, standby, Wi-Fi, iOS system features and touch.

## Real TV (TCL 43C645 first; any supported model)

Before setup on the TCL: the launcher on it is debug-signed, so restore to stock and uninstall it first
(`pm uninstall com.gathin.tvhome`), then run setup fresh. Never on a TV without its owner's go-ahead.

- [ ] CON-01 / CON-01b / CON-01f — the TV is found by name on the network; pairing sheet; connection chip states
- [ ] CON-01c / CON-01d / CON-13 — TV off or other network: "No TV found yet"; Local Network denied: checklist, Open Settings
- [ ] CON-04 / CON-07 / CON-11 / CON-12 / CON-15 — TV off while pairing; cancel; pair again; Test connection; a second phone, and Dev + TestFlight on one phone
- [ ] CON-09 / CON-10 — phone asleep a minute: reconnects; Reconnect automatically off stays off
- [ ] REM-02 / REM-03 / REM-05 — swipes, held arrows (also backgrounded mid-hold), held Volume
- [ ] REM-06 / REM-07 — Power to standby; wake from standby with network standby on
- [ ] REM-08 / REM-09 / REM-11 / REM-12 — keyboard into a TV search field; Input button; missing app; shortcut order
- [ ] SET-07 / SET-08 / SET-08b / SET-08c — "Already set up? Check my TV" both ways; delete and reinstall keeps the editor
- [ ] DBL-02 / DBL-03 / DBL-06 — debugging off; "Allow debugging?" left unanswered 2 min; an unsupported model
- [ ] DBL-12 — network unplugged mid-apply: stops at the group, nothing after it changed, restore works
- [ ] DBL-16 / DBL-16b / DBL-17 — debugging off by hand and by the button (also after 10 min idle); export the record
- [ ] LCH-09 / LCH-10 / LCH-12 / LCH-14 — remote app buttons and Settings key; one volume step per tap; HDMI inputs and Live TV; hold OK opens App info, the glow changes colour at once
- [ ] UND-06 — "Something's wrong: restore" during the test step
- [ ] EDT-04 / EDT-06 / EDT-07 / EDT-12 — phone asleep minutes then edit; wallpaper presets and a 48 MP photo; weather in another language
- [ ] EDT-10 — uninstall a non-system app: the TV asks to confirm
- [ ] EDT-13 — the editor link without BROWSABLE: the TV tab connects on the real TV
- [ ] PRO-05 — a new TV model: setup, every section 4–6, undo

## Physical iPhone only

- [ ] ACT-06 — Siri: "Open Netflix with Debloated TV"
- [ ] ACT-07 — Shortcuts app: Control TV, Run TV Quick Action, without opening the app
- [ ] ACT-08 — Home Screen widget: four controls act on the TV, no background polling (Battery › app shows no background activity)
- [ ] ACT-09 — Control Center control (iOS 18+)
- [ ] ACT-01 / ACT-03 / ACT-04 / ACT-05 — quick action with several steps, cancel mid-way; delete; sleep timer; favorite inputs
- [ ] REM-13 — Touch feedback off: no haptics; on: a light tap per press (only a device has a Taptic Engine)
- [ ] CON-05 / CON-06 — the address field on a phone set to Spain or Brazil; bad addresses
- [ ] BAK-01 — export a backup, import it on another phone
- [ ] Languages — pt-BR, es, de, fr, it: the Remote, TV and Settings tabs read naturally

## Performance (the point of the app)

- [ ] The TV's Home opens within a second after setup; no stutter scrolling the launcher
- [ ] Nothing runs on the TV between editing sessions (`adb shell dumpsys activity services com.gathin.tvhome` shows no service outside a session)
- [ ] The iPhone's Battery screen shows no background activity for the app after a day of normal use
