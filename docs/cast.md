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

## Heavy videos: converted while they play

The TCL's Cast player plays 1080p smoothly, stutters at 4K 30 fps (25 Mbit/s: 8 s of video in 22 s, with all the
data already there) and fails at 4K 60 fps / 85 Mbit/s (`IDLE (ERROR)` within 2–5 s). Its Realtek decoder is listed
up to 4096 x 2176 and 80 Mbit/s (`/vendor/etc/media_codecs_realtek_video.xml`), so 4K itself is the Chromium Cast
shell's limit, and above 80 Mbit/s the hardware's. iPhones record 4K 60 fps HDR at 55–90 Mbit/s.

So a video larger than 1080p or above 20 Mbit/s goes through `VideoStream` (`VideoStream.swift`):
`AVAssetReaderVideoCompositionOutput` makes upright 1080p (or 1080 x 1920) frames in Rec. 709 (AVFoundation tone-maps
HLG and Dolby Vision), the hardware H.264 encoder writes them with a keyframe every 6 s, and `AVAssetWriter` in the
HLS profile cuts exact 6-second fMP4 segments. The playlist is written in full before any segment exists (VOD), so
the TV knows the length and can seek; `MediaServer` waits up to 30 s for a segment that isn't ready and tells the
stream what the TV asked for. The stream stays at most 8 segments ahead, restarts at a segment the TV jumps to,
and deletes segments more than 3 behind. The LOAD carries `hlsSegmentFormat`/`hlsVideoSegmentFormat` = `fmp4`.
On a Mac the 1080p conversion of a 4K 60 fps HDR clip runs at about 2.5–3x real time.

Later: a native player in Purio's TV Home would use the decoder directly and play 4K up to 80 Mbit/s as is (only on
TVs that ran setup).

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
