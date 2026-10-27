# Board follow-through

This Hermes plugin delivers new Board outcomes into Nollie's canonical Bot Chat. The
gateway's existing durable Bot Chat queue runs the turn even when the app is closed.
It does not create a cron job or change a card merely by observing it.

It observes assignments to every Hermes profile except the private ones (see
[Private bots](#private-bots)), on boards that are not private. Private creators and
tenants are excluded before event evidence is returned.
Only task identity, title, ownership, state, source session and selected outcome
fields are included. No task bodies, comments, parent context, attachments or chat
transcripts are requested. A small add-on helper filters ownership metadata
before reading titles or events, all within one consistent read transaction on a
read-only connection. It never initializes a schema or creates a missing board.

New review requests, revision requests, completed work and exhausted failures wake
Nollie to continue already-authorized work. Routine review belongs to Nollie. A genuine
human blocker gets one useful question with the card reference. Unchanged work,
routine retries and already-handled events finish with `[SILENT]`. Existing approval
boundaries still apply. Delayed work needs one actual timed follow-up owned by the
task; this plugin does not treat a `scheduled` flag as a timer.

## Install and activate

From the repository root:

```sh
python3 Companions/nollie-workflow/install.py
python3 Companions/nollie-workflow/install.py --apply --enable
python3 ~/.hermes/plugins/nollie-workflow/control.py status
```

The first command prints the plan. Applying makes a dated, byte-verified backup of
the default config, backs up any previous plugin and state, installs the files and
leaves observation stopped. Board and cron helpers stay inside the add-on. The
installer does not change Hermes source. Enabling uses Hermes' supported plugin hot reload; it
does not restart the gateway or run an agent. The installation timestamp is the
baseline, so old blocked cards are not replayed. Events created after installation
remain eligible even before activation.

The authenticated default-profile dashboard namespace exposes:

- `GET /api/plugins/nollie-workflow/status`: plugin version, enabled state, poll time,
  receipt counts and `watch_binding_ready` for the loaded native pre-check capability.
- `GET /api/plugins/nollie-workflow/attention`: `{"counts":{"default":3}}`. It counts
  blocked cards needing input, capability or an unknown legacy reason. Review and
  transient/dependency waits do not count. This route does not read event history.
- `POST /api/plugins/nollie-workflow/events/read`: filtered events and per-task cursors.
  The request contains `{"cursors":{"default":{"task-id":123}}}`; profile and
  installation boundary are server-owned. This endpoint is read-only.
- `GET` and `PUT /api/plugins/nollie-workflow/private-bots`: the Private list, described
  below.
- `GET /api/plugins/nollie-workflow/bot-looks` and `PUT .../bot-looks/<profile>`: each
  bot's look, described under [Bot looks](#bot-looks).
- `GET /api/plugins/nollie-workflow/memory?bot=<name>`: what a helper remembers, from its
  Hermes memory files (`memories/USER.md` and `memories/MEMORY.md`), and whether Hermes uses
  memory for it (`memory.py`). `POST`, `PUT` and `DELETE .../memory/notes` add, change or forget one entry,
  named by its exact text; `PUT .../memory/switch` sets `memory.memory_enabled` and
  `memory.user_profile_enabled` through Hermes's own config calls. Every change takes the
  lock Hermes's memory tool takes (`flock` on `<file>.lock`), reads the file again and
  replaces it whole, so an entry Hermes adds meanwhile is kept; an edit to an entry Hermes
  has just changed gets `409` and nothing is written. Moss and bots named private are always
  refused. Another bot on the Private list is answered only with `on_this_mac=true`, which
  only Nollie on the Mac that runs Hermes sends and the Nollie Link door never lets through.

Check the status endpoint through the normal signed-in dashboard connection. A
404 means the dashboard has not loaded the plugin. A 403 means a nondefault profile
was requested. Do not start a second gateway to work around either result. The
normal `hermes --profile default plugins enable nollie-workflow` command asks the
running dashboard and gateway to reload plugins only when it changes something; a
copy that is already enabled stays loaded as it was. After upgrading the add-on,
restart the gateway and the dashboard.

When ready to allow follow-through turns:

```sh
python3 ~/.hermes/plugins/nollie-workflow/control.py activate
```

The observer polls every 15 seconds. `last_poll_at` should advance. Each event gets
a stable receipt ID based on board, task and event. Its exact prompt and cursor are
saved before enqueueing. Retrying an interrupted enqueue uses that same ID and
content. Pending work is revalidated against current allowed ownership and state.
A damaged receipt does not prevent other tasks from being delivered. Failed or
ambiguous execution is observed, not blindly replayed.

## Private bots

A bot marked Private in Nollie keeps its work out of Board follow-through. Hermes has no
such setting, so the list is a small file in the main bot's Hermes home (the directory
`hermes_cli.profiles.get_profile_dir("default")` returns, normally `~/.hermes`):

```json
{"version": 1, "profiles": ["scout"]}
```

The file is `nollie-private-bots.json`. Names are lowercase Hermes profile names, at most
64 of them. Each save replaces the whole list in one atomic write, under the lock file
`nollie-private-bots.lock` beside it, with user-only permissions. A damaged list is never
treated as empty: follow-through stops polling and the routes answer 503 until a new list
is saved.

Until the file exists, bots named `private` or `moss` count as private. This is a one-time
carry-over from older builds that went by those names. Once a list is saved, even an empty
one, only the list counts.

The followed bots are every profile Hermes lists (`list_profile_names`), less the private
ones, read again on each poll. A new bot is followed without an upgrade. A task is skipped
when its assignee is not followed, or when its creator or tenant names a private bot. A
board is private when its slug names a private bot. An event is skipped when its
payload's profile, assignee, author, implementer or reviewer names a private bot.
"Names" means the whole value or any word in it, so `profile:scout` names `scout`.

The routes, reachable only through the main profile like the others (any other profile
gets 403), answer with `Cache-Control: no-store`:

- `GET /api/plugins/nollie-workflow/private-bots` returns
  `{"profiles": ["moss", "private"], "saved": false}`. `saved` is false while the carry-over
  applies, and the names are the ones it uses. After a save it is
  `{"profiles": [...], "saved": true}`.
- `PUT /api/plugins/nollie-workflow/private-bots` with `{"profiles": ["Scout", "mason"]}`
  saves the list and returns it as saved: `{"profiles": ["mason", "scout"], "saved": true}`.
  Names are trimmed, lowercased, sorted and deduplicated. A name that is not a Hermes
  profile name, more than 64 names, or a body without a `profiles` list gets 422 and
  nothing is written. A name does not have to be an existing bot.

The mock gateway in `Tools/mock-gateway` serves the same two routes from memory.
`POST /api/_mock/private-bots` forgets its saved list.

## Bot looks

The character and colour the person picks for a bot in Nollie, so every device draws it
the same way: a helper added on the phone looks on the Mac as it was picked. Before this,
a look stayed on the device where it was picked and the others guessed one from the name.
The file is `nollie-bot-looks.json` in the main bot's Hermes home, with
`nollie-bot-looks.lock` beside it and user-only permissions:

```json
{"version": 1, "bots": {"planner": {"look": "duo", "colour": "#336699"}}}
```

`look` is a character id, `colour` is `#RRGGBB`, and either may be missing (the default).
A photo never comes here; it stays on its device. At most 64 bots.

- `GET /api/plugins/nollie-workflow/bot-looks` returns `{"bots": {...}, "saved": true}`
  (`{}` and `false` before any look is kept). Private bots are left out.
- `PUT /api/plugins/nollie-workflow/bot-looks/<profile>` with `{"look": "duo", "colour": "#336699"}`
  keeps one bot's look and returns them all; both null forgets it. One bot at a time, so a
  change on one device never undoes another device's change to another bot. A private bot
  gets 403, a bad name, look or colour 422. A damaged file answers 503.

The app takes the gateway's look for each bot it lists, except one changed on that device
and not yet confirmed, and offers its own for a bot the gateway has none for. The mock
gateway serves both routes from memory; `POST /api/_mock/bot-looks` forgets them.

## Papertrail

Papertrail is each bot's record of what left this Mac. The add-on listens to five Hermes
hooks (`post_api_request`, `api_request_error`, `post_auxiliary_call`, `post_tool_call`,
`post_approval_response`) in every bot whose name is not private, and writes one line per call to
`<bot home>/nollie-workflow/papertrail/<YYYY-MM-DD>.jsonl`. A line keeps when, the route
(`mac`, `network` or `online`), provider, `scheme://host[:port]`, model and token counts,
or a count of searches, pages and pictures. It keeps no prompts, replies, queries, URLs or
arguments. For the app's Why? it also keeps what started the work (a chat and its chat app, a
schedule's or Board task's id, a schedule's helper), how many messages a request carried,
whether the backup model answered, and the person's approval answers in the turn. Files are user-only, links are refused and days older than 35 are deleted. A
hook only hands its line to a writer thread, so Hermes never waits on the file. The Private
list is checked before every line: a bot marked Private stops recording at once. A failure
is noted by type only in `papertrail/last_error`; Hermes never sees it.

The route is decided by provider and host together: loopback is this Mac, private,
link-local, Tailscale, `.local` and dotless hosts are your network, everything else is
online. A `process://` provider such as the Claude plan counts as online. A local runtime
run as a process or over a socket file stays on this Mac; any other scheme goes by its host.

Copy the add-on into the other bots and enable it there:

```sh
python3 Companions/nollie-workflow/install.py --papertrail-bots career,nowhere,forager
python3 Companions/nollie-workflow/install.py --apply --enable --papertrail-bots career,nowhere,forager
```

Private names are refused. Only the default bot runs Board follow-through. Enabling the
other bots reloads them, but the default bot's add-on is already loaded and the dashboard
never reloads a mounted route, so restart the gateway and the dashboard after an upgrade.
Until then Nollie's own bot does not record and the app says Papertrail isn't on.

Each time a bot used apps on this Mac through Nollie Computer, the Mac app sends
`POST /api/plugins/nollie-workflow/papertrail/mac-session` (`{"bot", "apps", "actions", "looks"}`,
refused for private bots and phones) and one `mac` line keeps the apps' names and the counts, with
`screenshots_left: 0`: the model that looked runs on the Mac. The read answer lists them in
`mac_sessions`, newest first, apart from what left.

`mac_screen.py` refuses Hermes's own `computer_use` in every bot that is not private (it would send
this Mac's screen to the bot's model) and replaces any result of it that got through. It also refuses,
never asks, a terminal, code or wrapped call that would take a picture of the screen or record it:
`screencapture`, Quartz and ScreenCaptureKit calls from Python, osascript or Swift, PIL's ImageGrab, mss,
pyautogui, ffmpeg's screen input and the like, read in the command, the code and any script the command
runs. It is a list of known ways, not a sandbox: code that hides what it calls can still get past it.

`GET /api/plugins/nollie-workflow/papertrail?bot=career&days=7` (default scope only) groups
calls by turn and answers counts of replies that stayed and left, plus up to 200 entries
for what left, newest first. Private bots get 403, unknown bots 404, a bot without the
add-on 404, and a malformed name or `days` outside 1 to 35 gets 422. Responses carry
`Cache-Control: no-store`. The full contract is in `Docs/specs/papertrail.md`.

## Ask first

Every bot gets Ask first, Private ones too (nothing else of the add-on loads there, and nothing is
recorded): a `pre_tool_call` hook (`ask_first.py`) that holds any call that sends, pays or buys, posts
or deletes until the person says yes. It reads the call by fixed rules: the tool's name and arguments,
what another server's tool said about itself when Hermes registered it, shell commands and the scripts,
package scripts and Makefiles they run, code, web requests, whether a file being written was already
there, and for a click on a computer the label under the click and, for OK or Continue, the window,
dialog or page form around it (`screen_text.py`: the bot's own Cua computer is read with the Mac's text
recognition, this Mac and the browser from the bot's latest capture or page). A call it can't read asks
as `unsure`; the bot's Ask first switch (`nollie-workflow/ask-first.json`) turns only those off.
In a chat the call waits for Hermes's approval card with the whole action in plain words, and only
Allow once or Deny; each call gets a fresh key. In a schedule, Board work or any run nobody can answer,
the call is held and not done, and Night shift lists it as held. With approvals switched off it is
refused. If the hook can't load, `_refuse_unguarded` refuses the calls it would have checked.

It can't see what a script does when it can't read the script, words drawn on a screen it can't read
(it asks then), or an action hidden behind a tool whose name and arguments look harmless. What it
holds, the rules and what it can't see are in [Ask first](../../Docs/ask-first.md).

## Saved sign-ins

Version 0.4 adds `request_sign_in` in its own toolset, `nollie_sign_in`, for every bot that is not
private. A helper asks to sign in to a site; Hermes's own approval gate asks the person (Allow once
or Deny); Nollie on the Mac reads the password with Touch ID or the Mac's password and types it into
the helper's computer. Passwords never come here: the add-on keeps only which sites are saved, open
requests and a history, under `<main home>/nollie-workflow/sign-ins/` (0600 files, 0700 folders).
The tool answers `signed_in`, `declined`, `not_saved` or `not_signed_in` with one short sentence,
refuses private bots before anything is read, and refuses schedules and Board work. Routes, the
threat model and what is not done yet are in [Saved sign-ins](../../Docs/saved-sign-ins.md).

Pictures pause while a sign-in is typed. From the yes until 10 seconds after the Mac reports back
(`SETTLE`), a `pre_tool_call` hook (`PicturePause` in `sign_ins.py`) refuses every screenshot,
recording and action on a computer, in every bot, and says when to try again.
Ask first doesn't look at a screen then either, and the computer preview pauses too. The tool
answers only once the pause is over. A request file that can't be read, or a linked sign-ins folder,
counts as typing.

## Calendar, Reminders and Contacts

`apple_data.py` gives every bot that is not private tools for the Mac's calendar, reminders and contacts,
one toolset per area (`nollie_calendar`, `nollie_reminders`, `nollie_contacts`), shown only while that
helper's switch is on (`apple-data/bots.json`, set from Bot settings). Each call is a request file that
Nollie on the Mac answers. A change is worded by the Mac first, asked through Hermes's approval gate with
those words every time, and made by the Mac only after the yes; unattended runs are held. Routes, files and
the rules are in [Calendar, Reminders and Contacts](../../Docs/calendar-reminders-contacts.md).

## Stop or roll back

```sh
python3 ~/.hermes/plugins/nollie-workflow/control.py pause
hermes --profile default plugins disable nollie-workflow
```

Pause stops new observations and enqueues. Unloading also stops between deliveries.
An enqueue already in progress can finish. Accepted or running turns belong to the
existing Hermes delivery lane and are not revoked by pausing this observer. A
queued turn rechecks current task ownership before opening the card, but this is
an instruction to the turn, not an atomic task lock held until execution.

Keep `~/.hermes/nollie-workflow/state.json` and Hermes receipts when rolling back.
Deleting either can defeat duplicate protection. For a plugin upgrade rollback,
pause and disable first, move the current plugin aside, then restore the dated
`~/.hermes/plugin-backups/nollie-workflow-*` directory. Keep the current state and
receipts. Re-enable only when the restored code supports the saved state. Restore
the helper from its adjacent dated backup if that upgrade changed it; removing a
first-installed helper after disabling the plugin has no effect on other services.
An already imported helper stays in a running process until that process reloads.
Restore config from its backup only if a targeted comparison confirms no later unrelated
settings would be lost; disabling this one plugin is normally enough.

The companion does not disable existing Hermes notification subscriptions. Its
receipt identity prevents duplicate turns from this companion; other notification
routes can still independently wake an agent. The prompt explicitly checks whether
an outcome has already been handled. Verify the push adapter suppresses `[SILENT]`
before relying on quiet routine handling end to end.

## Tests

```sh
python3 -m unittest discover -s Companions/nollie-workflow/tests -v
```

Use the existing Hermes Python environment to include the FastAPI route tests
(`Tools/dev/verify.py python` uses its own environment with FastAPI).
Fixtures use temporary directories and injected APIs. They do not inspect live
tasks, private profiles or chats, and never run a model. The live acceptance check
is one newly created authorized task after installation, one canonical Nollie reply,
then an unchanged poll and a service reload with no second receipt.

## Checkpoints and explicit watches

Version 0.2 adds `nollie_followup` to the existing Kanban toolset for the default
profile. It requires the companion to be enabled. This is a lifecycle helper,
not a second scheduler, and an upgrade does not create or start any job.

- `checkpoint` saves the exact run ID, verified source-result identities, findings,
  remaining work and next action. Rephrasing the same result IDs is not new
  evidence. It never unblocks a task, resets a limit or queues a continuation.
  The caller must verify the evidence and use the normal native task/job tools
  for any authorized next slice. Native approval and loop guards remain in force.
- `bind_watch` requires an explicit watch request and one existing **paused** native
  daily cron job with model and provider pins and no finite repeat limit. It
  rejects other pre-run scripts and duplicate task/job bindings. It installs a
  fixed calendar gate using an atomic native-job comparison, confirms that
  update, and leaves the job paused. The caller verifies the model
  and delivery route before resuming that same job with native cron tools.
- `record_check` keeps an initial baseline, comparable facts, sources and server
  check time. Different variants use separate comparison keys. After all
  successful comparisons are recorded, `finish_check` finalizes that cycle. It
  returns `[SILENT]` only when every recorded comparison is unchanged. Never
  finalize a failed or incomplete check. Check completion leaves the watch
  active. Keep check timestamps out of compared facts. Up to 16 comparison
  groups and 128 recent observations are retained; each group's first
  baseline is preserved. This is bounded watch state, not a full research archive.
- `stop` closes the durable gate before pausing its exact native job. A failed
  pause cannot reopen the gate. A job whose route/prompt changed is not mutated.
  The gate also stops at the configured exclusive deadline. `status` returns the
  existing task's bounded checkpoint/watch state.

The native daily trigger plus calendar gate preserves a local wall-clock time
across DST and month boundaries. Off-days, completed cycles, stopped watches and
human-input blocks do not wake a model. A missed check can catch up once. The gate
checks current nonprivate task ownership and the pinned job signature each time.
A damaged or unavailable gate state fails closed, so inspect status rather than
claiming monitoring continues. The wrapper lives in the default home's `scripts`
directory and is created only when a watch is explicitly bound. The installer
backs up the plugin as before; follow-up state is preserved in
`nollie-workflow/followups.json` with private file permissions.

Binding also requires the small scheduler overlay described in
[Hermes compatibility](../hermes-patches/README.md). Hermes v0.22.2 has no hook
before a scheduled turn starts, and can wake a model when a pre-check script fails.
The checked overlay makes bound jobs stop when that script is missing or fails.
The companion checks the loaded capability. Its installer does not change Hermes
source or reload a running service. Tests import the checked scheduler and the
original job store, then exercise the add-on's binding and pause operations there.

Board outcomes are not suppressed by these watch records. Other subscriptions
can still wake Nollie independently. Use native cron's quiet-result contract and
avoid generating redundant Board outcomes for every monitor check. Checkpoint
and watch context are included in ordinary follow-through instructions without
removing failures or review requests.

Pins disable Hermes's global model fallback chain, but this helper does not prove
that a selected provider actually runs locally. A real local readiness check is
still required. `bot-chat:default` delivery also runs the recipient's configured
model; pinning a local worker does not pin Nollie's recipient turn. Unchanged
`[SILENT]` results are filtered by native cron before that delivery.

These mechanics do not make every existing task an automatic watch. A one-off
search stays one-off. Existing installs need this companion upgrade and the
explicit watch/continuation policy in their lead instructions. Fresh installs
receive the policy and companion in the managed setup. Check tool capability before
claiming these mechanics are available. A quoted request in tool arguments is
context, not a new approval for purchases, messages or account changes. No
existing SOUL, job or profile is changed by editing these repository files.

## Night shift and rehearsals

Version 0.3 adds two features, both off until turned on. The design is in
[Night shift and rehearsals](../../Docs/specs/night-shift.md).

- **Night shift card.** Each morning one card in Nollie's main chat lists what ran
  while nobody was watching: every schedule run, Board worker and helper, every tool
  call in it, and the receipt for each (the rule or approval that let it happen, or
  what stopped it). A quiet night still gets a card.
- **Rehearsals.** A new or edited schedule's first run is a rehearsal. Nollie holds
  every action that changes something, lets look-only tools run, keeps the reply out
  of the chat, and posts a report. The schedule stays paused until Turn on.

### Pieces

| File | Job |
| :--- | :--- |
| `log_privacy.py` | Keeps the words of chats out of Hermes's logs, in every Hermes process the add-on loads in |
| `receipts.py` | Classify one call with Hermes's own predicates, scrub text, the look-only list |
| `recorder.py` | The hooks in every followed profile: the guard and the recorder |
| `rehearsals.py` | The registry, the schedule signature and which runs rehearse |
| `night_shift.py` | Settings, receipt files, the Board outcome log and the card builders |
| `posts.py` | The cards posted into the main chat, 30 days at most |
| `night_service.py` | The service's sweep each tick, the morning card, pruning, Turn on and Keep off |
| `sleep_watch.py` | When the Mac was asleep, off or without Hermes, from the service's own ticks |

In the default profile `register` keeps everything above and also loads the recorder.
Every other profile loads the recorder and Papertrail, and only when it is not Private. A
`recorder-only` marker an older installer left in a copy no longer keeps Papertrail off. A
damaged Private list loads no recorder anywhere until it is repaired.

### The recorder

Two `pre_tool_call` callbacks, registered guard first. Both return at once, before any
file is read, unless the run is unattended: a cron run (`ctx.current_cron_execution()`),
a cron run's helper (`HERMES_CRON_SESSION=1`) or a Board worker (`HERMES_KANBAN_TASK`).
They also do nothing while both features are off.

- The guard blocks, in any unattended run: `computer_use`, the `cua-recorder` tools,
  `mcp__nollie_mac__*`, terminal commands using `osascript`, `open`, `shortcuts`,
  `cliclick`, `automator` or `screencapture`, and writes or commands that name the
  `nollie-workflow` folder. A failing toolset lookup blocks. In a rehearsal it blocks
  every call that is not look-only. Settings and the registry are read once per run
  (a lock wait of at most 0.5 seconds); a decision that cannot be made rehearses.
- The recorder never blocks. It classifies each call in Hermes's own order (hardline,
  sudo guard, deny rule, `command_allowlist`, risky pattern, permanent approval) and puts
  a line on a queue of at most 2000 lines. A background thread appends the lines. A full
  queue, or a day file over 4 MB, drops the line and counts it as unrecorded.
- `post_tool_call` settles each receipt, `on_session_start` and `on_session_end` mark the
  run, `transform_llm_output` answers `[SILENT]` for a rehearsal from the decision already
  in memory, and `post_llm_call` keeps a rehearsal's reply if the transform did not run.
  `post_approval_response` keeps every Always answer, in any chat, so a receipt can say
  when it was chosen. A `cronjob` create wakes the service's sweep at once.

Every stored string is scrubbed in the recorder's process: Hermes's
`redact_sensitive_text(force=True)`, then this add-on's own patterns, then URL query
strings and fragments are dropped. If the redactor raises the string becomes
`[hidden]`. A bot marked Private stops recording within a minute.

### Files

All in the main home's `nollie-workflow` folder, files 0600 and folders 0700.

- `night-shift.json`: `{"version": 1, "night_shift": false, "rehearsals": false,
  "morning_hour": 7, "rehearsals_since": null}`. No file means both off. A damaged file
  means both on with the last good values. `rehearsals_since` is stamped when rehearsals
  turn on, so the service knows to record the schedules that exist then.
- `receipts/<profile>/<YYYY-MM-DD>.jsonl`: one line per event,
  `{"v": 1, "at", "run", "event": "start" | "call" | "result" | "end" | "reply" | "always", ...}`.
  `<YYYY-MM-DD>.unrecorded.json` counts the dropped lines per run. Days older than 14,
  and every receipt of a Private bot, are deleted.
- `recorders/<profile>.json`: `{version, pid, at}`, written when a recorder loads. A bot
  without one is "not watched" and its new schedules stay paused.
- `rehearsals.json` (lock `rehearsals.lock`): each schedule Nollie has seen, its state
  (`on`, `waiting`, `ready`, `kept_off`), kind (`rehearse` or `check`), signature and the
  delivery it saved. Only the service and the routes write it. A damaged registry is
  kept for repair: the service skips the sweep, the routes answer 503 and recorders use
  the last good copy, or rehearse every run without one.
- `posts.json`: the cards, at most 400 and 30 days.
- `outcomes.json`: the Board outcomes follow-through saw (completed, blocked, gave up),
  the newest 500. `always.json`: the newest 500 Always answers.
- `night-shift.wake`: the wake flag. `night-shift-status.json`: last tick time and an
  error type name.
- `sleep.json` (lock `sleep.lock`): `{"version": 1, "seen": {"at", "boot"}, "gaps": [{"from", "to", "kind"}]}`,
  the newest 400 gaps within 35 days. Kinds are `asleep`, `off` and `stopped` (the Mac on, Hermes not).
  Times and kinds only.

### The sweep

Every 15 seconds while rehearsals are on, for each followed bot:

1. The first sweep after turning rehearsals on records every existing schedule as `on`.
2. A schedule with no entry, or an `on` one whose signature changed, is held: its
   `deliver` and `failure_deliver` are saved and set to `local`. A schedule with a
   script, `no_agent`, a monitor, a `once` schedule or a finite repeat is also paused
   with a check card, and so is any new schedule of a bot that is not watched.
3. A held schedule whose rehearsal ended gets a report card and is paused. A run that
   never wrote its end is reported as "The rehearsal did not finish."

When rehearsals are turned off, schedules still waiting for a rehearsal get their
delivery back and run for real. Paused ones stay paused until the card is answered or
they are resumed in Schedules.

While Night shift is on, the morning card is built on the first tick at or after the
morning hour (local time) when today's is missing. Its window starts where the last
card ended, or 12 hours back, and is at most 24 hours.

### Sleep notes

Each tick first looks at how long the Mac slept since the last one: a clock that keeps counting
through sleep against one that stops (`CLOCK_MONOTONIC_RAW` and `CLOCK_UPTIME_RAW`). A new process
compares its start with the stamp the last one left once a minute and the Mac's boot time, so a
night switched off reads `off` and a gateway that was stopped reads `stopped`. Gaps under three
minutes are dropped. Nothing is asked of macOS and no power log is read.

The recorder writes a schedule run's `due_at` (Hermes's `scheduled_instant`) on its start line. The
morning card then carries `sleep` (the gaps in its window), `due_at` and `late` on each run that
started more than five minutes after it was due, and `missed`: per schedule, the times due while
the Mac slept that no run stood for (Hermes runs a missed schedule once on waking, for the first
time it missed, and skips the rest). The card waits until 10 minutes after the latest wake, so what
waited has run. Missed times are counted with Hermes's own `compute_next_run`; they are never runs.

### Routes

Default profile only (403 otherwise), `Cache-Control: no-store`:

- `GET /api/plugins/nollie-workflow/posts?since=<unix seconds>&limit=<n>`: `{"version": 1,
  "posts": [...]}`, oldest first. `since` defaults to 14 days back, `limit` to 60 (at most
  200). Private bots are taken out, in names and in text, at read time too.
- `POST /api/plugins/nollie-workflow/rehearsals/{post_id}/turn-on`: the card's schedule
  must be `ready` or `kept_off` and unchanged. Its delivery is restored, the entry
  becomes `on` and the schedule is resumed. 200 answers the updated card. A changed
  schedule answers 409 with the card marked `changed` and rehearses again. A wrong
  state, or a one-off whose time has passed, answers 409 with the card. An unknown card
  is 404.
- `POST /api/plugins/nollie-workflow/rehearsals/{post_id}/keep-off`: the entry becomes
  `kept_off` and the schedule stays paused. 200, 404 or 409 as above.
- `GET /api/plugins/nollie-workflow/sleep?since=<unix seconds>`: `{"version": 1, "gaps": [...]}`, oldest
  first, cut to `since` (default 14 days back, at most 35). A schedule's page asks it why a run was late.

### Turn it on

Both features ship off. With a backup, on the Mac that runs Hermes:

```sh
python3 Companions/nollie-workflow/install.py --recorder
python3 Companions/nollie-workflow/install.py --apply --recorder
python3 ~/.hermes/plugins/nollie-workflow/control.py night-shift on
python3 ~/.hermes/plugins/nollie-workflow/control.py rehearsals on
```

The first command prints which profiles get the recorder and Papertrail. `--recorder` copies the add-on into each followed profile's `plugins/` (backing up a previous copy in
`~/.hermes/plugin-backups/nollie-workflow-<profile>-<stamp>`) and runs
`hermes --profile <profile> plugins enable nollie-workflow`. It never installs into a
Private profile or one named `private`, and installs none when the Private list is
damaged. Every copy keeps a Papertrail. Restart the
gateway while idle afterwards. Profiles added later need the
installer again; until then the card names them as not watched.

### Turn it off or roll back

```sh
python3 ~/.hermes/plugins/nollie-workflow/control.py rehearsals off
python3 ~/.hermes/plugins/nollie-workflow/control.py night-shift off
```

With both off the hooks do nothing. Schedules still paused by a card stay paused:
answer the card or resume them in Schedules. To remove the recorder from a profile,
`hermes --profile <profile> plugins disable nollie-workflow` and move its
`plugins/nollie-workflow` folder aside. The files above can be deleted once both are
off; `rehearsals.json` holds the saved delivery of any schedule still held, so restore
those first.

## Local deployment record

Version 0.2.0 was installed on October 18, 2026 with the normal backup installer.
The new gateway owns the observer, its previous enabled state was restored, and
existing receipts and the original event baseline were preserved. The dashboard
still needs an authenticated idle-safe reload. No watch or schedule was created.
See [`APPLIED-backend-update.md`](../../build/notification-status-20261018/APPLIED-backend-update.md)
for exact backups and the remaining activation step. This dated local record is
not fresh-install packaging or an end-to-end watch acceptance claim.
