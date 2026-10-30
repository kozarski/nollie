# Night shift and rehearsals

[← Architecture](../architecture.md) · [Conversation engine](conversation-engine.md) · [Conversation UI](conversation-ui.md)

Status: written before the code, then corrected after a review against Hermes's source. Both features are off by
default in the add-on; the cards show on the new chat view.

## Purpose

People leave Nollie and the crew running overnight. Two things make that easier to trust:

1. **Night shift card.** Each morning one card in Nollie's main chat says what the crew did while nobody was
   watching: every schedule and Board run, every action in it, and the receipt for each action (the rule or
   approval that let it happen, or what stopped it). A Share button makes a picture of the card with personal
   details blurred on the device.
2. **Rehearsal (dry run) for a new schedule.** A new schedule's first run is a rehearsal: Nollie stops before every
   action that changes something, writes down what it would have done, and lets it only look things up. The report
   is a card in the main chat. The schedule stays paused until the person reads it and taps Turn on.

Receipts are recorded by Nollie's own add-on at the moment each tool runs, never written by the model. Nothing in
them goes to an online service. They live in plain files under the Hermes home, so they are as safe as that folder:
unattended runs are stopped from writing there (below), but anything else with access to the Mac's files could.

Out of scope here: the old chat view (`TranscriptView`, what Release builds open), push alerts for the card, and
Mac window captures. See "Later" at the end.

## What Hermes gives, and what it doesn't

Read from Hermes v0.22.0 (`~/.hermes/hermes-agent`), source only.

- A plugin's hooks see which cron run they are in: `ctx.current_cron_execution()` gives `job_id`, `job_name`,
  `execution_id`, `scheduled_instant` and `profile`, or `None` outside cron. Delegated children see `None` but still
  have `HERMES_CRON_SESSION=1`. Board workers are separate processes with `HERMES_KANBAN_TASK` in their environment.
  The hook's `task_id` for a cron run is already `cron:<job_id>:<execution_id>`.
- `pre_tool_call` can return `{"action": "block", "message": <non-empty>}`. Hermes then never runs the tool, the
  message is its result, and `post_tool_call` fires with `status: "blocked"`. Every dispatch kind passes this point.
  A `pre_tool_call` callback that raises or times out also blocks, and after a timeout Hermes skips (blocks) that
  callback for 60 seconds, for every session of the profile. So a slow or broken recorder would block daytime work.
- `transform_llm_output` runs once per turn before the reply is stored; the first string a hook returns replaces
  the reply, and a cron reply of exactly `[SILENT]` is not delivered. It is fail-open: if it raises or is slow, the
  original reply goes on. Failed cron runs always deliver a failure notice, whatever the reply.
- A job's pre-run `script`, a `no_agent` job and a monitor gate all run before any agent or tool hook exists.
- **Hermes keeps no record of why an action was allowed.** An allowed call returns a bare `approved: true`, and
  `post_approval_response` never fires in cron. The add-on works the reason out in `pre_tool_call` with Hermes's own
  predicates and confirms it from the result in `post_tool_call`. (`hermes approvals test`'s `evaluate_command` is
  not used: it reloads the permanent allowlist and could race a person's Always.)
- In cron nobody can answer: an `approve` directive resolves from `approvals.cron_mode` (Corey: `deny`). So a
  rehearsal cannot literally ask; it holds each action and asks afterwards, all at once, with Turn on.
- Plugins load per profile (`<home>/plugins`). The recorder therefore installs into every followed profile and
  never into a private one.
- Jobs live in `<home>/cron/jobs.json` per profile. `cron.jobs` calls act on the current cron store, so the add-on
  wraps each in `set_hermes_home_override(home)` and `use_cron_store(home)` for the job's profile, passes ids only
  and checks the id it got back (`resolve_job_ref` falls back to names). `list_jobs(include_disabled=True)`.
  `resume_job` keeps an occurrence that passed while paused as due, so a resumed job may run at the next tick.

## Pieces

All Hermes-side logic is in `Companions/nollie-workflow`. Nothing in Hermes is patched.

| Piece | Where | Job |
| :--- | :--- | :--- |
| `receipts.py` | add-on, pure | Classify one tool call (target and receipt), scrub text, the look-only list |
| `recorder.py` | add-on, every followed profile | Hooks: the guard (Mac and rehearsal holds) and the recorder (receipt lines, through a queue) |
| `rehearsals.py` | add-on, pure + store | Which runs rehearse; the registry of schedules and their states |
| `night_shift.py` | add-on, pure | Build the morning card and the rehearsal reports from receipts, Board outcomes and jobs |
| `posts.py` | add-on, store | The cards the add-on has posted into the main chat, bounded |
| `night_service.py` | add-on, main home | The service's new duties each tick: sweep jobs, finish rehearsals, post cards, prune |
| `dashboard/plugin_api.py` | add-on routes | `GET /posts`, `POST /rehearsals/{id}/turn-on`, `POST /rehearsals/{id}/keep-off` |
| `LinkDoorPolicy` rules | `Services/Runtime/` | The three routes over Nollie Link |
| `ConversationPost`, `ConversationPostSource` | NollieCore | The cards, fetched and acted on over REST |
| `PrivateDetails` | NollieCore, pure | The personal parts of a text, for the share picture |
| Cards and share sheet | `Apps/Nollie/Conversation/` | Draw them on the new chat view |

## Settings

`<main home>/nollie-workflow/night-shift.json` (0600):
`{"version": 1, "night_shift": false, "rehearsals": false, "morning_hour": 7}`. `control.py night-shift on|off` and
`control.py rehearsals on|off` change it. The app's switch in Settings › Night shift changes `night_shift` only, through
`GET`/`PUT /api/plugins/nollie-workflow/night-shift` (`{"on": bool}`; a damaged file reads as on). The Link door lets
the owner's own devices reach it and never a shared member's. The recorder reads it (cached, rechecked at most every 10 seconds by
mtime). A missing file means both off; a damaged one means both on with the last good values, so a broken file never
turns protection off.

## Unattended runs

A run is unattended when `ctx.current_cron_execution()` is set, `HERMES_CRON_SESSION` is `1` (a cron run's helper),
or `HERMES_KANBAN_TASK` is set (a Board worker). Only these are recorded and guarded; for any other call both hooks
return at once, before any file is touched. Daytime chats are not recorded: the person saw those.

Run key: the hook's `task_id` when it is `cron:<job_id>:<execution_id>`; `board:<task_id>` for a Board worker;
otherwise `helper:<session_id>`.

### The two hooks

Hermes runs `pre_tool_call` callbacks one by one, and each fails closed. So the recorder registers two:

- **The guard** decides whether to block: the Mac, the add-on's own files, and rehearsal holds. It does no blocking
  I/O on the hot path: settings and the registry are read once per execution (by mtime, a lock wait of at most
  0.5 seconds) and cached. Its branches that block may fail closed; everything else returns `None`.
- **The recorder** never blocks. Its whole body is in `try/except` returning `None`. It classifies the call and puts
  a line on an in-memory queue (at most 2000 lines); a background thread appends them. A full queue drops the line
  and counts it, and the card says some actions were not recorded. `post_tool_call`, `on_session_start`,
  `on_session_end`, `post_llm_call` and `transform_llm_output` feed the same queue the same way.

### What unattended runs may never do

In any unattended run, real or rehearsal, the guard blocks:

- `computer_use`; tools of the `cua-recorder` MCP server (toolset `mcp-cua-recorder`, names `mcp__cua_recorder__*`);
  Nollie's own Mac tools (`mcp__nollie_mac__*`); terminal commands whose command words include `osascript`, `open`,
  `shortcuts`, `cliclick`, `automator` or `screencapture`. Receipt: `blocked / mac`, "Stopped: schedules never use
  your Mac's screen". The `cua` server's Spaces are separate virtual computers and stay allowed in real runs.
- `write_file`, `patch` and terminal commands that name the add-on's folder (`nollie-workflow`). Receipt:
  `blocked / plugin`.

If the toolset lookup raises in an unattended run, the guard blocks (fail closed).

### Receipts

The recorder classifies each call before it runs, in Hermes's own order for a terminal command
(`check_all_command_guards`): user deny rule, hardline, sudo guard, `command_allowlist` match, risky-pattern
detection, then a permanent approval of the pattern key. `post_tool_call` settles it: `status` is `done`, `failed`
or `blocked`, and a block replaces the receipt with what stopped it (from the `BLOCKED` text or the block kind).

| Kind | When | Detail | Card words |
| :--- | :--- | :--- | :--- |
| `tool` | The tool has no approval step (a file write, a web search, a Board tool) | | Part of this schedule's tools |
| `safe` | A terminal command Hermes does not flag as risky | | Not a risky command |
| `allowlist` | A command that matches `command_allowlist` | the entry | On your allow list |
| `always` | A risky command whose pattern the person chose Always for | what was allowed, and when if seen | You chose Always for this |
| `held` | Rehearsal: not done | | Held for you |
| `blocked` | Stopped by Hermes or Nollie | `risky`, `mac`, `deny_rule`, `hardline`, `plugin`, `other` | Stopped: … |
| `unknown` | The add-on could not tell | | Allowed. Reason not recorded |

Two more fields say which rule decided (1.1): `rule`, the safety check's own words for a risky or never-allowed
command ("recursive delete") or the person's deny rule that matched, and `ask`, what Ask first held a call for
(`send`, `buy`, `post`, `delete`, `unsure`). A stop keeps `rule` only when the stop it predicted is the one that
happened. Receipts from before have neither, and read as they did.

`always` names when the person chose it when the recorder saw that choice: in every followed profile it also keeps
`post_approval_response` answers of `always` (pattern keys, description, bot, time), the newest 500.

Every stored string (target, reply, title, detail) is scrubbed in the recorder's process, where Hermes has
registered the run's secrets: `agent.redact.redact_sensitive_text(text, force=True)`, then the add-on's own patterns
(`sk-…`, `ghp_…`, `Bearer …`, `password=…`, `-p<password>`, `user:pass@`, long hex or base64 runs), then URL query
strings and fragments are dropped. If the redactor raises, the string becomes `[hidden]`. Targets are short: the
command (first 300 characters), the file path, the URL's host and path, the search words, or the tool's first string
argument.

Store: `<main home>/nollie-workflow/receipts/<profile>/<YYYY-MM-DD>.jsonl`, 0600, folders 0700. One JSON object per
line: `{"v": 1, "at", "run", "event": "start" | "call" | "result" | "end" | "always", ...}`. A day file over 4 MB
takes no more lines (counted as unrecorded). The service deletes days older than 14. Each recorder also writes a
heartbeat, `<main home>/nollie-workflow/recorders/<profile>.json` (`{version, pid, at}`), when it registers. The
private profile never has a recorder and is never read; a bot marked Private later stops recording at once (the
recorder reads the Private list, cached for 60 seconds) and the service deletes its receipts.

## Rehearsals

### The registry

`<main home>/nollie-workflow/rehearsals.json` (0600, lock `rehearsals.lock`). Only the main home's service and the
routes write it; recorders only read it.

```json
{"version": 1, "since": 1792500000,
 "jobs": {"career/3f2a9c": {"profile": "career", "job_id": "3f2a9c", "title": "Morning prices",
          "state": "ready", "signature": "<sha256>", "kind": "rehearse",
          "saved": {"deliver": "bot-chat", "failure_deliver": null},
          "execution_id": "e-81", "post_id": "rehearsal-career-3f2a9c-e-81", "updated_at": 1792560000}}}
```

States: `on` (runs for real), `waiting` (seen, not rehearsed yet), `ready` (report posted, paused), `kept_off`.
`kind` is `rehearse`, or `check` for a job Nollie can't rehearse (below).

**The signature** is a sha256 over `followup_policy.route_signature(job)` (prompt, schedule, toolsets, model,
delivery, skills, workdir and more) plus `script`, `no_agent`, `precheck_fail_closed`, `monitor_script`,
`monitor_url` and the sha256 of the script and monitor files' contents. While a job is held, its delivery is
computed from `saved`, not from the `local` the add-on set. Pausing and resuming do not change the signature;
editing the job or its script does.

Turning rehearsals on records every existing job of every followed profile as `on` with its signature, so nothing
that already runs is held.

### Which runs rehearse

The guard decides once per execution, on the first hook call of a cron run, while rehearsals are on:

- an `on` entry whose signature matches the job now: a real run;
- a Board follow-through check: a real run, only when `followups.json` in the main home has an active watch with this
  job id, `route_signature(job)` equal to the watch's route and the same script. Its own gate does the checking;
- anything else (a new job, an edited one, a `ready` or `kept_off` job someone resumed): a rehearsal;
- the registry damaged: the last good copy in memory decides, and jobs missing from it rehearse. With no good copy,
  every run rehearses.

Some jobs can't be rehearsed, so the service never lets them run unseen: a job with a `script`, `no_agent`, a
monitor, a `once` schedule or a finite `repeat`. (A script runs before Nollie can watch; a one-off has no second
run to give.) On first sight the service pauses it and posts a **check** card: what it will do (its prompt, the
script's path and the first 12 characters of its hash), and Turn on.

### The service's sweep

Each tick (15 seconds) while rehearsals are on, for every followed profile:

1. A job with no entry, or whose signature no longer matches an `on` entry: becomes `waiting` (or `check`). The
   service saves `deliver` and `failure_deliver` and sets both to `local`, so neither a reply nor a failure notice
   can reach the main chat, where Nollie would "act on anything that needs action". A `check` job is also paused.
2. A profile with no recorder heartbeat: its waiting jobs are paused too, and the card says "Not watched: <bot>".
3. A `waiting` job whose rehearsal run has ended (its receipts have a `start` with `rehearsal: true` and an `end`, or
   the job's `last_run_at` is past that start and it is not running): the report is built from the receipts,
   posted, the job paused ("Rehearsed. Turn it on in Nollie when you're happy."), and the entry becomes `ready`. A
   run that never wrote `end` is reported as "The rehearsal did not finish."

The model can also create a job inside a run. The recorder's `post_tool_call` for `cronjob` or `cronjob_manage`
`create` wakes the sweep at once (a flag file), so a new job is seen in seconds. Between creation and the sweep the
guard still holds every action of an unknown job and silences its reply; only a failure notice could get out in
that window, and only for a job created outside a run (the dashboard, the crew) that fails within seconds.

### During a rehearsal

- Nollie's own look-only list runs and is listed as "Looked at": `read_file`, `search_files`, `session_search`,
  `skill_view`, `skills_list`, `web_search`, `todo`; `web_extract` and `vision_analyze` with an `http(s)` URL that has
  no query or fragment; `browser_snapshot`, `browser_get_images`; `browser_console` without an `expression`. Looking
  can still fetch pages (GET requests).
- Every other call is blocked with: "Rehearsal: this was not done. Nollie wrote it down for the person to read
  before the schedule runs for real. Carry on as if it worked, and say what you would do next." It is listed as
  "Would have", with its target.
- The reply: `transform_llm_output` returns `[SILENT]` from the decision already made (no I/O, no lock) and queues
  the original text (first 4000 characters, scrubbed) for the report. If that hook fails, the `local` delivery set
  by the sweep still keeps it out of the chat.

A rehearsal never runs a held action later. Turn on only lets the next runs go for real.

### Turn on and Keep off

- `POST /rehearsals/{post_id}/turn-on`: the entry must be `ready`, `kept_off` or `check`, and the job's signature
  must still match. Then the saved delivery is restored, the entry becomes `on` and the job is resumed. A changed
  job answers 409 and goes back to `waiting`: it rehearses again. A one-off whose time has passed answers 409 too.
- `POST /rehearsals/{post_id}/keep-off`: the entry becomes `kept_off`; the job stays paused.
- Both answer the updated post. Taps go straight to the add-on, never through the model.

## The morning card

While Night shift is on, the main home's service builds it on its first tick at or after the morning hour (Mac
local time) when today's card is missing. The window runs from the previous card's end (or 12 hours back for the
first), at most 24 hours. Asleep at 7? It is built on wake.

It holds every unattended run in the window, oldest first:

- schedule runs from the receipts, plus any job whose `last_run_at` is in the window but left none (a gated run),
  shown without actions;
- Board outcomes the add-on followed (completed, blocked, gave up), from a log it keeps of them (newest 500), with
  the worker's calls when it recorded them;
- rehearsals, marked as such; helpers of a cron run as their own `helper` runs.

A quiet night still gets a card: "Quiet night. Nothing ran." One short line each morning shows the watch works.

### When the Mac slept

The add-on's sleep watch (`sleep_watch.py`) keeps when the Mac was `asleep`, `off`, or on with Hermes `stopped`, from
the service's own ticks (see the add-on's README). The card carries:

- `sleep`: `[{"from", "to", "kind"}]`, the gaps in its window.
- On a schedule run, `due_at` (from the recorder's start line, Hermes's `scheduled_instant`) and `late: true` when it
  started more than five minutes after it was due. A gated run takes both from the job's `last_dispatch`.
- `missed`: `[{"bot", "bot_name", "job_id", "title", "first_due", "last_due", "count"}]`, a schedule's times due
  while the Mac slept that no run stood for. Hermes runs a missed schedule once on waking, for its first missed
  time, and skips the rest; a paused schedule was never due. These are never counted as runs.

The card is built 10 minutes after the latest wake at the earliest, so what waited has run. Private bots' `missed`
entries are taken out at read time, like their runs.

The app says it in one line under the counts, then marks each run that waited ("Due 2:00 AM") and lists each
schedule that missed times ("Didn't run 3 times · 2:00 AM to 4:00 AM"). The line counts the runs that waited (late,
due inside a gap) and the missed times: "Your Mac was asleep from 1:10 to 6:40, so two runs waited until it woke."
Off reads "until it was back on", Hermes stopped reads "Your crew wasn't running". The shared picture keeps the line.
A schedule's page says why its last run was late from Hermes's `last_dispatch` and
`GET /api/plugins/nollie-workflow/sleep`: "Your Mac was asleep at 7:00, so this ran at 7:41."

### Keep awake

Settings › Keep awake on the Mac ("Keep Mac awake for my crew", off by default). While it is on and the assistant
runs on this Mac, Nollie holds one `PreventUserIdleSystemSleep` assertion named for Nollie and the reason
(`pmset -g assertions` lists it): plugged in, while helpers work and while a schedule is due within 12 hours; on
battery, while helpers work or a schedule is due within 15 minutes, never below 20% or in Low Power Mode
(`KeepAwakePolicy`). The screen still sleeps, a closed lid still sleeps, and an app can't wake a sleeping Mac, so a
run due later waits and the card says so. Nothing in the Mac's own energy settings is changed. It works while
Nollie is open.

### Post format

`GET /api/plugins/nollie-workflow/posts?since=<unix seconds>&limit=<n>` (default profile only; 403 otherwise;
`Cache-Control: no-store`). `since` defaults to 14 days back, `limit` to 60. Answer:

```json
{"version": 1, "posts": [
  {"id": "night-2026-10-21", "kind": "night_shift", "at": 1792562400,
   "window": {"from": 1792519200, "to": 1792562400},
   "counts": {"runs": 2, "actions": 5, "held": 1, "stopped": 1, "unrecorded": 0},
   "unwatched": [],
   "runs": [
     {"id": "cron:244c3b0b8e42:e-80", "kind": "schedule", "bot": "default", "bot_name": "Nollie",
      "title": "Morning brief", "outcome": "done", "started_at": 1792540800, "finished_at": 1792540868,
      "actions": [
        {"tool": "terminal", "target": "df -h", "status": "done", "at": 1792540810, "receipt": {"kind": "safe"}},
        {"tool": "terminal", "target": "git push origin main", "status": "done", "at": 1792540820,
         "receipt": {"kind": "always", "detail": "git push", "granted_at": 1791900000}},
        {"tool": "computer_use", "target": "click", "status": "blocked", "at": 1792540830,
         "receipt": {"kind": "blocked", "detail": "mac"}}],
      "more": 0}]},
  {"id": "rehearsal-career-3f2a9c-e-81", "kind": "rehearsal", "at": 1792561000,
   "bot": "career", "bot_name": "Scout", "job_id": "3f2a9c", "title": "Morning prices",
   "schedule": "0 7 * * 1-5", "state": "ready", "check": null, "outcome": "done",
   "held": [{"tool": "send_message", "target": "Price drop on the SSD", "at": 1792560990}],
   "looked": [{"tool": "web_search", "target": "2TB NVMe price", "at": 1792560950}],
   "reply": "The 2TB drive is down to 119. I would have sent you a note about it."}]}
```

- Run `outcome`: `done`, `failed`, `stopped`, `skipped` (gated), `rehearsal`. A schedule run may add `due_at` and
  `late`; the card may add `sleep` and `missed` (see "When the Mac slept").
- Rehearsal `state`: `ready`, `on`, `kept_off`, `changed`. `check`, for a job Nollie can't rehearse:
  `{"reason": "script" | "once" | "repeat" | "unwatched", "prompt": "...", "script": "...", "hash": "3f2a9c01be44"}`;
  then `held`, `looked` and `reply` are empty.
- A run lists at most 40 actions; `more` counts the rest. Posts older than 30 days are dropped from the store.
- Bot names come from the profiles' display names. Private bots never appear, in names or in any text the add-on can
  check (`workflow_core.private_identity`).

Over Nollie Link the door allows `GET /api/plugins/nollie-workflow/posts` and
`POST /api/plugins/nollie-workflow/rehearsals/*/turn-on` and `.../keep-off`, the same as it allows resuming a
schedule. Turn on refuses a `check` job only if its signature changed since the card was posted.

## In the app

### NollieCore

- `ConversationPost` (`Codable, Hashable, Sendable`): `id`, `at`, `kind` (`.nightShift(NightShift)` or
  `.rehearsal(Rehearsal)`), plus `pending: ConversationPostAction?` while a tap is in flight and `problem: String?`
  when it failed. Unknown post kinds are skipped and unknown fields ignored.
- `ConversationRow.Kind.post(ConversationPost)`. Every exhaustive switch over `Kind` gets the case: the list item's
  `kind`, the row view's content and alignment, and the test helpers. The cache stores raw history rows, so its
  format is unchanged.
- `ConversationPostSource`: `posts(since:) async throws -> [ConversationPost]` and
  `perform(_ action, on postId) async throws -> ConversationPost`. `HermesConversationPosts` implements it on
  `HermesAPI.raw` with `profile=default`.
- `ConversationEngine` takes an optional post source. It fetches posts on attach and with every history refresh and
  keeps the newest 60, sorted once. A failed fetch keeps the last posts and never sets `problem`.
- `compose()` merges them in one pass: a post goes after the last shown stored row whose timestamp is at or before
  its time (a row without a timestamp takes the previous row's). A post older than the first row shows at the top
  only when the window reaches the oldest end. A post newer than every stored row goes after the stored rows and
  before the live tail, when the window touches the newest end. Others are outside the window. Row id `post:<id>`.
- `perform(_ action: ConversationPostAction, on postId:)`: `turnOn` or `keepOff`. While it runs the post shows the
  action as pending; the answer replaces the post; a failure keeps the post with a `problem`. A lost answer is never
  repeated; the next fetch tells.
- `PrivateDetails.segments(of:) -> [Segment]` marks the personal parts of a text: email addresses, phone numbers,
  paths under a home folder (`/Users/<name>/…`, `~/…`), URLs, IP addresses, long numbers, and `[hidden]`. Pure.

### Which chat gets posts

Only the default bot's main chat. `ChatRoute` gets `isMain`, set when the app opens the main chat. The live view
gives the engine a post source when the profile is `default` and the route is the main chat, or its stored id is the
default bot's canonical main chat.

### The view

On the new chat view (`Apps/Nollie/Conversation/`), list item kinds `nightShift` and `rehearsal`, added to
`ConversationListItem.kinds`.

- **Night shift card.** Title "Night shift" and the window ("Since 7:02 yesterday"). One line of counts ("2 runs ·
  5 actions · 1 stopped"). Then each run: the bot's face, its title, outcome and time, and its actions, each as the
  tool's short verb ("Ran", "Wrote", "Searched", "Looked at"), the target in code type, and the receipt words under
  it. A run shows its first three actions; "Show all" shows the rest. A round glass Share button in the corner.
- **Rehearsal card.** Title "Rehearsal", the schedule's title and bot. "Would have" with the held actions, "Looked
  at" with the rest, then the reply it would have sent, quoted. Buttons: Turn on (ink pill) and Keep off (outline
  pill). After a tap: "On. It runs for real from now on." or "Kept off." A changed schedule: "It changed since. It
  will rehearse again." A check card says why it can't rehearse ("This runs a script before Nollie can watch.",
  "This runs once.") and shows the prompt.
- **Why?** Each action, on the morning card and in a rehearsal's report, has a small glass Why? beside it. It opens,
  in place, who did it and for what ("Scout did this during your schedule “Morning prices”."), the fixed rule in
  plain words ("It matches “pg_dump” on your allowed list, so it runs without asking.", "You chose Always for
  “git push” on 17 Oct at 14:02") or what stopped it, and for a stop or a hold what the person can do. Times are
  in the person's own format. An action with no receipt says "Nollie didn't keep the reason for this one."; nothing
  is guessed. Words: `NightShiftWhy`. The screen keeps which are open, with the runs shown whole, as
  `<post id>/why:<run>#<index>` (`.why(key)` beside `.showAll`).
- **Taps.** Cells are recycled and measured in bare hosts, so cards hold no state and read nothing from the
  environment but Ink and AppStorage. A second closure beside `answer`, `post: (ConversationPost, ConversationPostTap)
  -> Void` with `.turnOn`, `.keepOff`, `.share` and `.showAll(run)`, goes through `ConversationItemView`, both lists'
  coordinators and `ConversationScreen`. The screen owns the share sheet (`.sheet(item:)`) and the set of expanded
  runs, which it passes into the list items so the list measures a card again when it grows.
- **Share.** A sheet with the picture that will be shared, then "Share" (`ShareLink` with the PNG). The picture is
  its own view, `NightShiftShareView`: solid Ink fills, no glass, no pill styles, no menus, `BotAvatar(drawn: true)`,
  390 points wide, rendered by `ImageRenderer` at the screen's scale and a fixed text size. Every personal part of a
  target or title is drawn as placeholder marks of the same length under a blur, so the picture never holds the
  words. Bot names, receipt words, times and counts stay clear. Nothing leaves the device until the person picks
  where.
- Accessibility ids: `post.nightShift`, `post.nightShift.share`, `post.nightShift.showAll.<run>`, `post.rehearsal`,
  `post.rehearsal.turnOn`, `post.rehearsal.keepOff`, `post.rehearsal.done`, `share.preview`, `share.send`. Each action
  reads to VoiceOver as one sentence: verb, target, receipt.

### Words

Plain and short. No em dashes. "Held for you", never "simulated". The card never claims a held action ran, or that
an allowed action was safe.

## Mock gateway

`Tools/mock-gateway/mock_gateway.py` serves `GET /api/plugins/nollie-workflow/posts` (403 for other profiles) and
the two POSTs, through its own handler beside `crew_rest`, before the catch-all. The fixture is small: a night shift
post with two runs and five actions (one `always`, one stopped at the Mac), and a rehearsal post with one held and one
looked action. The Mac slept for part of that night: the morning brief waited until it woke and an hourly
check missed three times, and `GET /api/plugins/nollie-workflow/sleep` answers that gap and the one the Schedules
fixture's morning brief waited for. `POST /api/_mock/night-shift` resets both and stamps them one and two seconds after the newest row of
the default main chat, so they land at its end; UI tests call it before each launch. With `{"changed": true}` the
rehearsal's schedule counts as edited since, so Turn on answers 409 with the card in state `changed`. Taps answer as
the add-on does: a refused one is a 409 whose body is the card itself. Neutral names only, no private bot.

## Tests

- Python, `Companions/nollie-workflow/tests`: receipt classification for every kind (faked Hermes predicates),
  scrubbing (vault secrets, tokens, query strings, a raising redactor), unattended detection, attended calls touching
  nothing, the Mac and add-on-folder blocks, the guard failing closed only where it should, the recorder never
  blocking (raising checks, a full queue), rehearsal decisions (on, changed, follow-through binding, damaged registry
  with and without a good copy), the look-only list (browser_console with an expression, a URL with a query), the
  reply silenced, the sweep (waiting with delivery saved, check jobs paused, unwatched profiles, a finished rehearsal
  posted and paused, an unfinished one), Turn on and Keep off (match, changed, wrong state, delivery restored), the
  signature (each field, the script's contents), the morning card (window, quiet night, caps, private bots left out,
  Board outcomes, a gated run), post store bounds, the routes (403, 404, 409), settings (missing, damaged), the
  installer (recorder into followed profiles only, never private).
- Python, `Tools/mock-gateway/test_night_shift.py`: the routes, reset, stamping, the profile check, and the mock
  against the real add-on: the cards' shape from its builders, and the same answers to the same taps on its routes.
- Swift, `Tests/Unit`: post decoding, placement in `compose()` (every rule above), actions (pending, done, failed,
  changed), `PrivateDetails`, list item kinds, the Link door rules, the share view replacing every personal token.
- UI, `Tests/UI/NightShiftUITests.swift` (golden, in `Tools/dev/verify.py`): resets the mock, opens the default main
  chat on the new view, finds the night shift card, the share preview and the rehearsal card in light and dark, then
  Turn on.

## Turning it on for Corey

Both features ship off. With Corey's yes, and after a backup, on the Mac that runs Hermes:

```bash
python3 Companions/nollie-workflow/install.py --apply --recorder
python3 ~/.hermes/plugins/nollie-workflow/control.py night-shift on
python3 ~/.hermes/plugins/nollie-workflow/control.py rehearsals on
```

`--recorder` copies the add-on into each followed profile's `plugins/` and enables it there. Every copy records,
guards and keeps a Papertrail (1.2; before, a copy not named in `--papertrail-bots` held a `recorder-only` marker and
kept Papertrail off, and that marker is now ignored and dropped on the next update). Then restart the gateway
while idle. Not done in this change.

## Known gaps

- A job created by the dashboard or the crew that fails within seconds, before the sweep sets its delivery to
  `local`, can still send a one-line failure notice.
- Run now with extra words (`manual_run_prompt`) adds instructions to an `on` job's run without changing its
  signature.
- Adding an MCP server to a profile widens what its `on` jobs can use without a new rehearsal (config changes are the
  person's own).
- A terminal command can still write the add-on's files if it doesn't name the folder.
- Profiles the crew creates later get no recorder until the installer runs again; the card names them as not
  watched and their new jobs stay paused.

## Later

- The same cards on the old chat view, so Release builds show them.
- A rehearsal line and Turn on in the schedule's page (Schedules), for people who never open the main chat.
- The crew installs the recorder when it creates a profile.
- A quiet push when the card is ready.
