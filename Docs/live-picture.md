# The live picture

[← Nollie](../README.md) · [Watch and take over](watch-and-take-over.md) · [Nollie Link](nollie-link.md)

The Watch screen plays a helper's computer as live video. The Mac makes the video, Nollie Runtime
carries it to a linked iPhone over Nollie Link, and the iPhone and the Mac show it as it arrives.
When there is no live picture, Watch keeps today's snapshots.

```
helper's computer        Nollie.app (Mac)                          Nollie Runtime          viewer
This Mac: one window ─SCK─▶ LiveHost ─▶ LiveEncoder (HEVC) ─┬─▶ in-process feed ────────────────▶ Mac Watch
Own computer: preview ─────▶ newest wins, one in flight     └─▶ XPC relay ─▶ /nollie/live ─TLS─▶ iPhone Watch
                             LiveJudge, once a second ◀── door stats + viewer reports
```

## Where the picture comes from

- **This Mac** (Nollie Computer): ScreenCaptureKit, one window: the one the helper last acted in for
  the current app, else that app's frontmost window. Only while Nollie Computer's task for the same
  bot and chat is running; never a window of an app the person didn't approve. The chat is matched
  by Hermes's own ids, as Nollie Computer keys it: the session that asked and those before it, back
  to the first; a newer id from compression is followed back through `parent_session_id` before it
  counts. The system cursor is left out: the helper's own pointer is drawn on the device. Its beats
  name no holder, so Watch offers no Take over: that pauses a helper's own computers, not Nollie
  Computer, which has its own Stop.
- **A helper's own computer**: the nollie-computer add-on's preview on this Mac's own gateway, asked
  back to back with `fresh=1` (add-on 0.4 keeps one Cua child per computer open, so a picture costs
  one screenshot call). The newest picture wins. The Private list and the exact chat are checked by
  the add-on on every picture, and so is the saved sign-in pause (add-on 0.5, below).

Cua's own public docs describe an H.264 desktop stream for its computers. It wasn't used: Cua isn't
installed on the Mac this was built on, and its desktop stream couldn't be checked against the
pinned Cua version. Passing that stream through, decoded by the same display path, is the next step
once it can be tried on a real install.

## Encoding

`LiveEncoder` (NollieCore) is a VideoToolbox HEVC session in real-time mode: no frame reordering (no
B-frames), keyframes on demand (a new viewer, a lost frame, a new size) with a 10 second safety
interval, and one frame in the encoder at a time. A picture that arrives while one is encoding waits
in a single slot, and a newer one replaces it (`LiveMailbox`), so frames are dropped rather than
queued. A still screen gets its keyframe from the last picture. A quality change builds a new
session, since bitrate changes on a running hardware session aren't reliable.

The hardware encoder is tried first. If it can't make a session, or two frames in a row come back
failed, the stream moves to the software encoder for good and asks for a keyframe.

Quality steps (`LiveQuality`): 1600 px at 30 fps and 6 Mbps; 1280 px, 24 fps, 3 Mbps; 960 px,
15 fps, 1.5 Mbps; 640 px, 10 fps, 0.6 Mbps.

## The wire

`GET /nollie/live?profile=<bot>&session_id=<chat>` as a WebSocket, the credential in
`X-Hermes-Session-Token`. No compression extension.

- **Video**, binary: a 20-byte header (version, type, flags with keyframe and "carries format",
  codec, sequence, capture time in microseconds, coded width and height), the parameter sets on
  every keyframe, then the HEVC sample as length-prefixed NAL units. At most 8 MiB.
- **From the host**, text: `hello` (kind, computer name, the picture's own size, which pointer spots
  are measured in), `beat` once a second (whether the picture is current, the link state, the quality
  level, who holds the computer, and `"hold": "sign_in"` while pictures are held back; a held beat is
  never fresh), `pointer`, `source` (a new size) and `end` with a reason.
- **From the viewer**, text only, at most 512 bytes: `keyframe` and a `report` once a second (frames
  got, shown and dropped while waiting for a keyframe, and a limit from Low Power Mode or heat).

`LiveWire` reads all of it strictly and is fuzzed.

## Nollie Link

The door answers `/nollie/live` itself and never forwards it to Hermes. Only a linked device, only
`GET` with a WebSocket upgrade, only one live stream per device. It reads the phone's messages
strictly (binary closes the socket) and keeps at most one video frame in flight to the phone: a
newer frame replaces a waiting one, and after a lost frame everything waits for the next keyframe,
which the door asks for once. Once a second it tells the host what it sent, held back, and how much
is still waiting. Removing a device cuts its stream.

Nollie Runtime reaches the Mac app over its own Mach service, `com.coreykozarski.nollie.runtime.live`,
with the same signing checks as the rest of its interface. The latest copy of the app to register is
asked; one that registers later ends the open streams on both sides, and when it quits an earlier
copy still running is asked again. When the Mac app isn't running there's no live picture, and the
phone uses snapshots. While anyone watches, Nollie.app keeps itself out of App Nap so beats and
pictures stay on time; it never keeps the display or the Mac awake.

## How the link is judged

Once a second `LiveJudge` reads the door's numbers and the viewer's report:

- **Fine** until 2 of the last 4 seconds held back at least 2 frames and a fifth of what was offered,
  then **behind**. Back to fine after 4 clean seconds in a row.
- **Stalled** after 2 seconds in a row where nothing moved, bytes were waiting and the viewer said
  nothing.
- Behind or stalled steps the quality down one level, and again if it is still behind 3 seconds
  later. 15 clean seconds step it back up.
- Low Power Mode or a warm device asks for level 2 at best; both, or a hot Mac, for level 3. A
  critical temperature on the iPhone closes the stream and keeps snapshots.

The viewer shows the state in words under the badge: "The connection is slow, so the picture is
lighter." and "Waiting for the picture to catch up."

## On the device

`LiveSampleBuilder` turns each frame into a `CMSampleBuffer` marked to display at once, and
`AVSampleBufferDisplayLayer` shows it. A gap in the sequence, a new format or a failed display
flushes and asks for a keyframe. The helper's pointer is its own view placed from pointer messages,
so it never waits for video.

The badge stays honest: **Live** only while frames are showing and the latest beat (at most 3 seconds
old) says the picture is current; **Paused** while the app isn't in front; **Stopped** when the host
ended the stream because the computer is no longer in use or went away; otherwise **Last seen**.
VoiceOver calls the picture "Live picture" only while the badge says Live, otherwise "Last picture".
Each new try starts from a clear display and forgets the last run's picture, so an old frame is
never dated or played as a new one; why the last stream ended stands until the new one says hello.
A snapshot that names another computer drops the last live picture too.
The stream closes when Watch closes or the app leaves the front, and opens again on return. Only the
Watch screen plays live; the Computer sheet and Bot settings keep snapshots.

## While a saved sign-in is typed

Pictures of every computer pause from the moment a saved sign-in is approved until 10 seconds after
it is typed ([Saved sign-ins](saved-sign-ins.md#pictures-pause-while-it-is-typed)). The live picture
follows the same rule as the preview, read from the same place:

- **A helper's own computer.** The add-on answers `paused` with no picture, and checks again after
  each capture, for `fresh=1` and for a capture other callers share. `LivePreviewSource` tells the
  host to hold; the stream stays open (a pause isn't "unavailable") and the next answer that isn't
  paused lifts the hold. A paused answer for This Mac ends the stream, as any This Mac answer does.
- **This Mac (Nollie Computer).** `LiveWindowSource` asks `GET /api/plugins/nollie-computer/paused`
  on the gateway this Mac types sign-ins for, before its first capture and twice a second after
  (the Mac waits 1.5 seconds before typing). Paused, an ask that fails, or one with no answer within
  0.75 seconds stops the capture and drops any frame still on its way. A sign-in this Mac is
  approving or typing counts as paused whatever the add-on says, and a fill holds every window
  stream before it starts, without waiting for an answer. Ten seconds of only failed or missing
  answers ends the stream; a real pause keeps it open however long it lasts. An add-on that can't
  say (none, or older than 0.5) ends the stream and Watch keeps what it had. With no gateway on
  this Mac and nothing being typed, nothing types here.
- **The host.** On a hold it stops the encoder, so the picture it keeps for keyframes goes too,
  sends no video and tells every viewer at once: beats say `"hold": "sign_in"` and are never fresh.
  A viewer that joins meanwhile is greeted and shown nothing. When the hold lifts, a new encoder
  starts, a picture taken before the hold began is never sent, and every viewer waits for a keyframe.
- **The viewer.** A held beat clears the display at once and forgets the last frame; frames that
  arrive anyway aren't shown, nor any captured before the hold began that arrives after it lifts
  (a frame can wait behind the beats on a slow link), and nothing asks for a keyframe until the
  hold lifts. Until a stream says hello, Watch keeps taking a snapshot every 2 seconds, so a pause
  that begins before the stream's first picture still shows. Watch shows
  "Paused while a sign-in is typed" with no picture, never Live, and a snapshot from before the
  pause never comes back. The mock gateway does the same on `/nollie/live` while a sign-in request
  is approved or being typed, for the add-on's 10 or 35 seconds after it is done, or while its
  preview state is `paused`.

## Measured

On the Mac this was built on (Mac Studio, M2 Ultra, macOS 27.2 beta), 21 Oct 2026:

| What | Median | p95 |
| :--- | ---: | ---: |
| Picture drawn → decoded on the viewer, through the real door over pinned TLS 1.3 on loopback, 1280×800 | 15.0 ms | 18.9 ms |
| Picture drawn → arrived at the viewer, same path | 13.9 ms | 17.8 ms |
| Picture → encoded wire message through `LiveHost`, 1280×800 | 12.5 ms | 17.4 ms |
| Add-on screenshot answer (PNG) → encoded frame | 33.2 ms | 43.8 ms |
| Software HEVC encode, 1280×800 / 960×600 / 640×400 | 14.5 / 9 / 5 ms | |
| HEVC decode, 1280×800, Mac / iPhone simulator | 0.8 / 0.6 ms | 1.0 / 1.3 ms |
| Mock gateway → frame handed to the display layer, iPhone simulator | 0 to 2 ms | |

This Mac's hardware HEVC encoder fails every frame (status -17691), so every number above is from the
software encoder. The first software frame takes 0.3 to 1.2 seconds to warm up, and so does each
quality change.

## Proof

- `NollieTests` and `NollieMacTests`: `LiveWireTests`, `LiveMailboxTests`, `LiveJudgeTests`,
  `LiveQualityTests`, `LiveEncoderTests` (Mac), `LiveStreamClientTests` (one against the real door
  over pinned TLS), `LiveWatchTests`, `WatchTakeoverTests`, `LiveLatencyTests`, `LinkDoorLiveTests`,
  `NollieLinkDoorTests`, and the Mac host's `LiveHostTests`, `LiveSourceTests`, `LiveRelayTests`.
  The sign-in hold: the beat's `hold` read strictly (`LiveWireTests`), the host sending nothing while
  held and starting from a fresh keyframe after (`LiveHostTests`), both sources holding and the
  window waiting for the add-on's answer, holding on silence and ending after ten seconds of it
  (`LiveSourceTests`), and Watch clearing the picture, pausing before hello, and never bringing
  back an older one (`LiveWatchTests`, `WatchTakeoverTests`).
- `Tools/mock-gateway/test_live_stream.py` checks the fixture with its own reader and the mock's
  socket, the sign-in hold included; `Companions/nollie-computer/tests/test_capture_pool.py` checks
  the add-on's pause with the capture pool, `fresh=1` and `/paused`.
- `NollieUITests/LiveStreamUITests` (golden): Live with video and pointer, latency read from the
  demo copy, nothing polled while playing, closed in the background and opened again, Last seen when
  the picture stops being current, light and dark.

Not yet proven on real hardware: a linked iPhone over Wi-Fi or Tailscale, the hardware encoder, the
relay between a Developer ID Nollie.app and Nollie Runtime, ScreenCaptureKit on a real Nollie Computer
task, and a real Cua computer's pictures through the add-on.
