# Conversation engine

[Spec index](README.md) · Depends on [Gateway client](gateway-client.md)

## Purpose

Keep one dependable conversation with each bot, however long it becomes. A reply can
stream, the connection can drop, and Hermes can shorten its working context without
splitting the chat or losing the place the person was reading.

This module owns conversation identity, messages, pending questions, outgoing work
and the local history cache. It has no views. The [gateway client](gateway-client.md)
owns the connection and wire protocol. The [conversation UI](conversation-ui.md)
owns drawing, scrolling, focus and the composer.

## Behaviour in plain words

- Opening the main chat returns to the same conversation. Compression keeps its
  title, draft, selection and reading place. A deliberate new chat or branch is a
  separate conversation.
- Previously loaded messages appear from the local cache. Scrolling back loads
  older pages, first locally and then from Hermes. Reaching an unloaded part does
  not make the chat look finished.
- A send appears once, with a clear waiting, sending or uncertain state. Losing a
  reply never silently sends the same message again.
- Reconnecting catches up on missed events. It keeps existing rows on screen
  while checking what happened. A disconnected view does not mean the bot stopped.
- A question or approval appears once. Its answer belongs to that exact question,
  bot and connection. An answer already accepted elsewhere closes the card.
- A confirmed compression adds one quiet row, “Earlier messages kept.” Older
  messages remain available. A failed or skipped compression adds no success row.
- Stopping a reply shows “Stopping…” until Hermes confirms its outcome. Partial
  text remains readable if a turn fails or is interrupted.

## Public types and contracts

These are new module interfaces. Wire names below come from Hermes's contract.
They are not proposed replacements for existing app classes.

| Type | Contract |
| :--- | :--- |
| `ConversationKey` | An opaque, locally assigned and persisted key. Never changes when the stored tip or live session changes. Scoped to the gateway's `PeerScope`, including the profile. |
| `LineageRecord` | The conversation key, proven root, current stored tip, known stored aliases, current live session binding and local revision. A missing root is unresolved, not permission to guess. |
| `SegmentRecord` | One known stored session and its proven relationship to adjacent compression segments. Records whether local coverage is complete, partial or unknown. A branch is not a compression segment. |
| `RowKey` | Stable identity for a displayed item. A durable address uses owner scope, local store generation and Hermes row ID. A provisional row uses a persisted local token. A binding can add a durable address without changing the displayed key. |
| `ConversationRow` | Row key, kind, ordered content, source address, revision and delivery state. Text, tools, attachments, notices and request cards have explicit kinds. Time is for display, never ordering or identity. |
| `ConversationInput` | A user intention, validated `DeliveredNotice`, RPC outcome, history page, cache outcome, visibility report or supplied clock event. Carries scope and operation generation. |
| `ConversationReduction` | The next state and ordered effects produced from one state and one input. No clock, random value, file access, network call or view access occurs inside the reduction. |
| `RequestLedger` | The request book. Keys include owner, runtime session, epoch and server request ID; approval IDs also retain their distinct durable identity. Contains open, presented, answering, uncertain, answered, declined and withdrawn entries. |
| `DispatchLedger` | The outbox. Stores a durable intention token, exact operation, conversation, submission binding, permitted payload reference and delivery evidence. Secret answers remain transient. An RPC request ID is correlation, not an idempotency key. |
| `HistoryPage` | Owner and resolved tip returned by Hermes, requested offset and limit, raw row count, ordered rows, request generation and local validation result. A local page revision is not a server snapshot revision. |
| `OlderPageRequest` | Conversation key, current history generation, oldest loaded boundary, desired page size and reading anchor. Repeating a request for the same boundary shares one load. |
| `WindowSnapshot` | Immutable rows in display order, loaded range, known gaps, loading/error state and monotonic local revision. Includes durable anchor bindings and live-tail status, but not an array of the whole lineage. |
| `ReadingAnchor` | The first visible row key and the signed offset of its top from the unobscured viewport top. The offset may be negative for a partly visible row. The UI captures and restores it when the window changes. |
| `HistoryCache` | Versioned storage for rows, identity bindings, lineage metadata, coverage, reducer checkpoints and ledgers. Reads and writes return explicit results. It never has access to credentials. |

Public operations are to open a conversation, submit an intention, accept a gateway
batch, request an older page, update the visible range, report a presented request,
and observe window changes. Effect results return as inputs. They never mutate
state behind the reducer. The same ordered inputs must produce identical state,
row keys, effects and checkpoints on every run.

### Identity and lineage

The root answers “which conversation is this?” The tip answers “which stored
session continues it now?” A runtime session ID answers “where can work be sent in
this process?” Keep all three distinct.

Use the root supplied by session listings (`_lineage_root_id`) and verified
compression relationships. `session.resume` takes a stored ID and returns a live
`session_id`; its `stored_session_id` and `session.info.stored_session_id` identify
the stored continuation. Known stored and runtime aliases always stay within the
same owner. An old deep link resolves to the existing conversation key.

Do not merge chats because they have matching titles, text, timestamps, a shared
parent field or the same bot. Explicit branches, resets and delegated work can
have parents without being compression continuations. If two records later prove
to be the same lineage, merge their alias tables transactionally and retain one
canonical local key, with the other key forwarding to it. Preserve drafts and
anchors; surface a draft conflict instead of dropping either draft.

A changed stored tip from the same validated live binding starts lineage
reconciliation. Confirm that it is the same compression lineage, move the tip,
retain the previous tip as an alias, and increase the history generation in one
transaction. Unsent intentions follow the confirmed new binding. Sent or uncertain
intentions keep their original evidence and are not resent. A reply from a page
load started under the previous generation cannot move the tip back.

There is no dedicated compression-complete notification in the pinned OpenRPC
contract. A status string or a shorter message count is not proof of compression.
Use a successful compression result and verified stored identity, or a verified
compression edge found during refresh. The quiet row has a persisted identity for
that transition. Repeated status, replay and refresh inputs update it rather than
adding another row. Historical edges without a known boundary do not manufacture
timestamps or insert notices into guessed positions.

### Message identity and reconciliation

REST history exposes the durable row as `id`; projected gateway history uses
`row_id`. Normalize both to the same scoped durable address. A row ID is scoped to
the profile's store, not globally and not to whichever tip currently owns it.
Keep a local store generation so an explicitly replaced or re-paired store cannot
reuse old cache addresses by accident.

For outgoing rows, allocate and persist a local token before dispatch. A successful
`prompt.submit.user_row_id` binds that row to its stored address. For streamed
rows, allocate a key from the accepted turn-start input and retain it through
deltas, interim segments and completion. A duplicate replayed event makes no new
row. Tool rows use the server's tool-call identity within that turn, not the tool
name. Repeated identical user messages remain separate messages.

Use `message.complete.persisted_turn` as positive persistence evidence. Its row
addresses can bind known local rows. Only `complete: true`, with the entire local
turn and final body accounted for, permits retiring the full provisional turn.
Missing IDs or `complete: false` mean that persistence is unproven. Do not erase a
partial answer or infer that a send failed. Preserve `display_kind`,
`display_metadata`, tool-call identity and server display projections when
normalizing history; do not recognize special rows by matching English text.

Never deduplicate unrelated rows by text or timestamp. Content comparison can
check an already established identity, but cannot establish one. If a refreshed
page cannot be bound safely to a provisional turn, keep the old rendered window,
mark the affected boundary unresolved and seek stronger evidence. Do not show
both copies as confirmed or silently discard one. This is a release-gated
reconciliation case, not a heuristic fallback.

For an explicitly confirmed edit or rewind, apply the server's survivor row map
to durable bindings while retaining stable displayed keys for survivors. Removed
rows leave the window only on confirmed history change. Rewind rows must not
return through older-page loading. A local compression summary never substitutes
for the user's historical messages.

## States and transitions

Connection, turn, history and delivery states are separate. A conversation can be
reading cached history while its connection is recovering and its bot is working.

| Area | States and transitions |
| :--- | :--- |
| Attachment | `closed` → `opening` → `attached`; lost connection → `recovering`; lost session binding → `rebinding`; scope change → `closed`. A late result from the old binding is ignored. |
| Turn | `idle` → `starting` → `streaming` → `finished`, `interrupted` or `failed`. A busy submission can be `queued`, `steered` or `redirected`, according to the reply. A connection loss changes certainty, not the bot's running state. |
| History | `cached` or `empty` → `checking` → `current`; requesting an older boundary → `loadingOlder` → `available`, `beginningReached` or `gap`. A tip change, rewind or invalidated boundary returns affected coverage to `checking`. |
| Outbox | `prepared` → `dispatching` → `accepted`, `rejected` or `uncertain`. Accepted may remain queued on Hermes. Only an unsent intention or proven rejection can become ready to send again without risking duplication. |
| Request | `open` → `presented` → `answering` → `answered`; loss of answer result → `uncertain`; server withdrawal → `withdrawn`; no supported presentation → `declined`. A terminal request never reopens because an older replay arrives. |
| Compression | `idle` → `requested` → `confirmed`, `unchanged`, `failed` or `uncertain`. Only confirmed success updates the quiet row; a verified tip transition updates the lineage in the same reduction. |

### Replay and reconnect

1. Restore the last committed reducer checkpoint, rows and ledgers. Keep cached
   history readable and block new dispatch until owner and live binding are known.
2. Ask the gateway for `session.events.since` using its `WireCursor` for that
   owner, epoch and runtime session. The gateway supplies ordered, validated
   `DeliveredNotice` values and a `CatchUpResult`.
3. Reduce replay and buffered live events in one sequence. Ignore already applied
   sequences within that exact epoch and session. Persist accepted state, its
   identity bindings and the new applied watermark atomically before returning
   `EngineReceipt`. A crash before commit permits the batch to run again safely.
4. Advance only through events actually received and applied. `latest_seq` may be
   ahead of the returned frames because the pinned handler samples these values
   separately. Fetch again when there is an uncovered interval; never skip to the
   advertised latest value.
5. Reconcile `open_requests` and current approvals separately from message replay.
   Server requests are not in the event ring. A question can remain open when
   this client never received its original request frame.
   Apply cancellations received after a request snapshot after that snapshot.
6. On `truncated`, a changed epoch, a lost live binding or an irreconcilable event,
   stop treating replay as complete. Reattach using `session.resume` or
   `session.activate` with `omit_messages: true`, refresh bounded history pages,
   reconcile inflight/queued work and open requests, then re-establish replay.

The pin does not provide an atomic snapshot plus replay watermark. During this
last recovery path, buffer new events within the gateway's bound, retain the old
window and reconcile using durable row evidence. Do not append relative deltas to
an inflight snapshot unless their boundary is proven. Repeat the bounded read at
a settled turn boundary if necessary. If continuity remains unproven, show
“Catching up…” with retry and preserve the draft. Do not release uncertain sends.
The harness must prove convergence for restart during streaming and compression
before this path can be called ready. A new server fence or turn identity may be
needed; the spec does not invent one.

### Request book and outbox

The request book accepts live frames and `open_requests` through the same entry
point. Re-delivery of the same ID updates one card. A changed method or conflicting
immutable question definition for an existing ID is a protocol problem, not a
second question. Mutable fields, including accepted clarification answers in
`open_requests.params.answers`, are authoritative progress and update that card. A
`request.cancel` closes only its matching request. Keep answered and withdrawn
tombstones durably long enough to reject stale replays, without keeping all old
cards in memory.

Send `approval.received` only after the UI reports that the card is actually
presented; loading a cached card is not presentation. Reply by the exact request
identity and only with a choice Hermes offered. `request.answer` supports a
recovered request whose original frame was not delivered to this client. An
answer timeout is uncertain until a fresh open-request or approval read resolves
it. A direct response to a server request has no separate acknowledgement: local
write acceptance is not answer acceptance. An explicit fresh list showing the
request is gone proves it is settled, not that this device's choice succeeded.
An absent optional snapshot field is not the same as an explicit empty list.
Use the gateway's capability policy to decline requests this app cannot display.
Never approve a hidden card to unblock a turn.

Restore accepted parts of a multi-question clarification from the recovered
request, including the result of `clarify.lock`. Do not ask accepted questions
again. If an answer expires or another client settles it, close the card without
claiming this device's answer succeeded. Secret answer text lives only in the
active presentation and dispatch buffer; persist the request identity and
uncertainty state, never that text in the outbox, cache, logs or recordings.

Persist an outbox intention before attempting network dispatch. Mark it
`dispatching` durably before handing it to the transport; after a crash, that state
is uncertain even if the transport may never have written it. Record the RPC
reply or other positive acceptance evidence before marking it accepted. A socket
close, cancellation of a local task or an expired timer is not a negative
acknowledgment.

The pin has no client idempotency token for `prompt.submit`. Thus the outbox is a
record of intent and evidence, not an automatic retry queue. For an uncertain
send, offer to keep waiting or to send a new copy with a clear explanation that
the first may have arrived. The latter creates a new intention. A response with
`queued` means Hermes holds the work; reconnect must not requeue it. Check
`voice_stopped` as a distinct outcome because `status` can be absent.

Use FIFO order for locally prepared sends in a conversation, with at most one
unresolved prompt dispatch at a time. Stop and exact-request answers have their
own tracked operation identities, so an uncertain prompt does not prevent them.
Different conversations do not block each other.
Only unsent items may be edited or cancelled locally. Stop, compress, edit,
branch, approval and other mutations use the same uncertainty rule. Retrying a
read is safe; replaying a mutation requires evidence or a new explicit intention.

## Endless history and local cache

### Hermes page contract at the pin

The history source is `GET /api/sessions/{id}/messages`. Every request specifies
the exact profile and uses `limit=120`, `order=latest`,
`include_compacted=true` and `inline_images=false`. URL-encode exact stored IDs.
An explicit limit without an order defaults to oldest, so order must be present.

| Field or behaviour | Pinned meaning |
| :--- | :--- |
| `limit` | Nonnegative; capped at 500. An omitted limit gives a latest page of up to 500. Nollie requests 120. |
| `offset` | Nonnegative count from the chosen end of the current projected history, not a cursor. With `latest`, it skips the newest rows. |
| Response order | Each page is returned in chronological display order even when paging from the latest end. Preserve server order. |
| `session_id` | The resolved stored continuation. An old alias can return a newer tip. |
| `profile` | The serving owner. Reject a different owner, even if the session ID looks right. |
| `pagination` | `limit`, `offset`, `order`, `returned`. There is no total, next cursor, has-more flag, history revision or snapshot token. |
| Ancestors | The endpoint already combines verified compression ancestors and removes repeated display generations. Do not append independently fetched parent transcripts to it. |
| Compacted rows | `include_compacted=true` includes archived display history while excluding rewound rows. It is needed for the endless chat. |
| Attachments | `inline_images=false` avoids returning stored inline image bodies. Attachment detail is loaded separately on demand. |

Keep raw pagination counts separate from displayed row counts. Hidden rows still
consume offsets. A page that renders no visible rows is not the beginning of the
conversation. A short or empty raw page is evidence of the current boundary only
for that validated paging generation, not a permanent claim that no older rows
can ever appear.

### Loading older pages

1. Read a 120-row page around the requested boundary from the versioned cache.
   Publish it immediately if its scope, schema and coverage are valid. Offline,
   preserve explicit gaps where coverage is missing.
2. On a cache miss, query the current tip. Treat Hermes's merged lineage as the
   ordering authority; segment records describe provenance and coverage, not a
   second transcript concatenation algorithm.
3. Fetch with a small overlap of known durable rows at the old boundary. Advance
   the raw offset by newly covered raw rows, accounting for that overlap. Validate
   the same owner, resolved tip, expected overlapping identities and ordering
   before joining coverage. Deduplicate by durable address or explicit binding.
4. If append, compression or rewind changes the read generation, invalidate the
   offset plan and restart from a known boundary. Do not label an unverified join
   complete. Offset paging can drift while another client writes; overlap can
   detect many changes, but cannot prove an arbitrary moving history is complete.
5. Keep at most one older-page load per conversation. Cancel obsolete requests
   after navigation or owner changes. A late old-generation response may be
   discarded; it cannot overwrite the live window or current coverage.
6. Commit rows, identity bindings and coverage together. Publish a new window
   retaining the reading anchor. Trimming the opposite edge must not remove the
   visible anchor or interrupt a drag. The UI restores the same anchor offset
   before the next displayed frame.

The optional pinned `/timeline` and `/messages/around` routes offer durable prompt
jumps, but are not a replacement cursor for ordinary backward message pages.
Their adoption for recovering a lost boundary needs its own fixtures. Until a
join is proven, present a retryable gap instead of silently skipping messages.

### Storage and bounds

Choose a versioned SQLite cache, independent of Hermes's own database. Store only
normalized display data and required protocol evidence. Never read Hermes's
database directly. Cache records contain cache schema version, projection version,
owner, local store generation, conversation identity, history generation and
coverage status. Persist outgoing content and drafts in a separate durable area
so rebuilding display pages cannot discard unsent work.

A migration either commits fully or leaves the prior version readable. A corrupt
or unsupported display cache can be rebuilt from Hermes after preserving drafts,
outbox and unresolved request evidence. Partial writes never create a “complete”
range. On disk-full or failed commit, stop dispatching new durable intentions,
retain the draft in memory and report that saving failed. Do not acknowledge a
durable replay checkpoint that was not saved.

The resident window targets 360 rows and has a hard ceiling of 500 rows and
16 MiB of decoded transcript bodies, including the active reply. These are initial
acceptance budgets, not measurements already achieved. Hold visible rows, the
reading anchor, live reply and visible request cards within that budget. Keep
offscreen bodies, rich text, tool output and attachment data on disk. The draft
is independent of window trimming. The live tail can retain a small state summary
while the person reads much older rows.

Maintain lineage and row lookup indexes on disk; visiting every old page must not
leave a full in-memory row index, height table or completed request book behind.
Coalesce streamed text updates for presentation without losing reducer inputs.
Large individual bodies use bounded previews and a separately loaded detail view.
If required visible pins exceed the ceiling, report a recoverable capacity error
instead of growing indefinitely or silently removing a visible request. Decline
new requests that cannot be safely presented under the gateway policy.

## Error cases

| Situation | Required result |
| :--- | :--- |
| Offline with cached pages | Keep reading and drafting. Show gaps honestly. Hold unsent work without claiming it reached Hermes. |
| Authentication or owner mismatch | End the binding, cancel loads and prevent cross-owner reads or sends. Keep that owner's durable state isolated. |
| Missing session or reclaimed runtime | Keep cached content; resolve stored lineage and rebind. Do not create an empty replacement chat automatically. |
| Conflicting lineage, cycle or unsupported depth | Keep separate records and mark identity unresolved. Never cross a branch because a parent ID exists. |
| Missing or malformed history row | Preserve valid coverage around a visible gap. Do not call the partial page complete. |
| Compression changes tip during paging | Increase generation, retain anchor and old rows, then validate a new paging plan. |
| Replayed completion after a live completion | One terminal turn and one set of rows. No repeated notification or side effect. |
| Stop or answer reply lost | Show uncertain state and read current server state. Do not claim success or blindly repeat. |
| Replay buffer or pending-input bound exceeded | Request recovery and retain the last committed window. Never discard arbitrary deltas then continue as current. |
| Cache schema change, corruption or disk full | Preserve drafts and uncertain intentions; rebuild only disposable pages. A failed save blocks new dispatch. |
| Store restored with reused row IDs | Invalidate the old store generation after explicit identity reconciliation. The pin lacks a durable store incarnation field, so automatic detection is an open contract issue. |

## What is measured and how

Use synthetic recordings with 10,000 rows spread across many compression
segments. Include repeated text, tool output, attachments, long rows, hidden rows,
one active reply and pending questions. Run the same recording through the
reducer, cache and real UI. The [tests and tools](tests-and-tools.md) spec owns the
shared fixture and evidence format.

| Measure | Acceptance and method |
| :--- | :--- |
| Determinism | Replaying identical normalized inputs produces byte-equivalent normalized checkpoints and effect lists. No wall-clock or random values leak into reduction. |
| Cache latency | A valid cached 120-row page reaches `WindowSnapshot` at p95 within 100 ms over at least 100 loads. Measure from load request to publication; separately measure UI presentation. Include cold process and warm process results. |
| Steady work | With 50 tokens per second and repeated older-page loads, reducer work does not grow with total lineage length. Record p50/p95/max reduction duration and main-thread handoff size. |
| Memory | Confirm the row and body ceilings continuously. In ten full backward/forward traversals, retained allocations after each settled traversal do not grow with pages visited. Record process memory, resident row/body counts and request count. UI owns the device-level flat-memory gate. |
| Anchor integrity | Every window change preserves the same `RowKey` and supplies its binding. UI measures actual position, including prepend, trim, partial rows and resizing. No transient jump may be hidden by a later correction. |
| Reconnect | Compare final rows, lineage, requests and outbox against an uninterrupted run. Count duplicate rows, dropped rows and repeated mutations; all must be zero for supported recovery cases. |
| Disk recovery | Crash at each write boundary. Restart yields the previous or next complete checkpoint, never a mixed checkpoint with advanced cursor and missing rows. |
| Paging integrity | Record each requested raw offset, returned IDs, overlap and generation. The accepted union matches the fixture's display history; gaps never masquerade as completed ranges. |

Keep content out of routine timing and diagnostic logs. Record fixture IDs, counts,
durations and redacted failure categories. Separate measured local cache time from
Hermes read time: the pin can materialize a merged lineage on the server, even
though the response is paged. This client spec does not promise flat server memory
or a 100 ms network response.

## Test plan

1. Table-driven reducer tests cover every transition, duplicate input, out-of-order
   rejection, wrong owner, stale generation and explicit clock event. Assert both
   resulting state and effect sequence.
2. Identity fixtures cover root → tip → tip rotation, open by old alias, a deliberate
   branch with the same text, missing root, conflicting aliases, repeated messages
   and survivor-row rebinding after confirmed truncation.
3. Replay tests cut the connection before dispatch, after write, before reply,
   during streaming, after final persistence and during compression. Include
   duplicate live/replay frames, epoch restart, truncation, `latest_seq` ahead of
   returned frames and crash before or after the checkpoint commit.
4. Request tests mix live frames, `open_requests`, approvals and cancellation.
   Cover a second device answering, an unseen card, a hidden or unsupported card,
   an answer with a lost reply and an obsolete request ID from an earlier epoch.
5. Outbox tests prove no automatic second mutation after an ambiguous write.
   Cover queued/steered/redirected outcomes, `voice_stopped`, no durable row ID,
   partial persisted turns, disk full, restart and a changed tip before dispatch.
6. History tests start with no cache, a partial cache, an old schema and a corrupted
   page. Page a 10,000-row lineage; include hidden-only pages, equal timestamps,
   repeated text, overlapping pages, append and rewind during reads, tip changes,
   unavailable ancestors and cross-profile ID collisions. Assert bounded memory
   and exact coverage or an explicit gap.
7. Compression tests use manual success, no-op, refusal, lock held, lost reply,
   automatic rotation and replay of each. One proven transition creates one quiet
   row, preserves the conversation key and anchor, and retains older display rows.
8. Run the pinned-Hermes end-to-end cases through the gateway and storage adapters.
   Compare them with the same recorded inputs through the scripted transport.
   The UI tests then verify the visible send, stop, question, gap and long-chat
   behaviours on phone, foldable layouts, iPad and Mac.

These are implementation acceptance tests. This documentation change does not run
the app, the pinned service, builds or simulator checks.

## What it replaces

This replaces the inherited conversation state, ad hoc event handling, reconnect
repair, request tracking, send retry behaviour and whole-transcript loading in the
networking and chat layers. It also replaces separate representations of the same
chat in navigation and message history with one lineage identity and one reducer.
No existing Swift structures, names or comments define this module's design.

The replacement must retain visible behaviour gathered in the shell and UI
specifications. Existing on-device drafts, connection choices and reading places
need an explicit migration fixture before the old path is removed. The wire
transport, presentation and app shell are replaced under their own specs.

## Decisions and open points

Decided: stable conversation identity follows a compression lineage; pure
reduction owns state; replay is the first reconnect path; uncertain mutations are
never automatically resent; history is cache-first and windowed; one compression
notice keeps the chat quiet; the cache uses versioned, transactional storage.

Open before implementation acceptance:

- Prove snapshot/replay convergence after epoch loss without an atomic server
  fence. If the required proof cannot be made at the pin, agree a Hermes contract
  change rather than weaken duplicate and loss guarantees.
- Prove history joins under concurrent mutation. Offset paging has no snapshot
  token; a stable row cursor or documented revision may be needed for uninterrupted
  older loading while another client edits history.
- Establish stable bindings when a live or legacy row has no durable identity,
  including compression that rewrites a representative row. Text matching is not
  an acceptable identity contract.
- Define a durable store incarnation and completeness signal for very deep or
  partially missing lineages. The pinned server bounds ancestry traversal, and
  does not return proof that every historical segment was included.
- Choose retention limits for on-disk display pages and completed ledgers, plus
  the exact migration of existing drafts and reading places. Eviction must never
  remove unsent work or pretend uncached older history is gone.
- Confirm the row/body ceilings on the reviewer's target devices. Any adjustment
  must preserve the 10,000-row, 50-token-per-second and flat-memory acceptance bar.

## Evidence from the pinned Hermes checkout

Read-only reference: Hermes v0.22.2 at
`d923a5eb487a17c0a68801bba9ef0f56c81040a8`. These paths describe the service's
observable contract; they do not prescribe Nollie's implementation structure.

- `apps/shared/src/gateway-contract.openrpc.json`: session listing and attachment,
  events replay, prompt outcomes, request recovery, compression, transcript rows
  and the positive-evidence contract of `PersistedTurn`.
- `hermes_cli/web_routers/sessions.py`: `/messages` parameters, resolved owner and
  tip, display projection, `/timeline` and `/messages/around` response behaviour.
- `hermes_state_messages.py`: message ordering, display-generation deduplication,
  compacted versus rewound history, compression-only ancestry and traversal bound.
- `tui_gateway/methods_session.py`: lineage metadata, stored/runtime identity,
  attachment results and separately sampled replay fields.
- `tui_gateway/session_compression.py`: manual busy/lock outcomes and the stored
  continuation changing after compression.
- `tests/hermes_cli/test_session_message_page_owner.py`: explicit profile ownership
  and backward pages returned in chronological order.
- `tests/hermes_cli/test_web_server_sessions_compression.py`: compression chains
  represented as one conversation in session listings.
