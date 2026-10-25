# UI test files: behaviour specs

One section per UI test file that was rewritten. Each says what the flow checks, in plain English, so
the test can be written again from the note alone. All of them drive the demo copy of the iPhone app
(`com.coreykozarski.nollie.demo`, which keeps its gateway in memory) against the mock gateway
(`Tools/mock-gateway/mock_gateway.py`, token `mock-token`). They skip when the mock or the demo copy is
not there, and the golden ones (listed in `Tools/dev/verify.py`) fail the run when they skip.

The mock answers by the first words of a message: `marathon N` (N tool steps then a long report ending
"Nothing else needed attention"), `tools` (a dozen tool cards), `card` (an HTML card with one link),
`table` (a markdown table only), `wide` (a six-column table), `files` (a PDF and a CSV), `compress` (a
compression, then "Carrying on"), `power rankings` (the whole answer sent as reasoning), `think it
through` (real reasoning, then a reply), `ask first ...`, `sign in <site>`, `crew ...`, `clean up the log
host` (a command that waits for an approval).

## HermesRemoteUITests.swift

Two flows on a gateway the person supplies. (1) Onboarding to a first reply: a fresh install, Get
Started, Skip, Connect your gateway, fill name, address and token (or user name and password), Test
Connection, Save; the bots list opens; one message is sent ("reply with the single word pong") and a
reply or the gateway's error shows; then Settings opens. (2) The last Settings row, scrolled to the
very end, sits fully on screen and not under the floating bar.

## RememberSignInUITests.swift

With the mock's password sign-in switched on: the gateway form's user name and password method shows a
"Remember sign-in on this device" switch, off until turned on, with a line saying it lives in the
Keychain and is never synced. Save signs in once. Settings, Gateways, Advanced lists a Forget row for
the remembered sign-in. When the gateway ends every session and the person taps Reconnect, the app signs
in again by itself (log: refresh expired, then password-login) and never shows "Sign in again". After
Forget, the same expiry asks the person (log ends at refresh expired and "Sign in again" shows). The
mock's password gate is turned off again afterwards.

## ChatShowcaseUITests.swift

Three tours. (1) A whole conversation: the list shows the seeded chats; a new chat is started; a message
about a full disk is sent; the typing bubble shows; a terminal tool step shows; an approval card
appears ("Approval needed") and Once answers it; the final reply arrives; the chat's context chip opens a
breakdown ("By category") that Done closes. (2) Opening a seeded chat shows its history at once, Back
returns to the list with the bar, a long press peeks with Open, the title pill opens the chat's info
("This chat"), the profile row opens the bot card (Avatar), and the sheet closes. (3) Settings,
Appearance shows the Tab bar section. Much of this belongs to screens that no longer exist (the tab bar,
the chat list with seeded chat rows).

## ChatScrollUITests.swift

A long reply and the reader's place. (1) A 30-step marathon grows from one typing bubble to many screens
in one update; once it ends its last line is on screen, above the composer by no more than 80 points, no
partial report text showed earlier, and no "Jump to latest" arrow shows. (2) With a 120-step marathon:
scrolled up while it streams, a row on screen stays within 24 points of where it was until the reply
ends; the jump arrow shows while away from the end and returns to the end; after the reply, scrolled up
again, nothing pulls the thread back (4 seconds); and further up among earlier messages it holds too.

## ProfileCardUITests.swift

The bot card from a chat's title pill, light then dark in two launches. Header named after the bot with
Close and "..." buttons; a tab row; from a chat "This chat" is on show with a rename row. The Name row
and the "..." menu's Rename chat both open the rename dialog (cancel closes it). Each tab shows its own
section: Look (Reset to default), Instructions (Edit instructions, Description), Model (ChatGPT or
Claude plan, hero, Advanced row), Display (Show in chats), This chat (Name). Close closes the card. From
the chat itself, the "..." menu and a long press on the pill both offer Rename chat; a real rename shows
in the header and in the list row.

## RotationUITests.swift

A chat is open with the keyboard up and the phone is turned to landscape: the app stays in the
foreground, the header (Back) is still there and typing still works; turned back, Back is on screen near
the top, typing still works, and tapping Back leaves the chat for the list.

## TableRenderUITests.swift

A reply with a six-column table: the table is wider than the screen (last column runs past the edge);
reading the whole accessibility tree does not take the app down; a sideways drag on the table scrolls the
table, not the thread; "Open the table full screen" opens a sheet titled Table with Copy as Markdown and
Done; a long press on the table shows the reply's own menu, not a table menu.

## CronRunNowUITests.swift

Settings, Scheduled Tasks, the task "Morning brief": Run now pressed twice quickly reads "Running..." and
turns off at once, the mock is asked for exactly one run, a result line "Last result: ok." shows, Save
stays off (nothing edited), and the button comes back as Run now. When the task is started elsewhere and
Run now is pressed meanwhile, the gateway's refusal reads "It is already running. Wait for it to finish,
then try again." and the button is ready again.

## LongTurnReturnUITests.swift

A long turn (a 600-step marathon) keeps running while the app is sent to the Home Screen for about a
minute and the mock drops its sockets (as iOS does to a suspended app). Coming back, the chat answers:
the + panel opens within 12 seconds, the end of the report is reached (by the thread or the jump arrow)
and the app is in front. Timings are reported. Settings: HERMES_E2E_AWAY (seconds away), HERMES_E2E_STEPS.

## ReasoningReplyUITests.swift

(1) An answer a model sends only as reasoning ("power rankings...") shows as the bot's reply with a real
table (header "Superpower", cells "Lab / Model: ...", no raw markdown pipes) and no extra Reasoning card;
after the app is relaunched and the chat reopened from history, the same holds. (2) Real thinking ("think
it through...") keeps its Show reasoning card above the reply; opened it reads Hide reasoning, and the
reply under it is whole.

## HeaderHittableUITests.swift

Over a long thread the floating header's Back, title pill and "..." are each hittable where drawn (the
accessibility hit test there finds the control, not a message behind it), and Back as an element leaves
the chat.

## ThreadLayoutUITests.swift

During three "tools" turns in a row, and after, no two neighbouring thread rows overlap: the next row
starts below where the one before ends. Checked over and over while streaming, through the settling
after each turn, and while scrolling up six times and down eight times. More than 30 checks must have
run and more than six tool cards must be on screen.

## SaveToPhotosUITests.swift

A reply with a picture ("disk-before-after.png") opens in the viewer; Save to Photos asks the Photos
permission (answered Allow), the button reads Saved and is off, and the app is still running a few
seconds later (it once stopped on every device). Needs the Photos permission unanswered before the run.

## BoardEditUITests.swift

On the Board, a task's sheet Edit menu: Rename changes the title the sheet shows (and is put back); Edit
the Description opens an editor, added words are saved and shown in the sheet; Done closes it. The task
is "Remove rotated logs older than 90 days", in Ready.

## CardsAwayUITests.swift

HTML cards far from the screen let their web views go: after two cards ("card please", "card again
please") and ten plain table replies, no web view is left in the thread; scrolling back up draws them
again.

## FileCardsUITests.swift

The "files" turn gives two file cards under the reply, one for report.pdf and one for "raw numbers.csv"
(a bare folder makes none); the MEDIA line is not in the words but the link's words are; tapping the PDF
card fetches it and opens a preview titled with the file name; after Done the card shows a size.

## HeaderShotsUITests.swift

Pictures only (plus one check) of the header over a long chat: at the end, scrolled up, during a fling,
in landscape, and after a tap on the status bar, which must take the thread to its top (the first step
is on screen in the top half).

## HeaderTextSizeUITests.swift

At accessibility text size, in a chat with a long title: Back keeps at least 12 points from the leading
edge, the title plate starts after Back and ends 12 points inside the trailing edge, the "..." circle
stays inside the trailing edge, and Back leaves the chat.

## AttachPanelUITests.swift

The + panel opens from the Attach button (the Files row appears), folds back with Close attach panel,
and opens again; the first open is not more than half a second slower than the second. Frames are
captured while it grows and folds.

## AttachRefusalUITests.swift

A PDF staged at launch (`-nollie-test-stage report.pdf`) shows over the composer; sending "card:
summarize the report" to a mock without PDF tools shows the plain explanation ("the gateway is missing
the tool it reads PDFs with", "Pictures and text files still go through") while the gateway's own words
("pdftoppm not installed") are kept, and the message itself still goes.

## ReasoningMenuUITests.swift

The chat's "..." menu has a Reasoning item that names the level (medium); it opens a list of six levels
(minimal, low, medium, high, xhigh, max) in that order of strength; high can be chosen.

## CardLinkUITests.swift

A link in an HTML card ("card please") opens outside the app (the app goes to the background) and the
card stays on its own document: its heading is still there and the link's page did not load inside it.

## DesignShotsUITests.swift

Pictures, nothing asserted: the bots list light and dark; a long press on a bot row and on a pinned tile;
the main chat and its menu and title tap; an approval in the thread light and dark (`-nollie-demo-say
clean-up-the-log-host`); the by-hand path (open a bot, type, send, approval, back, row menu History); a
pinned tile opening its chat from the face and from the name (pinned then unpinned); a bot's History,
What it knows, Settings pages, the Computer tab and the new-bot sheet; Papertrail light and dark.

## RemoveNollieUITests.swift

Settings, About, Remove Nollie's data: the sheet says "What goes" and "What stays"; the iCloud line
shows only after the iCloud switch is turned on; Cancel leaves it; Remove runs line by line and ends
with "Nollie's data is gone", and Done closes. The demo copy only pretends.

## AboutSourceUITests.swift

About shows the Nollie wordmark and the line "Your own crew of helpers, on your Mac and iPhone.",
Acknowledgements and Remove rows, no Send feedback link; the version ("Version ...") and the Developer
Mode switch sit behind Advanced.

## DiagnosticsUITests.swift

Settings, About, Diagnostics: a hero, the line "A file with what Nollie did today, to share if something
went wrong. Private details are left out." and a Share button.

## AwayFromHomeUITests.swift

On a phone linked to a Mac (the mock's link routes). At home: a status line "At home"; Settings, Away
from home shows the hero, "Everything works.", a Without Tailscale line (mentions Alerts) and a With
Tailscale line (Chat, Approve, Stop, Watch); the switch starts off; turned on with no Tailscale it shows
the steps; when the mock says Tailscale is ready the page shows Ready by itself; turned off again, the
Mac was told "on" then "off" once each. Away without Tailscale: the status reads "Away . alerts only";
sending shows the card "You're away from home." / "This needs Tailscale to reach your Mac."; Set up
shows the steps; Done closes it and the typed words stay unsent. With the exit node on, a bot's Computer
tab shows the exit node card (and no Open button); when the relay carries the traffic the card leaves.

## SettingsShotsUITests.swift

Pictures, nothing asserted, light and dark: Settings root; each page (Bots, Appearance, Notifications,
iCloud, Voice, Gateways, Away, About, Advanced with Developer Mode) top, lower part and its Advanced
page; sub pages (Models, Chat summaries, Acknowledgements, Remove); the Left and Night summaries; each
Bot settings tab; the Remove sheet in review and finished; Away from home scrolled.

## AskFirstUITests.swift

Light then dark: "ask first email" makes an Ask first card that says the bot wants to send something,
names the recipient, does not say "needs your OK" or show the gateway's rule words, has no Always and no
button check line; Allow once (light) sends ("Sent.") and Deny (dark) does not ("didn't send"), and the
card goes. "ask first click" makes a card whose check line says which button is about to be pressed
("You're about to press 'Send'") with the summary "Press 'Send' on its computer."; no raw tool names or
coordinates, no Always; the other answer is chosen.

## WholeReplyUITests.swift

A reply arrives like a message: a typing bubble and the tool steps show while it is written; none of the
report shows until the whole of it does (its first heading never appears without its last line); at rest
the end of the reply is on screen above the composer, no more than 80 points above it, the typing bubble
is gone and no "Jump to latest". The chat is a side chat of the default bot, sent "marathon 8".

## AskNollieControlShotsUITests.swift

The Ask Nollie control: found in the Control Center gallery (not the old Stop control), placed, then
pressed, which opens Nollie in the main chat with the composer and the keyboard up. Pictures go where
NOLLIE_CONTROL_SHOTS says; skipped without it.

## CrewNoteUITests.swift

Light then dark: "crew please" shows a note "I've added Scout to check new roles each morning." with Meet
and Undo; Undo answers in place ("Removed Scout"). "crew idea" shows Add and Not now; Add answers "added
Rover".

## MainChatContinuityUITests.swift

Light then dark: after "compress", the reply "Carrying on" arrives in the same chat; exactly one quiet
row "Earlier messages summarized" sits above it; Hermes's own compression lines ("/new", "Compacting")
are never shown.

## SilenceResultUITests.swift

With the mock started with the silence demo: the default bot's row preview reads "Your report is ready."
without NO_REPLY or [SILENT]; its chat shows that reply, no quiet marker rows, one reply row and no
heading for the two silent scheduled turns; the reply sits above the composer; after Back the row is not
marked unread. In the work bot's chat the literal user messages "[SILENT]", "NO_REPLY", "The marker
[SILENT] is literal text." and the reply "Your reminder is set." are all visible.

## ConversationSwitchOverUITests.swift

With Developer Mode and the new chat view on, the default bot's chat opens on the conversation screen
(list, bot pill, its own composer and send), a message about the log host streams, a tool step shows
("Ran a command"), the approval card is answered with Allow once (a quiet "Allowed" row), and "compress"
gives one summarized row with "Carrying on" in the same thread. Light and dark.

## BoardDragUITests.swift

On an iPad in landscape, one temporary task made through the mock is dragged from Pending to Blocked: a
"Block this task" alert asks for a reason, Block saves it; the card shows the reason, the task is blocked
with that summary, the Blocked lane count goes up by one, the attention count goes up by one and the
Board button's badge says so. The task is deleted afterwards. Skips on a phone.

## HelperAtWorkShotsUITests.swift

Pictures of the Lock Screen Stop (the Live Activity) for a sample helper in four states (live, stale,
stopping, stopped): the Dynamic Island compact and expanded, and the Lock Screen. Stop is there while
live or stale and gone once pressed. Skipped without NOLLIE_ACTIVITY_SHOTS.

## SignInUITests.swift

Light then dark: "sign in example.com" shows a card "wants to sign in to example.com" saying the helper
is never told the password, with no "needs your OK" and no Always. Allow once (light) ends with "signed
in to example.com" and "never told your password"; Deny (dark) ends "I won't sign in". The card goes.
"sign in other.org" makes no card and says there is no saved sign-in for it. Face ID is answered yes by
the demo copy; the mock's saved sites are reset first.

## PrivateBotUITests.swift

Light then dark: in the Work bot's settings (the Instructions tab) a Private switch is off until
turned on, then the line "Hidden from notifications, the chat list and backups." shows, and it turns
off again.

## BotsSettingsUITests.swift

Settings, Bots lists the Work bot (and no "glass for all" row); opening it shows the Look tab with the
shared look editor and no studio glass control.

## PapertrailUITests.swift

A bot's settings opened by launch flag: the Papertrail tab shows the day's answer at the top, an "On this
Mac" count, an "Online" count and at least one row, and not the "off" state.

## DevicePairingUITests.swift

Inert preview screens for pairing: the confirmation names "Studio Mac" and its address, its Connect
button is off, no camera view, and Manual setup opens the gateway form whose Save stays off; the link
confirmation reads "Link to Studio Mac?" with a link button that is off; the scanner preview says the
camera is off, closes, and the next step reads "Set up Nollie on your Mac." with "Scan QR code" and
"Connect manually" and no route buttons.
