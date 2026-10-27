# Nollie Computer

[← Nollie](../README.md) · [Architecture](architecture.md) · [Notices](legal/notices.md)

Nollie Computer lets a bot use a few apps on this Mac for one task, after the person approves them.
It is Nollie's build of Cua Driver (MIT), carried inside the Direct Mac edition as a bare helper,
`Nollie.app/Contents/Helpers/Nollie Computer`. Because it is not an app of its own, macOS charges its
Accessibility and Screen Recording use to Nollie, so Privacy & Security lists only Nollie.

## Only in the apps you pick, on a model on this Mac

- **The apps you pick.** A bot's settings, Computer, Advanced, **Apps on this Mac**
  (`ComputerAppsPage`) has the switch, the model and one switch per app, all off to start. The list
  is kept on this Mac by bundle id (`ComputerPickedApps`, `nollie.computer.apps`) and only narrows
  what `ComputerAppRules` allows. `mac_start` refuses an app that isn't picked ("Not picked" on the
  card), nothing starts while none is, and an app turned off mid-task is refused from the next
  action. There is no action that opens an app, and another app coming forward after a step ends
  the task, as before.
- **The window, checked below the model.** Before every action and again after any card,
  `ComputerWindowGuard` asks the window server: the window must still be the picked app's own, a
  task app or Nollie must be in front, and nothing of another app's may cover the spot a click or
  scroll lands on. A look is a picture of that one window only (the driver's window capture), and
  one that is bigger than that window at the screen's scale, or of a window that isn't the app's,
  is thrown away before anyone sees it.
- **A model on this Mac does the clicking.** A bot never sees the screen. It calls
  `mac_do(app, step)`; Nollie looks, hands the picture and the window's element rows to a vision
  model running on this Mac (`ComputerScreenClient`, only ever `http://127.0.0.1` or `[::1]`, no
  proxy, no redirects), which picks one action at a time as JSON the engine holds it to. Each action
  goes through every rule and card below, and only one short line (at most 240 characters) goes back
  to the bot. The add-on passes on words only, and the broker refuses the old single actions that
  returned pictures. Hermes's own `computer_use`, which sent whole screenshots to the bot's model,
  is kept switched off for every bot and refused by nollie-workflow (`mac_screen.py`).
- **Which model.** Nollie uses the engine of its own local model setup (the Models page): the
  state file `runtimes/llamacpp/server.json` in the Hermes home says where it listens and its key,
  and `presets.ini` says which models see pictures (a `mmproj` file on disk). Qwen3.6 35B-A3B comes
  first: a mixture of experts with about 3B active, so each step takes about a second on Apple
  silicon, and it reads app windows well. Qwen3.8 27B and Flash Next also work. With none,
  using this Mac stays off and the page offers **Get a model**.
- **Allow Mac control** (each bot's Computer tab) is now that bot's permission to ask; it no longer
  turns Hermes's own computer_use on. In Nollie's own setup the nollie-mac add-on comes and goes with
  it (see [the add-on](../Companions/nollie-mac/README.md#in-nollies-own-setup)); a hand-installed
  ~/.hermes still uses macOS's own Python.
- **Papertrail.** When a task ends, one line goes in the bot's Papertrail: the apps, how many
  actions and looks, and that no picture left (`POST /api/plugins/nollie-workflow/papertrail/mac-session`).

## What keeps a bot in check

The boundary between a bot and this Mac is the person, not a check on processes. A bot's own tools
(Hermes's terminal and process tools) run as the same user, inside the same Hermes job, as the
add-on, so no check of processes or files can fully tell them apart. What a bot can't get past:

- **The card.** Every task needs the person's yes on the Mac, with Touch ID or the Mac's password.
  The card names the bot, the chat it came from (its title and platform, as Hermes records them)
  and every app, with the ones that are view-only or refused. Nothing the caller sends besides the
  session id it asks about is used; the bot, chat and title come from Hermes.
- **Every risky step.** Sending, buying, deleting, uploading, accepting terms, installing, signing
  in, opening things and links ask again, each with Touch ID, and the rules on apps and actions
  below apply whoever is asking.

Defence in depth, which raises the bar but isn't the boundary:

- **Off until the person turns it on.** Nollie Computer is off by default and marked Beta (a bot's
  settings, Your Mac) until a clean-account test passes, and turning it off ends a running task.
  The Direct edition has no sandbox, so any process running as this user can turn the setting on
  with `defaults write`; it keeps Nollie Computer out of the way, it doesn't keep a bot out.
- The add-on process check (`ComputerPeer`), the pending-call check in Hermes (exact tool name and
  arguments), the direct-chat and open-in-Nollie checks, the other-driver and System control checks
  (readings older than 12 seconds count as on), and app signatures.
- After a yes, a click, key or typed line break goes ahead only if the same thing is still there:
  what is under the spot, or what has focus, with the same words and address. Accessibility and
  signature checks run off the main thread, and a Stop pressed during them wins.

Accepted, documented:

- A same-user process can rewrite Hermes's code, the add-on (between Nollie's checks) or Hermes's
  database, and so make a request look like a real one.
- It can stop Hermes and start its own launchd job in Hermes's place.
- Hermes turns `-` and `.` in a server's name into `_`, so another MCP server named `nollie_mac`
  would get the same tool name as this add-on.
- A private bot isn't read at all (not even its add-on's file), so its own computer_use isn't
  checked.
- Any process running as this user can turn Nollie Computer on (see above).

In each case the person still sees the bot, the chat and the apps on the card and answers with
Touch ID, and every action is still judged by Nollie's own rules.

## Building the helper

`Tools/computer-helper/pin.env` names the one driver release and how to check it: the tag, its
commit id, the tree ids of the driver workspace and the telemetry crate it links, the Cargo.lock
SHA-256, the Rust release with its SHA-256, and the SHA-256 of the binary the build must produce.

```sh
Tools/computer-helper/build-driver.sh
```

builds it into `~/Library/Caches/Nollie/computer-helper` (rebuildable; safe to delete):

1. Rust 1.97.1 from static.rust-lang.org, checked against its SHA-256, installed in the cache only.
2. A sparse clone of the tag (only the files the build reads), checked against the pinned commit
   and tree ids, with no local changes. The build stops if any folder above the source holds a
   `.cargo/config`, so nothing outside the clone can change it.
3. All 625 locked crates, fetched with `/usr/bin/curl` and checked against Cargo.lock
   (`vendor-crates.py`; `NOLLIE_CRATE_SEED` can point at a folder of `.crate` files to skip downloads).
   Every vendored file's SHA-256 goes in its `.cargo-checksum.json`, so cargo rechecks them each build.
4. `cargo build -p cua-driver --release --locked --offline` in a clean environment, with build paths
   remapped so the binary is the same on any Mac. It must match `DRIVER_BINARY_SHA256`; the cache's
   own records are never trusted for that.
5. `third-party-notices.py` writes the licence of every linked crate and stops on any licence other
   than the expected permissive ones and the six unmodified MPL-2.0 UniFFI crates.

Symbols are left in: the system `strip` on macOS 27.2 writes dylibs that dyld rejects when a
deployment target is set, which breaks the build's proc macros. Release builds should strip the
final executable on a macOS whose `strip` works. The build is Apple silicon only for now; a
universal helper needs the x86_64 standard library added to the pinned Rust.

The Xcode target `NollieComputer` runs the same script for DirectDebug and DirectRelease (cached, so
usually instant), and `NollieMac` depends on it. The Mac app's "Embed Nollie Computer" phase
(`embed-computer-helper.sh`) then, in the Direct configurations only:

- copies the binary to `Contents/Helpers/Nollie Computer` and checks its SHA-256 against the build;
- copies the notices to `Contents/Resources/Notices/Nollie Computer/`;
- signs the helper inside out with the app's identity, hardened runtime, the identifier
  `com.coreykozarski.nollie.computer` and two entitlements (Apple Events, screen capture).

Other configurations refuse a build folder that already holds the helper. DirectDebug without a
built helper still builds, with a warning, and cannot use the Mac; DirectRelease fails.

Never shipped: Cua's app, its menu bar item, its Node runtime, its perception add-on or Cua Spaces.
Never shown: Cua's name or marks anywhere in Nollie's interface. The credit is in
[Notices](legal/notices.md).

## How a task runs

Nothing about Nollie Computer runs until a person approves a task. Nollie only listens on its own
socket, `~/Library/Application Support/Nollie/Computer/control.sock` (this user only), for the
[nollie-mac add-on](../Companions/nollie-mac/README.md).

1. **Ask.** A bot calls `mac_start(apps, task)`. Nothing happens while Nollie Computer is off. As
   defence in depth, Nollie (`ComputerCenter`) first checks who is asking. The kernel says which
   process is on the socket (`ComputerPeer`): it must be macOS's own Python (by its signature) running
   exactly `-I <bot>/plugins/nollie-mac/server.py`, that file unchanged from the add-on Nollie ships
   (read by that very path, following no link), started directly by Hermes's own gateway (messaging
   chats) or dashboard (the Nollie app's chats): the one listening where Hermes listens, started by
   launchd as one job with the add-on, with no other gateway or dashboard above it, and with the
   add-on's input and output on pipes it holds. A `hermes chat` run, the TUI, a terminal or a bot's
   own tools are refused. Then it asks Hermes about the session (`ComputerSessionCheck`): its latest assistant turn must be a
   pending call to exactly `mcp__nollie_mac__mac_start` whose arguments are the request byte for
   byte (apart from the add-on's own stamp), made in the last 90 seconds and used only
   once (even across restarts). From the dashboard, the chat must be open in this Nollie with a turn
   Nollie sent still running, which only this app knows; from the gateway, it must be a direct
   messaging chat the gateway routes (its session key and chat id), never a group (Slack's group
   DMs count as groups, and Matrix, which guesses, doesn't count). The private bot is never asked about or
   shown. Nollie also refuses while Hermes's own computer_use could act for any bot (by Hermes's
   rule: not switched off and no person holding the lease, so a bot with no lease file counts;
   turning System control off in Nollie settles it), when it can't read that for a bot, or while
   another driver is running (by program name, by the signature the kernel holds for it, so a
   renamed or deleted copy, or one rebuilt under its usual name, counts; another user's too; or by a
   driver socket that answers), since either could press the card's buttons. A private bot isn't
   read at all, so its own computer_use isn't checked. It refuses at once when
   nobody is at the Mac (locked or asleep, or no keyboard or mouse use for 5 minutes), when Accessibility or Screen Recording is missing (it opens
   the walkthrough instead), or when every app is one it never offers. Otherwise it shows the
   approval card: the chat's title and platform, the apps, which are view-only, which were refused
   and why, and the bot's own words in quotes. Allow asks for Touch ID or the Mac's password, so
   only the person can say yes. No answer within two minutes counts as no. After the yes, the
   other-driver check and the pending call are checked again before anything starts.
2. **Start.** After a yes, Nollie opens approved apps that aren't running and starts the helper
   with `Process` (so macOS charges its permission use to Nollie), in embedded, bounded mode, on a
   private socket in a `0700` folder, with a home folder of its own, telemetry, update checks and
   scripting off, and a stdin pipe it holds.
3. **Two doors.** The helper's process-wide manifest (`ComputerManifest.door`) allows nothing but
   `check_permissions`: its socket admits any process running as this user, so that is all such a
   process gets. Nollie, the helper's parent, then opens trusted sessions, which the driver grants
   only to its parent's process id: `use` (look, click, type, keys, scroll in the approved apps
   that aren't browsers) and `view` (look only, in browsers). No session ever allows launching,
   quitting, menus, scripts, the clipboard, files, the whole screen or a display-wide click.
4. **Show.** While the task runs, a floating "Using Notes · Stop" panel sits at the top of the
   screen on every Space, the Dock menu has Stop, and Control-Option-Command-Period stops it from any
   app (registered only while a task runs).
5. **Act.** A step (`mac_do`) reaches Nollie with the task's secret id, and the model on this Mac
   turns it into actions, one at a time, up to ten a step. Nollie reads the element
   it lands on from its own last look at the window (never from the bot's description): an element
   token from that look, or a point in that screenshot's pixels. Each look is good for one action.
   Nollie then asks the app itself what is there now (by its own Accessibility permission): a click
   is judged on both, typing goes only into a text field that is still where Nollie saw it, and a
   key is judged on the element that has focus, where a password field says it is one (with a
   token, focus must already be there, since the driver only tries to move it). Then `ComputerActionRules`: browsers view-only; nothing
   typed into a password or code field; typing only into a known element, one field at a time;
   keys judged and sent in the driver's own canonical spelling, so no alias slips past; single
   letters only into a text field, like typing. A shortcut is looked up in the app's own menu bar
   and judged on the menu item's title: find, undo, select all, copy and new run; anything else
   asks, and a shortcut from the Apple menu, one Nollie can't find, or any shortcut into web
   content (which can handle keys before the menus do), or into an app built on a web engine, is
   refused. A click on a link (by the driver's tree, the app's own answer, or any parent up to the
   window, where an app that doesn't answer counts as a link, and never undone by a later answer)
   is clicked only by its spot in the screenshot, and asks, showing the site first and then the whole
   address, for web and mail links; other links, links whose address Nollie can't read or that
   hide a user name, and spots it can't name are refused. A preview whose words are an address
   asks with its words, Return or Space on a link counts as clicking it, sites written in lookalike
   letters are refused, and every click is checked again after the person's yes (the same thing,
   words and address at the same place). Scrolls turn the wheel at an element and never move focus;
   typing and keys go only where focus already is. Sending, buying, deleting, uploading, accepting terms, installing,
   signing in and opening things, Return or a typed line break, Delete, paste and a click it can't
   name all wait for the person's "Allow Once", which also needs Touch ID or the Mac's password.
   An answer only counts for the card the person saw.
6. **Stop.** Stop, `mac_done`, 30 minutes, 5 minutes without an action, the Mac locking or sleeping,
   nobody touching the Mac for 5 minutes (the bot's own input doesn't count), another app coming to
   the front right after a bot's step (seen during a card too, acted on when it closes), another
   driver appearing (checked every second) or Hermes's own computer_use opening for a bot (read
   every five seconds), the add-on that asked going away, a broken
   connection to the helper, the helper quitting,
   or Nollie quitting end the task. Nollie revokes every session, closes the helper's stdin first,
   so an action in progress dies with it, kills it if it is still there after half a second, and
   removes its private folder: gone within a second, whatever it was doing.

## Which apps a bot gets

`ComputerAppRules` keeps these with the person, by bundle id, App Store category or name:
Nollie itself; terminals, script editors, code editors, launchers and automation tools, containers,
and remote-desktop or virtual-machine apps, plus anything in the `developer-tools` category (they
can run commands); Finder, Activity Monitor, Disk Utility, Installer and other system tools;
password managers, Keychain Access and authenticators; System Settings; finance and crypto apps
(category `public.app-category.finance`, known wallets, banks and brokers). Browsers (known ones,
and any app that opens `http` links) are view-only.

Use is an allowlist (`ComputerAppRules.signers`): everyday apps such as Notes, Mail, Calendar,
Reminders, Pages, Numbers, Keynote, TextEdit, Preview, Messages, Outlook, Slack and Things, each with
who must have signed it. The copy on disk must hold that signature for its own bundle id (macOS's
apps by Apple, the rest by their maker's team), and before every action the running app is checked
the same way, so a copy swapped on disk or another app with the same bundle id is never used. Word, Excel and
PowerPoint (macros) and apps whose plugins can run anything aren't offered. Any other app says
"Nollie doesn't offer this app yet." on the card.

## Permissions

The walkthrough (`ComputerPermissionsView`, from the bot's Computer page or whenever a task needs
it) shows Accessibility and Screen Recording as macOS reports them for Nollie, without prompting.
"Ask macOS" shows macOS's own prompt, which only the person answers; afterwards the button opens the
right Privacy & Security page instead. The status refreshes while the window is open.

## What is proven, and what still needs a person

Proven on this Mac (Tests/Unit/ComputerHelperTests.swift, run inside the signed DirectDebug app):
the embedded helper starts, reports version 0.36.0 and embedded mode, refuses `list_windows` from
a plain caller with "outside the capability manifest", reports its permission attribution as
`host`, allows Finder only inside Nollie's trusted session, refuses another app, `list_apps` and
`get_screen_size` there, refuses input in a view-only session, stops in under a second, and leaves
`~/.cua-driver` and a standalone Cua Driver's pid file untouched. The rest of the rules and flows
are covered with a recorded driver (`ComputerCenterTests`, `ComputerRulesTests`).

Not yet proven, because it needs a person on a clean macOS account (the earlier spike's steps):
the exact wording of macOS's prompts, that Privacy & Security lists only "Nollie" after both grants
(no "Nollie Computer" or Cua row), and a real look, click and type in an approved app with those
grants. No permission prompt was raised or answered on this Mac, and nothing was clicked.

Stop on the iPhone: when a task starts, the Mac sends the iPhone a "Scout started using your Mac"
alert with Stop (needs iCloud alerts on, on both, and notification details shown on the iPhone); while
the iPhone can see the work, Stop sits on its Lock Screen too. Not built yet: a short local activity
log, x86_64 and a stripped, notarized helper.
Hermes's own `computer_use` is kept switched off for every bot that isn't private, and
nollie-workflow refuses it; while it could still act for any bot, or a standalone Cua Driver is
running, Nollie Computer won't start. A private bot loads nothing of Nollie's, so its own
computer_use isn't refused by the add-on.

The model was tried for real on this Mac (`ComputerScreenLiveModelTests`, Qwen3.6 35B-A3B on the
pinned llama.cpp): whole steps through Nollie's own loop, rules and cards in a throwaway window the
test draws, with a stand-in for the helper. The helper itself couldn't take part: this Mac hasn't
given Nollie Accessibility or Screen Recording.

Not done yet: Nollie's own child processes (uv and Python from `NativeDependencyInstaller`) still
inherit its Accessibility and Screen Recording, because macOS charges them to Nollie. They should be
started as their own responsible process.
