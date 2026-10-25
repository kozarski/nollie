# Unit tests: behaviour notes

One section per rewritten file in `Tests/Unit`. Plain English, no code. Each says what the old tests
checked, so the fresh tests could be written from the notes and today's app code alone.

## SnapshotRaceTests.swift

A chat reattaches by reading a snapshot of its session (rows, open questions, pending approvals, whether a
turn runs). Building its rows takes a moment off the main actor, and the world moves meanwhile. Checked:

- Events for the session reach a chat that has just been opened, even before the first reattach answer is
  applied. They wait, then are applied on top: a tool call done, the reply finished, the turn over.
- A reply that names a new session id makes that id the chat's before its rows are built.
- A question asked while rows are built stays and its answer reaches the bot; a card only an older
  snapshot listed goes. A question withdrawn meanwhile goes too and its waiter is let go (answered with null).
- A card answered here while rows are built, or while the snapshot is still being asked for, stays
  answered: no card, no attention, not announced again. Holds for approvals (with a queue entry) and questions.
- A card a newer snapshot no longer lists is settled: card gone, attention cleared, the posted
  notification taken down, a question's waiter let go with nothing sent. A withdrawn question does the same
  and also clears the turn surface (menu bar) attention.
- With two cards and the one the surface shows going (answered, withdrawn, unlisted), the surface shows
  the other one, with no new alert.
- A question asked after the snapshot was requested, absent from its list, stays (approval, clarify,
  sudo) and the bot keeps waiting; a later list asked after it, without it, lets it go. An older snapshot
  applied after a newer one does not remove it.
- A card listed again is announced once; the gateway hears "approval received" once.
- A turn surface started by a snapshot shows the card the turn waits on, with no alert, whether the card
  came with the snapshot or before it, and again after a second snapshot.
- An older "pending approvals" lookup returning late cannot bring back an answered card.
- One approval under two ids (the gateway's queue entry and the request itself) is one card: the request
  takes the queue card's place without a new announcement, no queue card joins an existing request card,
  and answering by the queue card's id answers the request, not the queue.
- Approve/Deny from a notification finds the right card: the app's own notification (card and request
  named) or a push naming only the request; a gone approval answers nothing; a tap while the chat opens
  waits for the card; an unnamed or blank one answers only when exactly one approval waits.
- Overlapping snapshots show each event once whichever finishes first; a turn that ended between the two
  still ends here: the reply heard once, the finish reported once, the queued message sent next.
- A question withdrawn between snapshots, or before the reply of a snapshot that left it up, goes. A card
  left up by a snapshot goes when a turn end (complete or error) came before that reply, but a question
  asked after the end stays.
- A message sent while rows are built stays after them and keeps the turn running; rows another snapshot
  added are not kept twice.

## HermesRemoteTests.swift

A grab bag of small checks, grouped here by topic:

- Gateway address: normalising what a person types (scheme added, lower-case host, trailing slash and pasted
  `/api/...` routes removed, optional path prefix applied), building API and WebSocket URLs (ws for http,
  wss for https), telling private hosts from public ones, and refusing empty text, other schemes and
  addresses with a query.
- Request signing: session-token mode sends the token header and no bearer; OAuth sends a bearer and no
  token header; Cloudflare Access headers only go out when both id and secret are set (half set is flagged);
  public headers never carry the bearer; the WebSocket credential is a token or a ticket by mode.
- Frames: parsing an event, an approval server request (with offered choices) and a response or error;
  encoding a response and a request.
- Streaming: deltas assemble into the reply; a final text wins over streamed text; after a tool call split
  the reply, only the part not already shown is added, with tolerance for whitespace drift and a fallback
  to the final text on divergence.
- Markdown blocks: fenced code (open and closed), headings 1 to 6 (seven hashes is text), lists with
  nesting, tabs as four columns, number continuation, depth capped at six, task items, quotes, rules, tables
  (alignment, ragged rows, escaped pipes, code spans, no outer pipes, header-only while streaming, mismatched
  delimiter row, blank line ends a table), images (standalone, linked, inline stays text, unbalanced link),
  Windows line endings, front matter hidden only when closed and keyed (also with a BOM or `...` closer).
  Heading fonts differ per level; the image view picks spinner, placeholder or image, with alt text or a
  generic title.
- Dashboard API with a faked transport: GET config sends profile and all auth headers; PUT sends a JSON body
  with bearer and no token header; an HTML login page is diagnosed; a 422 detail is surfaced.
- Chat registry: routes by the chat's current runtime id after a reconnect, replaces the same stored id,
  removes.
- Tab layout: old administration layouts fall back to chats and settings, the Board choice survives
  migration and round trip, full layout, chats and settings cannot be hidden, launch tab fallback.
- Turn stats prefer exact token counts and label them; estimates are marked.
- The bundled push companion files equal the source in the repo, and the versions agree.
- Transcript separators appear only after a gap; bot colours are stable and valid.
- Relay payload decryption against a vector made by the companion.
- Transcript messages decode in both wire shapes and survive the cache encoding.
- Chat owner: a call carries its owner as the profile or nothing; lookup order puts the selected bot
  first; a live copy beats an archived one.
- Bot deliveries: recognising a message to another bot from a terminal command in several shapes, the
  message tool, and non-deliveries; inbound "message from" rows.

## RememberedSignInTests.swift

"Remember sign-in on this device": a password saved per gateway, used to sign in again after Face ID.

- Storage policy: the Keychain item is this-device-only, never synced, behind the device owner check (Face ID
  or passcode, in the access control and not the plain accessibility attribute), in its own service so that
  nothing that reads gateway secrets ever prompts. On the Mac it uses the data-protection keychain.
- The sign-in never prints: not in `String(describing:)`, reflecting, interpolation or `dump`.
- The vault knows which gateways have a sign-in without a prompt, finds them again after a relaunch,
  opens one with the check's context (so there is a single prompt), and forgets on request. An item gone
  from under it is dropped from the list.
- A forget the Keychain cannot do (device locked) is done later: the gateway is never offered or used from
  then on, not after a relaunch either, the item is deleted by the next reload that can, and a sign-in
  remembered again in between survives. A delete that works says so.
- What the Keychain's statuses mean for delete (success or not found is gone; locked is not) and for listing
  (none is an answer, locked or missing entitlement is not, missing data is not).
- A list that cannot be read at launch is "unknown" until it can; a later failed read keeps what was known;
  a successful empty read is known and empty. The coordinator re-reads it before deciding.
- Saving the gateway form: on with something typed remembers; on with nothing typed keeps; turning off
  forgets; opened off and saved off keeps; a new address forgets; another sign-in method forgets.
- The decision table for using it: password sign-in with something remembered, a passcode, able to prompt
  now, not declined, not used a moment ago uses it; otherwise a reason (not a password sign-in, nothing
  remembered, no passcode, not now, declined, too soon). The Sign In sheet's button overrides declined,
  not-now and too-soon, but never the first three.
- Using it: Face ID with reason "Sign in to <gateway>", then sign in with the remembered password, keeping the
  gateway's own Access headers. A cancel falls back to the prompt, is not asked again by itself, keeps the
  item, and the sheet's button asks again and reports the cancel.
- On return to the app, only a refresh the gateway turned down is mended by signing in again; a socket
  refused after a fine renewal is not. A refused refresh signs in again however soon, including after a
  period away. By itself it is limited to once a minute and three in ten minutes per gateway (clock set
  back is ignored); the sheet's button is exempt and does not count; a fresh manual sign-in resets.
- A sign-in remembered for another address, or one with no address, is never sent and is forgotten, and
  the sheet says "moved". A password the gateway refuses is forgotten; a network failure keeps it.
  Nothing is asked in the background or for a browser sign-in. Simultaneous calls share one prompt.
- The runtime asks for a sign-in again when its refresh is turned down (and marks the refresh refused,
  clearing the mark after any later sign-in), keeps the gateway's Access headers, saves for next launch,
  and opens a refused socket again after a successful sign-in (never one that was closed on purpose).
- Removing a gateway forgets its sign-in. The saved secrets have no field a remembered sign-in could use.

## GatewayIntegrationTests.swift and KanbanStoreIntegrationTests.swift (live gateway checks)

Run against a real gateway or the mock; skipped unless settings are found. Settings come from the runner's
environment, then a `KEY=VALUE` file outside the repository (`HERMES_E2E_ENV_FILE` or `~/.config/nollie/e2e.env` in
the real home), then an older JSON file in the simulator's temporary folder. A required flag makes missing
settings a failure that lists paths and key names, never values.

- The connection test passes every step and reports a version.
- The REST endpoints answer: profiles, model options, config, config schema (approvals mode is a select),
  toolsets, environment variables.
- A turn streams over the socket: capabilities and ping, a session is made, a prompt with a `nollie-e2e-` marker
  gets deltas and a final message, usage and context breakdown add up, the command catalog is not empty; with no
  model provider on the gateway the error is the expected one and the check says it was skipped. The session is
  always closed and deleted.
- Leftover test chats (title or first prompt starting `nollie-e2e`) are found for every bot, taken over if another
  client holds them, deleted, and a second listing proves they went.
- Two devices on one chat: the watcher shows the other device's prompt once and the reply; an approval answered
  on one device clears from the other while the turn still runs, the answering device gets no "answered elsewhere"
  note, and attention is cleared.
- The Board: probe finds the plugin and remembers it per gateway; selecting another board reads and remembers it
  and opens the live socket; three changes made at once cost at most two reads; a refused move keeps the server's
  words after the next read and the next good write clears them.
- Projects: a chat moves into a project, the gateway's tree agrees, it moves out, a missing folder is refused
  with nothing moved.

## ProjectsAndGoalsTests.swift

- Chats grouped by project: projects in their own order, chats in list order; empty projects show unless the list
  is narrowed; archived projects' chats go under none; every bot's projects get their own groups even with equal
  ids; no projects still gives the one group; folded groups are kept as a list.
- The working line: a young turn gets none; later lines are paced by steps and seconds; the model's words are
  trimmed (quotes, trailing stop, first line, length, too short); the model is shown this turn's prompt, steps and
  last words; the loop writes once, drops a line for a changed turn, waits after a failed write, and does nothing
  when switched off.
- A turn the gateway cut short is a card only for the gateway's exact sentence; the away grace is read from config
  in three shapes, writes where the gateway reads, and its choices have set labels.
- The live check of moving a chat in and out of a project (see the live gateway section).

## ReasoningReplyTests.swift

A bot's answer is always its reply. The gateway's echo of the reply is not reasoning; an answer sent only as
reasoning becomes the reply; thinking before it stays as a card; an interim message already shown is not shown
twice; a turn cut off with no text never promotes thinking. The settling rule has cases for streamed text, spacing,
think tags, the promoted mark and a reconnect mid-answer. History: answers stored with empty content show; thinking
before a tool call, while running, or cut by length does not; a stalled response the gateway nudged on is not a
reply; an answer finished here survives another turn starting; hidden rows and blank reasoning stay out; previews
see the promoted answer; stored rows decode in both spellings and survive the cache.

## LongTurnReturnTests.swift

Coming back to a long turn: runs of reply text join into one piece in order, not across sessions or kinds, keeping
the first piece's other fields; one list refresh per kind per batch; a taken batch is closed; a joined batch gives
the same reply as one by one; redraw spacing grows with the reply; away the reply gathers and draws on return; a
snapshot's rows follow the history and keep shown ids; a snapshot lands with the turn running; events during a
snapshot come after it; the transcript cache keeps the newest 200 and is written off the main thread.

## PresentationModelTests.swift

The model modifier reaches content with nothing above it; a source scan finds every sheet, cover, popover and
preview in both apps and each passes the model on (more than thirty found); the scanner reads each kind and
ignores comments and strings, with correct line numbers.

## CronRunTests.swift

"Run now": running at once, one run however often it is pressed, finished or failed with plain words, requested
when there is no sign of progress, started when the gateway is still working after silence, another task's record
confirms nothing, the confirmation fades without cutting a later run short, the run outlives the page. Task list
wording for object schedules, paused and finished tasks, pause and resume confirmation.

## SocketTimeoutTests.swift

With a loopback WebSocket listener that goes quiet: a call times out, waiting for ready times out, returning to a
silent socket tears it down, a cancelled call returns at once. Retry delays start quick and back off to thirty
seconds; a gateway that appears seconds after launch is reached within three seconds.

## TranscriptRowsTests.swift

A token in the last reply leaves older rows and their context equal; the tail boundary rules; no two rows share an
id; a turn's tool calls fold into runs (except messages to another bot, split by long pauses); only the newest row
fades in; a streaming reply keeps the typing bubble until whole (checked by drawn height); a reply is announced
once when complete.

## ComposerCompositionTests.swift

iPhone: with nothing marked the keys are the composer's; while an input method composes, no key is taken and
stale commands are declined; accepting the candidate gives the keys back; a Return the input method took is
forgotten when the key comes up; a Return passed on afterwards follows the hardware rule; Shift-Return adds a
line under either setting; marked text without an input method changes nothing; which keyboards count as input
methods; a focused plain field is seen composing. Mac: Caps Lock and the keypad make no chord; a field editor
with marked text is composing only for an input method; keys sent to a real composer behave for Korean (Shift-
Return adds a line at the cursor, Return sends), Japanese and Chinese (keys taken whole send nothing), a held
Return sends once, the arrows give way only to an input method.

## Small files

- KanbanTests: the Board's payload shapes decode (board, task detail, boards, workers, log, envelope, events);
  which columns can be moved to and what asks for confirmation; patch and new-task field names; the event cursor.
- MarkdownTableTests: a wide table parses with every cell, VoiceOver text, Copy as Markdown round trip with
  alignment and pipes, column widths, edge fades; the Reasoning style differs from replies.
- HTMLCardTests: html fences become cards when closed; the document wrapper; navigation policy; the content rules.
- SiriTests: the catalog keeps bots and recent titles only; switch defaults; the status line and approval
  question wording; stop and control words; Stop and Ask Nollie intents.
- SubagentTests: helper rows follow `subagent.*` events in any order; delegation reports become notes.
- SummaryTitlesTests, SummaryProgressTests: titles are made once, a typed name wins; the counter for a run.
- GatewayFormHintsTests: connection type suggestions and the Save blocker text.
- SignInTests: which gateways lack a sign-in, pairing recovery, browser session ending on any thread.
- ReasoningEffortTests: level order, menu line, schema read, which bot's model list a chat reads.
- ChatMediaTests, FileScanTests, ReviewRegressionTests: pictures and files in replies and tool output.
- MarkdownCodeBlockTests: a huge fence parses in one pass; an open fence keeps all its lines.
- PlainReplyTests: a reply as plain words (tasks, markdown, front matter, pictures, tables, streaming).
- AttachmentRefusalTests, ComposerReturnTests, PhotoSaveTests, ReattachTests: wording and rules as named.
- HTMLCardWebViewTests: the card's web view delegate answers WebKit and a page cannot navigate away.
- Mac only: MacContinuityMenuTests, MacMediaSaveTests, MacSleepAwayTests, MacCardBackgroundTests,
  MacReplyCopyTests, MacBotAnimationTests (menu bar marks and ambient motion).
- Left as they were (already new code): LiveWatchTests, NollieLinkDoorTests, AskFirstSettingsTests.
