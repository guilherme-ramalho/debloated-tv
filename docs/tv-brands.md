# Roku, LG and Samsung remotes

Purio's remote on TVs that aren't Android TVs, from the phone, with no server (couch-tv's bridge idea, minus the
bridge). Core: `BrandRemote.swift` (shared interface, app matching, the WebSocket wrapper), `RokuRemote.swift`,
`LGRemote.swift`, `SamsungRemote.swift`; Android `core/.../TvBrands.kt`. The Connect screen tells the kind by the
ports a TV answers on (`TVKind.swift`).

| | Roku | LG (webOS) | Samsung (Tizen, 2016+) |
|---|---|---|---|
| Transport | HTTP, port 8060 (ECP) | WebSocket 3001 (TLS) or 3000 (SSAP) + pointer socket | WebSocket 8002 (TLS) + REST 8001 |
| Pairing | None. "Control by mobile apps" must allow network access, or every command gets 403 | TV asks to accept; client key kept in the Keychain | TV asks to Allow; token kept in the Keychain |
| Keys | `keypress/keydown/keyup/<Key>` | Buttons over the pointer socket; volume, mute, power over SSAP. Held keys repeat every 0.2 s | `ms.remote.control` Click, or Press/Release for a hold |
| Apps | `query/apps`, `launch/<id>` | `listLaunchPoints`, `system.launcher/launch` | `ed.installedApp.get`, REST `POST /api/v2/applications/<id>` (socket launch as fallback) |
| Typing | `Lit_<char>`, Backspace | `ime/insertText`, `ime/deleteCharacters` | `SendInputString` (base64, replaces the field) |
| State | `device-info` power-mode, `active-app` (read on connect, after Home/Back/launch) | Pushed: app on screen, volume and mute, power | Power on connect (REST); no volume or app on screen |
| Power | On and off | Off only | Toggle (off); on needs Wake-on-LAN |
| Missing keys | Subtitles, inputs | none | none |

App buttons match the remote's shortcuts to the TV's own apps by name (`BrandApps.match`: "Prime Video" finds
"Amazon Prime Video", "HBO Max" finds "Max"). TV setup, Purio's Home, the dock and favourite inputs are Android TV
only; the TV tab says so. Show on TV works where the TV has Chromecast built in (it says so at once otherwise).

**Turning LG and Samsung TVs on** needs Wake-on-LAN, a broadcast, which iOS allows only with Apple's multicast
entitlement (the same one SSDP discovery would need). Left out for now, to revisit together.

**Nothing polls.** State is pushed (LG) or read on connect and after a key that changes the screen (Roku, Samsung).

## Where the protocol details come from

- couch-tv (github.com/Seagey/couch-tv, MIT): `bridge/roku.py`, `bridge/lg.py`, `bridge/samsung.py` and their docs
  (Roku's 403 and Control by mobile apps, Samsung's REST launch being the one that works on a 2021 Frame, LG's
  pointer socket on 3001 over TLS). couch-tv itself says its LG and Roku code was tested against stand-ins only.
- aiowebostv (github.com/home-assistant-libs/aiowebostv, Apache 2.0): LG's signed registration manifest, sent as is
  (checked character for character), the SSAP endpoints and button names.
- Roku's ECP documentation (developer.roku.com).

## Tested

Against stand-in TVs on the Mac (`BrandRemoteTests`, `BrandRemoteTest`): an HTTP server answering as ECP and
Samsung's REST, WebSocket servers answering as SSAP (with a pointer socket) and Samsung's remote channel. Not yet on
a real TV: an LG is available to check before release (REM-22); Roku and Samsung go to testers first.
