# Behaviour specs: app area

Plain-English specs written before each file was rewritten. No code.

## App/SpeechBubbleShape
A Shape: rounded rectangle body (corner 16, or half the height if smaller) with a small curved tail (8 deep, 16 wide) at the bottom centre, all one closed outline. `tailOnTop` mirrors it so the tail rises from the top edge. The tail uses the 8 points of the frame on its side.

## App/Perf
Debug-only counters and main-thread stall logging; no-ops in Release. `tick(name)` counts re-evaluations and logs totals once a second. `watchMainThread()` (once) logs "main thread busy N ms" for stalls of 250 ms or more, excluding time the whole process was suspended (found by a fast heartbeat thread). `note(line)` logs a line. Log category "perf".

## App/TabBarMinimizeObserver
UIViewRepresentable with a `minimized` binding. Finds the system tab bar in the window (class name contains TabBar, bar-like size) and, on a display link, reports true when its width is under half the window's. Re-searches periodically. Stops when removed from the window.

## App/Theme
`AppTheme`: accent list (blue, indigo, teal, green, orange, pink, purple, graphite) with ids and names; `accent(id)` falls back to blue; `current` reads the saved key `theme.accent`. `Color.nollie` is the current accent.

## App/FittedSheet
Sheet content wrapper: scrolls, 40 points clear of the grabber, detent follows measured content height (plus large), thick material background; on Mac fixed width 460 and height up to 640.

## App/BackgroundTime
iOS only. Begins a background task by name; ends it on `end()` or when the system expires it; safe to end twice.

## App/ConnectionPill
Glass capsule showing a coloured dot (green open, orange connecting or reconnecting, red rejected or failed, grey idle) and the state label; accessibility label "Connection: <label>".

## App/BotMotionSource
Singleton feeding the bot tilt from device attitude. Keys `bots.motion` (default on), `bots.tilt` (default off), style key from CharacterView. Does nothing when reduce motion is on, motion is unavailable, or the app is inactive. Level is the attitude at start, drifting slowly to the current hold; dead zone about 5 degrees, full lean about 40; output smoothed.

## App/ComposeAction
Enum quick, sheet, none with raw string ids. Keys compose.tap and compose.hold. Tap choices quick, sheet (default quick); hold choices sheet, quick, none (default sheet). Titles "Start a chat", "Show options", "Nothing"; spoken phrases for VoiceOver. `tap(_:)`/`hold(_:)` parse stored string, falling back to default when missing or not allowed for that gesture.

## App/Handoff
`ChatHandoff.activityType` (base bundle id + ".chat"), `fill` puts title, session id, profile and gateway address into a handoff activity, `open` resolves a received activity to a nollie://chat/<session>?profile= link, switching to a saved gateway with the same address first, ignoring unknown gateways. `View.handsOff(chat)` (inactive when the chat has no stored id) and `View.continuesHandoff(model)`.

## App/MacAdaptations
`SettingsList` (phone: list with row height 54, section spacing 28; Mac: grouped form in a 700 wide centred column with row-style buttons), `SheetSize` (form 520x600, compact 440x340, wide 720x680), Mac-only `SettingsRowButtonStyle`, Mac sheet frame with Escape to close, Mac refresh button (command-R). View helpers: `sheetFrame`, `untitledPage`, `rowActions` (swipe vs context menu), `reloadable` (pull vs button).

## App/DeviceWords
Constants: device name (iPhone, iPad via hardware or simulator identifier, Mac), settings name, tap/click words, isMac, symbol, and phrases this/This/ThisTitle/your/the/kind, companionBrings.

## App/BotTurnReporter
TurnActivityReporting for phone: only `end` does something: tells BotAmbient the turn finished for that bot.

## App/TabLayout
Ordered primary tabs (chats, kanban, settings). Chats and Settings always present; duplicates and unknown dropped; parse from comma string; launchTab only kanban or chats; set(enabled) inserts new tabs before Settings unless full, ignores required; move; visible(hiding:); encoded.

## Security/AppLock
Observable lock: enabled flag in defaults (mirrors notification preview prefs, unlocks when turned off), locked at launch if enabled, relocks when foregrounded after more than 5 seconds, biometryName, unlock via device authentication; if the device cannot authenticate, record the error and unlock.

## Security/RememberedSignIns
Protocol for asking the device owner (canAuthenticate, methodName, authenticate(reason) returning the passed context or nil); system implementation; DEBUG demo implementation from `-nollie-demo-biometry yes|no`. Error enum (cancelled, gone, rejected, moved) with fixed copy. Coordinator: pure `decide` (password only, remembered, passcode, asked bypasses app-state and floor, not-now, declined, too soon), floor of min 60 s apart and 3 per 10 minutes ignoring future times, pure `formChange` (forget for non-password; remember if switch on and typed; forget if moved; forget only when switch turned off here; else keep). Instance: vault, authenticator, canPromptNow, replaceable signIn and clock; declined set, history per gateway; automatic sign-in from refused refresh or on return; button sign-in throws errors; one in-flight attempt per gateway; attempts check owner, read vault, forget if address moved or password rejected. Copy enum for what guards the sign-in. Tests: RememberedSignInTests.

## Bots/BotsView
Bots tab: searchable grid (2 columns on phone, adaptive on Mac, max 720 wide) of BotCards; tapping pushes the bot's detail; long-press menu: New chat, Chats, Bot settings, Make active (when not active). Plus button opens NewBotSheet. Loads profiles when empty and on gateway change; reloadable; scroll offset feeds BotAmbient. Footer sentence about Hermes profiles. Types kept: BotsView, BotSettingsRoute, BotCard (size 78, overlap 10), MotionDemoView, BotRow, BotDetailView; DEBUG look grid and motion demo overlays via launch flags. Detail view: Bot settings link, chats list with delete (confirm), compose request starts a chat with this bot.

## Bots/NewBotSheet
Create or edit sheet. Name slug rule (lowercase letters digits dash underscore, collapse runs, trim dashes), taken-name warning, look picker without photo, More options (description, model menu, start from), create via NewBotCreation steps with lock and runtime guards, save edits (description, model, look), delete with confirm (not the default bot). Accessibility ids newBot.*.

## Connect/GatewayFormView
Add/edit gateway form. Connection kind picker (local, tailscale, cloudflare, other) with titles, symbols, placeholders, help; `suggested(for:chosen:)` rule (public under local/tailscale suggests other; private/tailscale under other suggests the matching; cloudflare never). Fields name, URL, path prefix; default scheme http for local and tailscale else https; notes about scheme and risky choices; auth method picker (session token, password with remember switch and provider, browser sign in); optional Cloudflare Access headers; Test connection with steps; Save only after a pass and a name; `saveBlocker` sentence builder (kept exact); `noPasswordProviderMessage`. Changing anything resets the test; a link-supplied token is dropped if the address changes. Save builds the connection (clears identity on key changes; Mac direct keeps the managed installation link when unchanged), writes to store, applies remember/forget/keep through `formChange`, reactivates. Tested by GatewayFormHintsTests.

## Kanban/KanbanView (split into KanbanView, KanbanAsk, KanbanTaskSheet, KanbanNewTaskSheet)
Board page: horizontal paging lanes by presentation group (width min(380, width-40)), cards as glass buttons that open a task sheet, draggable between lanes (drop token gateway/board/task, only accepted when from this gateway and board and the task is not already in that lane; done, blocked and archived moves ask first), swipe actions (Done, Unblock; Delete, Stop or Block), context menu (Move to, Reassign, Priority, Comment, Stop, Discuss, Archive, Delete). Toolbar: board chooser when more than one board (with count of tasks needing help), options menu (about badge, check for tasks, refresh), new task. States: no gateway, plugin off, error, loading. Reads when showing, listens for events, refreshes every minute; stops events when hidden. Reveals a task requested by a notification. KanbanAsk cases and copy kept (Mac board uses them). `priorityName`, `liveCapsuleLift` kept. Dead: KanbanCardRow (unused) deleted. Task sheet: facts, warnings, description edit, result, children, runs with log, comments, history; rename; stop worker; polls every 6 s while a worker is on it. Log view polls every 4 s when live. New task sheet: title, details, bot, priority, triage.

## Kanban/BoardTaskRow and BoardLane
Row: title, preview, assignee chip (display name or capitalised id), stage chip (Working, Being reviewed, Needs your help, Waiting to continue, Queued, or the column title); stacks chips when narrow. Lane: header with title, symbol, count (blue when blocked lane has items), scrolling cards, empty text per lane, drop target highlight, optional scroll-to selection.

## Connect/GatewaySignIn
`GatewayConnection.lacksCredentials(secrets)`: token mode needs a non-blank token, oauth and password need a bearer. `GatewaySignIn.usesBrowser` (oauth and not needing pairing), `pending`, `browser` (sign in via browser, save session, reactivate, post sessions-changed; throws fresh-code error when pairing is needed). `GatewaySignInSheet`: walks the given connections one by one with step counter, explanation per case (pairing, browser, remembered, typed), buttons (scan a new code on iOS, browser, remembered with Face ID name and symbol plus Enter Sign-In, form), Skip/Later, errors; cancellation is silent; ids signin.*. `GatewaySignInBanner` with Sign In or Reconnect button setting `model.signInPrompt`.

## Connect/NollieTalk
`NollieTypedBubble` types text out (12 ms for a space, 22 ms otherwise; instant with reduce motion), reserving full height, tail on top. `Color.readableGreen`. `NollieGuide`: character above bubble; speaking while typing, thinking, listening; a happy hop when `turnKey` changes.

## App/NollieTabBar
Custom glass tab bar for the phone: capsule 56 high with 4 inset, 21 side margins, equal slots, clear glass lens under the selected slot, selected slot shows its title unless labels are off or the lens is being dragged. Drag gesture: after 0.22 s or 8 pt sideways, lens follows the finger and tabs switch under it with haptics; quick press is a tap. Tap on the current tab pops to root (when not at root) and bumps reselect counter; choosing any tab clears composeReturnTab. Badges: chats = cards waiting; settings = restart required or companion update. `overhang`, `reservedHeight` statics kept; `showLabelsKey`. Also `HidesTabBar`, `TabRoot` modifiers, pop-to-root probe, `hidesTabBar()` and `tabRoot(_:)`.

## App/CompanionPrompt
Sheet with two shapes: found companion (permission message by authorization state, button Allow / Continue / Open Settings, Not now) or not found (pitch, Set up notifications, Later). `installedVersion(on:)` checks the companion manifest. Same copy as before.

## App/SiriEntities
SiriCatalog: defaults keys siri.bots, siri.chats, siri.spotlightChats (default on except Mac), siri.answersApprovals (default off); stores bots as [name,label] rows and up to 50 chats as [id,title,bot]; spotlight sync indexes or deletes chat entities; profile(for:on:) picks bot id, else default, else selected. BotEntity/BotQuery, ChatEntity (Spotlight attributes)/ChatQuery (10 suggestions), ApprovalAnswer enum. SiriWords: status sentence (none running, one, many up to 3 named; waiting counts), approval question (plugin rule uses plain first line, else command; clipped at 120), approveRefusal (sign-in, ask first). Tests: SiriTests.

## App/SiriIntents
Intents OpenChat, NewChat, BotStatus, AnswerApproval (requires switch, auth, single approval, confirmation), iOS MacStop press (stop route then stop local replies), shortcuts provider with the same phrases, SiriAsk helper (connect and wait up to 10 s for an open socket).

## App/BotColors
Per-bot colour table (JSON in defaults key botColors), palette from NollieCore, deterministic default hex, save mirrors to extensions, `Color(hex:)` parses 6-digit hex with or without #, `hexString` as uppercase sRGB.

## App/BotAvatars (now BotAvatars, BotAvatarView)
BotAvatar view (character or photo, hop on finished turn within 1 s, perk on tap within 1 s, accessibility hidden). BotLooksMirror writes colours, resolved avatar choices, 128 px photo thumbnails, also under labels, to the shared store. BotAvatarStore: choices in defaults key botAvatars, resolve/look/showsPhoto/seat/set/migrate, photos as 320 square JPEGs in the BotAvatars folder with an image cache; CharacterLookPicker grid of looks with optional photo row.

## App/AppModel (split into AppModel, PendingRoute, AppModel+Links, AppModel+Notifications, AppDelegate)
The one shared model. Public property and method names are unchanged because Chat, Mac and Push code use them. Holds: store, remembered sign-in coordinator, lock, push registrar, runtime, tab and compose state, tab bar hide counters, visible chat, pairing and board requests, Ask Nollie state, notification routing state. Behaviour: activate a gateway (stop old, restore if abandoned, wire push, card notifier, auto-answer for System control, turn reporter, auto sign-in), deactivate, remove/reset (clears keychain items, photos, defaults twice), delete connection; sign in again on return and with remembered; companion update flag; away prompt; open links (nollie://chat, pair, Nollie Link offers, DEBUG demo notification); open stored chat; new chat request after 500 ms with side-chat window of 5 s; Bot Chat lookup in three steps; main chat open/start; Ask Nollie waiting on lock; board chat open and return; notification routing with identity check, owner check, 12 s socket wait, reply and approve/deny with sign-in and confirm rules. `PendingRoute` payload parsing is strict (bad connection id, bad gateway, bad bot id or "all" gives nil). `ApprovalConfirm` modes risky/all/off. iOS AppDelegate for push, foreground presentation and tap handling, including Stop from an alert.

## App/RootView
Window content: onboarding (or forced by DEBUG flags) vs main screen, lock screen above, keyboard tracking, launch tab with a wait up to 8 s for the Board plugin, layout reset on first run (chat-first migration), Companion prompt owed after the first gateway connects (one sheet at a time, waits for sign-in, lock, pairing; checks for an installed companion; re-owed if interrupted), sign-in sheet, away card, installer, pairing sheet on iOS; DEBUG launch flags. `LockScreenView`, `MainTabView` (sheet pages for Settings, Board, Tasks following `selectedTab`, dismissed by routes, new chat, lock, sign-in).

## App/NollieApp
App entry: setup in init (demo, perf watch, legacy folders, keychain group, preview mirror, image transcode, typing haptics, avatar migration), window with tint, colour scheme, URL opening, handoff; launch task; scene phase handling (foreground: away flags off, motion on, lock, push, cloud alerts, companion, reload remembered sign-ins, sign in again if expired; background: reverse).

## App/DemoMode
DEBUG demo copy on `.demo` bundle ids: memory-only keychain, gateway from `-nollie-demo-gateway url token name`, reach/tailscale/exit-relay/alerts flags; release build stub constants.

## Dead code removed
App/NollieTabBar (the bar view itself; the phone has no bottom tab bar, only its `hidesTabBar` and `tabRoot` modifiers are used, now in TabPageModifiers), App/ComposeAction (only the dead bar read it), App/TabBarMinimizeObserver (nothing used it), Kanban `liveCapsuleLift` (unused). The project file's Mac exclusions now list TabPageModifiers in place of the two removed files.

## Settings/MaintenanceViews
RestartRequiredBanner (glass card with heading, Update Hermes and Details buttons, spinner, message, failure text; alert to confirm update) and MaintenanceButtons (Update Hermes unless restartOnly, Restart gateway, phase line, last 12 log lines unless compact; alerts to confirm). Alert wording kept. Identifier banner.update.

## Settings/CronRun (now CronRunState, ScheduledWork)
CronRun state machine: idle, running, started, requested, finished(result), failed; begin only when not busy; answered decides finished/started/requested from the reply; failed handles cancellation, decoding (requested), transport (ask the job; finished or started if it shows), else plain words; settle returns to idle after 3 s unless a newer attempt began. Title, symbol and note per phase. Helpers ranSince, isRunning, result, isGood, plainWords, mayStillBeRunning. ScheduledWork: allows, owner, failureMessage, decode, paused, completed, status, next, date, result, confirms. CronRuns shared store by key.

## Settings/ScheduleViews (now CronView, CronSchedule, CronJobDetailView)
CronView lists jobs (title, status, next, last check), opens details, plus button asks Nollie in chat or (developer mode) opens the new task sheet. CronSchedule parses and describes schedules. ScheduleDraft holds the pickers (once, daily, weekdays, weekends, weekly, monthly, custom) and converts both ways, keeping a one-off's original spelling if the moment is unchanged. Detail view: summary, pause or resume, Run now, edit (name, task, when, developer: delivery and raw JSON), delete with confirm, refresh of the full record on open, follows list refreshes unless JSON was edited. Accessibility ids kept.

# Second pass (app files rewritten again)

## App/AppTab
`AppModel.AppTab` is the set of places the app can be: chats, bots, cron, kanban, settings. Raw string values are the names, identifiable by raw value, all cases listed. `title` gives "Chats", "Bots", "Tasks", "Board" or "Settings". The old symbol and plugin-name accessors had no callers and were removed.

## App/BotTurnReporter
Turn reporting on iPhone and iPad. Nothing shows while a turn runs. When one ends the bot of that chat gets its small finishing spin (`BotAmbient.turnFinished`). The Mac uses the menu bar reporter instead.

## App/Theme
The accent colours the person can choose in Settings, Appearance: blue (default), indigo, teal, green, orange, pink, purple, graphite, each with an id, a name and an RGB colour. `accent(id)` finds one and answers blue for an unknown id. `current` is the saved choice (key `theme.accent`) as a colour. `Color.nollie` is that colour for views that must fill with the accent.

## App/LockScreenView
Covers the app while it is locked: a padlock above "Nollie is locked", the last error from the lock if there is one, and a prominent glass button "Unlock with <Face ID, Touch ID or passcode>". It asks for unlocking as soon as it appears and again on each press. Regular material behind, centred.

## App/CompanionFlow
Decides when to offer the Companion setup. After the first gateway is saved (and the offer was never shown) the offer is owed. When something else is not in the way (the caller says so) and a gateway is saved, it is marked shown, waits 700 ms, looks up the Companion version on the gateway, and shows the prompt. If by then the app is locked or a device pairing is active, it is owed again and unmarked. Buttons: set up (card done, prompt closes, installer opens), allow (card done, prompt closes, asks for notification permission), later (card not done, prompt closes). `isShowing` is either sheet open. Keys `companionPromptShown`, `notificationsSetupCardDone`.

## App/TabLayout
Which tabs the bar holds and in what order, saved as comma-separated raw names. Possible tabs: chats, kanban, settings; chats and settings are required. Unknown names and repeats are dropped; missing required tabs return (chats first, settings last). Parsing nothing gives the default. `visible(hiding:)` leaves out tabs not ready. `set(tab, enabled:)` ignores required and unknown tabs, never exceeds the maximum, and inserts a new tab before settings. `launchTab` is kanban only for the raw value "kanban", otherwise chats. The reorder method had no callers and was removed.

## App/DeviceWords
Wording that depends on the device: device name (iPhone or iPad from the hardware model, or the simulated model on a simulator; Mac on macOS), the settings app's name, tap or click (and capitalised), isMac, a symbol name, and the phrases this/This/your/the/kind built from the device name, plus the Companion's benefits line in two cases. The unused title-case phrase was removed.

## App/Perf
Debug-only timing aids; in release every call is empty. `tick(name)` counts calls per name and logs all counts once a second (only while something was counted). `watchMainThread()` starts, once, a watcher: every 20 ms it notes how long since the last check (a gap over 200 ms means the app was suspended) and keeps one question in flight to the main thread; when the answer comes, the wait less the suspended time is how long the main thread was busy, logged as "main thread busy N ms" at 250 ms or more. `note(line)` logs one line. Log category "perf", subsystem "Nollie".

## App/BotColors
Each bot's colour as "#RRGGBB". Picks are saved as one JSON map under `botColors`. A bot with no (or an empty) pick gets the shared palette's colour for its name. `hex(for:overrides:)`, `defaultHex`, `color(for:overrides:)` (accent colour if the hex is bad), `set(color, for:)` which saves and refreshes the extension copy, `save`, `stored`, `palette`. `Color(hex:)` reads six hex digits with an optional leading "#" and surrounding spaces; anything else is nil. `Color.hexString` gives the sRGB value as "#RRGGBB".

## App/TabPageModifiers
`hidesTabBar()`: while the view shows on a tab other than chats, the tab's hider count in the model goes up by one and comes back down on disappear (never below zero, counted once per appearance). `tabRoot(tab)`: marks the tab as at its root while the view shows and adds an invisible probe that, each time the tab's pop-to-root counter goes up, pops the nearest navigation controller to its root with animation (once per counter value).

## App/Handoff
Offers the chat on screen to the person's other devices and opens one handed over. `fill` writes title and user info (session id, profile, gateway address), marks it eligible for handoff and not for search. `open` ignores an activity with no session id, builds `nollie://chat/<session>?profile=<bot>`, opens it directly when the gateway is missing from the info or is the current one, otherwise switches to the saved gateway with that address first, and does nothing if none matches. `handsOff(chat)` is active only when the chat has a stored id. `continuesHandoff(model)` listens for the activity type.

## App/BotMotionSource
Singleton that feeds the phone's tilt to the bots. Keys: `bots.motion` (on by default), `bots.tilt` (off by default), style key from `CharacterView`. Updates run at 30 Hz only when motion is on, tilt is on, the app is active, the device has motion and reduce motion is off. Otherwise updates stop, the tilt returns to zero and the lean memory resets. Per axis: the first angle counts as level; the level follows the hand at 1% per sample; the offset has a dead zone of 0.09 radians and reaches full lean at 0.7; the result is smoothed at 12% per sample. The enabled setter had no callers and was removed.

## App/BotAvatarView
`BotAvatar`: a bot's picture at a given size: the person's photo in a circle when the choice is photo (and photos are allowed), else the character in its pose. An idle bot hops (done pose) for the done animation's length after a turn finished less than a second ago, and listens for 1.2 seconds after a tap less than a second ago. Hidden from accessibility. `BotLooksMirror.mirror()` writes colours, avatar choices (resolved for every known profile) and photo thumbnails (JPEG, longest side 128, quality 0.75) into the shared keychain copy, also under each profile's label when it differs from its name.

## App/MacAdaptations
Helpers so one page works on phone and Mac. `SettingsList`: phone list with 28 point section spacing and 54 point minimum row height; Mac a grouped form with transparent scroll background, row-style buttons and side margins that centre a 700 point column. `SheetSize` ideal sizes (form 520x600, compact 440x340, wide 720x680). Mac: `SettingsRowButtonStyle` (tint or red text, whole row tappable, dimmed when pressed or disabled), `sheetFrame` (min 85 percent and max 150 percent of the ideal, Escape closes), Refresh toolbar button with command-R that disables while reloading, `untitledPage`, `rowActions` as a context menu. Phone: `sheetFrame` does nothing, inline empty title, trailing swipe actions, pull to refresh. The unused column-width accessor was removed.

## App/CompanionPrompt
The sheet shown once after the first gateway connects. `CompanionScript` picks the words and action: no Companion on the gateway gives the pitch with "Set up notifications" / "Later" and installs; with a Companion, it depends on notification permission: denied asks to open the system settings page; allowed shows "Continue"; otherwise "Allow notifications"; skip is "Not now". The sheet draws the character, title, message, two buttons and a footnote. With permission denied the main button opens the system notification settings and counts as later; otherwise allow runs. `card` stays reachable for snapshots. `installedVersion(on:)` reads the Companion's version from its manifest.

## App/NollieInk
Colours, type, spacing and button styles of the design. Second pass changes only how some pieces are built: dynamic colours turn a hex number into channels through one helper per platform, and the bot search field is split into its glyph, its entry, its clear button and a capsule modifier. Look and behaviour are unchanged.

## App/SiriIntents
Intents for open chat, new chat, bot status and answer approval, and the shortcut phrases. Status reads the gateway (brought up if needed, up to ten seconds for the socket) and says what runs and how many approvals wait. Answering by voice needs the Siri approvals switch; with no gateway, none or several approvals it says so; sign-ins and Ask first requests cannot be approved by voice; otherwise the bot and request are read back for confirmation and the answer is sent. On iPhone, `MacStop.press()` asks the linked Mac to stop through the gateway and stops local replies afterwards.

## App/AppDelegate
iPhone only. Launch: notification centre delegate, categories, mirror of bot looks, a debug permission request flag. Remote registration success and failure go to the push model and the cloud alert transport. A silent push records its receipt. A notification arriving in the app is shown or not by the foreground policy (cloud alerts by event; others by route and test flag); a stop result always shows; plain pushes note arrival and nonce for the setup test. A tap or button: dismiss is ignored; the Stop button stops the Mac with background time and posts the outcome as a note; a cloud alert opens by event id; others route to the chat with the action and any typed reply.

## App/PendingRoute
`PendingRoute` (where a notification or link goes) is unchanged. `ApprovalConfirm`: mode from the saved key, or from the older on/off key, else "risky"; `isOn` unless "off"; `shouldAsk` is false for "off", true for "all", else true when the approval is unknown or risky.

## App/DemoMode
Debug-only demo copy of the app (bundle id ending ".demo"). Reads launch arguments for reach, tailscale state, exit relay, alerts and a one-gateway setup (address, token, name), saved in memory and made active. Release builds only answer "off".

## App/AppModel, AppModel+Links, AppModel+Notifications
Same behaviour. Second pass: system notifications are observed through one small helper; deleting a connection falls back to the next with an early exit; a Bot Chat is looked up by three smaller functions (the gateway's own pointer, the recent list, a title search) with one helper for query items; the notification button handler picks its path with one switch.

## Bots

**BotDetailView**: one bot's page on the phone. Top row opens Bot settings (the bot's face and the words).
Under "Chats", the bot's stored sessions, newest first (100), each opening its chat; a long press offers Delete
with a preview of the chat. A failed read shows the reason in red; an empty list says there are no chats yet.
While the page shows, the tab bar's compose circle starts a new chat with this bot. Delete asks first, closes
the chat if it is open, removes the session on the gateway and reads the list again. `BotChats` holds the list,
the failure and the two gateway calls.

**BotsView**: the Bots tab. Searchable grid of bot cards (two columns on the phone, as many as fit on the Mac),
a plus button for a new bot, a note under the grid, a placeholder when no gateway is chosen. A card opens the
bot's page; the long-press menu offers New chat, Chats, Bot settings and Make active (when not active).
Profiles load when empty and when the gateway changes; scrolling feeds the ambient bot motion. `BotCard` is the
face standing on a glass pill with name, model and an active dot. DEBUG flags show a grid of every look and the
motion demo. The unused `BotRow` list row was deleted (nothing reached it).

**MotionDemoView**: every character state side by side, each on a look in turn. One button holds or releases
the states, another makes everyone do the happy hop for as long as that animation lasts.

## Connect

**NollieTalk**: the guide at the top of guided screens. The bubble types its text out letter by letter
(shorter pause after a space), reserves room for the full text, or shows it at once when motion is reduced.
The guide listens, speaks while typing, thinks while a step runs and hops when its turn key changes. Also holds
the readable green used across setup. `BubblePalette` names the words and backdrop colours (plain, or finished).

**OnboardingTeamStep / OnboardingComputerStep / OnboardingParts**: the assistant-name card (a field that shows
an accent edge while focused, a stronger edge with Increase Contrast) and the Mac computer step (one switch,
then a card showing set-up progress, "getting ready", the computer's state, the Cua buttons, or an
unavailable note). `StepHeading` and `glassCard` are the shared heading and card.

**GatewayFormView**: add or edit a gateway: kind, name, address, optional prefix, sign-in method (token,
password with remember switch, browser), optional Access headers, a connection test with step list, and Save
which needs a passing test. Pure helpers (`saveBlocker`, kind suggestions) keep their signatures. Password
sign-in moved into its own function.

**GatewaySignIn**: lacksCredentials, usesBrowser, pending and the browser sign-in. The sheet walks through the
gateways that need signing in, choosing one route each (pair again, browser, remembered, typed) and offering
the matching buttons; the banner on empty pages points at the same sheet.

**NollieLinkSheet** (Mac): the code for linking a phone, which hides when Nollie locks, the screen locks or the
app goes away; the list of linked phones, each with Remove after a confirmation.

## Conversation

**ConversationComposer**: the message box with a round ink button: Send, or Stop while the bot works and nothing
is typed. **ConversationLive**: chooses the old or new chat screen (DEBUG), the phone header (Back, bot pill with
a word on what it is doing), the Mac toolbar title and the engine wrapper for one open chat.

## Kanban

**BoardLane**: one lane, heading with count, scrolling cards, soft highlight under a dragged card, empty note.
**BoardTaskRow**: title, preview, who has it and a stage chip. **KanbanAsk**: the six questions before a board
change, each with its title, button word, hint, message and whether it is destructive, kept in one table.
**KanbanTaskSheet**: one task in full (facts, warnings, description with an editor, result, children, runs,
comments with a box, history, worker log) with Rename, Edit description and Stop the worker; reads again while
a worker is on the task. `TaskSheetState` holds the reads and writes.

## Security

**RememberedSignIns**: the device-owner check, the errors in plain words, the decision about when a remembered
password may sign a gateway in again (floor of a minute apart and three per ten minutes, never for the
button), and what saving the form does to the remembered sign-in. The copy enum moved to the top of the file.

## Settings

**SettingsPage**: the shared page parts (page, hero, facts, glass rows, switch, choice, notes). API unchanged.
**SettingsView**: grouped category rows, search, crew summary tiles, Done on the Mac. **SettingsHeaderSection**,
**AboutView** (Remove, wordmark, acknowledgements, version and developer mode), **DiagnosticsView** (makes the
file, then Share), **PrivacyView** (lock state, lock switch, ask-again choice), **SiriSettingsView**,
**SummariesSettingsView**, **BotsSettingsView**, **TroubleshootingView** (six symptoms, each a numbered check
list; the checks are kept one per line), **CronRunState** (the Run now button state and its reading of the
gateway's job records). New helper: `PageAction.swift` (the one big page action).

