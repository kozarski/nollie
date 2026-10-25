# Watch and take over

[← Nollie](../README.md) · [Nollie Computer](nollie-computer.md) · [Computer add-on](../Companions/nollie-computer/README.md)

While a helper uses one of its computers, its chat shows a small **Watch** pill under the
helper's name (in the toolbar on the Mac). Watch opens the computer full screen: on the
iPhone as a cover, on the Mac as a large sheet.

## What the person sees

- **The helper**, centred at the top: its character and name, and which computer it is on.
- **The screen**, live. Where a live picture can be had (a linked iPhone, or the Mac for a chat on
  its own Nollie Runtime) it plays as video; otherwise it is a snapshot every 2 seconds. See
  [The live picture](live-picture.md). Pinch to zoom, drag to look around while zoomed, double tap
  to zoom in or back out.
- **The badge**, honest about freshness: **Live** only while the picture is current (video playing
  with a beat in the last 3 seconds, or a snapshot captured in the last few seconds), **Paused** when
  updates have stopped here (the app is in the background), **Stopped** when the live picture ended
  because the computer is no longer in use, **Paused while a sign-in is typed** with no picture at
  all while Nollie types a saved sign-in (from a snapshot or the live picture's beats), and **Last
  seen 2 min ago** (or "Last screen" when the time isn't known) for anything older. Under it, when the connection struggles: "The connection is
  slow, so the picture is lighter." or "Waiting for the picture to catch up."
- **The helper's pointer**: its own small character, in its colour, beside a dot on the spot
  it last clicked, dragged to or moved to. It is drawn only when the add-on found that spot in
  the helper's own tool call on this computer. Nothing is guessed: no spot, no pointer.
- **Take over** and **Stop**, as pills at the bottom. Take over shows only while the helper
  holds the computer. Nollie Computer on the Mac has its own Stop and isn't paused by Take over,
  so its picture offers none.

Watching changes nothing on the computer or in Hermes.

## Take over and hand back

Take over asks for Face ID, Touch ID or the device's passcode, then sets the helper's desktop
lease to a person. The screen says "You have the computer. Nollie is waiting." (with the
helper's name) and **Hand back** returns it. If the Watch screen closes meanwhile, the chat
keeps an orange Watch pill so the way back is one tap away. Another device learns who holds
the computer when its Watch screen opens; until then its pill shows only while the helper is
busy. Private bots never get a Watch pill.

On an iPhone linked to the Mac with Nollie Link, Take over and Hand back go through the Mac's door,
which lets exactly these two POSTs through with a single `profile` and nothing else (see
[Nollie Link](nollie-link.md)). Face ID stays on the phone, before anything is sent. Away from home
without Tailscale, Watch, Take over, Hand back and Stop say so instead of trying.

What pauses while a person holds the computer:

- Hermes's own computer and browser tools refuse every action, screenshots included, by
  Hermes's own rule, and void anything that was already running when control changed.
- The helper's Cua computers: the computer add-on's `pre_tool_call` hook refuses every `cua`
  tool while Nollie holds the lease, and tells the helper to wait.

Version one on the iPhone pauses the helper so the person can act; tapping on the remote
screen to click is not built yet. The person acts through whatever they normally use to reach
that computer (or on the Mac itself).

### How the lease is changed

The add-on owns both changes (`POST /api/plugins/nollie-computer/take-over` and
`/hand-back`, behind the gateway's sign-in). Each goes through Hermes's own locked lease
transition, so the epoch only grows and Hermes's readers always agree.

- **Take over** remembers who held the lease before (the helper, or Mac control switched
  off) in `<home>/bot-desktop/nollie-takeover.json`, then writes a person, `nollie-watch`.
  It never takes the computer from someone else who holds it; it answers "Someone else has the
  computer right now." instead.
- **Hand back** restores exactly the earlier holder, and only while the lease is still the one
  Take over wrote. If Mac control changed meanwhile, the lease is left alone. If the record is
  missing or doesn't match, the helper stays paused for the Mac (Mac control off) rather than
  being given more than it had.
- A helper that had no lease file gets none back: Hand back removes the file, under the same
  lock, holder and epoch checks, so the helper never ends with more than it had and Mac control
  reads as before. The cost: Hermes counts a missing file as epoch 0, so an action admitted
  before Take over that is still running at Hand back is not voided by its epoch check.
- Neither one touches config, approvals, tool lists or Nollie Computer.
- Private bots are refused with the same answer as an unknown bot, before anything is read.
- Both are safe to repeat. A lost answer is never repeated: the next preview says who holds
  the computer.

## Stop

Stop is one tap: it stops the helper's current turn in this chat, the same as the composer's
Stop. It does not stop or switch off the computer.

## What's in the preview now

`GET /api/plugins/nollie-computer/preview` gains two optional fields (add-on 0.2):

- `control`: `helper`, `you` or `someone`, read fresh for each answer. Without it, Take over
  isn't offered (an older add-on).
- `pointer`: `{x, y, at}` from the latest successful `computer_click`, `computer_double_click`,
  `computer_move_cursor`, `computer_mouse_down`, `computer_mouse_up` or the end of a
  `computer_drag` on the same computer. Cua documents these numbers as pixels of the last
  `computer_screenshot`, which is what the preview shows, so the app places the pointer as a
  fraction of the picture's own size and drops it if it falls outside.

Add-on 0.4 keeps one Cua child per computer open between pictures instead of starting one
for each, so a picture costs one screenshot call. `fresh=1` on the preview skips the
1.5 second cache (a capture already on the way is still shared). The answer is the same as
before, and the Private list and the exact chat are checked before every picture.

## Proof

- The live picture has its own proof list in [The live picture](live-picture.md#proof).
- `python3 -m unittest discover -s Companions/nollie-computer/tests` (take over, hand back,
  restore, refusals, the hook, the pointer) and `Tools/mock-gateway/test_computer_preview.py`.
- `NollieTests/WatchTakeoverTests` (badge, pointer placement, Face ID first, refusals).
- `NollieMacTests/NollieLinkDoorTests` (Take over and Hand back through the door: POST with one
  `profile` only, reaching Hermes; anything else refused before Hermes).
- `NollieUITests/ChatNavigationUITests/testWatchTakeOverAndHandBack` against the mock gateway,
  with light and dark pictures of the pill, the live view, the taken-over state and a stale screen.
- The add-on was also run against Hermes's real lease module in a throwaway home: Take over made
  `computer_use` refuse, Hand back restored the helper. No real computer was used.

Not yet proven: a real Cua computer pausing on the hook with Hermes running, and the hook
firing for a named profile whose plugin list doesn't include this add-on.
