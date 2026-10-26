# Architecture

[← Nollie](../README.md)

Nollie is the native app. Hermes runs the assistant.
A saved gateway connects the app to one Hermes installation; each profile appears as a bot.

## Source map

| Directory | Responsibility |
| :--- | :--- |
| `Apps/Nollie/` | Shared iPhone/Mac app model, SwiftUI screens, onboarding and push integration |
| `Apps/Mac/` | Mac window, menus, app delegate, platform adapters and the live picture's host (`Live/`) |
| `Packages/NollieCore/` | Gateway networking, wire models, chat/runtime state, storage, pure policies and the live picture's wire, encoder and client (`Live/`) |
| `Shared/` | Bot drawing, appearance policy, icon and types shared with extensions |
| `Extensions/` | Notification presentation; the Ask Nollie control and the Lock Screen Stop (Live Activity) |
| `Services/Runtime/` | Direct Mac runtime supervisor, signed IPC, the Nollie Link door with its live relay, and bundled entry point |
| `Services/Notifications/` | Opt-in Mac notification helper |
| `Companions/` | Gateway-side integrations for pairing, computer previews, using this Mac (nollie-mac), workflow, the crew, the polite web reader and legacy push |
| `Tests/Unit/`, `Tests/UI/` | Unit and app UI tests |
| `Tools/` | Mock gateway, validation, packaging and release scripts |
| `Docs/` | Focused development and product notes |

Everything Nollie writes outside its app lives in `~/Library/Application Support/Nollie`;
`NolliePaths` (`Packages/NollieCore/.../Storage/`) says where, and `Tools/dev/test_one_folder.py`
fails on code that looks a folder up by itself. Removing Nollie goes through one plan
(`Apps/Nollie/Settings/Removal/`): `RemovalPlan.build` lists steps from what is on disk, and
`RemovalPlan.permits` checks each step again just before `RemovalRunner` does it. Nollie Runtime and
Nollie Notifications watch their own bundle (`Services/Runtime/AppPresence.swift`) and stop, without
deleting anything, when Nollie.app goes to the Trash. [Remove Nollie](help/remove-nollie.md)

`Apps/Nollie/App/AppModel.swift` coordinates the active connection and navigation.
`GatewayRuntime` owns a connection's session state; `ChatSession` assembles the transcript.
Platform effects enter the core through narrow hooks instead of UI framework dependencies.

## Gateway contract

REST handles stored resources and configuration. `/api/ws` carries live JSON-RPC requests and events.
Preserve the gateway's base-path prefix and the exact profile on every scoped request.

| Concern | Contract |
| :--- | :--- |
| Readiness | Dashboard JSON, accepted credentials, then `gateway.ready` on the socket |
| Existing chat | `session.resume`, with history and persisted row identities |
| New chat | `session.create` |
| Send and stream | `prompt.submit`, `message.delta`, tool events, `message.complete` |
| Stored history | `GET /api/sessions/{id}/messages` |
| Approvals | Typed server requests and matching responses on the same connection |
| Settings | Profile-scoped REST endpoints, with capabilities checked before exposing controls |

The public status endpoint is not authentication proof.
Connection tests must confirm a protected request and socket readiness.
Cloudflare Access headers, where configured, accompany both HTTP requests and socket upgrades.

Native account sign-in uses the gateway's authorization/token flow, with refresh credentials stored through Keychain.
Session-token connections use the gateway's supported token transport.
Never log credentials or add them to diagnostic URLs.

A resumed session may resolve to a compression descendant.
Notification navigation keeps the requested identity, exact profile and persisted row ID, and fails safely when a message is gone.
Intentional-silence projection hides trusted control results without deleting raw history or hiding literal user messages.

## Owned background services

Only `NOLLIE_DIRECT` builds package the managed runtime path.
The signed helper owns an isolated home, separate API/gateway children and a stable credential per installation.
Its executable and launch-agent entry are relative to the containing app bundle.
Installation data belongs under Application Support/Nollie, not the source checkout.
Every third-party version the setup installs is pinned with its checksum in `Tools/pins.json`; the app also
carries a Setup Kit (Nollie's reviewed Hermes changes and its add-ons, each file checked by SHA-256 before use).

The app verifies identity and readiness before saving a managed connection.
Ephemeral endpoint changes are resolved through authenticated helper status.
Starting or stopping the helper must not affect an independently installed Hermes service.

A linked iPhone reaches the managed assistant only through the helper's Nollie Link door: TLS 1.3 with a pinned key,
a device credential on every request, an explicit route allowlist and a JSON-RPC allowlist on the socket. Hermes stays on loopback. See [Nollie Link](nollie-link.md).

While a helper's computer runs, the helper also runs a small HTTP and SOCKS5 relay on Apple's VM network so
the computer reaches the web from the Mac, through its VPN or Tailscale exit node when one is on: VM sources
only, public destinations only, web ports only, nothing logged. See [Exit relay](../Services/Runtime/README.md#exit-relay-for-helpers-computers).

The Direct edition also carries Nollie Computer (Nollie's build of Cua Driver) as a bare helper that
only Nollie starts, only for a task the person approved, limited to those apps and stopped with the
task. See [Nollie Computer](nollie-computer.md).

A helper's own computer can be watched live from a chat, and taken over: the person holds the
helper's desktop lease (after Face ID) and the helper waits until they hand it back. See
[Watch and take over](watch-and-take-over.md). The Mac makes the live picture (ScreenCaptureKit or the
add-on's pictures, encoded as real-time HEVC); Nollie Runtime relays it to a linked iPhone on the door's
own `/nollie/live` route. See [The live picture](live-picture.md).

Saved sign-ins keep passwords in the Mac's Data Protection Keychain only, behind Touch ID or the Mac's
password for every read. A helper asks through the workflow add-on and Hermes's approval gate; the Mac
types the sign-in into the helper's computer and the helper hears only how it went. Pictures of every
computer pause while it is typed. See [Saved sign-ins](saved-sign-ins.md).

Helpers can look at the calendar, reminders and contacts on the Mac that runs Hermes, for the
helpers the person turns them on for. Nollie on the Mac reads them itself (EventKit and Contacts), and
words any change for a card before making it only after the yes. See
[Calendar, Reminders and Contacts](calendar-reminders-contacts.md).

Ask first holds every tool call or computer action that sends, buys, posts or deletes for the person's
yes, by fixed rules in a Hermes hook of the workflow add-on; unattended runs hold it for Night shift.
See [Ask first](ask-first.md).

The notification helper has separate consent and scoped read access.
It observes eligible outcomes and publishes private CloudKit events; it does not open agent sessions or perform tasks.
Managed-runtime endpoint refresh in the notification helper remains a release gap.

## Companion boundaries

Each companion has its own instructions in [Companions](../Companions).
Keep credentials, ownership filters and idempotent delivery rules in the relevant integration.

Workflow's Board reader and cron binding helpers live inside `nollie-workflow/hermes_support`.
Both the standalone installer and managed Setup Kit keep them there; neither copies helpers into
Hermes source. The add-on imports Hermes's existing Board and locked job-store code.

Four source exceptions remain for Hermes v0.22.2: cron checks must stop before agent creation,
Board notifications need a trusted machine tag and accurate timeout wording, and quiet Bot Chat
needs that tag carried through delivery, storage, completion and resume. Hermes has no supported
hooks at these points. The managed setup uses the minimal reviewed overlay and checks each pinned
file's hash before replacing it. A changed source is refused. The
[patch map and tests](../Companions/hermes-patches/README.md) record each gap and its coverage.

The legacy push source in `Companions/hermes-push/` is mirrored into
`Apps/Nollie/Resources/hermes-push/` by `Tools/sync-push-companion.sh`.
Change the source, run the sync tool, then verify parity.
Do not silently install companions or restart a user's gateway while changing app code.
