# Design decisions

Why the app and launcher are built the way they are. Add an entry when a decision changes.

## Performance first

The point of debloating is a TV that feels fast. Anything with a runtime cost on the TV or the phone is weighed
before it ships, and the default is to leave it out:

- **No background companion on the TV.** The Home editor connects only while you edit; the remote talks to Google's
  built-in Android TV Remote Service. The launcher runs no extra service for the phone.
- **Wallpapers are processed on the phone**: framed and downscaled to the TV's resolution (1280×720 for the
  launcher), compressed (≤ 1 MB), so the TV doesn't decode or hold large images.
- **Playback-aware auto-connect**: the editor connects automatically only when nothing is playing; during playback
  it asks first, so it never interrupts video.
- Weather is opt-in (off until a city is set) because it means a periodic network request on the TV.

## Remote: Android TV Remote Service v2

The iPhone speaks the TV's own remote protocol (pairing on 6467, control on 6466, mutual TLS with a pairing code).
No ADB, no Mac, no cloud relay in normal use. ADB is only used for the one-off setup (below).

## Home editor protocol

`docs/launcher-editor-contract.md`. The phone opens the editor with a deep link sent over the remote connection
(`tvhome://phone-edit?k=…`) carrying a fresh key, so there is no second pairing. Traffic on TCP 9764 is
AES-256-GCM with HKDF-derived keys and counter nonces; the hello carries a key ID so a stale key is rejected
cleanly and the phone retries. The phone checks the remote link is fresh (recent inbound traffic) before sending.

## TV setup from the phone (no computer)

- **ADB from the iPhone**: a native ADB client (`Adb.swift`: CNXN/AUTH with RSA token signing, shell v1, sync push)
  over the TV's network debugging (port 5555). Wireless-debugging-only TVs (pairing code, TLS) aren't supported yet.
- **The upstream engine, ported, not reinvented**: cleanyourtv's tested per-model lists and its safety guards (core
  package rules, never-disable header, Wi-Fi owner check for the setup wizard, Home owner and launcher checks, TV
  input driver and Settings handler checks, read-back after disabling) are ported to Swift (`Debloat.swift`).
  The recovery record uses upstream's `recovery.py` v1 format, so records from either side are interchangeable.
- **Profiles = upstream data + a small manifest**: `debloat.txt` and `tv.json` stay byte-for-byte upstream (MIT);
  `profile.json` adds how to recognise the TV over ADB, the stock launcher, launcher options and a starting theme.
  Only models with a tested list are offered; unknown TVs get a clear "not supported yet", never a guess.
- **Apply in groups with checks in between**, stopping if the TV stops answering; the recovery record is saved
  before the first change and keeps the original state across retries.
- **Launcher install mirrors upstream's `build-and-install.sh`**: push and checksum, install, start it, and only then
  disable the stock launcher and hand Home over; if Home doesn't end up on the new launcher, roll back.
- **The launcher APK is bundled in the app** (not downloaded), so the app and the launcher it installs always match
  and setup works offline.

## Launcher lives in this repo

`tv-launcher/` holds the launcher source (upstream cleanyourtv plus our changes) rather than a separate fork, so the
app and the launcher it ships version together. Upstream merges are recorded in `tv-launcher/UPSTREAM.md`.

## Build variants

Two schemes: **Debloated TV Dev** (Debug, separate app ID and name) and **Debloated TV** (Release). The dev app sits
next to the production one, so a maintainer can keep using the released app while working on the next version.
Each app has its own pairing, ADB key, settings and recovery records.
