# Nollie rewrite specs

**Decided:** one generated gateway contract, one conversation per Hermes lineage, one deterministic engine, a bounded local history window and a bottom-anchored chat. Uncertain sends are never repeated automatically. Real pinned Hermes supplies the integration tests; reviewed recordings supply replay tests and demos.

**Open:** the pinned server has no atomic snapshot/replay checkpoint or stable history page cursor. Recovery and history joins need proof before cutover. Durable identity for some older rows, store replacement detection, cache retention, migration, test isolation and baseline performance devices also need decisions. These are acceptance gaps, not completed work.

## Read in this order

| Module | Spec | Owns |
| :--- | :--- | :--- |
| 1 | [Gateway client](gateway-client.md) | Generated Swift wire types, transport, connection state, replay and explicit request declines |
| 2 | [Conversation engine](conversation-engine.md) | Lineage, reducer, request book, outbox, compression and windowed cached history |
| 3 | [Conversation UI](conversation-ui.md) | Bottom anchoring, composer, follow rules, adaptive layout and performance limits |
| 4 | [Shell, home, Board and Settings](shell-home-board-settings.md) | Navigation, bot home, task work, preferences and service boundaries |
| 5 | [Tests and tools](tests-and-tools.md) | Real-Hermes harness, recordings, replay, demo and acceptance evidence |

Each file specifies intended behaviour. It is not a claim that the rewrite is implemented or verified. Public types are proposed boundaries; generated wire names follow Hermes. Existing implementation choices do not override these contracts.

The separate [Papertrail](papertrail.md) and [Night shift](night-shift.md) feature specs remain in this folder, with [In your pocket](pocket-audit.md), what works on each device. They are outside these five rewrite modules and retain their own acceptance work.

## Source boundary

Use the read-only Hermes checkout at a checkout of Hermes Agent at tag `v0.22.2`.

| Item | Exact pin |
| :--- | :--- |
| Release label | `v0.22.2` |
| Commit | `d923a5eb487a17c0a68801bba9ef0f56c81040a8` |
| OpenRPC file | `apps/shared/src/gateway-contract.openrpc.json` |
| OpenRPC SHA-256 | `8848b394df533af8b37afd3cdccfc48b3e3d6ca1ce4037ebaf38653e33ed832e` |

Hermes's public contract is the wire authority. Its pinned server routes and tests clarify behaviour absent from OpenRPC, including history pagination, replay timing and the scripted model server. Each module names the evidence it uses. A new pin needs a reviewed contract diff and regenerated recordings; it is not a silent dependency update.

The design is written from those service contracts and Nollie's product needs. Current app screen text was inspected only to inventory visible home, Board, chat-menu and Settings behaviour. Existing Swift structure, identifiers and comments are not design sources. Do not use the former client as a reference implementation or copy its tests into new fixtures. Test inputs come from synthetic scenarios and observed Hermes exchanges.

The app stays native on Mac, iPhone and iPad. The minimum deployment targets in the project are macOS 26 and iOS/iPadOS 26. Later layout APIs need checked availability and a working base layout. Owned runtime, phone-link, computer-control, sign-in and notification services keep their existing product contracts and permission boundaries. Their implementations are not being redesigned here.

Required third-party licence and copyright notices remain in `LICENSE` and app distributions. Rewriting a module is not a reason to remove a notice or reuse excluded branding. No restricted Cua source is a reference for these specs.

## A few terms

| Term | Meaning here |
| :--- | :--- |
| Lineage | One conversation across the stored sessions Hermes makes when it shortens its working context. |
| Root, tip and aliases | The conversation's first known segment, its current continuation, and earlier identities that still open it. |
| Reducer | A rule that takes the current state and one input and returns the next state and requested work. The same inputs always give the same result. |
| Replay | Asking Hermes for events missed during a break, then applying each once. |
| Sequence and epoch | An event number and the identity of the server run that issued it. Numbers from different runs cannot be compared. |
| Request book | Questions and approvals waiting for an answer, with their exact owner and outcome. |
| Outbox | A saved record of what the person tried to send and what is known about delivery. It is not an automatic retry queue. |
| Window | The bounded set of rows kept ready to display. The rest stays on disk or is read from Hermes when needed. |
| Uncertain | Work may have reached Hermes, but its outcome is not proved. A lost reply never means “safe to send again.” |
| p95 / p99 | The time that 95 or 99 out of 100 measured cases finish within. The worst case is reported separately. |

## Shared boundaries

| Boundary | Owner and rule |
| :--- | :--- |
| Connection/profile scope | Gateway defines `PeerScope`. Every other module keeps it on data and actions; display names never establish ownership. |
| Transport versus history | Gateway owns frames, calls and replay. Engine owns bounded REST history reads, lineage and storage. REST/plugin adapters share connection authentication and scope checks. |
| Durable replay progress | Engine commits data and applied sequence together, then returns `EngineReceipt`. Gateway never advances a cursor to an advertised sequence it has not delivered and committed. |
| Requests | Gateway routes/declines; engine tracks conversation requests; UI reports usable presentation; shell reports lock/window availability and owns app-level setup requests. Offscreen is not automatically unsupported. No module invents an answer. |
| Sending | Engine records an intention before dispatch. Gateway reports evidence. UI shows that evidence. No layer silently retries an uncertain mutation. |
| Scrolling | Engine publishes `WindowSnapshot` and stable row identities. UI owns `ReadingAnchor` geometry and follow state. Neither loads the full lineage just to keep a scroll offset. |
| Performance | UI's measurement table owns end-to-end limits. Engine's timings are component diagnostics within that budget. Harness supplies repeatable workloads and evidence. |
| Demo | Recordings go through the production decoder, engine and UI in isolated storage. No separate demo chat engine or Python mock gateway. |

## Acceptance and replacement

Implement in module order, with tests supplied alongside each module. Old paths may remain temporarily to support a reviewed cutover, but only one engine owns a selected conversation at a time. Do not mirror sends, approval answers or other mutations into both paths.

Before retiring a path, prove its replacement against the matching synthetic recording, the real pinned service and the visible behaviour inventory. Preserve connection choices, drafts and reading positions through an explicit migration fixture. Missing proof remains an open gate; a successful build does not establish replay correctness or scroll stability.

The full chat acceptance target is a 10,000-row lineage with 50 scripted tokens per second, cached rows visible at p95 within 100 ms, steady scrolling, no content jumps and bounded memory. The [UI spec](conversation-ui.md#what-is-measured-and-how) defines the workload, tolerances and evidence. Claims about real-device performance need real-device measurements.

This change is documentation only. No Python tests were changed. No app build, Hermes process, simulator, screenshot run or performance test was run. The reviewer runs builds and relevant tests, inspects phone simulator and Mac window captures, and records the remaining runtime evidence. Required skips fail acceptance.

## Spec template

Use one Markdown file per module. Write the behaviour for someone who uses Nollie before describing the machinery. Keep exact wire names in the contract tables; explain unfamiliar terms. Distinguish a server fact, a product decision and an unresolved limit.

```markdown
# Module name

[Spec index](README.md) · Links to dependencies

## Purpose

What this module gives the person. What it owns and where it hands work on.

## Behaviour in plain words

Normal use, interruptions and recovery. Preserve the visible actions that matter.

## Public types and contracts

| Type or boundary | Contract |
| :--- | :--- |
| Proposed name | Inputs, outputs, identity, owner, lifetime and guarantees |

## States and transitions

| State | Event | Next state and effect |
| :--- | :--- | :--- |
| Starting state | Explicit input | New state and observable result |

Name stale-work, cancellation, replay and persistence rules where relevant.

## Error cases

What the person sees, what is retained, and whether retry is safe.

## What is measured and how

Workload, limits, clocks, sample counts, platforms and required evidence.
Separate a proposed acceptance limit from a measured result.

## Test plan

Pure tests, recorded fixtures, real-service checks and visible acceptance.
Name the owner of anything that cannot be proved in this module alone.

## What it replaces

Responsibilities being retired and behaviour that must survive.
Give a cutover condition without adopting the previous code's structure.

## Decisions and open questions

What is settled. What needs evidence or a product/protocol decision.
State which open item blocks acceptance and the safe behaviour until then.

## Evidence

Pinned contract methods, public routes, tests and product requirements.
Do not cite the previous implementation as the design authority.
```
