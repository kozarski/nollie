# Owned Mac runtime

This is the Direct edition's runtime lifecycle implementation. It does not register a service or start Hermes merely by being linked. Store and phone builds cannot start it.

The signed helper must supply a fixed installations directory and its bundled `runtime_entry.py` to `NativeRuntimeBackend`, then own one `NollieRuntimeSupervisor`. The backend validates the installation UUID, private ownership, all four preparation receipts and the entrypoint digest before each start or restart. A file lock prevents two helpers owning one installation. It never adopts a saved PID.

The two child roles are explicit: `--profile default serve --host 127.0.0.1 --port 0 --isolated` and `--profile default gateway run --external-supervisor`. Environment values are constructed from the owned installation; inherited credentials and existing Hermes settings are not passed. Only the API child receives the fresh session token. API keys arrive on their own pipe (see API keys below). The private owner pipe is not inherited by later agent subprocesses. Closing it or losing the helper ends these two children.

Readiness requires the API's exact sentinel plus authenticated identity with the launched PID and the owned gateway's current running record. Ready means these two processes started, not that a model, Cua, phone access or workflow companions are configured. Process output is drained without being persisted. Restarts revalidate the receipts and stop after three failures within ten minutes. A deliberate stop never restarts.

## Authenticated service

`RuntimeHelperMain` supplies fixed paths under `Application Support/Nollie`, the signed bundled entrypoint, and the Mach service `com.coreykozarski.nollie.runtime`. Its Store fallback returns immediately. The Direct helper is unsandboxed so it can reach the same prepared installations as the Direct app.

Before exporting or resuming each connection, the listener requires the current UID and sets the OS code-signing requirement to the exact host identifier `com.coreykozarski.nollie`, Apple anchor and team `5985LRZFZS`. The app must pin the corresponding exact helper identifier before resuming its connection. The only requests are UUID start, status and stop. There are no caller-selected paths, executables, environments or URLs.

The helper mints a 32-byte random token per installation in its private Data Protection Keychain. Background reads cannot prompt. A successful explicit start returns this token separately from the JSON status document, over authenticated IPC only. A ready start for the same installation is idempotent. Status never returns credentials. Tokens never appear in receipts, plists, argv or logs.

The private `RuntimeService/enabled.json` receipt contains only a version and installation UUID. It is written atomically with mode 0600, under a private owned directory. Symlinks, hardlinks and shared files are rejected. The enabled installation resumes after helper restart using the existing credential. Explicit stop clears consent before stopping children; failure to clear it is reported. Ordinary process termination preserves consent, while closing owner pipes stops the children. Unregister the exact service after stopping it; removing an installation's data is a separate choice.

Startup has a 60-second response deadline. Failed or timed-out starts revoke consent; owned-child cleanup keeps new starts blocked until it finishes. A live but stale gateway heartbeat does not count as ready: it must be from this child launch, no more than 120 seconds old and no more than 5 seconds in the future.

## API keys

Provider keys and tokens for the owned assistant live in this helper's Data Protection Keychain
(`RuntimeKeyStore.swift`): one generic password per key, service `com.coreykozarski.nollie.runtime.keys`,
account `<installation>/<bot>/<NAME>`, this device only, readable after the first unlock, never synced, never
prompting. Remove Nollie deletes them with the helper's other items.

**Every start moves keys out of files** (`RuntimeKeyMigration.swift`), restarts included, under the supervisor
lock and Hermes's own `.env.lock`. In `home/.env` and each `home/profiles/<id>/.env`, a line whose name ends in
`_KEY`, `_TOKEN`, `_SECRET` or `_PASSWORD` is a key, except process-wide settings (`TERMINAL_*`,
`HERMES_KANBAN_*`, `HERMES_TELEGRAM_*`, `NOLLIE_*`) and the session token. Each key is written to the Keychain
and read back; only then is the file rewritten without those lines (a new owner-only copy, renamed over the
original if it hasn't changed since it was read), with one comment line saying where the keys went. Every
other line stays byte for byte, and the file is never left empty (Hermes treats an empty `.env` as no bot).
Stopping at any point loses nothing: the next start finds the key in the file again and repeats. An empty value
is Hermes clearing a key, so the Keychain forgets it too. Left in the file and counted: a symlinked or hard-linked
file, a file that isn't UTF-8 or has a quoted value running past its line, a value with an escape python-dotenv
and Hermes read differently, a name another value refers to with `${NAME}`, and any key whose Keychain write
failed. `op://` references are not keys and stay. Hermes's `.env.bak-*` copies lose the keys the Keychain holds.
A bot Hermes deleted (its folder gone, or `profiles/.deleted/<id>`), and a setup whose folder is gone, have their
keys forgotten. The status document says how many keys are still in files (`keysLeftInFiles`), never which.

**Hermes reads them from its environment.** After the migration, the Keychain's keys for this installation go to
each child as `{"version": 1, "profiles": {bot: {NAME: value}}}` on descriptor 4 (`NOLLIE_KEYS_FD`), written after
the spawn and closed. They are never in argv, the launch environment (which `ps eww` shows any app running as
you), a file or a log. `runtime_entry.py` reads them before anything else, drops the variable, and registers a
Hermes secret source (Hermes's contract for Bitwarden and 1Password) that is always on: the launch bot's keys go
into the process environment as Hermes applies its sources at start, and each other bot's into that bot's own
secret scope, never the shared environment. Whatever a bot's `.env` says about a name wins, in every process: a
key Hermes writes there later is the newer one until the next start moves it, and an empty one stays cleared. A
bot made as a copy records the names it takes along (`.nollie-keys-from`, names only, messaging tokens left behind
as Hermes's own copy does); the copy uses them at once and the next start copies them in the Keychain. The
entry point refuses to start without a valid key pipe. The source hooks `env_loader._load_secrets_config` and
`get_secret_source_values`, guarded by five exact source hashes.

**What stays on disk.** `auth.json` in each bot's folder: sign-ins Hermes makes itself (ChatGPT plan, Nous, xAI,
MiniMax, its own Claude sign-in) and any key added with `hermes auth add`. Hermes rewrites these as tokens refresh
and has no environment or path for them besides `HERMES_HOME`. The local model's loopback key
(`runtimes/llamacpp/.api_key`). `.op.env`, if someone set up 1Password for Hermes. Keys Hermes writes to a `.env`
stay there until the next start. `python3 Tools/runtime-helper/run-keys-smoke.py --python <env>/bin/python --source
<pinned-hermes-source>` runs Hermes's own resolution with this source, offline.

## When Nollie.app is gone

`AppPresence.swift` holds this helper's own bundle open by descriptor and checks every 45 seconds,
confirming a change five seconds later. Dragged to the Trash or deleted: the helper stops Hermes and
its children (consent stays), closes the Link door, stops Cua's background part, writes
`RuntimeService/app-gone.json`, boots itself out of launchd and exits 0, so `KeepAlive` doesn't
start it again. It deletes nothing: nobody is there to ask. A launch from the Trash at login stops at
once the same way. A newer copy in the old one's place counts as an update: the helper stops Hermes
and exits 75, and launchd starts the new copy's helper. Moved elsewhere (not a Trash): it keeps
running. A reinstalled Nollie reads the note and offers **Use it** or **Remove it**. Nollie
Notifications quits the same way. Real launchd and Login Items behaviour on a Trash still needs a
signed install to prove.

## Nollie Link door

`LinkDoor*.swift` and `RuntimeLink.swift` add the TLS 1.3 door a linked iPhone uses. It listens only while a device is linked or a pairing code is showing, accepts private source addresses only, checks a device credential on every request, refuses routes outside its allowlist, reads every socket frame the phone sends and passes only the app's own JSON-RPC calls, and swaps in the session token before passing a request to the API child on loopback. A device credential is still powerful: it can chat with every bot and answer their approval cards. Device credentials are stored as hashes in `RuntimeService/link.json`; the TLS key lives in this helper's Keychain group. The app reaches it through four more XPC requests (offer, status, cancel, remove), which never return credentials. `LinkDoorLive.swift` answers `/nollie/live` itself, the live picture of a helper's computer: it relays a provider's messages to one linked phone, dropping video rather than queueing it, and never reaches Hermes. Its provider is `LiveRelay.swift`, which asks Nollie.app for the picture over a second Mach service, `com.coreykozarski.nollie.runtime.live`. That listener makes the same checks as the main one (the current UID, and the exact signed host as its code-signing requirement). The app calls it three ways (register, push, end) and answers three (open, control, close); every message is size-capped and read strictly on arrival, and the app captures only Nollie Computer's approved window or asks the computer add-on. The latest app to register is asked. With no app registered, a stream ends "unavailable" and the phone keeps its snapshots. Design: [The live picture](../../Docs/live-picture.md). Protocol, threat model and tests: [Nollie Link](../../Docs/nollie-link.md).

## Exit relay for helpers' computers

`ExitRelayPolicy.swift`, `ExitRelayWire.swift`, `ExitRelay.swift` and `RuntimeExitRelay.swift`. While the Mac
sends everything through a Tailscale exit node, Apple's VM networking gives helpers' computers no internet.
The relay lets them reach the web from the Mac instead: its connections are ordinary Mac connections, so they
follow the default route, which is the VPN or exit node when one is on. It never changes Tailscale, routes,
DNS or the firewall.

**When it runs.** Whenever a helper's computer runs, with or without an exit node (Corey, 21 Oct): a
computer then has the relay from the start of its session, and an exit node turned on mid-task just works.
Every 5 seconds the helper looks for Apple's VM network: a `bridge<N>` interface with a `vmenet<N>` member
(read from `ifconfig bridge<N>`, run only while a bridge exists) holding a private IPv4 address with a /16 to
/30 mask. Internet Sharing's bridge, Wi-Fi, Ethernet, Tailscale and loopback never count. While that network
exists the relay listens; once the last VM stops, it is stopped and every connection closed. It never asks
Tailscale. The state goes to the app with Away from home (`relay`: `off` while the helper starts or stops,
`idle` when no computer runs, `on`, or `failed`), and to `RuntimeService/exit-relay.json` (version, state and
port only; mode 0600, written whole and moved into place) for the computer add-on, whose path Hermes's
children get in `NOLLIE_EXIT_RELAY`. The exit node card shows only when an exit node is on and the relay is
off or failed.

**Where it listens and who may use it.** TCP on the bridge's own address, port 47610, and nowhere else: never
`0.0.0.0`, the home network or Tailscale, no peer-to-peer, no shared port. macOS accepts a packet for that
address on any interface, so every connection's source is checked before a byte is read: it must be a VM's
address inside the bridge's subnet. The Mac's own address, the network and broadcast addresses, IPv6 and
everything else are dropped. A forged source inside the subnet can't finish a TCP handshake from elsewhere,
because the replies go to the bridge.

**What it speaks.** One port; the first byte decides. HTTP: `CONNECT host:port` (how https and other TLS
travel), and plain `http://` requests in absolute form, passed on in origin form with `Host` taken from the
target, `Proxy-*` and hop-by-hop headers dropped, and `Connection: close`. The head is read like the Link door's:
CRLF only, ASCII only, at most 16 KiB, 64 headers and 8 KiB per line, HTTP/1.0 or 1.1. Names are plain DNS
names; userinfo, escapes, zones and disguised addresses (`127.1`, `2130706433`, `0177.0.0.1`) are refused.
SOCKS5: no authentication (the listener is reachable from the VM network only), CONNECT only; BIND and
UDP ASSOCIATE are refused.

**Where it may go.** Names are resolved on the Mac (5 seconds). The whole request is refused if any address
is not on the public internet: loopback, unspecified, private (10/8, 172.16/12, 192.168/16), link-local
(169.254/16, fe80::/10), CGNAT and Tailscale (100.64/10, fd7a:115c:a1e0::/48 inside fc00::/7), ULA, multicast,
reserved, documentation and benchmarking blocks, Teredo and the rest of 2001::/23, anything outside
2000::/3, the VM subnet and the Mac's own addresses. Mapped (`::ffff:a.b.c.d`), 6to4 and NAT64 addresses are
judged by the IPv4 address inside. The relay then connects to the vetted address itself (up to four, in the
resolver's order), never to the name again, so a name can't change its answer between the check and the
connection. Upstream connections may not use the loopback interface.

**Ports.** 80, 443, 8080 and 8443 only. Helpers' computers browse, download and fetch code over the web.
Refusing the rest keeps them from sending mail (25, 465, 587), using SSH, or reaching other services from the
Mac's address, which is what an exit node shows the world.

**Limits and what is kept.** 128 connections, 96 from one VM; 15 seconds from accepting to a connected
upstream (10 to connect); 5 minutes without a byte either way closes a connection. Bytes pass through
unread. Nothing is logged: hosts, addresses, URLs and sizes are never written anywhere. Only counts are kept,
in memory (open, served, refused sources, busy, refused destinations, malformed, upstream failures). Three
failed upstream connections in a row, with none getting through since, count as `failed` (the exit node may
be offline), and the card shows.

**Tests.** `NollieMacTests/ExitRelayTests`: every refused range in IPv4 and IPv6, mapped and embedded
addresses, names with mixed public and private answers, the port list, the binding rule from interface
fixtures, the source rule, both parsers (a malformed corpus, every partial read, oversized heads, seeded
random and mutated input), and the whole relay on loopback in front of a fake website: CONNECT by address
and by name, plain HTTP forwarding, SOCKS5 including one byte at a time, refused destinations that never open
a connection, the Mac's own address turned away, timeouts, the connection cap and the failing state. Only
Debug builds have the test allowance (loopback clients, and one exact loopback address and port as the
fake website); release builds don't contain it. `RuntimeExitRelayTests` in `run-tests.py` covers turning it on
and off, a network it can't listen on, the state file and when the card shows.

**Not proven yet.** A real helper's computer behind a real exit node; whether Cua's local Linux runtime uses
Apple's NAT bridge on every Mac (Lume does; a QEMU user-mode network would need no relay); and whether macOS
shows a firewall or Local Network prompt when the signed helper listens on the bridge.

## Model inventory compatibility

The pinned Hermes picker synchronously fetches two remote metadata catalogs on a cold cache, even during its normal nonblocking read. DNS can outlast the HTTP timeout. The managed API entry point applies an in-memory compatibility scope to normal `build_model_options_payload` calls: models.dev uses its existing cache-only API, and the curated manifest uses the current profile's validated memory or disk cache. Missing metadata stays missing and Hermes retains its built-in fallback lists. Saved model selection, credentials, authentication and provider probes are unchanged. This does not prove model inference works.

The scope is local to the request context. Explicit `refresh=True` and unrelated reads retain Hermes' behavior. No additional warmup, config write or installed-source change is made. Four exact source hashes and imported module paths must match before applying it; another Hermes revision needs a reviewed compatibility update. The gateway role does not install this scope. Updating the bundled entry point takes effect after the next app-native managed service stop and start.

## Local model setup check

The app uses Hermes' catalog, quickstart, job, pause and resume routes for an explicitly confirmed download on its own managed default setup. The family and approximate download size are shown before starting; Hermes can re-price the exact variant after installing the engine. A saved nonsecret receipt lets the app observe the same job after reopening. A server restart loses Hermes' in-memory job record, so the app reports interruption and keeps the downloaded files rather than pretending the original job resumed.

A completed download and selected model are separate from a verified reply. The managed API child adds authenticated `POST /api/nollie/local-model/reply-check?profile=default`. It accepts no caller-selected model, URL, credential or prompt. It derives the current local model from the default setup, verifies that model is staged, and obtains the router through Hermes' process-ownership check. The router must be literal HTTP loopback. Its credential remains inside that process.

The check sends one fixed greeting directly to the local engine with no tools, history, memory or agent fallback. It accepts only a completed nonempty response for the exact model, with a 64 KiB response limit, 4,096-character reply limit, three-second connect timeout and 180-second total deadline. It neither follows redirects nor uses environment proxies. Only one check runs at a time; leaving the screen cancels client observation, while a request already accepted by the engine may finish within that bound. Failure does not change settings or claim readiness. This check proves a small local inference, not tool use or a complete personal-assistant task.

The endpoint is registered before normal authenticated API assembly and additionally requires the native session credential. Nondefault profiles are rejected before reading model state. Five additional exact source hashes guard the router and ownership APIs. No route is added to existing Hermes installations or the gateway role. Updating the bundled entrypoint takes effect after the app-managed service is stopped and started again. Offline tests verify boundaries, registration and reply handling; a real model download and inference remain a separate acceptance step.

## Packaging and proof

The helper app target includes these Swift files (the exit relay's four and the two key files among them) plus `ConfigurationBackup.swift`, `ScopedHermesImport.swift`, `NativeDependencyInstaller.swift` and `NativeSetupKit.swift`, and bundles `runtime_entry.py` unchanged. Updating that resource requires changing the embedded digest and tests. Its private Keychain group is `$(AppIdentifierPrefix)com.coreykozarski.nollie.runtime`.

Embed `Nollie Runtime.app` under `Contents/Helpers` and the LaunchAgent plist under `Contents/Library/LaunchAgents` in Direct builds only. Register through `SMAppService.agent(plistName:)` after explicit setup consent, respect approval state, and complete the ordinary ConnectionTester handshake. Store archives must contain neither embedded service nor registration plist.

The parent build always runs `Tools/runtime-helper/embed-runtime-helper.sh`. Tracking only the generated signature seal allowed an incremental build to leave an older helper inside the app after the standalone helper rebuilt. The script rejects a standalone entry point that differs from current source, copies the signed helper, then compares the entire embedded bundle and LaunchAgent to their inputs. A build fails on any mismatch. Synthetic bundle tests cover stale resources, unchanged seal bytes and Store exclusion.

The notification helper uses the same always-run rule through `embed-notification-helper.sh`, with full built-to-embedded bundle comparison. This verifies packaging; it does not register, restart or establish notification delivery.

Both scripts resolve trusted build roots physically, reject path traversal and linked paths within those roots, and reject overlapping source and destination bundles before copying. Normal system aliases above the build root remain supported.

`python3 Tools/runtime-helper/run-tests.py` checks Direct and Store policy, credentials and consent through fakes, private temporary receipts, signature requirement parsing, cancellation, heartbeat freshness and the owner-pipe wrapper. It also typechecks the real helper entrypoint in both modes. It does not register a service, access the real Keychain or launch Hermes. Signed IPC, live Keychain access, login restart and the final app connection still require end-to-end acceptance.

For the catalog regression, `python3 Tools/runtime-helper/run-model-inventory-smoke.py --python <prepared-environment>/bin/python --source <pinned-hermes-source>` runs the actual inventory code in disposable empty homes with every network request blocked. It checks the original foreground-fetch regression, the scoped fix, saved selection and missing-credential status. It neither contacts nor changes a running service.

## Setup Kit: reviewed Hermes changes and Nollie's add-ons

The Direct app carries `Contents/Resources/Setup Kit`, built on every Direct build by `Tools/runtime-helper/embed-setup-kit.sh` from `Tools/dev/setup-kit.py`:

- `hermes-overlay/`: `HermesOverlay/` here, generated by `Tools/dev/hermes-overlay.py` from the pinned Hermes archive or a local checkout passed with `--source`. It contains only the four [remaining extension gaps](../../Companions/hermes-patches/README.md). Workflow helpers stay in the add-on. Each entry records the original's SHA-256 and the reviewed file's. While preparing Hermes, the app checks `overlay.json` against `NativeSetupPlan.hermesOverlayDigest`, checks each original in the freshly unpacked tree, writes the reviewed file and checks it again, all before the tree is published. The Hermes receipt records `<version>+nollie.<digest prefix>`, so a changed overlay means a fresh, verified Hermes.
- `add-ons/`: the add-ons `Tools/pins.json` marks managed, `managed_addons.py` and `kit.json` (every file's size and SHA-256). The "addons" step runs the installer with the managed environment's Python. It checks every file, keeps a dated copy of an older add-on, starts Board follow-through on a first install only, builds the page reader's environment from its hash-locked requirements (wheels only) and lists the add-ons in `plugins.enabled` with a dated backup of `config.yaml`; a name the person disabled stays disabled. It never uses `hermes plugins enable`, whose dependency sync would rebuild the verified environment. At launch the app brings a prepared setup's add-ons up to the kit it carries; Hermes loads them the next time the service starts.

The service still needs only the four runtime receipts; add-ons are not a start condition.
