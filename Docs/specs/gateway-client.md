# Gateway client

[Spec index](README.md) · Next: [Conversation engine](conversation-engine.md)

## Purpose

Keep Nollie connected to the right Hermes bot. Turn messages on the wire into typed values, recover missed events, and give every request a clear outcome. A dropped connection must not lose a reply, repeat a send, or leave Hermes waiting for a screen that Nollie cannot show.

This module has no views, chat rows or local history store. The [conversation engine](conversation-engine.md) decides what an event means. The shell supplies the selected connection, credentials and profile. The [test harness](tests-and-tools.md) supplies the same wire through recordings.

## Behaviour in plain words

- Connect, wait for Hermes to say it is ready, then exchange capabilities before attaching chats.
- Keep each connection, bot and chat separate. An old socket cannot update a newly selected bot.
- After a break, ask Hermes for the events missed since the last saved event. Apply each event once.
- If Hermes restarted or no longer has all the missing events, ask the engine to rebuild the current state from saved history and a fresh session snapshot.
- Restore questions that Hermes is still waiting for. Remove questions answered elsewhere or cancelled by Hermes.
- Answer an unsupported request promptly. Do not pretend that the person refused it.
- Report a lost mutation response as uncertain. Reconnecting is not permission to send it again.

## Source and scope

The source of wire types is `apps/shared/src/gateway-contract.openrpc.json` in the read-only Hermes checkout at `d923a5eb487a17c0a68801bba9ef0f56c81040a8` (`v0.22.2`). Its SHA-256 is `8848b394df533af8b37afd3cdccfc48b3e3d6ca1ce4037ebaf38653e33ed832e`.

That file contains 257 client methods, 774 schemas, 16 server request methods and 77 notification types. Generating a type does not enable a feature. Nollie calls only the methods required by these specs and advertises only the request handling it provides.

The OpenRPC file describes method parameters and results. It does not fully describe authentication, the outer message envelope, socket heartbeat, replay retention or concurrent snapshot timing. The pinned Hermes server is the evidence for those details. Proposed Nollie policies below are labelled separately from those server facts. No existing Nollie Swift implementation is a design source for this spec.

## Public types and contracts

These are proposed boundary names. Generated wire names come from the contract; the remaining names describe new Nollie boundaries.

| Public value or boundary | Contract |
| :--- | :--- |
| `ContractStamp` | Contract version, source commit, SHA-256 and generator format version. Included in generation checks and fixture manifests. |
| `HermesWire` | Generated namespace containing every schema, typed client call, typed server request and notification payload. No hand-maintained duplicate models. |
| `FieldPresence<Value>` | Distinguishes an absent field, explicit `null`, and a supplied value when the schema permits those distinctions. A missing required field is a decode failure. |
| `PeerScope` | Local connection identity and explicit profile identity. Never a display name, credential or inferred currently selected bot. All calls, replies, events and cursors carry this scope locally. |
| `WireCursor` | Scope, runtime session ID, opaque replay epoch and highest contiguous sequence committed by the engine. A cursor cannot move between epochs or sessions. |
| `SharedWireLink` | Opens one connection, writes one complete text message, yields incoming text messages and closure, and closes. Write acceptance proves only local transport acceptance. It never proves a mutation ran. |
| `TapeWireLink` | Implements the same transport boundary from a script. Expected sends, incoming text, failures, barriers and clock changes pass through the production decoder and connection rules. No canned engine state. |
| `WireStep` | One scripted action: `expectSend`, `receive`, `close`, `advanceClock` or `barrier`. Unexpected writes or unconsumed required steps fail a test. Request-ID substitutions are explicit bindings, never broad ignored fields. |
| `LinkState`, `LinkInput`, `LinkEffect` | Values consumed and produced by the pure `LinkMachine` transition function. It reads no clock, network, disk or global selection itself. Time, randomness and cancellation arrive as inputs. |
| `DeliveredNotice` | Scope, local socket generation, adopted epoch, optional session/sequence, live or recovered source, and a typed payload. Recovery is metadata, never a fabricated server field. |
| `CatchUpResult` | Generated replay result plus local scope and generation. Preserves `events`, `latest_seq`, `truncated`, `count`, `epoch` and `open_requests` without treating them as an atomic snapshot. |
| `EngineReceipt` | Engine acknowledgement that a contiguous event batch and its new cursor have been committed together. Until it arrives, the gateway may redeliver that batch after a failure. |
| `PresentationOffer` | Shell-supplied ability to offer a named request in the exact scope and session, including a matching window and an unlocked app. Capability and availability are separate from whether the card has actually appeared on screen. No credentials or answer text. |
| `RequestDisposition` | Deliver to the engine's request book, send a typed result, send an unsupported-method error, or send a supported not-shown decline. Every received request takes one of these paths. |
| `CallOutcome<Value>` | Typed success, explicit remote rejection, definitely not sent, or uncertain after submission. Includes a local call identity for outbox reconciliation, not a server idempotency claim. |
| `LinkIssue` | Typed connection, authentication, compatibility, malformed-message, size-limit, timeout or recovery problem. Contains safe metadata and a short display message, never raw frames or authenticated URLs. |

The gateway owns decoding, transport ordering, call matching and replay staging. The engine owns durable event application, the request book and outbox. The shell owns authentication and presentation availability. None may silently take another module's job.

### Generation rules

1. Read the pinned OpenRPC bytes locally. Generate all `methods`, `components.schemas`, `x-server-requests` and `x-notifications` in a stable order. The same input and generator version produce byte-identical output without timestamps or machine paths.
2. Preserve exact wire keys, method strings, required fields, defaults, enum values, object openness and union alternatives. Preserve integer precision. Do not route identifiers or sequence numbers through floating-point values.
3. Support references, nullable unions, arrays, maps, literal discriminators, recursive JSON values and the schema combinations present in this pin. Fail generation on a construct not implemented. Never replace an unfamiliar shape with a string or an untyped dictionary.
4. Validate outgoing values against the pinned contract. Omit an absent optional field; encode explicit null only when allowed. No extra parameter keys: Hermes rejects unknown parameters.
5. Decode known incoming required fields strictly. Allow additional keys for forward compatibility without letting them change known meanings; retain unknown members only where the contract defines an open object. Unknown enum cases and unknown event types remain explicitly unknown, never mapped to a successful known state.
6. An unknown non-critical notification may be recorded as safe metadata and acknowledged as deliberately ignored. An undecodable state-changing event prevents cursor advancement and requires recovery or a compatibility error. No silent gap in chat state.
7. Keep the small outer JSON-RPC envelope and the socket heartbeat extension separately documented. Do not alter the OpenRPC file to pretend those definitions came from it. Add source-backed tests for them.
8. Do not copy upstream prose into generated comments. Include required source and licence provenance without transferring branding or product presentation.

## Wire behaviour at this pin

### Messages and scope

The socket endpoint is `/api/ws`. Each WebSocket text message is one JSON object. Hermes can flush several messages together, but each remains a separate WebSocket message. Do not parse a JSON array as a batch or treat network chunks as complete messages. Binary input is unsupported.

Client calls carry `jsonrpc: "2.0"`, an integer `id`, `method` and object `params`. Results and errors echo the ID and have no method. Nollie allocates a fresh integer within each socket generation and rejects replies from an older generation. A response must contain exactly one of result or error.

Server requests carry a string ID, a method and parameters containing `session_id`. Keep the string opaque, including the pinned `srq-` form. Never confuse it with a reply to an integer client call.

Notifications have outer method `event`; `params` contains `type`, optional `session_id`, optional `payload`, and a per-session `seq` when sequenced. `gateway.ready` arrives first and supplies `replay_epoch`, `change_events`, optional `heartbeat`, and skin data. A session-less event has no replay cursor and must be refreshed through its feature's read method after reconnect.

Set `profile` only on methods whose generated parameter schema permits it. Match the requested profile with the returned session identity. A stored session ID and a runtime session ID are different values: `session.resume` takes a stored ID and returns a runtime ID; `session.activate` addresses a live runtime session. Never use a title as identity, even though Hermes accepts exact titles for resume.

### Authentication and socket limits

Credentials enter through the shell's credential provider and exist only for the connection operation. The pinned server accepts a local session token for its local mode. Its gated mode accepts a verified user access token or a gateway ticket; tickets are single-use and short-lived. A display ticket is not a gateway login. Nollie must not request or manufacture the internal process credential.

Use the normal system HTTP/WebSocket stack. Preserve certificate validation, proxy and network-change behaviour. Do not wait for a separate reachability check before attempting a connection. Never log request URLs, headers, credentials, prompt bodies or server request answers.

The pinned dashboard configures a 384 MiB incoming WebSocket ceiling to accommodate attachments. That is a server ceiling, not permission for Nollie to retain messages of that size. The proposed Nollie receive limit is 16 MiB per message and a bounded staging queue of 1,024 events or 8 MiB, whichever fills first. Oversized messages fail with a typed limit issue. Queue overflow closes the connection and starts recovery; it never drops selected deltas and continues as if complete. A repeated oversized snapshot stops automatic retry and asks the owning module to use a bounded read.

Outbound attachment limits belong to their individual method contracts and product policy. Reject a file before encoding if it cannot fit those limits. Do not raise the chat receive limit or keep an attachment encoded in the event queue to accommodate an upload.

### Capabilities and heartbeat

After ready, send `client.capabilities` with `server_requests: true`. This is a promise to answer every server request with a supported result or an explicit error, not a claim that every method has a screen. Its result lists possible server requests and `declines_not_shown`. Also read `gateway.capabilities`; withhold exclusive-submit features unless `per_session_exclusive_submit` is true.

The socket advertises `heartbeat`. When true, use the transport extension `gateway.ping`, whose result is `{ok: true}`. It is answered by the socket reader even when normal dispatch is busy. This method is absent from OpenRPC and needs an explicit adapter test. OpenRPC's separate `ping` returns `{pong: true}`. Do not substitute one result shape for the other.

Proposed liveness policy: one heartbeat every 15 seconds while active, one outstanding heartbeat, and a 45-second reply deadline. A foreground wake triggers a check. Suspension pauses local deadlines; waking does not invent a server failure from time spent suspended. These values are Nollie policy and use the injected clock.

## States and transitions

The overall connection has the states below. Catch-up status is also tracked per attached session, so one session needing a history rebuild does not freeze healthy conversations.

| State | Input | Next state and effect |
| :--- | :--- | :--- |
| Stopped | Connect with a scope | Opening. Start a new generation and request a transport. |
| Opening | Socket accepted | Awaiting ready. Begin a 15-second ready deadline. |
| Awaiting ready | Valid `gateway.ready` | Negotiating. Adopt this generation's epoch and exchange capabilities. |
| Negotiating | Required capabilities accepted | Connected. Attach desired sessions and begin each session's catch-up. User sends for that session remain held until recovery is complete. |
| Connected | Missing sequence, reconnect or session attachment | Catching up for that session. Buffer new events and request replay. |
| Catching up | Complete replay and engine receipt | Live for that session. Release staged events in sequence order. |
| Catching up | Changed epoch, truncated ring or invalid sequence coverage | Rebuilding for that session. Request authoritative history and session state from the engine. |
| Rebuilding | Engine proves reconciliation and commits a new baseline | Catching up, then Live after a successful replay barrier. |
| Any active state | Transport lost, heartbeat deadline or temporary server failure | Waiting to reconnect. Close this generation; resolve outstanding calls as not sent or uncertain. |
| Waiting to reconnect | Injected retry deadline | Opening, with a fresh generation. |
| Any active state | Authentication refused | Needs sign-in. Stop timed retries until the shell supplies changed credentials. |
| Any active state | Unsupported required contract or repeated oversized state | Needs attention. Keep cached reading available; do not loop. |
| Any state | Disconnect, lock requiring disconnect, removed account or changed scope | Stopped. Cancel owned work and discard volatile credentials and uncommitted wire buffers. |

Proposed retry schedule is 1, 2, 4, 8, 16 and then 30 seconds, with injected jitter up to 20 percent. Reset the attempt count after a minute of healthy connection. Manual retry can open immediately. Cancellation and stale-generation inputs are harmless and never revive a stopped connection.

Calls have independent deadlines. Read-only probes may be retried according to their declared policy. Mutations, request answers and session-control actions have no blanket automatic retry.

## Replay and recovery

1. Reattach the intended session through the engine's exact stored/runtime ID mapping, using `omit_messages: true` where supported. Start buffering that session's new events before attachment completes.
2. If the saved cursor has the same epoch, call `session.events.since` with its runtime `session_id`, `last_seen` and permitted explicit profile. If the epoch changed, do not reuse the old number. Request an authoritative rebuild instead.
3. `events` contains event parameter objects, not full JSON-RPC frames. Decode them through the same payload decoder as live events. Validate the returned session and epoch, reject conflicting duplicates, and merge replay with buffered live frames by sequence.
4. Deduplicate only within the same scope, session and epoch. Deliver contiguous batches in ascending sequence. Events at or below the committed cursor are duplicates. Hold a later sequence until its gap is filled or recovery is required.
5. `latest_seq` is a high-water observation, not proof that all events through that value were returned. Hermes reads replay entries, latest sequence and truncation separately. A new event can arrive between those reads. Never assign `latest_seq` directly to the applied cursor. Request the remaining range or use buffered live events.
6. Advance the durable cursor only with `EngineReceipt`, after the engine commits state and cache together. A crash before that receipt causes safe replay. Do not acknowledge data merely because it was decoded or placed on a UI queue.
7. Merge `open_requests` into the request book independently of notification replay. During catch-up, preserve cancellation inputs and apply them after the restored request snapshot so a late snapshot cannot resurrect a cancelled request. Requests are not reconstructed from an old notification ring.
8. If `truncated` is true, a known required sequence is missing, or the epoch changes during a call, do not apply the incomplete replay as a successful recovery. Preserve the reading position and outbox while the engine fetches authoritative bounded state.
9. Re-fetch session-less feature state after reconnect, using the shell's refresh list. Those events are not replayed.

Hermes retains at most 512 events and 4 MiB of frozen event data per session, at most 64 retained sessions, and 64 MiB across the process. Eviction and a single oversized event can both create a replay gap. Sequence counters remain monotonic within the epoch even after the session's ring is evicted. These limits make replay a reconnect aid, not a history API.

A session snapshot has no atomic event-sequence checkpoint at this pin. A moving turn can change while REST history, session state and replay are read. The engine must reconcile authoritative row/turn identities and prove convergence in fixtures. If that cannot be proved, remain in Rebuilding and obtain a stable turn boundary before committing the new cursor. Do not claim an atomic snapshot or append replayed text blindly to snapshot text. A stronger upstream snapshot fence remains an open protocol need.

## Requests the app can and cannot show

Request handling is scoped to the connection and session, never whichever chat happens to be frontmost. The engine keeps one entry per server request ID and epoch. The UI may attach or detach a presentation without creating another request.

A supported card can be outside the viewport while the person reads older messages. Keep it pending and offer a clear way to reach it; do not decline it or move the reading position merely because a reused cell is offscreen. Actual visibility is a separate acknowledgement. Send `approval.received` only after a usable approval card is on screen, using its durable approval `request_id`, not the outer server request ID. Creating or restoring a row does not qualify. Its `acknowledged` result records presentation, not an answer or permission to act.

The pinned `display.install.sudo` request is app-level and has an empty `session_id`. Route that declared exception only to an explicitly active setup surface for the owning connection, or return the unsupported error when no handler is available. Never assign it to the currently selected chat. Other empty-session requests need their own documented contract and route before being supported.

| Request situation | Required response |
| :--- | :--- |
| Supported question with an available presentation | Give the typed request to the request book once. Offer its card without changing a browsing position. Send only an explicit person's answer. |
| Window-owned bridge, but no suitable window in this client | For `preview.read`, `preview.act`, `terminal.read`, `window.read` and `tour`, send error code `4404` only when `declines_not_shown` is true. No hidden action or guessed answer. |
| Unknown request method | Send JSON-RPC error `-32601` with the exact request ID. |
| Known non-window request with no supported or safely available screen | Send `-32601` promptly with short text such as “This request cannot be shown here.” This is a client limitation, not a user refusal. A supported offscreen card alone is not this case. |
| Malformed known request | Send `-32602` when its request ID can be recovered safely. Do not create a partly decoded approval card. |
| Already cancelled or answered request | Do not show or resend it. Treat a later answer as expired. |
| Request for a session outside this connection's attached scope | Do not display it in another bot. Use a supported not-shown decline for window bridges; otherwise send a scoped error and record safe diagnostic metadata. |

The pinned window-decline behaviour matters with several clients. One `4404` leaves the request open for another attached client that can show the window. Hermes settles it only after all answering clients decline. An ordinary `-32601` error settles the request immediately. Therefore a known window bridge on iPhone uses the negotiated `4404` path, even when iPhone has no matching bridge feature.

If the server does not advertise decline support, never send `4404` and assume it is harmless. Mark that connection incompatible with multi-client window requests and report the limitation. The pinned server advertises support; older behaviour needs a separate compatibility decision before shipping it.

The current contract's other request families are `approval`, `clarify`, `secret`, `sudo`, `display.install.sudo`, `vault.code`, `vault.save_login`, `vault.unlock_prompt`, `setup_beat`, `theme.apply` and `theme.pick`. Each has a declared presentation handler or the explicit unsupported path. No method waits silently because it was omitted from a switch.

A direct request is answered with a JSON-RPC result or error carrying its string ID. A restored request can use `request.answer` with `{id, result, profile}`; its result is `ok` or `expired`. That method accepts an object result, not an error. Use the direct error-frame path for unsupported requests and negotiated declines, preserving transport identity for decline counting.

A direct response has no acknowledgement frame. Local write acceptance cannot mark a person's answer as accepted. Keep the request answering or uncertain until authoritative state settles it. A fresh snapshot that omits the request, or an `expired` result, proves it is no longer open; neither proves which answer won. `request.answer` returning `ok` proves the result was accepted, not that the requested action finished. The pinned server does not broadcast a general answered-request event, so other clients reconcile through cancellation where present and fresh request state.

`clarify.lock` locks one question and returns remaining question IDs or `expired`. Restore accepted answers from `open_requests`; do not ask them again. `request.cancel` withdraws a request by ID, method and reason. Server timeout, interrupt, no available screen and a person's explicit refusal remain distinct outcomes. Secret answers are transient and never enter recordings, history cache or logs.

## Error cases

| Failure | Behaviour |
| :--- | :--- |
| Invalid JSON, bad envelope or missing required state field | Stop accepting that message, preserve committed state, and report a protocol issue. Repeated incompatibility stops automatic reconnect. |
| Unknown response ID | Ignore as stale with a bounded metadata counter. Never match it to another call. |
| RPC error | Preserve code and safe category for the caller. Display approved plain text; do not expose raw diagnostic data. |
| Socket closes after a write | The mutation is uncertain unless server evidence proves its outcome. The outbox owns reconciliation. |
| One session disappears | Ask the engine to resolve its exact lineage. Do not create a replacement conversation merely to make the call succeed. |
| Request answer races cancellation or another client | Accept `expired` as settled. Remove the active card without saying the answer succeeded. |
| Replay queue fills or a required event cannot decode | Do not skip it. Close, recover and retain the last committed cursor. |
| Profile/account changes while replies are in flight | Cancel owned work. Old generation and scope inputs cannot affect the new selection. |
| Timeout while server may still be working | Separate connection liveness from method completion. Keep the operation uncertain rather than repeating it. |

## What is measured and how

These are proposed acceptance budgets, not results from this documentation change. Use the fixed device and build matrix in the [test harness](tests-and-tools.md).

| Measure | Method and pass condition |
| :--- | :--- |
| Contract coverage | Compare generated inventory with the pinned manifest: all 257 methods, 774 schemas, 16 request methods and 77 event types accounted for. Regeneration has no diff. |
| Replay correctness | Compare the engine's final state and committed cursor for uninterrupted and fault-injected delivery. No missing, repeated or cross-scope effect. |
| Recovery timing | In a warm local replay fixture with 512 small events, measure ready-to-engine-receipt. Proposed p95 is at most 500 ms, excluding deliberate server delays and authoritative history rebuilds. Record rebuild separately. |
| Streaming overhead | Deliver 50 token events per second while reading history. Proposed gateway decode and ordering time is p95 at most 2 ms per ordinary event on the slowest supported test device. No main-thread network or JSON work. |
| Queue and task bounds | Record queue counts/bytes, pending calls and owned tasks through 1,000 reconnects. Never exceed configured queue limits; settled generations leave no pending calls or tasks. |
| Decline latency | From validated unsupported request to queued error response, p95 at most 100 ms under the streaming workload. Do not wait for human prompt deadlines. |
| Isolation | Inject matching IDs across two profiles and two endpoints. Zero cross-scope delivery or cursor reuse. |
| Data minimisation | Inspect test logs and recording exports. They contain only fixture data, safe IDs and timing metadata, with no credentials or secret answers. |

## Test plan

- Generator fixtures cover required/optional/null fields, all enum alternatives, unions, nested maps, escaped Unicode, large exact integers, unknown additive fields, malformed known values and every extension collection. Deliberately change the digest and a schema to prove drift fails.
- Pure transition tables cover every state and input above, cancellation, delayed callbacks, timeout boundaries, fixed retry jitter, sleep/wake, authentication renewal and connection removal. Advance virtual time; do not wait on real timers.
- Transport scripts cover interleaved results, requests and events; integer and string ID separation; one object per WebSocket message; malformed or binary input; size limits; stalled writes; close before and after local write acceptance; and the separate heartbeat result shapes.
- Replay scripts cover duplicate and reordered delivery, live events arriving during replay, a `latest_seq` ahead of returned entries, stale-generation responses, an epoch change mid-call, a missing sequence, truncation from count/bytes/session eviction, an oversized unretained event and a crash before cache acknowledgement.
- Request scripts cover every listed method's supported or unsupported path, wrong-session requests, recovered open requests, locked clarify answers, timeout, cancellation, concurrent answers, locked-app presentation loss and all-client versus one-client `4404` declines.
- The pinned-Hermes harness verifies real handshake, profile routing, active-session attachment, replay, gateway restart, request settlement, and multi-client decline counting. It also checks snapshot/replay convergence while a turn streams.
- Demonstrate that reading cached history remains available during each failure and that uncertain mutations never produce an automatic duplicate send. UI and performance acceptance belong to the later reviewer run.

## What it replaces

This module replaces the inherited gateway wire models, socket handling, call dispatch, reconnect logic and ad hoc request routing. Replacement happens behind the boundary above, without parallel live clients or copied implementation structure. Existing connection choices and stored credentials remain usable through a deliberately reviewed migration. The old Python mock is replaced by the shared recording transport described in the test harness.

## Decisions and open points

Decided: generate wire types from the pinned contract; use one production decoder for live and recorded traffic; isolate every generation and profile; commit cursors with engine state; recover gaps rather than skip them; explicitly reject unsupported requests; negotiate `4404`; never retry an uncertain mutation automatically.

Open before implementation acceptance: prove snapshot/replay convergence during an active turn; confirm the 16 MiB receive budget against the largest supported bounded response; finalise the platform request-handler matrix with the shell and UI; and decide whether any older Hermes version is supported. These are explicit tests or product decisions, not permission to infer missing server guarantees.

## Evidence in the pinned Hermes checkout

All paths below are relative to a checkout of Hermes Agent at tag `v0.22.2`.

- `apps/shared/src/gateway-contract.openrpc.json`: generated method, schema, request and notification definitions.
- `tui_gateway/contracts/base.py`, `liveness.py`, `sessions.py`, `server_requests.py` and `prompt_voice.py`: field presence, capability results, resume/activate identities, replay results and request-answer shapes.
- `tui_gateway/ws.py`: ready envelope, one text object per message, heartbeat extension, ordered writes and failure behaviour.
- `tui_gateway/event_replay.py` and `tui_gateway/methods_session.py`: sequence scope, epoch, retention limits, truncation and separately sampled replay fields.
- `tui_gateway/server.py`, `server_requests.py` and `session_transports.py`: request routing, reconnect snapshots, cancellation and per-client decline counting.
- `tui_gateway/methods_prompt.py` and `methods_voice.py`: restored answers, clarification locks and capability advertisement.
- `hermes_cli/web_server_chat.py` and `web_server.py`: socket authentication modes and configured incoming frame ceiling.
