# Conversation UI

[Spec index](README.md) · Depends on [Conversation engine](conversation-engine.md)

## Purpose

Make a long conversation feel like Messages. New replies stay in view when the person is at the bottom. When they read earlier messages, the page stays where they left it.

This module draws the conversation and collects actions. The engine owns messages, requests and sending state. Opening, resizing or closing a screen must never send a message or invent a person's answer. Losing the ability to present a request may trigger the gateway's explicit decline policy.

## Behaviour in plain words

- A short conversation sits at the bottom. Older messages grow upwards. Text stays upright, in reading order, including for VoiceOver and selection.
- The composer sits in a bottom safe-area inset. It takes up real layout space above a docked keyboard, so it never covers the last message. Floating keyboards and side bars also leave every action reachable.
- New messages follow the bottom until the person scrolls away. A small button takes them back to the latest reply. Streaming never pulls them away from earlier text.
- Opening a chat for the first time goes to its latest message. Returning restores its reading position and draft. A message link opens that exact message, including an older lineage segment.
- Sending deliberately returns to the latest message after the engine accepts the local send intent. A rejected send leaves the draft and position alone. A sent message stays visible while delivery is uncertain.
- Replies can contain text, code, links, attachments and expandable steps. Settings may fold ordinary steps, but never a request waiting for an answer. Compression adds one quiet row in the same conversation.
- Stop asks Hermes to stop this turn. It says work stopped only after Hermes confirms it. Pausing a computer preview is a separate action.

## Public types and contracts

These are proposed boundaries, independently named for this design.

| Type | Contract |
| :--- | :--- |
| `ConversationSurface` | Receives a `WindowSnapshot`, composer state, presentation settings and an action sink. Draws only the resident window. Does not fetch, persist, decode wire messages or infer delivery. |
| `ViewportLedger` | Per window and conversation: follow state, `ReadingAnchor`, focused control and measured viewport. Survives keyboard, width and appearance changes. Two windows can read different places. |
| `FollowChoice` | Exactly `following` or `browsing`. Loading, dragging and connection status are separate facts. |
| `ReadingAnchor` | Engine-owned row identity plus the signed distance from its top to the unobscured viewport's top. A partly visible row can have a negative distance. Never an index or session tip. |
| `SurfaceAction` | Scoped intent to edit a draft, submit, stop, answer, load older rows, reveal a row or open content. Includes conversation identity and displayed revision. Stale actions cannot reach the newly selected bot. |
| `CardVisibility` | Request identity and transport generation, with separate facts for a supported presentation being available and its card actually being visible. An offscreen supported card remains pending. Creating a row is not proof that its card was shown. |
| `LayoutReceipt` | Viewport bounds, anchor and offset before/after a change, bottom distance, resident count, row revisions and elapsed time. Contains no message bodies or secrets. |

The list uses a native collection view wrapped by SwiftUI: `UICollectionView` on iPhone/iPad and `NSCollectionView` on Mac. SwiftUI supplies the surrounding screen and row content. The native list owns cell reuse, measurements and scroll compensation. This is a design choice, not performance proof.

There is one list owner per displayed conversation. Updating inputs patches that list; detaching cancels observers and media work. A streaming token or width change cannot recreate its identity or draft. Streaming updates the active reply's revision. Bounded height and rich-text caches use row revision, actual column width, text size and appearance as their keys.

## States and transitions

Measure bottom distance within the usable viewport, excluding the composer, keyboard and safe areas. Distances are in points.

| Current state | Event | Next state and effect |
| :--- | :--- | :--- |
| Following | Reply grows, request arrives, composer or keyboard changes height | Stay following. Keep the last row above the inset, without repeated scroll animations. |
| Following | Person scrolls more than 48 pt from the bottom | Browsing. Capture the first visible row and offset. |
| Browsing | Person finishes scrolling within 24 pt of the bottom | Following. Between 24 and 48 pt, keep the previous state to avoid flicker. |
| Browsing | Reply grows, replay arrives, page lands or card changes height | Stay browsing. Preserve the visible row and offset. Indicate that newer content is available. |
| Either | Tap latest, or engine accepts a local send intent | Following. Reveal the current bottom. |
| Either | Open a message link or restore an earlier position | Browsing. Page to that row; do not briefly flash the latest reply first. |
| Either | Resize, fold, rotate, change text size or return from another tab | Preserve state, draft, selection and anchor. Geometry alone cannot resume following. |

Before inserting, trimming or resizing rows, capture the anchor and native scroll position. Apply the change, measure its new position and compensate in the same layout transaction. During drag or deceleration, preserve the person's movement and velocity. Do not cancel their gesture to finish a page load. For width/text-size changes, also retain the first visible text block within the anchor row so reflow does not skip their place.

If the anchored row was deleted, use the nearest surviving older row, then the nearest newer row. Explain that the message is gone. Do not jump to the bottom.

## Measurable layout rules

These are initial acceptance limits. Changing one requires a recorded design decision.

| Area | Rule |
| :--- | :--- |
| Width | Use the chat pane's actual safe width. Inset each horizontal edge 16 pt, or 12 pt below 360 pt. Centre a readable column up to 720 pt; wide-replies preference may use the remaining safe width. |
| Short history | Final row sits 12 pt above the composer inset. Spare space is above the first row. No inverted coordinates. |
| Rows | At least 8 pt vertical separation. Text wraps without a fixed line count. Wide code/tables scroll inside their row. Attachments reserve bounds before decoding. |
| Composer | One through six text lines at ordinary sizes, then internal scrolling. At accessibility sizes it may grow to half the usable chat height. At least one input line and Send/Stop stay reachable. Preserve marked text and selection. |
| Controls | At least 44 by 44 pt touch hit areas; native Mac sizing and keyboard focus. Labels wrap or enter a labelled menu before overlapping. Approval text and decisions remain readable. |
| Narrow layout | One content pane and a native route back to bots whenever safe width cannot fit a 260 pt sidebar, divider and 420 pt chat pane. |
| Wide layout | Sidebar beside chat only when both minimum widths fit and the system permits it. Large text can require narrow layout at the same width. Keep the chat's readable width. |
| Foldable | Use scene size, each edge's safe inset and system-reported reserved regions. Move controls clear of fold/camera regions. Preserve conversation, draft, focus and anchor when opening or closing the device. Never size from a device name or guessed hinge angle. |
| Insets | Respect each edge separately, including side bars and right-to-left layout. Only backgrounds extend into unsafe regions. Never count the keyboard inset twice. |

The checked-in minimum targets are iOS/iPadOS 26 and macOS 26. The base layout works there using safe areas and available width. A later fold-specific API needs a verified SDK signature, an availability gate for its declared version and the base layout as fallback. Selecting that API is an implementation checkpoint, not a requirement to raise the minimum OS.

VoiceOver reads oldest to newest and keeps focus when pages arrive. Do not announce every streamed fragment. Completed replies and new requests get concise announcements without stealing focus. Reduce Motion removes animated jumps and decoration, preserving follow rules. Solid appearance, reduced transparency and the largest accessibility text size retain all actions.

## Error cases

| Case | Behaviour |
| :--- | :--- |
| Older page unavailable | Keep rows and position. Put Retry at the boundary. Distinguish a gap from the beginning of history. |
| Compression during paging | Accept only the engine's current generation; retain row identities and the single summary marker. |
| Unsupported request, locked screen or unavailable presentation | Report unpresentable to the request book and gateway decline policy. A supported card merely scrolled offscreen stays pending with a route back to it, without forced scrolling. Never silently wait on an unsupported request or auto-approve. |
| Answer elsewhere or expiry during a tap | Reconcile through the request book. Absence from a fresh pending list proves only that it is no longer open, not which answer won. Never apply the tap to a replacement card. |
| Huge text, code or image | Render bounded blocks. Offer an explicit disk-backed viewer for the full result. Never decode a whole large attachment into the scrolling list. |
| Memory pressure | Release offscreen measurements and media, then trim unpinned rows. Preserve anchor, draft and decision. Show the engine's limit state if those cannot fit. |
| Lost connection or send result | Display the engine's waiting/uncertain state. The UI never retries mutations. |
| Two windows | Each keeps its anchor. Share a local answering state to prevent duplicate taps. Other clients learn settlement through authoritative refresh or events where available; there is no assumed immediate answer broadcast. |

## What is measured and how

Use a **10,000-row lineage** across at least ten compression segments, including short/long text, code, attachments, steps and approvals. Stream **50 scripted tokens per second** while scrolling older history, paging, expanding rows and resizing the composer. Fixture tokens are defined units with recorded sizes; report bytes and observed event rate too. Character chunks are not provider tokens.

Use release builds on the oldest supported physical iPhone, a supported iPad and a baseline Mac named in the harness manifest. Measure five runs after one warm-up. Simulator captures prove layout only. Report device, OS, build, refresh rate, fixture digest and trace separately per platform.

| Measure | Acceptance and method |
| :--- | :--- |
| Cached history | At least 100 requests per run; p95 older-page intent to rows visible and positioned at most 100 ms. Separate warm application cache and cold process reads. Network cannot satisfy cache-only samples. |
| Steady scrolling | At 60 Hz: p95 frame interval at most 16.7 ms, p99 at most 33.4 ms, no stall above 100 ms, over a continuous 60-second scroll while streaming. Record frame timestamps and a trace. At other rates report missed-refresh counts too. |
| No content jumps | Prepend, trim, replay, compression and unrelated row growth leave anchor error at most 1 pt, with no displaced intermediate frame. Use receipts plus frame captures; subtract deliberate scrolling. |
| Reflow | Same reading block remains visible after width/text-size changes, within 2 pt of its requested new offset where viewport bounds allow. No blank flash or reset to latest. |
| Flat memory | Honour engine caps of 500 resident rows and 16 MiB decoded bodies, including pinned rows. Name separate media/height cache caps in the manifest. After five minutes warm-up, compare first/last one-minute median process footprints in a 20-minute traversal run. Growth is at most the larger of 20 MiB or 10%, with no retained row/observer growth over three traversals. Report peak and trend. |
| Streaming work | Unchanged offscreen rows do no new parsing/layout because another row received text. Profile update counts and parser time. Publish at most once per display frame without dropping text. |

The memory allowance covers allocator variation, not accumulated history. Also compare 1,000, 10,000 and 100,000-row synthetic disk histories with the same resident window. Resident row/body counts stay constant; the 100,000-row footprint remains within the same allowance of the 10,000-row run.

## Test plan

1. Pure follow tests cover every transition and the 24/48 pt boundary. Insertions, keyboard changes and reconnects alone cannot change browsing to following.
2. Native-list tests prepend/trim during drag and deceleration, resize a reply, decode an image above the viewport and replay duplicates. Assert identity, anchor and gesture continuity.
3. Composer tests cover multiline drafts, hardware keyboards, marked text, attachments, failures, Return-key preference and Stop. Two input paths cannot submit one draft twice.
4. Request tests verify usable presentation precedes `approval.received`, offscreen supported cards stay pending, truly unavailable presentations use the gateway decline rules, and late taps cannot answer a settled or differently scoped request. A local reply write is not proof Hermes accepted the answer.
5. Screenshot/interaction runs cover safe widths of 320, 390, 600, 768 and 1,024 pt, narrow Mac windows, foldable outer/inner/partial-fold layouts and iPad split windows. Include both colour schemes, right-to-left, largest text, keyboard and a long approval command.
6. Check VoiceOver, keyboard-only navigation and Reduce Motion. Inspect phone/tablet simulator pictures and a Mac window capture. Run physical-device performance through [Tests and tools](tests-and-tools.md).

Builds, screenshots and runtime measurements are future acceptance work. None were run for this documentation change.

## What it replaces

Replace the previous transcript renderer, composer layout and separate scroll-follow rules with this surface. Preserve visible chat preferences and supported actions. Retire the second rendering/sending path once every chat uses the new engine. The surrounding app stays SwiftUI; the native list is an owned platform adapter.

## Decisions and open questions

Decided: bottom anchoring, safe-area composer, two follow states, stable row anchors, reusable native lists and the acceptance limits above.

Open: name baseline devices; verify the fold API bridge; measure media/height cache caps; confirm the text renderer meets selection, accessibility and long-code budgets. These choices cannot weaken the no-jump or bounded-window requirements.
