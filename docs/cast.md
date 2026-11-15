# Show on TV (Cast)

Photos and videos from the iPhone's library on the TV. The TV's own built-in Cast player (Google's Default Media
Receiver, app id `CC1AD845`) does the playing; Purio serves the file and sends commands. No Google SDK: the sender
is about 300 lines in `ios/Sources/Core/Cast.swift`, written like the remote protocol in `Wire.swift`.

## How it works

- **Connection:** TLS to the TV's port 8009. Each frame is a 4-byte big-endian length and a protobuf `CastMessage`
  (source, destination, namespace, JSON payload). Cast devices present self-signed certificates that change, and
  don't ask senders for one, so the certificate isn't checked; the session only carries commands and links to the
  phone's own server.
- **Session:** `CONNECT` to `receiver-0`, `LAUNCH` the media receiver, wait for `RECEIVER_STATUS` with its
  `transportId`, `CONNECT` to it, then `LOAD` a URL. `PLAY`, `PAUSE`, `SEEK` need the `mediaSessionId` from the
  TV's `MEDIA_STATUS`. `PING`/`PONG` every 5 seconds while open. `STOP` closes the player and the TV returns to Home.
  `CastController` is this as a pure state machine (unit-tested); `CastSession` puts it on a socket.
- **Media server** (`MediaServer.swift`): an HTTP/1.1 server on a random port, only while the library is open. Each
  item gets a random path (only the newest two are reachable); byte ranges supported, 64 KB chunks.
- **Following the phone:** `CastFollower` sends a photo only after the viewer has stayed on it for 0.35 s.
- **Photos:** converted to JPEG at most 3840 px (`PhotoPrep`), upright, without metadata. **Videos** are served
  straight from the library file; slow-motion and other composed videos are exported once to a temporary file.

## What the TCL's player accepts (15 Nov 2026, Android 11, mediashell)

| Media | Result |
|---|---|
| JPEG 4K and 1080p | shown |
| HEIC | `LOAD_FAILED` (hence the conversion) |
| H.264 .mov / .mp4, HEVC .mov / .mp4 | play (content type `video/quicktime` or `video/mp4` both work) |
| HEVC 10-bit HLG (iPhone HDR) | plays; colours not checked by eye yet |
| Portrait HEVC (rotation metadata) | plays; orientation not checked by eye yet |

The player's cold start takes about 12 seconds; a running player loads the next item in under a second.

## Testing

`CastTests` (unit), `testLiveShowsAPhotoOnTheTVAndStops` with `CAST_TEST_HOST=<TV>` (shows a test picture on that
TV, then closes the player), UI tests `testHeaderFitsShowOnTV` and `testShowOnTVOpensAPhotoFullScreen`, and the CST
cases in `TESTING.md`. The `android-tv` emulator image has no Cast player. Anything that loads media takes over the
TV's screen: check that nothing is playing first (`adb shell dumpsys media_session`).
