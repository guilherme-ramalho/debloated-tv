# Launcher editor: mobile contract, TV implementation pending

This branch implements only the iPhone client. No TV adapter, Android permission changes, or background service is installed. Normal navigation and foreground-app identity continue to use Android TV Remote Service v2 directly.

## Intended lifecycle

An explicit Connect editor / Pair TV Home action opens the launcher with `tvhome://phone-edit` / `tvhome://phone-setup`. A future launcher update must implement those links and expose its editing endpoint only for the editing session. iPhone closes the connection when its tab changes, its TV changes, or the app backgrounds. The TV must independently expire its listener and code; a disconnected phone must not leave an indefinite editing server. These are backend acceptance requirements, not capabilities implemented by the mobile client.

Use TLS on TCP 9764 with mutual certificate authentication. Pairing temporarily accepts an unpinned certificate only during explicit setup. Display a short-lived single-use code on the TV, verify the RSA code proof bound to both devices’ keys, then persist the authorized iPhone certificate. The phone stores the TV SHA-256 certificate fingerprint under a separate Keychain service, `PersonalTVRemote.HomeEditorPin.v1`. Existing navigation pairing is separate. Implement attempt limits, code expiry, and explicit revocation on the TV. Never expose this endpoint to the internet.

## Framing and envelopes

Each TLS application message is unsigned-varint length + UTF-8 JSON. The editor frame limit is 4 MiB; the remote-control decoder retains its existing 64 KiB limit. Wallpaper JPEGs are limited to 1,000,000 bytes before base64 encoding. The phone sends a keepalive ping every 15 seconds only during an editing session.

Pairing messages: phone `{"type":"pair"}`, TV `{"type":"code"}`, phone `{"type":"proof","proof":"BASE64"}`, TV `{"type":"paired"}` only after proof verification and client authorization. Proof uses the existing Android TV RSA pairing construction, not the literal code.

Requests use a fresh UUID and have a 20-second timeout:

```json
{"type":"request","id":"UUID","operation":"snapshot","payload":{}}
```

```json
{"type":"response","id":"UUID","ok":true,"result":{}}
```

Failures: `{"type":"response","id":"UUID","ok":false,"error":"Readable reason"}`. Keepalive: `{"type":"ping"}` / `{"type":"pong"}`. Unknown/malformed responses terminate the editing session. The client never automatically retries mutations. If a response is lost, refresh before deciding whether to repeat a change.

## Snapshot and operations

`LauncherSnapshot` in `ios/Sources/Core/Preferences.swift` is the Codable wire schema. A snapshot contains `revision`, `layout`, `apps`, `inputs`, optional `sleepDeadline` (Unix seconds), and optional base64 `wallpaperJPEG`.

- `layout`: `dockCount` (1–7), package-ID `order`, `hidden`, and `wallpaper` (`quiet-night`, `aurora`, `dusk`, or `photo-UUID`). Hidden apps do not consume dock slots.
- `apps`: up to 200 objects with `id`, `name`, `launchURL`, optional `logo`, optional `installed`, and `system`. Derive installed/system flags from Android package data. Return launch intents that target that app; validate all incoming package IDs independently.
- `inputs`: up to 40 objects with stable `id`, readable `name`, and real `launchURL`. Never infer HDMI ports from PS5/Switch labels.
- `snapshot`: no mutation; return the current snapshot and wallpaper bytes when a photo layout is active.
- `applyLayout`: payload `expectedRevision`, `layout`, optional `wallpaperJPEG`. Reject stale revisions, invalid images, invalid package IDs, invalid bounds and unsupported presets. Write atomically, then return the actual new snapshot. Photo UUIDs refer to the supplied image; persist the new asset before changing layout.
- `uninstall`: payload `package`. Reject system/protected packages and the launcher/helpers. Open Android’s uninstall confirmation. Return `{"status":"confirmationRequired"}`; this is not an uninstall-success response. Refresh package data after the TV activity returns.
- `sleepTimer`: payload `minutes` (1–240, or 0 to cancel). Persist and schedule an actual TV-owned timer, then return a snapshot containing the confirmed deadline. Define reboot behavior on the TV. If supported permissions cannot execute it reliably, reject the operation; never claim success for a phone-only timer.

Android must enforce these checks even if a modified client skips them. The adapter belongs inside the existing launcher, on demand; it must not reintroduce the removed playback-title companion or continuously poll media state.

## Deferred acceptance checks

With the TV available: implement the adapter; verify setup/code expiry/certificate pinning; apply and restore a draft including photos; reject stale revision without losing layout; confirm hide versus actual uninstall; sync and launch real inputs; verify a timer after iPhone disconnects; verify listener shutdown and baseline volume/shortcuts/weather/wake. Test keyboard, Siri, saved actions, widgets and Control Center on the physical iPhone. No TV-backed feature should be marked complete until its actual result is observed.
