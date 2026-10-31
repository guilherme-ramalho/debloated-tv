# Launcher editor: mobile contract, TV implementation pending

Version 2. The iPhone side lives in `ios/Sources/Core/LauncherClient.swift` and `ios/Sources/App/HomeEditor.swift`; the TV side lives in the launcher (`Editor*.java` in com.gathin.tvhome). Normal navigation and foreground-app identity keep using Android TV Remote Service v2 directly.

## No second pairing

The editor reuses the trust the remote already has. Opening a session briefly starts an invisible activity on the TV, which some streaming apps treat as an interruption, so the phone opens one by itself only when the remote reports Home (`com.gathin.tvhome`) in front. With any other app or input in front it asks first (the remote reports the app, not whether it is playing). In standby it waits. To open a session, the phone:

1. Creates a fresh random 32-byte key.
2. Sends `tvhome://phone-edit?k=<base64url key, no padding>` as an app link through the paired remote connection. Only a phone paired with the TV's remote service can deliver it. The launcher's `EditorLinkActivity` (Theme.NoDisplay, finishes at once) starts `EditorServer` with that key.
3. Connects over plain TCP to port 9764, retrying for up to 10 seconds while the listener starts. Before sending the link it checks the remote connection has heard from the TV in the last 12 seconds (the TV pings every few seconds) and reconnects the remote first if not, since a socket can die silently while the phone sleeps. Up to three tries, each with a fresh key; a session that drops while the TV tab is open reconnects by itself (at most three times a minute).

The TV listens only until one phone proves the key. It serves that phone and closes when the phone disconnects, after 45 seconds without a frame, or after 20 minutes. It also closes after 30 seconds if no phone connects, or after 3 failed attempts. A key is never accepted twice; a new session sends a new link. The phone keeps its session while the app is in the foreground, whichever tab is open (a ping every 15 seconds), and closes it when the app goes to the background; opening the TV tab or returning to the app reconnects if needed. Nothing runs on the TV outside a session.

## Framing and encryption

Each message is unsigned-varint length + bytes; the editor frame limit is 4 MiB.

- Phone → TV: `"TVH2"` + 16-byte phone nonce + 8-byte key ID (HKDF-SHA256(key, no salt, `tvhome-editor v2 key-id`, 8 bytes)). A listener started for a different key closes the connection at once without counting a failed attempt; the phone retries for up to 10 seconds, so a listener left over from an earlier link cannot turn a newer key away. TV → phone: `"TVH2"` + 16-byte TV nonce.
- Keys: HKDF-SHA256(key, salt = phone nonce + TV nonce, info = `tvhome-editor v2 phone-to-tv` or `tvhome-editor v2 tv-to-phone`, 32 bytes).
- Every later frame is AES-256-GCM `nonce(12) + ciphertext + tag(16)`. The nonce is 4 zero bytes + a big-endian counter starting at 0 in each direction. Frames must arrive in order; anything that fails to open ends the session. The first frame that opens proves the key.
- `EditorTest` (launcher) and `EditorCipherTests` (iPhone) check the same known-answer vector.

Plaintext is UTF-8 JSON. Requests use a fresh UUID and have a 20-second timeout:

```json
{"type":"request","id":"UUID","operation":"snapshot","payload":{}}
```

```json
{"type":"response","id":"UUID","ok":true,"result":{}}
```

Failures: `{"type":"response","id":"UUID","ok":false,"error":"Readable reason"}`. Keepalive: `{"type":"ping"}` / `{"type":"pong"}` every 15 seconds during a session. The client never automatically retries mutations. If a response is lost, refresh before deciding whether to repeat a change.

## Snapshot and operations

`LauncherSnapshot` in `ios/Sources/Core/Preferences.swift` is the Codable wire schema. A snapshot contains `revision`, `layout`, `apps`, `inputs`, optional `sleepDeadline` (Unix seconds), and optional base64 `wallpaperJPEG`.

- `layout`: `dockCount` (1–7), package-ID `order`, `hidden`, and `wallpaper` (`quiet-night`, `aurora`, `dusk`, or `photo-UUID`). Hidden apps do not consume dock slots. On the TV the three presets are drawn as a gradient behind Home (EditorBackground) with no picture in memory. A photo is centre-cropped to 1280×720 on the phone before sending, so Home holds about 1.8 MB for it in RGB_565, and Home releases it under memory pressure while it is in the background (WallpaperPlayer.trim).
- `apps`: up to 200 objects with `id`, `name`, `launchURL`, optional `logo`, optional `installed`, and `system`. Derive installed/system flags from Android package data. Return launch intents that target that app; validate all incoming package IDs independently.
- `inputs`: up to 40 objects with stable `id`, readable `name`, and real `launchURL`. Never infer HDMI ports from PS5/Switch labels.
- `snapshot`: no mutation; return the current snapshot and wallpaper bytes when a photo layout is active.
- `applyLayout`: payload `expectedRevision`, `layout`, optional `wallpaperJPEG`. Reject stale revisions, invalid images, invalid package IDs, invalid bounds and unsupported presets. Write atomically, then return the actual new snapshot. Photo UUIDs refer to the supplied image; persist the new asset before changing layout.
- `uninstall`: payload `package`. Reject system/protected packages and the launcher/helpers. Open Android’s uninstall confirmation. Return `{"status":"confirmationRequired"}`; this is not an uninstall-success response. Refresh package data after the TV activity returns.
- `sleepTimer`: payload `minutes` (1–240, or 0 to cancel). Persist and schedule an actual TV-owned timer, then return a snapshot containing the confirmed deadline. Define reboot behavior on the TV. If supported permissions cannot execute it reliably, reject the operation; never claim success for a phone-only timer. The current launcher rejects it: an ordinary app cannot switch the TV off.

Android must enforce these checks even if a modified client skips them. The adapter belongs inside the existing launcher, on demand; it must not reintroduce the removed playback-title companion or continuously poll media state.

## Deferred acceptance checks

With the TV available: implement the adapter; verify the link starts a session, a wrong key is refused and the listener closes after the session; apply and restore a draft including photos; reject stale revision without losing layout; confirm hide versus actual uninstall; sync and launch real inputs; verify a timer after iPhone disconnects; verify listener shutdown and baseline volume/shortcuts/weather/wake. Test keyboard, Siri, saved actions, widgets and Control Center on the physical iPhone. No TV-backed feature should be marked complete until its actual result is observed.
