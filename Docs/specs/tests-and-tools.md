# Tests and tools

[Spec index](README.md) · Supports [Gateway client](gateway-client.md), [Conversation engine](conversation-engine.md) and [Conversation UI](conversation-ui.md)

## Purpose

Make a broken connection, a long conversation or an awkward window size easy to reproduce. A passing result must show that Nollie works with the pinned Hermes release, keeps the person's words, and stays steady while new words arrive.

This module owns the test runner, recordings, fixture checks and demo playback. It uses the gateway's replay transport and the same conversation engine as the app. It does not own a second chat engine.

## Behaviour in plain words

There are three ways to run a scenario:

1. **Real Hermes:** start a fresh, local Hermes with a scripted model server. Drive the app through its real WebSocket and history requests. Save the observed exchange and the result.
2. **Replay:** run that exchange again with a controlled clock. Disconnect at a named point, repeat an event or deliver a late reply. Check exactly what the app does.
3. **Demo:** show the same recording in the app. The person can play, pause, restart and choose a prepared scenario. It never connects to a saved bot or sends a real message.

A recording is evidence of a particular exchange. A modified recording is a test of a particular fault. Keep those origins visible in the report. Neither substitutes for a run against Hermes.

Every required scenario has an expected result and a deadline. A missing dependency, skipped scenario, unexpected request, exhausted script or incomplete teardown fails that run. Do not quietly replace a real-Hermes run with replay.

## Reference and boundary

The read-only Hermes checkout is a checkout of Hermes Agent at tag `v0.22.2`.

| Evidence | Pinned source |
| :--- | :--- |
| Hermes revision | `d923a5eb487a17c0a68801bba9ef0f56c81040a8` |
| Gateway contract | `apps/shared/src/gateway-contract.openrpc.json` |
| Contract SHA-256 | `8848b394df533af8b37afd3cdccfc48b3e3d6ca1ce4037ebaf38653e33ed832e` |
| Scripted model server | `tests/fakes/fake_llm_provider.py` |
| Real server lifecycle and socket test reference | `tests/e2e/core/terminal/_gateway_client.py` |
| Isolated multi-profile HTTP test reference | `tests/e2e/core/dashboard/_helpers.py` |

These are Hermes protocol and test references. No former client implementation is a source for the new harness. The production app does not bundle Hermes's test server or runner.

The pinned scripted server supports streamed and complete text, reasoning text, parallel tool calls, malformed tool arguments, HTTP errors with an optional retry delay, a hanging request, a dropped or stalled stream, and an arbitrary response body. It records model requests. Character chunk size and delay are configurable; they are not token counts. Requests with a nonempty tools list consume the main script. Other requests use a separate auxiliary responder, including summary requests. An exhausted main script otherwise returns default text.

The harness must count and validate both request streams and make exhaustion fail. It must verify which stream each scenario uses. Do not assume the standalone default server provides a strict script. The server does not itself create WebSocket gaps, epoch changes, replay truncation, history pagination races or device layout changes. Exercise those through the real gateway lifecycle, a controlled test transport or the app test runner, as marked below.

## Public types and contracts

Names in this table are proposed for the rewrite. Wire names remain those of Hermes.

| Type or boundary | Contract |
| :--- | :--- |
| `ScenarioBlueprint` | Stable scenario name and revision, purpose, initial synthetic data, profile scope, script steps, required execution modes, checkpoints, deadlines and expected outcomes. No personal data or arbitrary provider address. |
| `HermesRunLease` | Owns one isolated run directory, child process group, loopback endpoints and cancellation handle. Start succeeds only after protocol readiness. Stop is safe to call again and reports whether every owned process and port closed. |
| `FixtureManifest` | Recording format version, scenario revision, Hermes commit, contract digest, capture tool revision, provenance, payload checksums, normalization rules and required capabilities. A mismatch fails before playback. |
| `RecordedExchange` | Ordered WebSocket frames, HTTP exchanges and connection boundaries with relative monotonic times and named checkpoints. Sequence numbers and epochs retain their meaning. Requests are paired with responses without merging client and server request identifiers. |
| `FixtureGate` | Validates the manifest, wire shapes, references, checksums, sanitization and scenario expectations. Returns structured failures and never makes an unknown fixture look compatible by dropping fields. |
| `ReplaySchedule` | Uses `WireStep` and `TapeWireLink` from [Gateway client](gateway-client.md). It supplies expected sends, received bytes, socket boundaries, clock advances and barriers to the production decoder and connection machine. It never injects finished view state. |
| `HistoryReplaySource` | Matches expected HTTP method, profile, path and query against recorded history requests; returns recorded status, headers and body or a declared fault. Uses the production history decoder. Unmatched requests fail. |
| `DemoPlayback` | Selects a validated scenario and controls its clock. Playback state and storage are separate from live connections. Only declared recording branches are available. |
| `RunEvidence` | Scenario result, execution mode, checkpoints, expected versus actual outcomes, sanitized artifact paths, timings, environment and cleanup result. A pass requires all required evidence, not only a zero process exit. |

The gateway spec owns framing, request identifiers, replay ordering and connection transitions. The engine spec owns conversation identity, row identity, requests, outbox and cache semantics. The UI spec owns layout and performance thresholds. This module supplies inputs and observes those contracts; it does not reinterpret them.

## Startup, isolation and teardown

For each run:

1. Verify the checkout commit, contract digest and required preinstalled dependencies. Never fetch packages, update Hermes, install a service or use a different revision automatically. A local setup issue is a failed preflight with a clear reason.
2. Allocate a fresh owned temporary root. Resolve paths and reject symlinks or locations inside a personal Hermes home. Place the child home, Hermes home, cache, temporary files and app test storage under this root. Create only named synthetic profiles. Give each parallel test unique names, database paths and ports.
3. Build an environment from an allowlist. Pass only the needed executable paths, locale and explicit test configuration. Do not inherit provider credentials, personal profile paths, proxies, account state or session tokens. Supply fresh ephemeral test authentication through private process state, never command-line logs or recordings.
4. Start the pinned scripted model server on loopback with a system-assigned port. Route every main and auxiliary model request to it. Disable updates, telemetry, lazy installs and external catalog fetches. A runner must enforce loopback-only egress for the complete child tree; configuration alone is insufficient. If that enforcement is unavailable, fail preflight. Tool actions use harmless temporary files and never personal apps, messaging services or external sites.
5. Start the pinned backend with `python -m hermes_cli.main serve --host 127.0.0.1 --port 0` in its own process group and the isolated environment. Wait for the `HERMES_BACKEND_READY` port announcement, then authenticate and wait for `gateway.ready`. Announce capabilities through the production client. HTTP readiness must also succeed before a history test begins.
6. Load only the scenario's synthetic data through public operations. If a scenario needs a direct database seed, create it before step 5, version it to the Hermes commit, and validate it with a public history read once the server is ready. Never write the database beside a running Hermes process.
7. Drive named checkpoints with condition-based waits and monotonic deadlines. The clock controls replay delays; the real-Hermes lane measures elapsed time. Do not turn a fixed sleep into proof that an action finished.
8. On success, failure, cancellation or interrupted startup, close app connections and stop the owned process group. Allow a bounded graceful shutdown, then kill only the remaining owned group. Stop the scripted server, join workers and verify process exit and port closure. Never find and kill processes by name. Sanitize artifacts before retention; remove the temporary root after capture. A cleanup failure changes the run to failed.

The app's test container has no access to saved connections, production keychain entries, notification delivery or production companion services. A demo starts directly in its isolated mode before those services are initialized. Leaving demo mode closes playback and clears its transient state before a live connection can be selected.

## Recording format and review

A fixture bundle contains one manifest, ordered exchange data, expected checkpoints, safe attachment files when needed, and a short explanation of the scenario. The first format is version `1`. The manifest carries separate versions for the recording format, scenario and engine cache seed. No recording format version is inferred from a filename.

Capture raw wire bytes only in private temporary storage. The committed fixture is a sanitized derivative. Export is allowlisted and fails on unknown sensitive fields. Remove authorization headers, cookies, session tokens, URL query authentication, home paths and credentials from request bodies, model-server records and logs. The scripted server records headers and authentication in memory, so its raw request log is never an artifact by default. Use synthetic message text and attachments from the start; redaction does not make a personal conversation an acceptable fixture.

Normalize volatile values through a declared, consistent mapping. Map profile, session, turn and request identifiers without changing equality, alias relationships or ordering. Keep client numeric identifiers numeric and server request identifiers in their own domain. Preserve sequence gaps, duplicates, epoch boundaries, result versus error shape, HTTP status and empty versus absent fields. Relative time may replace wall time, with units declared. Never sort events or fill missing fields to make an assertion pass.

Every retained frame must decode against the pinned contract or be explicitly marked as a malformed-input fixture with its intended failure. HTTP history fixtures must satisfy the separately documented REST shape. Preserve unknown optional fields in compatibility examples. Validate all referenced attachments, hashes, scenario checkpoints and identifier mappings. Reject unsupported versions, missing checksums, truncated capture files and mismatched provenance before a demo or test can use them.

Use three provenance values:

- **Captured:** sanitized from a successful run against the pinned Hermes process.
- **Fault variant:** derived from a named captured bundle, with each duplication, removal, reordering or failure stated in the manifest.
- **Synthetic scale:** generated text and rows for a declared size or layout case. It makes no claim that Hermes emitted that whole exchange.

Changing a pin requires a fresh contract check and new real-Hermes capture review. Keep the old recording until the replacement's expected differences are reviewed. Do not silently rewrite all snapshots or treat a newly recorded outcome as correct merely because it is new.

## States and transitions

| Owner | States and allowed transitions |
| :--- | :--- |
| Real-Hermes run | `prepared → starting → ready → exercising → collecting → stopping → passed`. Any error or cancellation enters `stopping`, then `failed` or `cancelled`. No result is final before cleanup completes. |
| Recording | `capturing → sanitizing → validating → reviewable`. A failure at any step leaves an unusable capture with sanitized diagnostics. Only a reviewed bundle enters the fixture catalog. |
| Replay | `validated → running ↔ paused → completed`. An unexpected send, missing checkpoint or deadline goes to `failed`. Restart makes a fresh engine and cache from the seed, not a partially reset one. |
| Demo | `choosing → loading → playing ↔ paused → finished`. Restart returns to `loading`; an invalid bundle returns to `choosing` with a short error. All exits close its transport and history source. |

Live use and demo playback are mutually exclusive in one scene. Demo actions follow a declared branch: send the prepared message, answer the prepared question, disconnect, reconnect or load older rows. An arbitrary typed message stays a local draft with a clear indication that this is a recording. It is never turned into a canned answer that appears live. No demo action invokes a real approval, computer action or Board mutation.

## Error cases

| Case | Required result |
| :--- | :--- |
| Wrong Hermes commit, contract digest or fixture version | Fail before startup or playback; identify the mismatched field without dumping private paths or configuration. |
| Missing dependency, port bind failure or startup timeout | Fail the real-Hermes lane and clean up. Do not report a skip or replace it with replay. |
| Main or auxiliary script receives unexpected traffic | Record a structured mismatch and fail at the end of the step, even if Hermes receives a fallback response. |
| A model request reaches a non-loopback host | Terminate the owned run, report an isolation failure and fail the whole lane. |
| Unexpected outgoing frame or HTTP request during replay | Stop at the first difference and report field paths with sanitized values. Do not advance the recording looking for a match. |
| Deadline, lost reply or gateway disconnect | Check the module's declared uncertain or reconnecting state. Never make the harness resend a mutation to get the desired screen. |
| Unsafe content in a capture | Reject export. Retain only sanitized diagnostics; no raw capture is added to the catalog. |
| Failed screenshot, missing metric or unsupported required device configuration | Mark the corresponding acceptance item incomplete and the required lane failed. Unit results cannot fill that gap. |
| Cancelled run or surviving child process | Report cancellation or cleanup failure separately; neither counts as a pass. |

## Coverage plan

Use Swift Testing for pure transitions and reducers, XCTest for UI flows and measured performance, and small Python unit tests for runner and fixture tooling. No unit test needs a running app to check a state transition. Parallel tests use separate scopes and never listen for shared notifications without a unique case identifier.

| Scenario | Real Hermes | Replay and pure tests | App evidence |
| :--- | :--- | :--- | :--- |
| Fresh connection, capabilities, invalid authentication and unknown fields | Verify the actual handshake and refusal | Framing, generated decoders, late calls and unsupported methods | Clear connection and sign-in states |
| Text, reasoning, tool work, question, approval, cancel and completion | Script model output and use real gateway requests | Every request outcome; unsupported requests declined exactly once | Request is readable and answerable; stop is truthful |
| Socket loss before send, after send and during a turn | Drop only the test connection and reconnect | Outbox uncertainty, duplicate events, late replies, stale generation | No duplicated message or hidden failure |
| Event replay | Verify `session.events.since` on the same server and after restart | Sequence gaps, epoch changes, truncation, replay/live overlap and bounded recovery | Quiet recovery preserves the visible reading position |
| Replay response race | Capture active streaming during replay | Returned `latest_seq` ahead of returned frames must not skip events; use actual applied sequence | No missing words or premature ready state |
| Compression and lineage | Trigger summary work through the auxiliary responder; read real history | Root/tip/alias changes and duplicate segment rows; one quiet compression row | Same conversation and draft stay open |
| Older history and cache | Page `/api/sessions/{id}/messages`; confirm profile scope and latest-first options | Offset drift, overlapping pages, malformed or mismatched pages, interrupted writes, schema change and eviction | Older rows arrive in place; cache miss falls through to Hermes |
| Ambiguous send result | Interrupt delivery and inspect public persisted history | Missing row identifiers are unproven, never proof of rejection; no automatic resend | Person can see and resolve the uncertain send |
| Home, Board and Settings | Exercise public reads and writes exposed by the pinned server and owned integrations | Stale results, scope changes, denied permissions and failed saves | Navigation, bot selection and drafts survive transitions |
| Long lineage and active stream | A smaller real lineage validates the same semantics | A versioned 10,000-row scale fixture drives bounded-window and cache tests | Full performance and layout matrix below |
| Demo and isolation | Not a live-service acceptance lane | All catalog fixtures load; expected sends match; no production side effects | Same prepared scenario works offline on Mac and phone |

Replay fault variants must name the production condition they represent. A deliberately reordered frame is a robustness test, not a claim that one WebSocket connection reorders frames. Real fault cases distinguish model-provider failure from app-to-gateway disconnection.

For lineage paging, use the engine's exact query and cache rules, including `limit=120`, `order=latest`, `include_compacted=true` and `inline_images=false`. The pin provides no stable REST snapshot revision. Cover history changing between offset pages and require the engine to preserve existing rows and recover without fabricating continuity.

## What is measured and how

The [Conversation UI performance budget](conversation-ui.md#what-is-measured-and-how) is the acceptance authority, including sample counts, run lengths, repetition and thresholds. This runner records the evidence and fails missing measurements. These are requirements, not results from this documentation work.

- **Correctness:** compare named checkpoints against expected conversation identity, visible row identities and order, pending requests, outbox state and emitted effects. Persisted state plus replay must converge with the uninterrupted run. A screenshot alone does not prove that every message survived.
- **Scale and pacing:** use the UI spec's 10,000 rows across at least ten compression segments. Stream 50 scripted tokens/s. Each fixture token is a defined unit with recorded text, size and timing, not a provider token. Validate those boundaries and the observed delivery rate; character chunk count and reported model usage do not establish the rate. Record event and byte rates too. A pacing failure invalidates the benchmark.
- **Cache delay:** measure older-page demand through read, decode, merge and positioned display. Record warm and cold reads separately, sample count and p50/p95/max. Apply the UI spec's 100 ms p95 and sample requirements. Measure the Hermes fallback separately.
- **Scrolling:** collect frame intervals and hitches during the UI spec's continuous scroll workload. Apply its p95, p99 and worst-stall limits. Record device, OS, refresh rate, release build, thermal state and duration. A screen recording helps review jumps but does not replace frame metrics.
- **Position:** track a stable row's offset in points before and after prepend, compression, late image sizing, keyboard changes and resizing. Test both follow states against the UI spec's anchor and reflow limits, including intermediate frames.
- **Memory:** report resident rows, decoded bytes, each memory cache, process footprint and observer count. Use the UI spec's five-minute warm-up, 20-minute traversal, median comparison and scale comparison. Apply its engine caps and plateau allowance. Retained rows or observers cannot grow even if the footprint stays under the allowance.
- **Isolation and cleanup:** record endpoint host checks, refused egress, synthetic profile names, owned process exit and port closure. Never include the authentication material used by the run.

The reviewer runs and inspects the phone/tablet simulator and Mac window evidence, including foldable-size layouts and continuous size changes. Follow the UI spec's layout matrix and physical-device performance requirements. Record actual dimensions; a device nickname is not a layout measurement. Keep simulator, Mac window and physical-device results distinct. Name baseline hardware and separate media/height cache caps in the acceptance manifest. Use the UI spec's run durations and fixture-defined token units.

## Test plan for this module

1. Validate good fixtures and reject a changed digest, unsupported version, broken identifier mapping, missing attachment, truncated file and unmarked malformed frame. Deliberately seed secret-shaped test markers in every export surface and verify rejection without printing them.
2. Run a real-Hermes smoke scenario twice in fresh roots. Compare normalized exchanges and semantic checkpoints. Report permitted timing differences. Assert that neither run can see the other's profiles, ports, cache or requests.
3. Exercise startup failure at every acquired resource and interrupt a running scenario. Confirm every owned child exits and every opened port closes. Test that cleanup never targets an unrelated process.
4. Run each captured exchange through `TapeWireLink`, the production decoder and the reducer. Assert both resulting state and outgoing effects. Run each listed fault variant under a controlled clock, including events at the timeout boundary.
5. Verify strict script accounting, auxiliary request routing and the model server's text, tool, error, hang, drop and stall paths. A scripted default answer must not conceal an unexpected extra request.
6. Play every demo bundle without network access and with production storage made unavailable. Restart, pause, switch scenarios and exit while streaming. Verify deterministic reset and no live-service calls.
7. Run the complete UI and performance matrix from the UI spec. Attach metrics, screenshots and required inspection notes to `RunEvidence`. A skipped required case or absent evidence fails the release gate.

Future Python changes are checked with `python3 -m unittest discover -p 'test*.py'` from the changed tool's tests folder. The test runner must report test count and failures, and reject an accidentally empty required suite. This docs-only task changes no Python tests and runs no app builds or simulators.

## What it replaces

The recordings replace the separate Python mock gateway for demos and routine UI scenarios. Strict replay replaces ad hoc fake transports and fixed-delay scripts. The pinned Hermes lane replaces protocol confidence based solely on mocks. Existing feature acceptance remains required until each replacement has matching evidence; deleting an old fixture is not evidence of coverage.

Keep one fixture catalog for gateway tests, engine tests, UI tests and demo playback. Each consumer selects the relevant exchange and expected checkpoints from that catalog. It must not maintain a second story with independently invented chat events.

## Decisions and open points

Decided: real pinned Hermes is the integration authority; the scripted model server is the only model endpoint; recorded exchanges feed the shared replay transport and demo; required skips fail; data is synthetic; runtime and visual acceptance remain reviewer-owned.

Open before implementation acceptance: select and prove a runner-level loopback-only egress mechanism on each test host; name baseline hardware and media/height cache caps; confirm all required compression and server-request scenarios can be driven through the public surface at this commit. Any unavailable real scenario stays an explicit failed acceptance item, with replay coverage reported separately.
