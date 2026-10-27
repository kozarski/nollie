# Papertrail

[← Architecture](../architecture.md)

Status: written before the code (20 Oct 2026); the door added in 1.2 (27 Oct). Papertrail is the per-bot record of
what left your Mac.

## Purpose

Papertrail shows, for each bot, every reply or background job that sent something off this Mac: when, which route,
roughly how much, and every place it connected to. Replies that stayed on this Mac are counted, not listed. It lives in
Bot settings, and Settings sums it up across bots.

It has two sources, both writing the same day files:

- the workflow add-on's Hermes hooks: model and helper calls (with tokens), searches, pages, pictures, payments and
  the person's answers (why it went);
- Nollie Runtime's door (1.2): one line per connection that Hermes, or any program it starts, makes through it, with
  the host, port, time and kind of program. See [The door](#the-door-nollie-runtime).

Out of scope for now: costs in money, the plan meter itself, history from before Papertrail was turned on,
and anything the private bots do (they never record).

## What Hermes already keeps, and why it is not enough

Read from Hermes Agent v0.22.0 source (no database opened).

- `messages` rows have no model, provider, base URL or usage. Tool rows (`role='tool'`, `tool_name`) carry a
  timestamp but say nothing about which backend served the call.
- `session_model_usage` keeps one summed row per (session, model, billing_provider, billing_base_url,
  billing_mode, task), with `first_seen` and `last_seen`. No single call is kept, and the rows cascade away
  when a chat is deleted or pruned.
- A response with no usage block (common on local servers) is not stored at all (`agent/turn_usage.py`).
- The dashboard's `/api/analytics/usage` files usage under the day a session started and has no provider
  split; `/api/analytics/models` has no base URL and no per-day split. No route answers "this bot, these
  routes, these times".
- Hermes's `is_local_endpoint` counts LAN and Tailscale hosts as local. That is wider than "this Mac".

Plugin hooks do see every call, with the live route (fallbacks included):

| Hook | Fires | Kwargs Papertrail reads |
| :--- | :--- | :--- |
| `post_api_request` | each successful main-loop model call | `session_id, turn_id, api_request_id, model, provider, base_url, ended_at, usage` |
| `api_request_error` | each failed main-loop call (the request still went out) | `session_id, turn_id, api_request_id, model, provider, base_url, ended_at` |
| `post_auxiliary_call` | each attempt of a helper call (titles, compression, vision, approval, ...) | `session_id, turn_id, api_request_id, aux_task, model, provider, base_url, ended_at, usage, error` |
| `post_tool_call` | each tool call | `session_id, turn_id, tool_name, args, result, status` |
| `post_approval_response` | each answer to an approval question | `turn_id, session_id, choice, pattern_key(s)` |

`usage` (when present) has `input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
reasoning_tokens`. Hooks are delivered per bot home (the plugin manager is keyed by `HERMES_HOME`), so a
recorder installed in a bot's home hears only that bot, including cron, gateway turns and subagents.

So Papertrail records from hooks, in Nollie's own add-on. Hermes is not patched.

## Corey's setup today

All four public bots (Nollie, Scout, Mason, Forager) use provider `claude-subscription-directsdk-experimental`,
whose base URL is `process://claude-subscription-directsdk-experimental`: a local process that talks to the
Claude plan online. Its `api_mode` is `chat_completions`, so `post_api_request` fires with usage. Web search
is Exa (`web.search_backend: exa`); pages are read by nollie-reader straight from the sites. This is why
routes are decided by provider and host together, never by "is the URL on this machine" alone.

## Route rule

`route(provider, base_url)` gives one of three answers:

- `mac` (On this Mac): the host is loopback (`localhost`, `127.0.0.0/8`, `::1`, `0.0.0.0`), or the provider
  is a local runtime (`llamacpp`, `llama.cpp`, `llama-cpp`, `ollama`, `lmstudio`, `lm-studio`, `mlx`,
  `local`) and the URL is empty or a `process://`, `unix://` or `file://` address.
- `network` (Your network): the host is RFC 1918, link-local, CGNAT `100.64.0.0/10` (Tailscale), IPv6
  `fc00::/7` or `fe80::/10`, ends in `.local`, or has no dot. It left this Mac, so it is listed.
- `online`: everything else, including any non-HTTP scheme (`process://`) whose provider is not a local
  runtime, any other scheme without a host, and an empty URL with any other provider.

When unsure, Papertrail says it left. Hiding a call is worse than over-reporting one.

Tools: `web_search` and `x_search` count as searches; `web_extract` counts its URLs as pages (at most 5, as
Hermes reads no more; none when `urls` is not a list) and
`browser_navigate` counts one page; `image_generate` counts one picture. These always count as online.
Searches answered from Hermes's 20-minute search memo are still counted, so search counts can run a little
high. Calls with `status` `blocked` are not counted (nothing was sent).
The Mac's calendar, reminders and contacts tools (`calendar_events`, `calendar_search`, `reminder_lists`,
`reminders_open`, `contacts_search`) are recorded as route `mac`: a read that stayed on this Mac. An entry
that left lists them in `local_reads` (`["calendar"]`), and the row says "read your calendar".

## Recording (Companions/nollie-workflow)

- `papertrail.py`: the route rule, the recorder and the reader. No Hermes imports at module level.
- `register(ctx)` (`__init__.py`): for any bot whose name is not private (`private`, `moss` or a saved private
  name), register the four hooks above with the bot's home taken at register time. The board service and
  follow-up tool stay default-only, as today.
- Every bot that is not private records, crew bots included, from the moment they are made (1.2). The managed setup
  and the crew add-on copy the add-on into each bot without the old `recorder-only` marker, an update drops a marker
  an older Nollie left, and the add-on no longer honours one.
- `install.py --papertrail-bots career,nowhere,forager` (default is always included) also copies the add-on
  into each named bot's `<home>/plugins/nollie-workflow` and, with `--enable`, enables it there. Private
  names are refused. A bot that has the copy but no `state.json` still records Papertrail; only the default
  bot runs the board service.

Storage, per bot: `<home>/nollie-workflow/papertrail/<YYYY-MM-DD>.jsonl` (Mac local date), mode 0600, folder
0700, symlinks refused. One line per call, appended under `fcntl.flock` on `papertrail.lock`:

```json
{"v":1,"at":1760970000.5,"route":"online","source":"model","provider":"claude-subscription-directsdk-experimental",
 "host":null,"model":"claude-sonnet-5-5","task":"","tool":"","turn":"t-42","session":"20261020_...",
 "in":1200,"out":340,"cache":9000,"think":0,"searches":0,"pages":0,"images":0}
```

- `source` is `model` (main loop), `helper` (auxiliary, `task` names it), `tool` (`tool` names it) or `approval`.
- Why it went (1.1), from Hermes's run context with no file read: `origin` (`chat`, `schedule`, `board`, `helper`
  for a schedule's helper), `job` or `board` (ids only), `platform` (the chat app, when Hermes says), and on model
  calls `messages` (Hermes's `message_count`) and `backup` (the provider is one of the bot's `fallback_providers`,
  not its main one). An `approval` line keeps a person's answer in a turn: `choice` (`once`, `session`, `always`,
  `deny`) and `ask` (what Ask first asked about, from its rule key). Timeouts, withdrawn questions and answers
  outside a turn are not kept. Older readers skip `approval` lines by their source.
- `host` is `scheme://host[:port]` for HTTP(S) URLs only, never a path, query or credentials; `null` otherwise.
- No words are kept: no prompts, replies, queries, URLs or arguments. Only when, where and how much.
- Lines older than 35 days are removed: on the first write of each day, files older than 35 days are deleted.
- The recorder never raises into Hermes and never blocks a call. A hook only builds its line and hands it to
  one writer thread, which takes the lock and appends (Hermes skips a hook callback whose earlier call for
  the same turn is still running, so hooks must return at once). At most 5,000 lines queue; at exit Python
  waits up to 3 s for the rest. Any failure is noted by exception type only in `papertrail/last_error`.
- The Private list is checked again before every line (cached on the file's mtime, size and inode), so a bot
  marked Private while Hermes runs stops recording at once. A damaged or linked list writes nothing.
- For search lines, `provider` holds the search service (`web.search_backend`, else `web.backend`; `xai`
  for `x_search`). Only searches, page reads and pictures are recorded from `post_tool_call`.
- The folder is created when the add-on loads in a bot, so the route stops answering "not on" before the
  first call.

## Reading: `GET /api/plugins/nollie-workflow/papertrail?bot=<name>&days=<1-35>`

Served in the default scope like the other workflow routes (a request with `?profile=` other than default is
refused with 403 by `home()`). `bot` defaults to `default`; `days` defaults to 7.

- 403 `"Papertrail is not kept for private bots."` when `bot` is private (saved list or carried-over names).
- 404 `"No such bot."` for an unknown bot; 422 for a malformed name or days.
- 404 `"Papertrail is not on for this bot."` when the bot has no `papertrail` folder yet.
- Responses carry `Cache-Control: no-store`.

Calls are grouped into entries: one entry per `turn` (calls without a turn group by session, route and
10-minute window). An entry whose calls all stayed on this Mac and used no online tools is counted as a local
reply, not listed. Everything else is listed.

```json
{
  "bot": "career",
  "days": 7,
  "now": 1760970000,
  "today_starts_at": 1760914800,
  "tomorrow_starts_at": 1761001200,
  "since": 1760396400,
  "recording_since": 1760396400,
  "stayed": {"today": 12, "window": 40},
  "left": {"today": 3, "window": 9},
  "entries": [
    {"id": "t-42", "at": 1760969000, "started_at": 1760968900, "route": "online",
     "provider": "claude-subscription-directsdk-experimental", "provider_name": null, "host": null,
     "model": "claude-sonnet-5-5", "calls": 6, "helpers": ["title_generation"], "services": ["exa"],
     "input_tokens": 18000, "output_tokens": 900, "cache_read_tokens": 52000, "reasoning_tokens": 0,
     "searches": 2, "pages": 3, "images": 0}
  ],
  "more": 0
}
```

- `why` (1.1, absent on entries recorded before): `{"origin", "task", "platform", "messages", "backup",
  "approvals": [{"at", "choice", "ask"}]}`. `task` is the schedule's or Board task's name, read when the week is
  asked for (`<bot home>/cron`, the Board outcome log), never kept in the record; a name that holds a private
  bot's is left out. An entry made only of answers is neither listed nor counted.
- `tomorrow_starts_at` is the Mac's next local midnight (not always 24 hours later, on clock-change days).
- `since` is the start of the window (local midnight, `days - 1` days before today). `today_starts_at` is
  today's local midnight on the Mac, so the app splits Today from the rest without guessing time zones.
- `recording_since` is the start of the oldest day file, or `null`.
- `stayed` and `left` count entries; `today` is the part since `today_starts_at`.
- `entries` are newest first, at most 200; `more` counts the rest. `route` is `online` when any part went
  online, else `network`. `provider`, `host` and `model` are the entry's largest online model route by tokens,
  or its largest network route when nothing went online (null when only tools went online). Token counts,
  `calls` and `helpers` count only the calls that left this Mac. `provider_name` is Hermes's display name for the provider when it resolves.
  `services` lists search backends used (from the bot's `web.search_backend`, else `web.backend`).

The Link door allows `GET /api/plugins/nollie-workflow/papertrail`.

## The screen (Bot settings, Papertrail tab)

A tab `Papertrail` after Model, hidden for private bots.

- Top: two glass capsules side by side (stacked at accessibility text sizes): the count of replies that
  stayed **On this Mac** and the count that went **Online**, this week. Big number, one short label each.
  Replies that only reached your network are listed but sit in neither capsule.
- Then a quiet native list in two sections, **Today** and **Earlier this week**. Each row: the route
  ("Claude plan", "OpenRouter", "Your network", "Exa" when only a search left), the amount ("19k tokens ·
  2 searches · 3 pages") and the time ("14:32", or "Mon 09:12"). Developer Mode adds the model and host.
- Each row has a small glass Why? that opens, in place, what started it ("Scout was running your schedule
  “Morning brief”."), why it went where it went (the bot's online model, its backup, your network, a web search),
  the person's own answers ("You said yes to sending at 14:02."), then "What went:" in sizes and kinds only.
  An entry from before 1.1 says "Nollie didn't keep the reason for this one." Words: `Papertrail.Entry.why(bot:)`.
  The device that answered is not recorded yet: Hermes's approval hook does not say, so the words leave it out.
- Nothing listed this week: "All quiet", "Nothing seen leaving all week." Every "nothing" is said as what
  Papertrail saw ("Nothing seen leaving today"), because it can't see a program that ignores the door while the
  network filter is off.
- Add-on missing or not on (404): one row, "Papertrail isn't on for this bot yet."
- Load failure: "Couldn't load Papertrail." in the sheet's status line. A 403 means a private bot only when
  its message says so; the Link door's own 403 is a load failure.
- The tab reads again when the gateway changes and just after the Mac's next midnight.

Route labels live in NollieCore: known provider ids get short names (Claude plan, ChatGPT plan, Anthropic,
OpenAI, OpenRouter, Nous Portal, Google, xAI, Exa, ...); otherwise `provider_name`, then the host, then
"Online". Amounts count input plus output tokens and round: under 1,000 as is, then `1.2k`, `18k`, `1.4M`.

## Mock gateway

`Tools/mock-gateway/mock_gateway.py` serves the same route from seeded data for `default` and `work`
(a busy week with today and earlier rows, a network row, a search-only row), 404 for a bot with Papertrail
off, 403 for private names. Seeded provider strings must read well after `--neutral-models`.

## The door (Nollie Runtime)

`Services/Runtime/PapertrailDoor.swift` (the proxy) and `PapertrailDoorBook.swift` (the lines). Built for the managed
setup the Direct Mac app runs; a Hermes you run yourself has no door.

- **Where it listens.** 127.0.0.1, a free port chosen at each start, loopback clients only. A fresh 64-hex secret per
  run. Hermes does not start without it (`NativeRuntimeBackend.prepare`).
- **How Hermes is pointed at it.** Both children get `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` and their lowercase
  twins set to `http://unplaced.program:<secret>@127.0.0.1:<port>`, `NO_PROXY=localhost,127.0.0.1,::1` and
  `NODE_USE_ENV_PROXY=1` (`RuntimeContract.Door.environment`).
- **Labels.** `runtime_entry.py` (`_label_door`), before Hermes is imported, swaps the user name for `<bot>.<kind>`:
  for Hermes's own requests (`urllib.request.getproxies_environment`, which requests, httpx, aiohttp and urllib all
  read) the bot is the Hermes home of the work in hand and the kind `hermes`; for every child started through
  `subprocess` (terminal, code, MCP servers, the reader's helper, a model's own program) the bot is the same and the
  kind comes from the Hermes module that started it: `terminal`, `code`, `mcp`, `reader`, `model`, else `program`.
  The proxy variables are put back into a child's environment when Hermes left them out (it gives MCP servers only a
  few variables). A proxy a program chose itself is left alone.
- **What it speaks.** `CONNECT host:port` and plain `http://` requests, read with the exit relay's strict parser.
  No secret, or the wrong one: 407, nothing passed, nothing written. Bytes pass through unread.
- **What it writes.** Before connecting, one line in the bot's own Papertrail, under the add-on's lock:
  `{"v":1,"at":…,"route":"online|network","source":"door","kind":"terminal","host":"github.com","port":443}`.
  Never a path, query, header or byte. Loopback is not a line. Nothing is written for a bot on the Private list (or
  `private`, `moss`), for any bot while the list can't be read, for a bot with no home, or for the `unplaced` label.
  The folder is made 0700 when missing (so every bot with a home is "on"), day files 0600, links refused, files over
  35 days old pruned.
- **Reading.** `papertrail.read` puts each door line into the reply whose own calls span its time (5 s either side;
  the latest-starting one when several do); the rest group by bot and hour. Entries gain `connections`:
  `[{"host","port","kind","route","count"}]`, most used first. `calls` still counts model and tool calls only. A
  reply that stayed on this Mac but whose terminal reached the internet is listed, not counted as stayed.
- **The screen.** A row named only by connections shows the place it reached most. Why? names who connected ("Scout
  ran a command that connected to github.com.") and "Connected to …" lists every place, up to six by name. Advanced
  lists every host.

## What Papertrail still can't see

Said plainly here, not hidden:

- **Programs that ignore proxy settings**, started by Hermes or not: SSH and anything over it (`git` with an SSH
  remote, `scp`, `rsync`), raw sockets, mail sent with `smtplib` or read with `imaplib` (Hermes's email platform),
  UDP and QUIC, and name lookups a program makes for itself. Node honours the variables only from versions that read
  `NODE_USE_ENV_PROXY`; older ones go direct. The network filter (below) is the answer to these; it is off.
- **Children started without `subprocess`** (`os.system`, `os.exec*`, `os.posix_spawn`) keep the `unplaced` label:
  the door passes them on and writes nothing, rather than guess at a private bot.
- **A connection made in a context with no bot**, or by an HTTP client one bot made and another reuses, is labelled
  with the bot whose home Hermes reports at that moment (the main bot outside any reply). A kept-alive connection is
  one line, however many requests it carries.
- **Not Hermes:** helpers' own computers (their traffic goes through the exit relay, which logs nothing), Nollie.app's
  own (iCloud alerts, update checks), remote images in cards, setup downloads.
- **A Hermes you run yourself** has the add-on's hooks but no door.
- Image providers billed per picture are counted as pictures, without tokens.

## The network filter (built, off)

See [Network filter](network-filter.md): a Network Extension content filter in the Direct edition that records any
connection from Hermes's process tree that did not come through the door, and can refuse it. Off until the developer
portal has the capability.

## Tests

- Python (`Companions/nollie-workflow/tests/test_papertrail.py`): route rule table; recorder writes one
  wordless line per call, refuses symlinks, survives a damaged file, prunes after 35 days; grouping, local
  counting and the 200 cap; the route's 403/404/422 answers and no-store header; `register` skips private
  bots; door lines join their reply or their hour and keep no words. When `NOLLIE_HERMES_PYTHON` is set, a
  throwaway Hermes home fires the real hooks.
- Door labels (`Tools/runtime-helper/test_runtime_entry.py`): requests and each kind of child carry the bot and kind,
  a program's own proxy is kept, nothing changes without the door.
- Swift (`Tests/Unit/PapertrailDoorTests.swift`, NollieMacTests): the route rule, labels, the private rule, one
  wordless 0600 line in a 0700 folder, nothing for private, loopback, missing or linked homes, pruning, and the door
  on loopback (tunnel, 407 without the secret, a line before an unreachable host, credentials never passed on).
  `RuntimeSupervisorTests` checks the proxy environment.
- Mock (`Tools/mock-gateway/test_papertrail.py`).
- Swift (`Tests/Unit/PapertrailTests.swift`): decoding, labels, amounts, Today split; the Link door rule.
- UI: `PapertrailUITests` (golden) opens the tab on the mock; `DesignShotsUITests` shoots it light and dark.
