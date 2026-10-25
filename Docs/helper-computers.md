# A computer of its own

[← Nollie](../README.md) · [Nollie Computer](nollie-computer.md) · [Notices](legal/notices.md)

Each helper (Hermes profile) can work on its own computer inside the Mac: a named local Linux
computer made by Cua. Its commands, files and code run there instead of on the Mac, so the person's
files stay out of reach. One switch per helper in Bot settings, Computer tab. Off by default.
Never offered for a private bot.

## What people see

- **The switch:** "A computer of its own", with one line under it.
- **Guided setup** when Cua is missing, old, not running, or can't run computers yet. One step at a
  time, never a terminal. On the Mac the step offers **Set up Cua** (or Update, Start, Finish). The
  iPhone says plainly to open Nollie on the Mac.
- **Setting up Cua:** one progress line (Downloading, Checking, Installing, Starting, Getting ready).
  If it fails, the reason in plain words, **Get Cua** (Cua's download page) and **Try again**.
- **Getting ready:** "Getting <Name>'s computer ready. The first time takes a few minutes."
- **The card:** Ready, Working, Asleep or Needs you; **Watch** (the existing live preview),
  **Reset computer** (asks first), and the computer's name behind the ⓘ button.
- **Off:** the helper's terminal goes back to what it was. Its computer is kept; **Remove its
  computer** erases it, after asking.
- **Mac setup:** the Computer step is one toggle, "Give your helpers their own computers". It sets up
  Cua and turns on the main helper's computer. Set up later stays available.

Working means a command, file or code tool is running for that helper right now.

**The relay, for exit nodes.** While the Mac sends everything through a Tailscale exit node, Apple's VM
networking gives the computers no internet at all (seen on 14 Oct 2026 with Tart, Lume and Cua). So whenever
a helper's computer runs, Nollie Runtime runs a small relay that only the computers can reach, and their web
traffic leaves from the Mac like any other app's, through its VPN or exit node when one is on. It runs with
or without an exit node, so one turned on mid-task just works. Help line: "Your helpers' computers use your
Mac's connection, including your VPN." Nothing asks the person. Rules and limits:
[Nollie Runtime](../Services/Runtime/README.md#exit-relay-for-helpers-computers).

Each computer is pointed at the relay once, when it is made or reset: the add-on runs one fixed script
through Cua's MCP server (`space_bash`) that puts a login-shell snippet in `/etc/profile.d` (or the
computer user's own profile). The snippet sets `http_proxy`, `https_proxy`, `all_proxy` and `no_proxy`
whenever the relay answers, which is from the start of the computer's session, so its desktop browser has
them too; if the relay is ever down, nothing changes. With an exit node on, the status says
`"internet": "relay"` while the relay carries the traffic, and `"exit_node"` when it can't (the relay is off
or failing, or the computer was never pointed at it). Only then does the Computer tab show the card: "Your Mac sends everything
through a Tailscale exit node, so your helpers' computers can't reach the internet. Turn off the exit node
in Tailscale on this Mac." On the Mac, **Open Tailscale** opens the app; nothing changes Tailscale's
settings. An exit node on the iPhone doesn't matter and shows nothing.

Cua has no setting of its own for a Space's proxy: `cua spaces create` takes none, and the MIT Hermes plugin
passes no environment to commands (checked against Cua's public docs and the plugin at the pinned commit,
21 Oct 2026). Cua's own "hotspot" shares the Mac's network with a Space too, but its docs don't say what it
refuses, so Nollie doesn't use it. Not yet proven on a real computer: which shells the plugin starts (a
login shell reads the snippet; a plain `bash -c` doesn't), whether the computer's user may write
`/etc/profile.d`, and whether the relay (checked every 5 seconds) is up before the desktop session starts, since
the browser reads these settings only then.

## How it works

| Piece | Where | Does |
|---|---|---|
| Switch, setup step, card | `Apps/Nollie/Chat/HelperComputerSection.swift`, `HelperComputerModel.swift` | Reads and changes the computer through the gateway, on iPhone and Mac alike |
| States and words | `Packages/NollieCore/.../Computer/HelperComputer.swift` | Which screen shows, every visible sentence |
| Onboarding step | `Apps/Nollie/Connect/OnboardingComputerStep.swift` | The Mac setup's single toggle |
| Cua setup (Mac) | `Apps/Nollie/Connect/CuaSetup.swift` → Nollie Runtime (`Services/Runtime/CuaInstaller.swift`) | The app only asks; the helper downloads, checks and installs |
| Per-helper changes | `Companions/nollie-computer/dashboard/own_computer.py` | Plugin, settings, the computer, the ownership record |

### Turning it on (the add-on, for that profile only)

`POST /api/plugins/nollie-computer/own-computer {"profile", "action": "on", "request_id"}`:

1. Saves the profile's current `terminal.backend` and the four plugin settings (once), and a dated
   backup of its `config.yaml`.
2. Installs Cua's MIT Hermes plugin with Hermes's own CLI for that profile:
   `hermes --profile <p> plugins install https://github.com/trycua/hermes-cua-spaces --ref fcf30603… --force --enable --yes-deps`.
   Hermes's scanner rates this exact commit "caution" (17 findings in its README, CI workflow and
   byte-order-mark handling, reviewed), so `--force` accepts it. A "dangerous" verdict can never be
   forced, and no other commit is installed. The plugin needs the `cua` Python package 0.5.x,
   which Hermes installs into its environment.
3. Sets `plugins.entries.cua-spaces.settings`: `space: nollie-<profile>`, `on: local`,
   `image: linux`, `delete_on_exit: false`. A named computer keeps Hermes's approval prompts, and
   the plugin never deletes it.
4. Creates the computer with Cua's CLI: `cua spaces create linux --on local --name nollie-<profile>`.
5. Records `local:nollie-<profile>` in `~/.hermes/nollie-computer/owned-spaces.json` (others kept,
   backed up first), so the existing preview finds it.
6. Points the computer at Nollie Runtime's exit relay (see above) and records the port in its entry.
   If Cua can't run the script, nothing fails: the computer keeps its own network.
7. Only then sets `terminal.backend cua`: the helper's commands move once its computer exists.

**Off** puts back each saved value exactly (unsetting what was unset), disables the plugin if it
was off before, and leaves the computer. **Reset** deletes and recreates the computer under the same
name and points it at the relay again. **Remove** (only while off) deletes it and its ownership entry.

**Remove Nollie** runs `own_computer.py release` with that Hermes's own Python: each helper's settings
go back as with Off, then each computer Nollie named (`nollie-<profile>`) and recorded is deleted. A
managed setup's computers are deleted without touching its settings, since the setup goes next. A
computer whose helper can't be switched back, or that Cua can't answer for, is kept and reported.

Every request carries an ID. The same ID never runs twice, so an answer lost on the way is never
repeated: the app reads the status instead. Reads (`GET .../own-computer?profile=`) only talk to an
already running Cua daemon (`--daemon ~/.cua/cua.sock`) and never start anything.

### Setting up Cua (Mac)

After the person's one yes, the app asks Nollie Runtime over its signed XPC connection
(`cuaSetupStart`, `cuaSetupStatus`). The helper:

1. Uses the person's own Cua Spaces when it is in `/Applications` or `~/Applications` and is 0.12.0
   or newer, and never moves, updates or deletes that copy. If it is older, it asks the person to
   update it from Cua's site. Otherwise it uses, or updates, Nollie's own copy.
2. Downloads `cua-spaces-0.12.0-darwin-universal.dmg` from Cua's GitHub release (GitHub hosts only)
   and checks its size and Cua's published SHA-256 (`93dd2b31…53c114`).
3. Mounts it read-only and checks the app with `codesign` against
   `identifier "com.trycua.spaces.macos"` and team `YCK386LBJ7`, then Gatekeeper (notarization),
   and its version.
4. Stops an older daemon, copies Cua's signed app unchanged into Nollie's own folder
   (`~/Library/Application Support/Nollie/Cua/Cua Spaces.app`), checks the copy again and swaps it
   in. Nothing goes into Applications, so Cua doesn't show in Applications or Launchpad. The folder
   is kept out of Time Machine, because it can be downloaded again.
5. Makes no link on the PATH. Nollie Runtime and the add-on call Cua's tool by its full path inside
   the copy in use (`.../Cua Spaces.app/Contents/MacOS/cua`); the managed Hermes gets that path as
   `NOLLIE_CUA_CLI`, and `own_computer.py` otherwise looks in Applications, then Nollie's folder.
6. Starts Cua's daemon and asks `cua --json runtime doctor` whether Linux computers can run. If not,
   it lets Cua add Lume itself (never Homebrew); otherwise it explains plainly.
7. Records what it made in Nollie's own folder: `CuaSetup/installed.json` (its copy, and whether
   `~/.cua` was new) only when it installed Cua itself, and `CuaSetup/ready.json` once a setup
   finishes. Removing Nollie deletes `~/.cua` only with that record.

Cua keeps its state and its computers in `~/.cua` (`~/.cua/cua.sock` is its daemon). Cua's public
docs describe no setting to keep that state elsewhere, so Nollie leaves it there. Unverified without
a real install: whether a future Cua offers such a setting.

### One menu bar item

Nollie never opens the Cua Spaces app, which has its own window and menu bar item, and never makes
it a login item. Only Cua's background part runs: Nollie Runtime starts it headless with the
command-line tool inside the app (`Cua Spaces.app/Contents/MacOS/cua daemon start`) when the helper
launches after a finished setup, or when the person taps **Start Cua**, and stops it
(`cua daemon stop`) before Nollie is removed or when Nollie.app is gone.

Checked by tests: `CuaInstallerTests` records every program the installer runs (only Cua's CLI, only
`daemon start`, `daemon stop`, `runtime doctor` and `runtime setup`); `Tools/dev/test_cua_headless.py`
fails on any code path in Nollie that opens the app, runs its window program, or registers it at
login; `ComputerRulesTests` keeps Cua Spaces out of the apps Nollie Computer may open.

Not guaranteed without a real install: what Cua's own daemon does when it starts (Cua 0.12.0 is
expected to run without a window, but a future Cua could show one), and whether Cua Spaces adds its
own login item the first time the person opens it themselves. Nollie can't stop a person from
opening the app; it only never does so itself. Also unverified: that macOS never lists an app kept
in `Application Support` in Launchpad or Spotlight's Applications results.

Nothing downloaded runs inside Nollie.app. Without Nollie Runtime (an existing Hermes, or the Mac
App Store edition) the step falls back to Cua's download page and notices when Cua appears.

Cua Spaces is Cua's own app under its own terms. Nollie never bundles, reads or adapts its code; see
[Notices](legal/notices.md).

## Testing

```sh
python3 -m unittest discover -s Companions/nollie-computer/tests -v   # the add-on
python3 -m unittest discover -s Tools/mock-gateway -p 'test_own_computer.py' -v
python3 Tools/runtime-helper/run-tests.py                             # the installer and the relay's switch, with a fake Mac
```

Swift: `NollieTests/HelperComputerTests`, `NollieMacTests/HelperComputerTests`, `NollieMacTests/ExitRelayTests`
(the relay itself). UI: `NollieUITests/HelperComputerUITests` (a golden flow in `Tools/dev/verify.py`) and
`AwayFromHomeUITests` (the exit node card, and the card leaving once the relay carries the traffic).
`Companions/nollie-computer/tests/test_exit_relay.py` covers the state file, the card rule, pointing a
computer at the relay through a fake Cua MCP server, and the snippet itself in bash against a real listener.

The mock gateway serves the same routes. `POST /api/_mock/own-computer` sets the fixture:
`{"reset": true}`, `"setup"` (`ready`, `no_cua`, `old_cua`, `cua_not_running`, `no_runtime`),
`"ready_after"` seconds, `"exit_node"` and `"relay"` (booleans), and `"profile"` with `"on"`, `"state"` and `"message"`. The demo copy
opens a bot's Computer tab with `-nollie-demo-bot-page settings -nollie-demo-bot-tab computer
-nollie-demo-bot-profile <name>`; on the Mac, `-nollie-demo-cua-setup downloading:0.42` holds one
setup step for its picture.
