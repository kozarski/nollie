# Nollie computer companion

Preview frames, and Take over and Hand back for a bot's computer, through the existing
authenticated Hermes gateway. See [Watch and take over](../../Docs/watch-and-take-over.md).

Read-only preview frames:

```text
GET /api/plugins/nollie-computer/preview?profile=default&session_id=<exact stored ID>[&fresh=1]
```

The response has `state` (`live`, `idle`, `paused` or `unavailable`), optional `computer_name`,
`kind` (`mac` or `space`), `target_source` (`session` or `owned`), `image_data_url`,
`captured_at` (Unix seconds), and `message`.
`live` means the frame was just captured. It does not mean a bot is using the computer.
Nollie's blue activity indicator comes from running computer tools in the chat.

`paused` means Nollie is typing a saved sign-in somewhere, or finished less than 10 seconds ago:
no image, no pointer, and the cached frame is dropped. It is read from the main home's
`nollie-workflow/sign-ins/requests/` before each capture and again after it, so a frame taken as a
sign-in began is never shown. Show nothing for that computer until the next `live` frame.
The pause holds for `fresh=1` too, and for a capture other callers share: one that lands after a
sign-in began reaches no one.

```text
GET /api/plugins/nollie-computer/paused
```

answers `{"paused": true|false}` by the same rule, failing closed (add-on 0.5). Nollie's live
picture of a window on this Mac asks it before capturing and twice a second while it does.

The companion reads only that profile's exact session through Hermes's ordinary read-only
session helpers. A paired successful computer-tool result establishes the target. A completed
`space_bash` call can also establish its exact qualified Space ID, independently of the command's
output. That selection does not count as computer activity in the app. A new
target without enough information invalidates the previous target. Private bots are
excluded (see [Private bots](#private-bots)). Prefix IDs, rotated IDs, archived chats, other owners, paths and remote addresses
cannot select a computer.

An explicit ownership record at `~/.hermes/nollie-computer/owned-spaces.json` can associate
a profile that is not private with its verified Space. It has version `1` and a `profiles` object mapping
profile names to qualified `local:name` or `cloud:name` IDs. No VM inventory is searched.
The owned computer is shown when the chat has no target or only a historical Mac target.
An unfinished Mac tool call in the latest turn conservatively retains the Mac identity.
A session Space takes precedence while it exists; only Cua's structured `not_found` lookup
allows fallback to the owned computer. Stopped, unauthorized, or temporarily unavailable
Spaces do not silently switch to another machine. The response identifies the actual Space
and its `owned` source. Mac control remains independent.

Live capture supports existing local and cloud Cua Spaces. An explicit target or a unique
bare name is checked with `sandbox_get`; it must resolve to the same named Space with status
`ready`. A qualified target must also keep its location. Then `computer_screenshot` captures
it. The child process has only `sandbox:get` and `computer:screenshot` permissions and
connects to the existing `~/.cua/cua.sock`. One child per Space stays open between frames
(add-on 0.4), so a frame is one `computer_screenshot` call. The lookup runs again every 30
seconds on the same child. It never creates, starts or resumes a VM, starts a daemon, changes
the globally selected computer, sends input, or updates a desktop lease. Direct, relay and
host Mac capture returns `unavailable`; a historical Mac reference can instead show the
separately identified owned Space as described above. Nollie can show an existing tool screenshot as
**Last screen** for them.

Cua may maintain the existing VM lease when attaching to a ready managed cloud Space.
That connection belongs to the existing daemon and can outlive the short preview process.
This is Cua's normal running-VM lease maintenance; the companion never creates a claim,
resumes a stopped VM, or grants computer-control permission.

Requests use `Cache-Control: no-store`. Frames stay in memory for at most 1.5 seconds for
coalescing; `fresh=1` skips that cache for a caller that wants each next frame. Either way,
at most one capture per Space is on the way at a time, and everyone asking meanwhile gets
the same frame. The Private list is checked again before each capture and before any frame
is handed out. Capture is limited to five seconds and four MiB of PNG data. A child is closed
after 15 seconds unused, on any failure, timeout or cancellation, when no chat shows its
Space any more, and when Hermes stops; at most four are open. Remote errors and stderr are
never returned. Cua resolves its own local credentials; none travel to Nollie.

The preview also carries `control` (`helper`, `you` or `someone`, read fresh from the bot's
desktop lease for each answer) and, when the chat's own tool calls name one, `pointer`
(`{x, y, at}`): the spot of the latest successful Cua click, double click, cursor move, mouse
down or up, or the end of a drag on the same computer, in the pixels of its screenshots.

## Take over and hand back

```text
POST /api/plugins/nollie-computer/take-over?profile=default
POST /api/plugins/nollie-computer/hand-back?profile=default
```

Both answer `{"control": "you" | "helper" | "someone"}`; a private, unknown or unreadable bot
gets the same `409`. They change only `<home>/bot-desktop/lease.json`, through Hermes's own
locked transition (`tools/bot_desktop/lease.py`), plus a small record of the earlier holder at
`<home>/bot-desktop/nollie-takeover.json`. Take over never evicts another person. Hand back
restores the earlier holder only while the lease is still Nollie's (`nollie-watch`, same
epoch); a bot that had no lease file gets the file removed again, under the same lock and checks.
Without a matching record it leaves Mac control off rather than granting more. Config,
approvals, tool lists and Nollie Computer are never touched.

While Nollie holds the lease, Hermes's own computer and browser tools refuse by Hermes's rule,
and this companion's `pre_tool_call` hook (`__init__.py`) refuses every `mcp__cua__` tool,
directly or through the one-tool bridge, so a Cua computer pauses too.

## A computer of its own

The same add-on serves one switch per helper (`dashboard/own_computer.py`):

```text
GET  /api/plugins/nollie-computer/own-computer?profile=work
POST /api/plugins/nollie-computer/own-computer {"profile": "work", "action": "on|off|reset|remove", "request_id": "<uuid>"}
```

Unlike the preview, these routes change things, for that profile only and only when asked: they
install Cua's MIT Hermes plugin at a pinned commit, set its settings and `terminal.backend`, and
create, reset or delete the helper's named local computer through Cua's CLI. Private bots are
refused. Reads talk only to an already running Cua daemon. See
[A computer of its own](../../Docs/helper-computers.md).

Every status also says `"internet"`: `null` without a Tailscale exit node on this Mac, `"relay"` while Nollie
Runtime's exit relay carries the computer's traffic, and `"exit_node"` otherwise (Apple's VM networking then
gets no internet, so the computer can't browse). The add-on asks Tailscale's command line for
`status --json`, or failing that checks whether the default route leaves on Tailscale's interface, at most
every 15 seconds. It only reads: it never changes Tailscale. The relay's state comes from the small file
Nollie Runtime writes (`NOLLIE_EXIT_RELAY`, else `~/Library/Application Support/Nollie/RuntimeService/exit-relay.json`):
version, state and port, nothing else. The app shows one card on the helper's Computer tab, only for `"exit_node"`.

Turning a computer on, and resetting it, points it at the relay once: one fixed script through Cua's MCP
server, in a child allowed only `spaces:space_bash`, that adds a login-shell snippet setting the usual proxy
variables while the relay answers (it runs whenever a computer does, exit node or not). Only the port is filled in. If it fails, the switch still works and the
card stays. See [A computer of its own](../../Docs/helper-computers.md).

## Installation

View the installation plan:

```sh
python3 Companions/nollie-computer/install.py
```

After approving this local Hermes change:

```sh
python3 Companions/nollie-computer/install.py --apply
```

The installer backs up `~/.hermes/config.yaml` beside the original with a dated suffix,
copies only the plugin files to `~/.hermes/plugins/nollie-computer`, backs up an existing copy,
and runs `hermes --profile default plugins enable nollie-computer`. Hermes owns the enable setting
and plugin reload. No dependencies are installed and no service is restarted. If a named
profile overrides the enabled-plugin list, enable this plugin in that profile using Hermes's
plugin controls too. Rollback begins with `hermes plugins disable nollie-computer`; the saved
copy can then be restored. Do not place a backup inside another discoverable plugin folder.

Installation and a real Space capture remain separate checks. The local tests use injected
sessions and MCP replies; they neither inspect personal chats nor capture a real computer.

To stage an update and record already verified ownership without any runtime reload:

```sh
python3 Companions/nollie-computer/install.py --apply --files-only --owned-space default=local:my-computer
```

Repeat `--owned-space` for another profile. The installer refuses a private profile. The installer preserves other ownership
entries, backs up an existing record, and writes it with user-only permissions outside the
replaceable plugin directory. It does not inspect or provision the named computers. Runtime
activation remains a separate coordinated step.

## Private bots

The preview refuses any bot on the Private list that nollie-workflow keeps in the main
bot's Hermes home: `nollie-private-bots.json` in the directory
`hermes_cli.profiles.get_profile_dir("default")` returns, holding
`{"version": 1, "profiles": ["scout"]}`. A refused bot gets the same `unavailable` answer
as an unknown chat, before its session is read. The list is read on every request, so a
change applies to the next preview.

Until the file exists, bots named `private` or `moss` count as private, a one-time
carry-over from older builds. Once a list is saved, only the list counts. A list that
cannot be read refuses every preview rather than allowing them. An owned Space is never
returned for a private bot, and the installer will not record one.

This companion is installed on its own, so `dashboard/private_bots.py` is its own copy of
nollie-workflow's reader. `tests/test_private_bots.py` checks that both copies answer alike.
nollie-workflow owns the routes that change the list (`GET` and `PUT
/api/plugins/nollie-workflow/private-bots`); this companion only reads it.

## Tests and demo

```sh
python3 -m unittest discover -s Companions/nollie-computer/tests -v
python3 -m unittest discover -s Tools/mock-gateway -p 'test_computer_preview.py' -v
```

The mock test needs the existing `websockets` package used by the demo gateway. Start the
gateway with `--computer-demo` to seed a real `mcp__cua__computer_screenshot` event and a
changing synthetic desktop. `POST /api/_mock/computer-preview` accepts `state` (`live`,
`idle`, `unavailable`, `stale`, `unsupported`), `active` (a tool-start or completion event),
`held` and `reset_log`. Take over and Hand back flip `held` and count `control_writes`. `GET` returns the state, frame count, request log and a counter of config or
desktop-lease write attempts. The fixture belongs to profile `default`, session
`20260921_154212_a1b2c3`. Stale frames carry a timestamp 30 seconds in the past.

## Protocol references

The installed Cua CLI help and the upstream sources establish the read-only calls and
explicit-daemon behavior:

- [MCP permissions and screenshot tool](https://github.com/trycua/cua/blob/main/libs/cua/crates/cua-cli/src/mcp.rs)
- [Explicit daemon connection](https://github.com/trycua/cua/blob/main/libs/cua/crates/cua-cli/src/lib.rs)
- [Local reconnect refuses a stopped VM](https://github.com/trycua/cua/blob/main/libs/cua/crates/cua-sandbox-core/src/sandbox.rs)

No Cua implementation code is copied into this plugin.
