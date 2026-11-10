# Debloat profiles

One folder per supported TV, bundled into the app. `debloat.txt` and `tv.json` come unchanged from cleanyourtv's
`examples/<model>/` (MIT); `profile.json` adds what the app needs to run it without a computer:

- `match`: properties the TV reports over ADB (all keys must match one of the listed values).
- `stockLauncher`, `launcher`: what install disables once the new Home screen is up, and which key helpers it turns on
  (the same switches as upstream's `HOME_KEY_SERVICE` / `INPUT_KEY_SERVICE` / `RESTORE_KEY_SERVICES`).
- `theme`: the launcher's config.json for this TV; the app fills in `dock_apps` from what the user keeps.
  Everything that depends on the model lives here, never in app or launcher code: the remote's app buttons
  (`app_keys`), its Settings button (`settings_key_keycodes`), the Live TV app (`live_tv_package`), apps to hide
  (`hidden_apps`), and quirk switches such as `correct_prehandled_volume_keys` or `glow_snap`. The first four start
  empty for every model (`DebloatProfile.modelSpecificDefaults`), because the launcher's built-in defaults are
  upstream's author's TCL; leave one out and that model simply doesn't get it.
- `developmentOnly`: shown in debug builds only.

Phase 2 generates these for every model upstream supports.
