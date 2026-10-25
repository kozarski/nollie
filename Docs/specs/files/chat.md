# Chat files: behaviour specs

One section per rewritten file in `Apps/Nollie/Chat`. Plain English, no code.

## HTMLCard.swift

A fenced html block in a bot's reply draws as a web view card instead of code.

Safety: content may come from a model that read hostile pages. The web view uses a non-persistent
data store shared by all cards, no script message handler, JavaScript on, https-only subresources (a
content rule list), no media autoplay, no automatic window opening, and no in-card navigation.

Public API used elsewhere:
- `HTMLCard.isCard(language:)`: true for html or htm (trimmed, any case).
- `HTMLCard.document(_:dark:background:)`: the page as loaded. Fragment is wrapped as
  `<!doctype html><html><head>HEAD</head><body>FRAGMENT</body></html>`. A document with a head gets the
  head additions inserted right after the opening head tag. A document with html but no head gets a head
  before its body. HEAD sets charset, viewport, colour scheme, system font and label colour, images/tables
  that never exceed the width. `background` nil means transparent.
- `HTMLCard.navigation(to:isMainFrame:userLink:)` returns allow, openOutside or block. Frames: block.
  nil or about:blank in main frame: allow. Otherwise only a user-activated https/http/mailto link opens
  outside; everything else blocks.
- `HTMLCard.Actions` (full, showSource, copy) for the Mac right-click menu.
- `HTMLCard.ruleListJSON` blocks http, ws, wss, file, ftp (not https).
- `HTMLCard.pageBackground(dark:)`: nil on iPhone; on Mac a hex of the secondary background.
- `HTMLCard.heightCap`, `HTMLCard.openOutside(_:)`, `HTMLCard.configuration()`, `HTMLCard.log`.
- `HTMLCardView(html:onShowSource:)`: in the thread. Sized to content up to the cap (60% of screen height on
  iPhone, 480 on Mac), minimum 48, loading label until in, full screen button, fade at the bottom when the
  content is taller than the cap. Web view only lives while near the screen (4 s grace after leaving).
- `HTMLCardSheet(html:)`: full screen, scrolling, with a Show Source toggle and Copy HTML.
- `HTMLWebView(document:scrolls:height:loaded:actions:)` with `makeCoordinator()`, `makeWebView(_:)`,
  `update(_:_:)`. Coordinator is the navigation and UI delegate (async policy method so WebKit sees it),
  loads the compiled rule list then the string, then reads the body height at 0, 250, 800, 2000, 4000 ms
  (clamped 24...6000), never pushed by the page.
- Mac `CardWebView`: wheel goes to the thread when not scrolling, command-click opens full, own menu.

Tests: HTMLCardTests, HTMLCardWebViewTests, MacCardBackgroundTests.

## MediaViews.swift

Finds and shows the pictures and files a message points at.
- `TranscriptMedia.images(in:)`, `files(in:)`: cheap pre-check (MEDIA: marker, markdown image or link, a path on its
  own line), then MediaScan. `attachedImages(in:profile:)` reads "[User attached image: name]" marks.
- `MediaThumbStrip(refs:profile:side:alignment:)`: up to 12 thumbnails; two or fewer in a row, more in a sideways
  scroll; a tap opens `ImageViewerSheet`. Mac: drag out the file and a right-click menu (`MacMediaMenu`).
- `MediaThumb(ref:profile:side:)`: spinner, then the picture (never the full bitmap), or the file's name on failure.
Tests: ChatMediaTests, MacReplyCopyTests.

## ImageViewerSheet.swift

Full screen picture: pinch (1x to 6x), double tap (1x or 2.5x), drag when zoomed; Save (Photos on the phone,
Downloads on the Mac) and Share. `PhotoSaveFailure(error, addOnly:)` explains a refused save and offers Settings.
Tests: PhotoSaveTests.

## MarkdownTableLayout / MarkdownTableGrid / MarkdownTableSheet

Column arithmetic (`MarkdownTableMetrics.columnWidths`, `overflow`), a layout placing cells by rows, the cells with
header and hairlines and spoken labels, the stacked form for accessibility sizes, and the full-screen sheet with a
pinned header and a Copy as Markdown button. Tests: MarkdownTableTests.

## MessageBubbleShape / FlowLayout / AttachPanel / RenameChatSheet / SummaryProgressViews / ImageTranscode

- Bubble outline with a right-hand tail mirrored for the left; plain rounded when untailed.
- Wrapping layout for chips; each child measured against the room left on its line.
- The + panel (items with title, symbol, colour, disabled) with identifiers `attach.<title>`.
- Rename sheet: focused, text selected, Return saves, Escape cancels, empty name disabled.
- Summary sparkle and the progress strip ("Summarizing n of m", then "Summaries up to date" for 2.5 s).
- HEIC and friends become JPEG at 0.88 keeping orientation; `TypingHaptics` ticks at most eight times a second.

## HTML card, file, staged, interrupted-turn cards

Specified above (HTML); file cards fetch through the gateway into the media cache, name a copy under the file's own
name, Quick Look, Share, Save to Files or Downloads; staged cards preview with Quick Look thumbnails; the interrupted
turn card explains in words and links to the keep-work-running setting (`AwayGraceSection`, `AwayGraceSheet`).

## ChatProjects / ChatGoals / ChatSummaries / ChatExtras / ChatModelControls

- Project grouping (`ChatProjectGroups.make`), move menu and sheet, folder icon, chip.
- The on-device status line for a working chat: pacing (`Pace.due`), a one-at-a-time writer, `clean` fitting the
  model's words to one line; `ChatGoalLine` shows goal or step.
- On-device titles and summaries with a per-chat cache of 300, progress counters, availability reasons.
- Session cache, jump button, selectable text, avatar renderer (`BotAvatarImage`), attachment thumbnails.
- Reasoning levels, token chip and context sheet, fast and YOLO toggles.

## Composer files

- `ComposerReturnRule`, `InputComposition` (marked text counts only for input methods), `ComposedKeys` (Mac).
- `ComposerTextView` (SwiftUI on the Mac, UIKit text view on the phone with paste configuration).
- `ComposerView`: capsule with +, field, mic/send/stop; attach panel; long paste offer; steer; history; drafts.
- `NewChatSheet`: To: chip field, bot cards, project picker, first message with attachments.
- `Dictation`, `AttachmentPickers`: recorder, camera, waveform.

## Conversation files

- `ConversationView`: opens a stored or new chat, sends the first message, drafts, sheets, keyboard tracking.
- `ChatHeader`, `ComputerControlsButton`, `ChatMenuItems`, `BottomDock`, `QueueStrip`, `InteractivePop`.
- `ChatListView` (bots page, sessions list, grouping, selection), `ChatRoute`, `SessionRow`, `SessionPreview`.

## Transcript files

- `TranscriptView` plus Content, Following, Disclosure extensions; `TranscriptRowModel` (separators, folding, lazy
  split); `RowContext`; `TranscriptRow` (a streaming reply shows only the typing bubble, then the whole reply pops in);
  `MarkdownView` and friends; `TypingBubble`, `WorkingLine`. Tests: TranscriptRowsTests, MarkdownTableTests,
  HTMLCardTests, WholeReplyUITests (not run here).

## CardsView / ApprovalCardView / AnswerCards

Approval, clarify and value prompt cards; screen action wording (`screenLine`, `screenStep`). Tests: BotsHomeTests,
DesignSnapshotTests.

## Second pass: how the pieces are split now

- Conversation screen: `ConversationView` owns the composer text, the open panels and the thread metrics.
  `ConversationLoader` opens or makes the chat and sends the compose sheet's first message.
  `ConversationSheets` shows each panel's sheet (Watch full screen on the phone), asks again for an approval
  confirmed from a notification, and keeps the app's idea of the visible chat right. `ConversationFrame`
  floats the dock and header over the thread on the phone and makes the dock a bottom inset on the Mac;
  `ThreadMetrics` holds the dock, header and keyboard figures and decides what a keyboard frame means.
  `ConversationTopBar` (phone) and `ConversationToolbar` (Mac) are the header. `BottomDock` shows the banner,
  the queue, and one of the Read-only pill, a question card or the composer.
- Bot card: `ProfileCardState` holds what the card edits (description, privacy, model, look, delete) and says
  where a bot thinks and what it may touch. One view per tab (`ProfileLookTab`, `ProfileInstructionsTab`,
  `ProfileModelTab`, `ProfileComputerTab`, apps, this chat, display); the Advanced pages are in
  `ProfileAdvancedPages`; the header and floating buttons in `ProfileCardHeader`. Identifiers are unchanged.
- Thread: `ThreadPrefs` reads the display switches, `ThreadTasks` holds the delayed scroll jobs, `ScrollReading`
  is what the scroll view reports each frame. Following, disclosure holding and content are the extensions.
  `DisclosureHold` is the one place a disclosure tells the thread where its header is.
- Rows: `RowContext` compares what the rows are drawn with; `TranscriptRowModel` builds, folds and splits rows.
- Composer: `ComposerLogic` has the long-text rule, quoting, the pasted-file name and history recall as plain
  functions; `ComposedKeys` (Mac) and `PasteTextView` (phone) keep an input method's keys its own.
- New chat: `Recipient` is the chosen bot and the To: text; `RecipientRow`, `BotMatchList` and the sheet's
  first-message bar are the parts.
- Chats list: `SessionListRules` is the filtering and order; the rows, menus and swipes are `SessionRowCell`.
- Summaries: `SummaryCache`, `SummaryWriter` and `ChatSummarizer` split storage, the model call and the queue.
- Media: `MicCapture` is one recording (dictation and the voice memo share it); `FileFetch` and `VideoFetch`
  hold a file card's or video card's fetch state.
- Removed as dead: `TokenChipView` (nothing used it).
# Chat, third pass (group A: web cards, markdown tables and media)

Behaviour is unchanged. What changed is how the code is put together and worded. Public names and
signatures stay as they were.

## HTMLCard / HTMLWebView / HTMLWebCoordinator / HTMLCardView
- `HTMLCard` holds the containment rules: https-only subresources, no script channel to the app, main frame
  only, a tapped link goes to the browser and everything else is refused. The page head inserts are now a table of
  (selector, declarations) pairs. The rule list is built from a short scheme list.
- `HTMLWebView` has an explicit init (document, scrolls, height, loaded, actions). The Mac's `CardWebView`
  keeps scroll-wheel hand-off, command-click for Full Screen and the three menu entries. The three representable
  methods are thin and go through small functions (`blankView`, `applyLiveSettings`).
- The coordinator measures height with a small `HeightProbe` (script, sample times, range). The navigation ruling
  is `rule(for:mainFrame:)`; the delegate method stays in its async form.
- `HTMLCardView` splits into content, full-screen button, fade-out and leave/return timer functions. The card
  sheet shares `CardPage` helpers with the inline card.

## Markdown
- `MarkdownView` keeps blocks and inline caches in `MarkdownCaches`. Block drawing, the code block and the list are
  separate views. `Style`, `blocks`, `inline`, `headingFont` are unchanged.
- Tables: `MarkdownTableMetrics` (widths, overflow), `MarkdownTableLayout` (measure then place),
  `MarkdownTableGrid` (header and body cells, alignment through `CellSide`; `.bubble` and `.sheet` presets),
  `MarkdownTableStack` (accessibility sizes), `MarkdownTableView` (card), `MarkdownTableSheet` (full table).
- `MarkdownImageView`: asks before loading, 15 second timeout, cached download. `display(success:failure:timedOut:)`
  and `placeholderTitle(alt:)` are unchanged.

## Media
- `MediaViews`: `TranscriptMedia` lookups, `MediaThumbStrip`, `MediaThumb`, Mac `MacMediaMenu`. Fetching
  from the gateway cache is shared in `GatewayCopy`.
- `AttachmentThumbs`: memory cache plus downsampled decoding, sync and async.
- `ImageViewerSheet`: zoom (pinch, double tap, drag), Save to Photos or Downloads, Share, `PhotoSaveFailure`.
- `VideoCards`: `VideoFetch` (fetch, first frame, length, player), `VideoCard`, `VideoCardStrip`.
- `FileCards`: `FileFetch`, `FileCard` (icon by kind through a table), `FileFetchFailure`, `FilesExporter`.
- `ImageTranscode`: HEIC and other formats to JPEG for the gateway; `TypingHaptics` lives here too.

## Wording changed
- File card errors: "There is no gateway connected right now.", "The gateway would not let Nollie open NAME.",
  "NAME is gone from the gateway.", "NAME is too big for the gateway to send.", "Nollie could not get to the
  gateway to fetch NAME.", "You are offline. NAME can download once the gateway is back.", "NAME did not download: ...".
- Image viewer: "This file is not a picture this device can show.", "The gateway could not send this file: ...".
- Photos save: "Nollie is not allowed to add to Photos. Switch that on in Settings, then try again." and
  "Photos could not keep it: ..." (PhotoSaveTests updated).
# Chat, third pass (composer, attachments, goal line, new chat)

Behaviour is unchanged. What each file does now, in the order the pieces are built.

## PasteTextView (phone)
A UITextView with a placeholder label, a Paste that is offered whenever the pasteboard holds anything, and
hardware keys from a small table (arrows recall history, Return sends, Shift-Return adds a line, Command-Return
sends; the first three take priority over the system). While an input method composes the table is empty and
UIKit's cached commands are refused. A Return that goes down during composition is noted and cleared when the key
comes up. `takeComposedReturn()` hands the noted Return over once.

## ComposerTextView (Mac) and ComposerUIKitField (phone)
One public view, two bodies. Same inputs: text, placeholder, focus, line limit, send, paste-data, arrow and
return-sends. The Mac field mirrors focus both ways, lets keys through while composing, adds lines for Shift-Return
(also repeats), treats keypad Enter like Return, and stages pictures, PDFs, movies and sounds pasted with Command-V.
The phone field sizes itself between one line and `maxLines`, routes the on-screen Return by the rule below, and
treats an input method's passed-on break as a hardware Return.

## ComposerKeyRules, ComposedKeys
`ComposerReturnRule` decides send or newline. `InputComposition` says whether the focused field holds marked text
under an input method (a stand-in can be set for tests). `PastedAttachment` names pasted files and tells text from
pictures. `ComposedKeys` (Mac) remembers a Return seen during composition and where the break belongs.

## ComposerView, ComposerStrips, ConversationDock, ComposerHooks
The composer capsule, the + panel overlay, reply quote, staged files (`StagedStrip`, also used by the New Message
sheet), long-text offer and the queue/banner dock. Hooks stage dropped and picked files and react to the chat
appearing.

## Attachments and recording
`AttachPanel`, `AttachSources` (rows, `Intake` reads picks and files, the 200 MB limit), `AttachmentPickers` (camera,
audio session, `MicCapture`, voice memo sheet), `Dictation` (controller, mic button, waveform).

## Goal line
`ChatGoals` watches busy chats and keeps one line per chat; `ChatGoalTypes` holds the data and `Pace`;
`ChatGoalWriting` collects a turn into the model's input, asks the on-device model and tidies the answer.

## Other
`ChatModelControls` (Fast mode, approvals toggle, reasoning levels), `ChatExtras` (jump button, selectable text),
`RenameChatSheet`, `NewChatSheet`.

## Wording changes
- Rename sheet note: "The new name shows in the chat list and the header." became "Shown in your chat list and at
  the top of the chat."
- Steer strip: "Agent is working. Send queues the message." became "Your bot is busy. Send queues this message."
- Paste with nothing on the pasteboard: "Nothing to paste." became "There's nothing to paste."
- Chat menu: "YOLO (skip approvals, this session)" became "YOLO (no approvals for this session)".
- Read-only pill spoken label: "Read-only: this is another bot's chat" became "Read-only. This chat belongs to
  another bot."
- Dictation: "Nothing was heard. Try again a little closer to the mic." became "I didn't catch anything. Try again
  closer to the mic."; hints "Stops listening and puts the words in the field" became "Stops, then types what you
  said" and "Records, then turns it into words on this device" became "Records you, then writes it out on this
  device".
- Microphone refused: "Microphone access denied." became "Nollie can't use the microphone. You can allow it in
  Settings."; recorder failed: "The recorder would not start." became "Recording didn't start. Please try again."
- Picked file errors: "Could not read NAME" became "Nollie couldn't open NAME."; "NAME is larger than 200 MB."
  became "NAME is over 200 MB, which is too big to attach."
# Chat, third pass (helper C)

Behaviour is unchanged. These notes say what each file does after the third restructure.

## Thread rows
- `TranscriptRow`: classifies an item once (`RowShape`, with small builders for the person, tool and
  assistant cases) and draws one view per shape. Equality compares the item, the display settings and the two
  open flags. On the Mac a row aligns right, left or centre by shape.
- `RowContext`: what rows are drawn with (settings, live state, open sets, actions). Equal when nothing a row
  shows changed. `rowView` adds the time heading, accessibility group, highlight and time beside the row.
  `RowActions` keeps the closures in one object; `WithText` and `WithFlag` name their shapes.
- `TranscriptRowModel`: builds rows (unique ids, time headings after a 15 minute pause, run ends, folding of tool
  runs) and decides where the lazy part ends (`tailStart`, `split`).
- `TimeRevealColumn`: one offset on the column plus a pan hung on the enclosing scroll view (iPhone).
  `RevealRule` holds the thresholds, `StillnessWatch` remembers when the thread last moved.
- `ScrollMetrics`, `ConversationLayout`, `InteractivePop`, `FlowLayout`: same jobs as before; keyboard following,
  dock measuring, the one full-screen back pan per stack, and the wrapping layout.

## Bubbles and cards
- `PersonBubble`, `SteerBubble`, `ReplyLine`: share `BubbleMenu` (context menu built from action and closure
  pairs; Share is a flag).
- `StagedCard`: kind facts come from a table keyed by attachment kind.
- `InterruptedTurnCard`: lines under the title are a list; the explanation is three short sentences.
- `TranscriptNotices`: start failure card, injected note, bot message notice, reasoning disclosure.
- `TranscriptSmallViews`: line cap, code block, attachment chips, copy button.
- `SubagentRow`, `CrewNoteCard`, `TodoChecklist`: small views split into named parts.
- `ActivityViews`: `ToolRunRow` (run header and step list) and `ToolCardView` (header, details, output).
- `CardsView`, `ApprovalCardView`, `AnswerCards`: pending cards. `ChatSession.approvalCard` builds the approval
  card for both the dock and the thread. Screen action wording comes from two tables.
- `SummaryProgressViews`: sparkle and the progress strip; the strip is driven by a small `StripNote` value.

## Visible wording changes
- Interrupted turn: "Send a message to carry on." became "Send a message to pick up where it left off."; the
  three-sentence explanation was reworded.
- Start failure card: both explanatory sentences reworded.
- Value prompt card: "Sent directly to your gateway; never logged by the app." became "This goes straight to
  your gateway. Nollie never logs it."
- Approval: safety check note and the two System control accessibility hints reworded.

## Third pass: thread and small files (D1)

- `TranscriptView`: state and body only. The spacing sums and the "what has a row" answers moved to
  `TranscriptView+Facts` (autoInset, dockReach, visibleBottom, bottomInset, bubbleCap, approvals, systemControlStop,
  visibleItems, typingTool and friends). Behaviour is the same: a streaming reply still shows only the typing bubble
  until the whole reply pops in. The sheets, the scroll margins and the debug readout are small named parts.
- `TranscriptView+Content` and `+Following`: same jobs, restated with named helpers (`showsWorkingBubble`,
  `turnOnSystemControl`, `Set.mark`); every comment rewritten shorter.
- `TypingBubble`: `ToolBadge` is one symbol on a mint background.
- `MessageBubbleShape`: explicit init, same parameters and defaults; the mirror is one affine transform.
- `ToolCallSheet`: the text builder is a pair of static helpers, the page (Done, Share) is `ToolCallPage`.
- `ContextBreakdownSheet`: the bar is `BreakdownGauge`; usage lines come from a table with a `positive` filter.
- `ChatSummaries` / `ChatSummaryParts`: the queue is drained by one worker task; the debug stand-in is its own
  function; the on-device model's guide text is reworded (not shown to people).
- `SessionCache`: the stored-key helper is now `entryName(for:bot:)` (was `key(connection:profile:)`, only used inside).
- `TodoChecklist`: argument decoding split into `todoList(in:)`.
- Visible wording: the Summaries "unavailable" reasons in Settings were reworded (see report).

## Third pass (D2): bot and chat chrome, thread, list comments

- `SheetChrome`: `doneToolbar(id:)` puts a Done button in the corner that dismisses the enclosing sheet (inline title on
  the phone). Used by the bot sheets, Keep Work Running, Context, and the Mac bot card.
- `ChatHeader`: header, pill, computer button and chat menu keep their inputs and look. Status text is a small
  `StatusLine` value; names are cut by one `shortened` helper; the bot's display name is a `ChatSession` extension.
- `SessionRow` / `ChatRowStyle`: row parts are small views. Row spacing is one `Metrics` value chosen once
  (`-nollie-row-style a|b|c` in debug); the unused `variant` is gone.
- `BotMenuItems`: rows come from one `row(...)` builder; `page(kind)` says which pages carry the chat id.
- `BotHistoryView`: context menu, swipe actions and the delete confirmation are named parts.
- `ProfileTab` titles come from the raw value; `ProfileTabRow` is a strip plus a tab-bar semantics modifier.
  `ProfileCardView.floating(...)` is the sheet version of the card.
- `ToolCallSheet`: `ToolCallText` builds the headed sections; the sheet only shows and shares them.
- `ContextBreakdownSheet`: gauge, category row and session counts are separate views.
- `SummaryProgress`, `SummaryCache` and `ChatSummarizer`: same behaviour, new shape (`SummaryCache.Table`).
- Thread (`TranscriptView`, `+Content`, `+Following`, `TypingBubble`): same behaviour. Row split is a `RowPlan`; the
  follow-the-end rules are unchanged and still only ever act through `mayFollow`.
- Comments across the list, thread, conversation and row files were reworded.
- Visible wording: the archive failure, the delete confirmations on the Chats list, the stale approval line, the
  model-start notice and the Apple Intelligence "not available" line (see the report).
