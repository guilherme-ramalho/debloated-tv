# TV launcher

The Home screen running on the TV (`com.gathin.tvhome`): [Gathin23/cleanyourtv](https://github.com/Gathin23/cleanyourtv) (MIT, see LICENSE) with this project's changes on top. Only `launcher/` and `tools/` are copied here; the rest of upstream (device lists, themes, docs) stays upstream.

- **Version numbers are ours.** The app offers "Update Home screen" when its launcher's `versionCode` is higher than
  the TV's (`docs/launcher-editor-contract.md`), so bump `versionCode` in `launcher/app/build.gradle` for every
  launcher change that ships, and on an upstream merge keep it above both sides (never take upstream's lower number).
  13 / `3.3.1` = app 1.1 (1.0 shipped 12 / `3.3`).
- First base: `8ae8df83` (main, 31 October 2026), merged with the changes below in `5149f48`.
- **Upstream base now: `6e8615eb`** (main, 2 November 2026, Launcher 3.3). From `8ae8df83`: 3.3's tile menu on by
  default, `glow_snap`, `open_on_start_on_wake`, the `library` key action, the ColorOS TV `MODERN_HOME` category, the
  HOME picker backdrop, the cinematic "Last opened" refresh, the glass highlight fix after a cold start, the VPN pill on
  dark glass, `com.android.location.fused` in the core guard, and `build-and-install` taking WRITE_SECURE_SETTINGS
  back on an install without RESTORE_KEY_SERVICES (#2458). Two conflicts, both resolved by keeping both sides:
  `Config`'s constructor (3.3's `openOnStartOnWake`/`glowSnap` beside our volume fix and weather) and
  `MainActivity.onResume` (our weather start beside 3.3's hero refresh). The app mirrors #2458 in
  `LauncherInstaller` and writes `tile_menu: false` into every profile's theme (the phone arranges Home).
- **TCL volume fix**: `VolumeKeyCorrection` undoes the extra first step TCL AR11 applies before accessibility (theme `correct_prehandled_volume_keys`).
- **Top buttons at the header's top**: Inputs, network and Settings are pinned to the header's top, level with the greeting (`alignTop` on `leftBlock` instead of upstream's `alignBottom`), so the weather or date lines under the clock never push them down. Both `layout/` and `layout-iw/`; upstream's `alignDateBelowIconsWithClock` special case is gone (one rule for every header).
- **Date column on the greeting's line**: `leftBlock` is horizontal: the greeting over the clock, then the divider and the day/date/weather column, which starts level with the greeting so weather or lunar lines grow downward (upstream hung it from the clock's bottom). `date_below_clock` and the compact header still work (they find the column and clock row through their parents). `layout-iw/` (Hebrew) keeps upstream's arrangement.
- **Weather beside the clock**: `HomeWeather`, `HomeWeatherData` and the `weather_*` icons and strings (theme `weather`), translated into every launcher language.
- **Phone TV Home editor**: `Editor*.java`, see `../docs/launcher-editor-contract.md`. Presets are drawn (`EditorBackground`); any wallpaper applied from the phone turns the app-colour ambient glow off and lightens the Cinema shelf (`cinematic_scrim` 55, `cinematic_art` 20; `EditorLayout.wallpaperShows`) so it is actually seen.
- **Keep watching for the phone** (14; 15 keeps finished and older shows): `KeepWatching` reads Android's Continue watching list when the phone asks (`READ_TV_LISTINGS` in the manifest, granted by the phone); editor requests `keepWatching`, `resumeWatching`, `hideWatching`. Nothing on Home's screen changes.
- `MainActivity` / `WallpaperPlayer`: rebuild Home after a phone apply, and release the wallpaper bitmap under memory pressure while Home is in the background.

## Updating from upstream

Merge in a clone of cleanyourtv (branch `debloated-tv`), then copy `launcher/` and `tools/` back here:

```bash
git -C ../cleanyourtv archive debloated-tv launcher tools LICENSE | tar -x -C tv-launcher
```

## Build and install

From the project folder: `./update-tv-home-editor.sh tv` (tests, then installs over network debugging).

## Left upstream for now (in `../../cleanyourtv` and on GitHub)

- `examples/`: per-model debloat lists. Bring in when building the phone-only guided debloat (tested profiles).
- `docs/devices/tcl-*`: TCL device notes. Bring in alongside `examples/`.
- `addons/sleep-timer`: candidate for the sleep timer the editor currently refuses; check its memory and CPU cost first.
- `themes/`, `tests/`, the rest of `docs/` and `addons/`: not needed to build or run this TV.
