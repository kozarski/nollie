# Nollie: notes for coding agents

Nollie is an iPhone, iPad and Mac app for Hermes Agent: each Hermes profile is a bot, and
chats work like Messages. Branch `main` is the product.


## Rules
- No attribution lines in commits or PRs (no Co-Authored-By, no session links), and no mention of AI tools in
  code, comments, commits, docs or app text.
- No push, PRs or remote changes without Corey's yes.
- Never commit or print secrets (tokens, keys, `.env` values).
- Text people see: plain, warm and short. No em-dashes.
- Every visible change comes with proof you have looked at: a build, the relevant tests, and screenshots
  (simulator for the phone, a window capture for the Mac).
- Nollie is MIT, © Corey Kozarski. Keep third-party notices (Hermes, Cua, Sparkle and the rest) in `LICENSE`,
  `Docs/legal/notices.md` and app distributions. The Nollie name, characters and icon are not under the code license.
- Clean room for Cua: Cua Spaces, `spacesd`, the Spaces SDKs and the Cua Bots samples (`examples/cua-bots-*`)
  are FSL-1.1 with a non-compete. Never read, copy or adapt their code, and never bundle them. Cua Driver and
  `trycua/hermes-cua-spaces` are MIT: fine to use with credit in `LICENSE`. Nollie may talk to a Cua install
  through its public CLI, MCP server or the MIT plugin. Nollie Runtime may fetch Cua Spaces for the person after
  their yes (Corey, 21 Oct): Cua's own signed, notarized release from Cua's GitHub, checked against its published
  checksum and team ID, installed unmodified as Cua's app. Never bundled, patched or redistributed. Why that is
  fine under FSL-1.1: Cua makes the release available, not Nollie; each person's use is their own internal use, a
  named Permitted Purpose; and the non-compete covers only commercial products, while Nollie is free. If Nollie
  ever charges, check again. Public docs are fine to read.

## Layout
- `Packages/NollieCore`: no UI. Gateway connection and runtime (`Runtime/GatewayRuntime.swift`), chats
  (`Chat/ChatSession.swift`), Hermes API calls (`Networking/HermesAPI.swift`), Kanban.
- `Apps/Nollie/`: the app, shared by iPhone and Mac where possible. `App/AppModel.swift` (one model), `App/SystemControl.swift`
  (the per-bot switch for using the Mac), `App/NollieInk.swift` (colours, type, button styles), `Chat/` (BotList,
  BotSheets with the bot menu, ConversationView, TranscriptView, CardsView with approval cards, ProfileInfoSheet
  = Bot settings), `Settings/`, `Push/`.
- `Apps/Mac/`: the Mac app (`MacRootView.swift` window and sidebar, `MenuBarTurnReporter.swift` menu bar,
  `NollieMacApp.swift`, `Computer/` for Nollie Computer: a bot using approved apps on this Mac, `Live/` for the
  live picture of a helper's computer: [The live picture](Docs/live-picture.md)).
  `Update/` is Sparkle's automatic updates (Direct edition only, compiled out of the store build): [Releasing](Docs/releasing.md#automatic-updates-direct-mac).
- `Apps/Watch/`: Nollie on Apple Watch (approvals, the crew at work, Stop), embedded in the iPhone app. `App/` the watch app,
  `Widgets/` its Smart Stack widget and Stop control, `Shared/WatchWire.swift` what phone and Watch say over WatchConnectivity;
  the phone's side is `Apps/Nollie/Watch/` (`WatchLink`, and `WatchCards` for which approvals the wrist may allow).
- `Shared/`: bot drawing, appearance policy, app icon and types used by apps and extensions.
- `Extensions/`: notification presentation on the iPhone and the Mac; `Controls/` has the iPhone's Ask
  Nollie control and the Lock Screen Stop (a Live Activity, started by `App/HelperAtWorkActivities.swift`;
  intents in `Shared/AskNollie.swift` and `Shared/StopMac.swift`).
- `Services/Runtime/` and `Services/Notifications/`: the owned Mac runtime and notification helpers.
- `Companions/`: the gateway-side pairing, computer, nollie-mac, workflow, crew, web reader and legacy push integrations.
- `Tests/Unit/` and `Tests/UI/`: app tests: `NollieTests`, `NollieMacTests` and `NollieUITests`.
- `Docs/`: focused setup, development, architecture and release guides.
- `Docs/logging.md`: how to watch Nollie in Console, the Mac log files, privacy rules and the `NollieLog` channels.
- `Tools/sparkle/`: fetches the pinned Sparkle into a cache, embeds and signs it in the Direct build, holds the feed URL and
  the public update key (`update-feed.env`). `Tools/release/sparkle-keys.sh` makes the key once; `sparkle-appcast.sh` signs a release.
- `Tools/pins.json`: every pinned third-party version and checksum the Mac setup installs; `Tools/dev/check-latest.py`
  reports which are behind (read-only). How to bump one: [Development](Docs/development.md#update-pinned-versions).
- `Tools/mock-gateway/mock_gateway.py`: a fake Hermes for demos and UI tests. `Tools/dev/make-demo-app-sim.sh`:
  installs the demo copy (`com.coreykozarski.nollie.demo`) in a simulator.

File placement, design, copy and testing conventions: [Contributing](Docs/contributing.md).

## Build and test
- Mac (signed, team 5985LRZFZS): `xcodebuild -project Nollie.xcodeproj -scheme NollieMac -configuration Debug -destination 'platform=macOS' -allowProvisioningUpdates build`
- iPhone simulator (unsigned): `xcodebuild -project Nollie.xcodeproj -scheme Nollie -configuration Debug -destination 'platform=iOS Simulator,name=<simulator>' -derivedDataPath <dir> CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build`
- Everything at once: `Tools/dev/verify.py` (builds, unit and Python tests, golden UI flows; a skipped flow fails).
- Tests: the same with `test -only-testing:NollieTests/<Suite>` (Swift Testing; keychain tests need a signed simulator build). Cases run in parallel: a test that
  listens for app-wide notifications needs values unique to each case.
- Design pictures: start the mock gateway (`python3 Tools/mock-gateway/mock_gateway.py --port 9139 --token mock-token --neutral-models`),
  install the demo copy, launch it with `-nollie-demo-gateway http://127.0.0.1:9139 mock-token Studio -companionPromptShown YES`
  plus flags like `-nollie-demo-tab chats`. `NollieUITests/DesignShotsUITests` and `NollieTests/DesignSnapshotTests`
  produce the reference shots; UI tests drive the demo copy already installed, so reinstall it after a change.
- On a device: build scheme `Nollie` for `id=<udid>`, then `xcrun devicectl device install app --device <id> <Nollie.app>`.

## Hermes facts the app relies on
- Hermes Agent v0.22.2 (pinned in `Tools/pins.json`); its dashboard API listens on 127.0.0.1:9119 by default and
  the gateway runs as a launchd service.
- Bots are Hermes profiles; a bot marked Private is kept out of shared views and of other bots' work.
- System control: a bot's desktop lease (`<home>/bot-desktop/lease.json`, holder `agent` or `human`) plus its
  `cua:<action>:<background|foreground>` keys in `command_allowlist`. Spaces (VMs): the bot's `cua` MCP server.
