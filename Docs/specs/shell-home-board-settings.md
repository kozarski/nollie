# Shell, home, Board and Settings

[Spec index](README.md) · Uses [Gateway client](gateway-client.md), [Conversation engine](conversation-engine.md) and [Conversation UI](conversation-ui.md)

## Purpose

Give each bot a familiar place, and keep the person oriented between its chat, work and settings. A screen always belongs to a known connection and bot. Switching either must never send an action to the wrong place.

This module owns navigation and application preferences. It asks other modules for data and actions. It does not keep a second transcript, interpret reply fragments or reopen sessions just to draw a badge.

## Behaviour in plain words

### Shell and home

- Restore the saved destination when it still exists. With no connection, explain how to connect. While locked, hide content and incoming previews until the person unlocks.
- Each Hermes profile is a bot with its chosen name, character and colour. Keep its main chat easy to reach. History and a new side chat stay separate choices. Compression never adds another bot or main-chat entry.
- Preserve bot pinning, history search, unread state, useful previews and an indication when a bot needs an answer. Opening a chat never marks a request answered.
- The bot's home choice decides which chat opens when selected. Resolve it through the engine's lineage identity. If it was removed, offer a new choice rather than opening another bot's chat.
- Keep drafts and reading positions per conversation. Wide windows show bots beside content; narrow windows show one pane with a clear route back. Use the conversation layout rules.
- Notifications and links name the exact connection and destination scope: profile/conversation for a message, board/task for Board. Unlock, resolve, then navigate. Explain missing targets; never guess from a title.
- Private bots stay out of home, search, notifications, exports and demos. Only the explicit authenticated bot-settings path may manage their privacy choice. Background reads never fetch their conversations.

### Board

Board shows ongoing work and tasks needing the person's help. Empty, disconnected and unavailable are different states. Opening Board does not install its plugin or start workers.

Keep task creation, renaming, descriptions, assignment, priority, moves, comments, block/unblock, done, archive, delete and Stop the Worker. Offer only actions supported by the service and current task. Dragging and choosing Move have the same effect and confirmation rules.

Task details show description, result, latest summary, children, runs, comments, history and available worker log. Discuss task opens the intended bot conversation with task context and a route back. It submits nothing until the person sends it.

The badge counts distinct tasks needing human attention, not every worker event. Keep a change pending until confirmed. A lost result is uncertain: refresh the task before offering another attempt. Stop names the worker; it does not mean stop the gateway. Delete requires a clear confirmation of its scope.

### Settings

Keep ordinary choices short and put technical detail in Developer Mode. Preserve these visible capabilities when supported:

| Area | Behaviour to retain |
| :--- | :--- |
| Connections | Add, pair, select, reconnect and remove. Forget saved credentials separately and explain the effect. Keep the existing setup usable while checking a new one. |
| Bots | Add a bot; edit name, description, instructions, character, colour, home and privacy; manage Apps & Access. Report partial saves by section and retain failed edits. Never repeat an uncertain creation automatically. |
| Appearance | Theme, glass/solid appearance, text size, reply width/style, colours, timestamps and step/reasoning visibility. Accessibility settings take precedence. Pending approvals remain visible. |
| Notifications and lock | Consent, preview privacy, quieting Mac-driven chats, App Lock and supported shortcuts. A failed privacy update is visible. Locked content cannot leak through search, badge descriptions or window previews. |
| Schedules | Ask for a task, view, pause/resume future runs, edit supported details and delete. Keep previous results. Do not silently rewrite a custom schedule. |
| Access and computers | Per-bot access, per-task Mac permission, Watch, Take over, Hand back and Stop stay separate. Picture freshness is not worker status. Reconnect cannot restore revoked access. |
| Mac services | Setup/import, runtime health, pairing, saved sign-ins and removal remain owned service flows. Client-only Mac and iPhone do not offer to host the runtime. |
| Help and About | Status, troubleshooting, version and acknowledgements. Restart/update explain their effect before starting. Keep third-party notices available. |

Keep [Papertrail](papertrail.md) and [Night shift](night-shift.md) behind their own contracts. Routing them through this shell does not broaden permissions or complete their pending acceptance work.

## Public types and contracts

These are new design names. The user-visible inventory above is the only input taken from current app screen text.

| Type | Contract |
| :--- | :--- |
| `PlaceInApp` | Home, lineage conversation with optional row, Board with optional task, or a Settings section. Chats carry exact connection/profile scope. Board carries connection/board scope; an assignee profile is only an explicit filter. Discuss task resolves a separate exact profile/conversation. Settings carries the scope of the value being edited. |
| `NavigationLedger` | Per-window saved destination, selected bot and pending link. Owns neither transport nor transcript. Stores opaque identities, not credentials or preview text. |
| `BotHomeRecord` | Stable profile identity, display name/art reference, main-lineage reference, optional chosen home, unread/attention summary and privacy eligibility. A rename does not change identity. |
| `AccessSnapshot` | Advertised capabilities, connection kind, platform support, privacy and permission facts. Enable an action only when every required condition holds. Unknown information withholds it. |
| `BoardRead` | Connection/board scope, task identities, server lanes, attention facts, event marker if present, fetch time and freshness. Unknown task states remain visible and read-only. |
| `BoardChange` | One task intent, immutable target, displayed revision/fingerprint and local attempt ID. The local ID tracks work; it is not server deduplication. |
| `PreferenceEdit` | Device, connection or profile owner; old confirmed value and proposed value until that owner confirms. Credentials use a separate service boundary. |
| `ShellEffect` | Navigation, scoped read or confirmed action through a service boundary. Carries a generation so a late result cannot replace another connection's screen. |

Remote actions use the gateway transport boundary and small REST/plugin adapters with explicit contracts. Local preferences use local storage. Runtime, credentials, sign-ins and notifications have separate service boundaries. The shell never reads Hermes databases or launches tools by interpreting chat text.

## States and transitions

| State or event | Transition |
| :--- | :--- |
| No connection | Show setup. Save a new connection as usable only after authentication and gateway readiness. |
| Opening | Read capabilities and eligible roster. Preserve local drafts and selection. Loading is not an empty roster. |
| Connection drops | Keep confirmed data labelled stale. Reconnect may retry reads; uncertain writes cannot retry automatically. Chats recover through the engine. |
| Sign-in expires | Keep edits, disable remote writes and offer sign-in. Re-read the scope after success before enabling actions. |
| Switch connection/bot | Advance selection generation, detach old view subscriptions and cancel screen reads. Preserve drafts. Sent mutations remain tracked under their original owner. |
| Lock/background | Hide content, stop screen polling/previews and report requests no longer presentable. Never claim remote work stopped. Unlock and reconcile on return. |
| Settings edit | Clean → edited → saving → confirmed, partially saved, rejected or uncertain. Old saves cannot overwrite newer edits. |
| Task change | Ready → awaiting result → confirmed, rejected or uncertain. Refresh uncertain work before another attempt. |
| Missing Board plugin | Explain the missing capability. Recheck is a read; installation stays an explicit setup action. |
| Selected resource deleted | After confirmation, return to its parent and clear only its saved destination. Failure leaves it present. |

Home uses roster summaries, without resuming every conversation. Read and attention differ: a card may be read but still unanswered. Read markers remain local per connection/profile/lineage until a server contract supports cross-device synchronisation.

## Contract evidence and limits

Hermes paths are relative to the pin in the [index](README.md#source-boundary).

| Surface | Evidence and constraint |
| :--- | :--- |
| Bots | OpenRPC `profiles.list`, `profiles.describe`, `profiles.create`, `profiles.configure`. Roster includes previews; configuration reports sections separately. Saving a name does not prove instructions saved. |
| Settings/schedules | OpenRPC `config.get`, `config.set`, `config.show`, `cron.manage`, `gateway.capabilities`. Match each method's declared scope. Gateway support does not prove a restricted phone route is permitted. |
| Board | `plugins/kanban/dashboard/plugin_api.py`, under `/api/plugins/kanban`: board/task reads, task writes, comments, reassignment and run termination. Supply explicit `board` after resolving selection; omission uses the server's active board. |
| Refresh | Board read returns grouped columns, `latest_event_id` and server time. A local generation is not a server transaction revision. Start with refresh on entry, after changes, manually and every 60 seconds while visible. Never label polling Live. |
| Concurrent edits | Task patch may apply fields separately; the inspected endpoint has no expected-revision compare-and-swap. Send one conceptual change, refresh on failure/conflict and report partial results. Do not claim atomic multi-field saves. |
| Owned services | [Nollie Link](../nollie-link.md), [Watch and take over](../watch-and-take-over.md), [Saved sign-ins](../saved-sign-ins.md), [Ask first](../ask-first.md). Keep their allowlists and permission checks. These contracts are separate from OpenRPC. |

## Error cases

- A missing bot is not permission to open the default profile. Keep its draft and explain the missing destination.
- Ignore old-scope read results in the visible screen. Record mutation results under their original owner.
- Unknown fields may leave known read-only content usable. Unknown actions or permission meanings never enable a control.
- Interrupted creation, comment, deletion, update or restart is uncertain until proved. A spinner timeout cannot authorise repetition.
- Denied permissions stay denied after relaunch. A server privacy change removes cached previews/subscriptions before another home render.
- Corrupt preferences reset only the affected value to a documented default. Never grant access, disable lock or delete drafts.
- A restricted connection cannot bypass a missing route by trying a different transport.

## What is measured and how

| Measure | Acceptance |
| :--- | :--- |
| Scope | Zero wrong-bot previews, sends, saves or tasks during rapid switching and delayed replies. Assert target/generation, including two windows. |
| Home reads | One roster read per refresh, sharing in-flight requests. No session resumes or per-bot history reads just to paint home. Record call counts. |
| Navigation | Cached tap-to-content p95 at most 100 ms over 100 switches. Cold opens show progress within 100 ms; report remote wait separately. |
| Board polling | At most one read in flight per board and one periodic read per 60 seconds per visible board. None from hidden/locked/disconnected screens. Count manual and reconciliation reads separately. |
| Accessibility/privacy | All actions reachable by keyboard or VoiceOver. No clipped decisions at largest text size. Locked captures and diagnostics contain no message bodies or credentials. |
| Saved choices | Drafts, home, pins and appearance survive relaunch/resizing. Removing a connection affects only its own state. |

## Test plan

1. Pure navigation tests: restore, unlock, missing targets, aliases, links, back and two windows. Delay every read across a scope switch.
2. Adapter fixtures: missing capability/plugin, partial saves, Board conflict, unknown task state, lost result and sign-in expiry. Prove no duplicate mutations.
3. Recorded UI flows: first connection, return to main chat, history, side chat, Board attention/detail/discussion, settings save, permission refusal and reconnect with drafts.
4. Privacy checks use invented bots only, including a privacy change while visible. Cover home, search, notification and export paths. Never use personal profiles.
5. Check Direct Mac, client-only Mac and iPhone. Unsupported service actions explain the limit. Cover narrow/wide, largest text, dark/solid and locked screens.
6. Reviewer runs builds, unit/UI tests through the new harness and inspects phone simulator and Mac window captures. None were run for this documentation task.

## What it replaces

Replace duplicated navigation, home summaries, Board screen state and settings coordination with these boundaries. Preserve the visible inventory, service permissions and notices. Retire direct chat/transport ownership from the previous shell when all routes use the new engine.

## Decisions and open questions

Decided: explicit target scope, one conversation owner, capability-based controls, local read markers, honest polling freshness and no automatic retries of uncertain writes.

Open: review the complete settings inventory before cutover; define server support if shared read markers are wanted; decide whether Board needs live updates after the polling baseline; record owned-service flows outside pinned Hermes. Their acceptance remains pending until those recordings exist.
