# Nollie's crew

A Hermes add-on that lets Nollie, the main assistant (the `default` profile), run a crew.
When ongoing work needs a specialist, Nollie adds a permanent crew member itself. Each member
is an ordinary Hermes profile with its own persona (`SOUL.md`), a role, a one or two sentence
"come to me for" line (the profile description, which Nollie reads when routing work), an
optional schedule, and tools that never go beyond Nollie's own.

Hermes already has profile create, edit and delete, schedules, the Board and `delegate_task`
for short-lived helpers. It has no tool for an agent to create a permanent bot; this is it.

## Tools

Only the `default` profile registers them, and every call checks the caller again through
Hermes's own context (`current_profile_name`). Calls from any other profile return
`Only Nollie can manage the crew.` Changes are also refused from delegated helpers and from
scheduled runs; a scheduled run may still make a suggestion.

| Tool | What it does |
| :--- | :--- |
| `crew_add(name, role, come_to_me_for, asked_by_person, schedule?, toolsets?, model_route?)` | Adds a member, or makes a suggestion |
| `crew_list()` | Members, roles, "come to me for" lines, status, room left, the open suggestion and the names of other bots |
| `crew_update(name, new_name?, role?, come_to_me_for?, schedule?, clear_schedule?, toolsets?, model_route?)` | Changes a member |
| `crew_pause(name)`, `crew_resume(name)` | Parks the member in Hermes and holds its schedule |
| `crew_retire(name, confirm?)` | Without `confirm: true` returns `needs_confirmation` and a question |
| `crew_undo(token)` | Reverses an add, update, pause, resume or retire |
| `crew_not_now(suggestion)` | Records the person's "Not now" said in the chat |

Every result is JSON with `ok`. Successful changes carry `status`, a `note` to show in the chat
as it is, `changes`, an `undo` token and `actions` for the app:

```json
{"ok": true, "status": "added", "profile": "scout", "name": "Scout",
 "note": "I've added Scout to check new roles each morning.",
 "changes": ["Added Scout to the crew", "Tools: file, web", "Model: local, on this Mac"],
 "undo": "<token>",
 "actions": [{"id": "meet", "label": "Meet", "profile": "scout", "name": "Scout"},
             {"id": "undo", "label": "Undo", "token": "<token>"}]}
```

Other statuses: `suggestion`, `suggestion_waiting`, `declined_before`, `needs_approval`,
`needs_confirmation`, `full`, `updated`, `paused`, `active`, `retired`, `removed`, `restored`,
`not_now`.

## Rules

- **The person asked, or it's Nollie's idea.** With `asked_by_person: true` the member is added
  and the result has the note with Meet and Undo. Otherwise nothing is created: the result is a
  suggestion (`"Want me to add Scout to check new roles each morning?"`) with Add and Not now.
  One suggestion is open at a time. Not now is remembered by profile id and by the role's words,
  so the same idea, even reworded, comes back as `declined_before`. The person can still ask for
  it themselves. A missing `asked_by_person` counts as Nollie's idea.
- **The person's OK.** Using the Mac (`computer_use`, a Cua MCP server), the online plan
  (`model_route: "plan"`), connections (`connections`, any other MCP server), a schedule Nollie
  picked (`asked_by_person: false` in the schedule, or `cronjob`) and anything that messages
  other people (`send_message`, Discord, other platform toolsets) need the person. The add-on's
  `pre_tool_call` hook sends these requests to Hermes's own approval prompt, which the app
  already shows as an approval card. Hermes reports the person's answer through
  `post_approval_response`; only a recorded "once", "session" or "always" for those exact
  details lets the tool through, within 20 minutes, for one change. Without it the tool returns
  `needs_approval` and changes nothing, so a missed hook fails closed. With no person present
  (`-q`, cron) Hermes blocks the call. The approval key is unique to the request, so "always"
  never covers a different request. An update asks only for reach the member doesn't already
  have. With approvals set to off the tools stay at `needs_approval`.
- **Never more than Nollie.** Requested toolsets must be ones Nollie has and hasn't switched off;
  the crew tools themselves and app-only toolsets are never granted. The member's config lists
  its toolsets explicitly for every platform Hermes knows, each limited to what Nollie has on
  that platform, so no platform default grants more. It copies Nollie's behaviour settings and
  approval rules (the same deny list, mode `smart` or `manual`, and `deny` for unattended,
  scheduled and single-query runs), with no standing approvals (`command_allowlist: []`). It
  never copies messaging channels, plan sign-ins, secrets, the subscription block, auxiliary
  model pins or connections the person didn't agree to. External logins are never borrowed.
  The plan route is only offered when Nollie itself uses a plan. A final check refuses to write
  any config that reaches past Nollie's current one.
- **Models.** The crew runs locally by default: the model recorded with
  `install.py --local-model`, else Nollie's own model when it is local, else Hermes's
  managed `llamacpp` runtime. The plan route copies Nollie's model choice only; Hermes doesn't
  copy plan sign-ins into new profiles, so how a member signs in to a plan is still an open
  design decision.
- **Cap.** At most 8 members (active or paused) created by this add-on. Bots made by hand are
  not counted. A retired member stops counting; bringing one back needs room.
- **Only its own members.** A member is changed only when the add-on's record and the
  `nollie-crew.json` marker inside its profile agree. Other profiles are only read for their names,
  to avoid clashes. The `private` profile (Moss) is never opened: not even its display name is
  read, and `Moss`, `Nollie` and Hermes's reserved names can't be used.
- **Retire and Undo.** Retiring saves a Hermes export of the member (chats included, credentials
  excluded) in `~/.hermes/nollie-crew/archives/`, then deletes the profile with Hermes's own delete.
  Undo of a retire imports it back. Undo of an add takes the same path, so nothing is lost.
  Undo of an update restores the files and schedule from before. Tokens work once; the latest
  64 are kept.
- **Pause.** Writes Hermes's `gateway.parked` marker, asks the running host to stop serving the
  member, and pauses its schedule. Resume reverses all three.

## The app's buttons

The authenticated dashboard namespace (default profile only, `403` otherwise) takes the
person's taps. These answers come from the app, never from a model.

- `GET /api/plugins/nollie-crew/crew`: the same as `crew_list`.
- `POST /api/plugins/nollie-crew/suggestions/<id>` with `{"answer": "add"}` or
  `{"answer": "not_now"}`. The suggestion card names everything the member would use, so the
  Add tap is the person's yes to exactly that.
- `POST /api/plugins/nollie-crew/members` with `{"name", "role", "come_to_me_for", "instructions",
  "toolsets"}`: a ready-made helper the person picked in the app's gallery. It is added at once, as
  if the person had asked, with the same result (note, Meet and Undo). Its instructions go in its
  `SOUL.md` under "What you do", above the fixed rules, and are refused if they would skip asking
  first ("buy it without asking", "assume a yes"). Its toolsets are kept to ones Nollie has that need
  no further yes; anything else (the Mac, connections, schedules, messages) is left out, never asked
  for, and an empty list falls back to the safe default. It runs on the crew's local model.
- `POST /api/plugins/nollie-crew/undo` with `{"token": "<token>"}`.

Answered or stale requests, and refused ready-made helpers, return `409` with `ok: false`.

## Handoffs

`handoffs.py` holds the limits for work passed between bots, with its own tests:

- `check_handoff(chain, to)`: at most two levels (person, Nollie, one member, one more) and no
  loops back to any bot already in the chain.
- `Conversations(root).bot_message(conversation)`: counts bot-to-bot messages since the person
  last spoke and pauses at 12 with a question for the person. `person_spoke()` resets it.
  `handoff()` does both.

Hermes has no single handoff hook yet, so these are not wired in. The places to call them are:
a `pre_tool_call` hook on the Board tools that assign a card to a crew member and on
`cronjob` deliveries to `bot-chat:<member>` (check the chain, count the message, block with the
question when paused), and `pre_gateway_dispatch` for bot-authored messages, which Hermes
already budgets separately with `gateway.bot_loop_guard`. The chain itself has to travel with
the work (for example in the card's metadata), which needs app and Board support.

## Install

```sh
python3 Companions/nollie-crew/install.py
python3 Companions/nollie-crew/install.py --apply --enable --local-model llamacpp:<model>
```

The first command prints the plan. `--apply` copies the add-on to `~/.hermes/plugins/nollie-crew`
(a previous copy moves to `~/.hermes/plugin-backups/nollie-crew-<date>`). `--enable` backs up
`~/.hermes/config.yaml` beside itself with a dated suffix, then runs
`hermes --profile default plugins enable nollie-crew`. `--local-model` records the crew's
local model in `~/.hermes/nollie-crew/settings.json` (backed up first). No profile is created and
no service restarts. Rollback: `hermes --profile default plugins disable nollie-crew`, then
restore the saved copy if needed. Keep `~/.hermes/nollie-crew/` (the record, archives and
settings): without it the add-on no longer recognises its members and leaves them alone.

## Tests

```sh
cd Companions/nollie-crew/tests && python3 -m unittest discover -p 'test*.py' -v
```

The unit suites use a temporary Hermes home with fixture bots and need nothing from Hermes.
Under Hermes's own Python they also run the dashboard routes, a run of every lifecycle step
against Hermes's real profile and cron code, and one scripted conversation in real Hermes
processes using Hermes's offline scripted model (`tests/fakes/fake_llm_provider.py`): Nollie
adds a member, retires it after the confirmation question, and a request that needs the Mac
is blocked by Hermes's approval prompt with no person present. Everything runs with a
temporary `HOME` and `HERMES_HOME`; nothing touches the live Hermes.

```sh
cd Companions/nollie-crew/tests && \
PYTHONPATH=$HOME/.hermes/hermes-agent:<Hermes dependency site-packages> \
  $HOME/.hermes/tools/python-<version>/bin/python3 -m unittest discover -p 'test*.py' -v
```

The site-packages folder is the `venv` named in `~/.hermes/installs/<id>/facts.json`.
