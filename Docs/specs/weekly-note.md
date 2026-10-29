# The weekly note

[← Architecture](../architecture.md) · [Papertrail](papertrail.md) · [Night shift](night-shift.md)

Status: built for 1.4 "Trust you can see" (27 Oct 2026), on by default, Sunday evening.

## Purpose

Once a week, a calm, short note says what each helper did and what left the Mac, with one tap beside each line to
undo it or turn it off. It says only what Nollie recorded. No model writes or summarises any of it: every sentence is
a fixed one in `WeeklyWords`, filled with counts and names from the records.

## Where the facts come from

`GET /api/plugins/nollie-workflow/week?bot=<name>` (the workflow add-on, `weekly.py`), read for every bot that is not
private, in the main bot's scope like Papertrail. Counts, names and times only:

| Field | Record |
| :--- | :--- |
| `places` | Papertrail's day files: each off-Mac place this week (model routes, search services, pages, pictures, payments, iCloud notes, every host the door saw, by kind), counted, with when it was first seen in all 35 kept days |
| `replies` | Papertrail: replies that stayed on the Mac, that left, that went online (every one, not only the 200 listed) |
| `answers`, `asks`, `earlier_answers` | Papertrail's approval lines: the person's answers this week by choice, what Ask first asked about, and the count in each earlier whole week kept |
| `schedules` | The bot's cron store (names scrubbed, a private bot's name left out) and Hermes's run ledger `cron/executions.db`, opened read only: runs that finished, failed or never said, this week. `runs` is null when the ledger can't be read |
| `board` | The Board outcomes the add-on followed: done, stopped, gave up |
| `apps`, `web` | The bot's config: connected apps (MCP servers) by name, on or off, and a URL one's host; whether the web tools are on. Never a command, argument, header or key |
| `filter` | `on`/`off` from Nollie Runtime's switch file (`NOLLIE_NETWORK_FILTER`), `none` when Hermes wasn't started through the door |

Private bots are refused (403) before their home is looked up. The Link door allows the read with exactly one `bot`.
A member of someone's household is never let through (the family door passes chats only), and the app shows neither
the card, the setting nor the notification on a member's device.

## What it says

- **New this week** first: a place or service first seen this week (only when at least one whole earlier week was
  recorded, so a fresh Papertrail never calls everything new), a schedule made this week, and a helper that asked more
  than usual (at least 3 questions, and at least twice the earlier weeks' average and three more than it).
- **Each helper**: its schedules that ran or are new ("Morning brief", "Ran 5 times · 1 didn't finish · Paused"),
  Board tasks, questions with the answers ("Yes 4 · No 1"), This Mac when this device can read it and it is on; then
  "Went online 10 times. 40 replies stayed on your Mac." and its places, new ones first, six at most.
- Helpers with nothing recorded are named on one line; a week that couldn't be read is said, never guessed.
- With the filter off: "Papertrail's filter is off, so a program that skips Nollie's door could go unseen." With no
  door: "This setup has no door, so Papertrail sees model calls, searches and pages only."

## The taps (`WeeklyAction`)

| Tap | What it does | Undo |
| :--- | :--- | :--- |
| Pause (a schedule) | `POST /api/cron/jobs/{id}/pause` in the bot's scope | Resume |
| Remove (a new schedule) | `DELETE /api/cron/jobs/{id}`, after "Remove this schedule?" | none, it says so |
| Turn off (a connected app the place's host matches exactly) | `PUT .../week/switch {kind: app}`: `mcp_servers.<name>.enabled: false` | Turn on |
| Remove (the same app) | After "Remove “notes” from Scout?" and "This can't be undone.": `POST .../week/remove-app`, which takes the server out of the bot's config with Hermes's own config code (as `DELETE /api/mcp/servers/{name}` does), reads the config again to be sure it is gone, and keeps "You removed “notes”" in the bot's Papertrail as a change (`source: change`, stays on the Mac). One a plugin brings is refused (409) | none, it says so |
| Turn off web (beside web search or pages) | `PUT .../week/switch {kind: web}`: `web` joins `agent.disabled_toolsets` | Turn on |
| Turn off (Can use your Mac) | The bot's This Mac switch (`SystemControl`) | Turn on |
| Mute (beside every helper's name, Nollie's too) | `PUT .../mutes/<bot> {muted: true}`: kept in `<main home>/nollie-weekly.json` for every device. Each device reads it with its bots and raises no banner for that helper's finished replies (one that arrives by push goes quietly to the list, since iOS lets an extension quieten a notification but not drop it); the Mac's iCloud alerts helper leaves them out too. Questions, approvals, failures and "started using your Mac" still come | Unmute, everywhere |

Nothing is offered that isn't real: no app is guessed for a host it doesn't have, and the web tools are offered once.
App and web changes reach the bot from its next chat. Hermes's portal connectors are accounts, not entries in a bot's
config, so Remove is offered for connected apps (MCP servers) only. The Link door lets the owner's devices through for
`GET mutes`, `PUT mutes/*`, `GET/PUT weekly-note` and `POST week/remove-app`; a household member is refused.

## Where it shows

- A glass capsule under the header of Nollie's own main chat, from the chosen evening until put away with its cross.
- A notification at 18:00 on the chosen day (Settings › Your week: one switch, one day; Sunday by default; the switch
  and day are kept on the gateway, `GET/PUT .../weekly-note`, so every device agrees). "Your week" with the live
  counts, in fixed sentence shapes filled from the same records as the note: "Scout and Planner did 12 things. 4 places
  online, 1 new.", "Scout kept busy. Nothing went online.", "A quiet week. Nothing recorded." Things are schedule
  runs, Board tasks and questions; places are those reached online (not the person's iCloud or their own network);
  new is the note's New this week. Private bots are never read or counted.
- Where it is built: on the Mac, by the iCloud alerts helper (`NollieAlertHelper`, `CloudAlertHelperObserver`), at
  the moment it goes out. It reads `/api/profiles` and each public bot's week then, so the counts are as fresh as the
  records, and sends it once per week as an iCloud alert (`weeklyNote`, routed to the main chat, with the note opening
  over it). If any helper's week can't be read, or the bots can't be listed, it says the fixed line "What your
  helpers did, and what left your Mac." It goes out up to 12 hours late for a Mac that was asleep, never for a week
  before iCloud alerts were on. Its going to iCloud is kept in Nollie's Papertrail ("1 weekly note", `source: alert`).
- Every 6 hours the helper says so (`POST .../weekly-note/live`). A device whose iCloud alerts are on and whose
  gateway heard from the Mac in the last 36 hours schedules nothing of its own; any other device schedules a local
  notification with the fixed line, which can't know the counts ahead of time. Scheduling the counts on the phone
  ahead of time, or counting in a background refresh, was turned down: iOS runs those late or not at all, so the
  counts could be stale or never sent.
- Settings › Your week, and the note in a sheet on iPhone, iPad and Mac.
- The Watch: a page with the week, its one line and each helper's counts.

## Mock gateway

`Tools/mock-gateway/mock_gateway.py` serves the route for `default` (a busy week with a new connected app, more
questions than usual) and `work` (a new, paused schedule), reading paused states from the seeded schedules, and the
switch. `POST /api/_mock/week {"state": "quiet"}` empties the week. Demo flags: `-nollie-demo-weekly` opens the
note, `-nollie-demo-weekly-anchor center|bottom` scrolls it, `-nollie-demo-settings weekly` opens the setting, and
the Watch's `-nollie-watch-sample week`.
