# Permissions

[← Nollie](../README.md) · [Architecture](architecture.md) · [Contributing](contributing.md)

Every system prompt Nollie can cause, why it exists, when it appears and what happens if the answer
is no. The rule: **a prompt appears only after a person pressed something that says why**, and
nothing is asked on its own at launch.

The code is in `Apps/Nollie/Permissions/`:

| File | What it holds |
| :--- | :--- |
| `PermissionCenter.swift` | The kinds, their one-line reasons, the states, and the center that reads and asks |
| `PermissionClients.swift` | The real system calls for each kind (and the made-up answers for demo pictures) |
| `LocalNetworkAccess.swift` | Local Network, the one permission the system will not let an app read |
| `PermissionRow.swift` | The one row style used by setup, Settings and the Mac switch |
| `PermissionsSettingsView.swift` | Settings › Privacy › Permissions |

`PermissionCenter.refresh()` only reads and never prompts. `PermissionCenter.ask(_:)` is the only
way to prompt, runs from an Allow button, skips anything already answered, and shows at most one
prompt for a kind at a time.

## Inventory

| Permission | Why Nollie needs it | Where and when it is asked | If declined |
| :--- | :--- | :--- | :--- |
| **Notifications** (iPhone, iPad, Mac) | Replies, approvals and finished work. A yes also registers the device for push. | Mac setup, step "Allow a few things" (Allow button). iPhone setup, the Ready step right after connecting (Allow button). Also from Settings › Notifications, Settings › Privacy › Permissions, the iCloud alerts switch and the companion offer sheet. Always from a button. | Nothing arrives while Nollie is closed. Chats still work. Settings shows "Open Settings". |
| **Local Network** (iPhone, iPad, Mac download) | Finding and reaching the Mac over Wi-Fi (Bonjour `_nollie._tcp`, the Mac's door) and a Hermes dashboard on the home network. | Mac setup, same step (Allow button). iPhone: on the link or pairing confirmation, with a line saying the phone will ask; the system prompt appears when Link or Connect is pressed. Settings › Privacy › Permissions. | The phone cannot find the Mac at home. The link screen says so and offers Open Settings. A Mac reached over Tailscale still works. |
| **Camera** (iPhone, iPad) | Reading the pairing code on the Mac, and taking a photo for a chat. | Scanner: a line says why and an "Allow camera" button asks, so opening the scanner shows nothing by itself. Photo for a chat: the system prompt appears when Camera is chosen in the attach menu. | The scanner shows Open Settings and "Connect manually" stays. Photos can still be picked from the library. |
| **Microphone** (iPhone, iPad, Mac) | Talk mode, dictation and voice memos. | Talk: the first press of the composer's Talk button opens a sheet with the bot, one line on why ("I listen while you talk. Your voice stays on this iPhone, and only your words are sent.") and Allow microphone, which shows the system prompt (`VoicePermissionSheet`). Dictation and memos: the first press of the mic button (`MicCapture.start`). Settings › Privacy › Permissions. | The Talk sheet says the mic is off and offers Open Settings. The mic button says access was denied. Typing, the play button and Read replies aloud still work. |
| **Speech recognition** | Talk mode and dictation are turned into words on the device with the system's `SpeechAnalyzer` (`DeviceTranscriber`), which has no permission of its own. The first use in a language may fetch Apple's speech model. `NSSpeechRecognitionUsageDescription` is kept for older paths. | Never prompts today. | n/a |
| **Speaking replies** | Read replies aloud, the play button on a reply, and talk mode use the system's on-device voices (`AVSpeechSynthesizer`). | No permission. | n/a |
| **Photos, add only** (iPhone, iPad) | Save to Photos from the picture viewer and video cards. | The first Save to Photos tap. Settings › Privacy › Permissions. | The viewer explains and offers Open Settings (`PhotoSaveFailure`). Share and copy still work. |
| **Downloads folder** (Mac) | Save to Downloads from the picture viewer. | The first Save to Downloads click (macOS asks about the folder). | The viewer says it was not saved. |
| **Face ID / Touch ID / passcode** | App lock, approving from a notification, saved sign-ins and remembered sign-ins. | When the lock switch is turned on, on the first saved sign-in use, or on a locked reply. Never at launch unless the lock is on. | The lock falls back to the passcode. Saved sign-ins need the device owner. |
| **Live Activities** (iPhone) | The Lock Screen card and Stop while a helper uses the Mac. | iOS asks the first time a card is started, which is when a Mac task begins. There is no app prompt. Settings › Privacy › Permissions shows the switch. | No Lock Screen card. Stop in the app and in notifications still works. |
| **Siri and Shortcuts** | New chat, open a chat, what is my bot doing, Stop. | App Intents have no prompt. Settings › Siri & Shortcuts. | n/a |
| **Accessibility** (Mac download) | Letting a bot click and type in the apps the person approves (Nollie Computer). | Turning on Nollie Computer in the bot's Computer page opens the Mac permissions window, which has the Allow rows. Also when a task starts without it. Never in setup. | A bot cannot use the Mac. The task fails with a plain message and the window opens again. |
| **Screen Recording** (Mac download) | Letting a bot see those apps; the live picture of a helper's computer. | Same window as Accessibility. The Watch picture checks first (`CGPreflightScreenCaptureAccess`) and never prompts. | Same as Accessibility. Watch shows no picture. macOS may ask to reopen Nollie. |
| **Background items** (Mac download) | Nollie Runtime (`SMAppService.agent`) keeps the assistant and the iPhone door running. The alert helper (`SMAppService.loginItem`) checks for finished work while Nollie is closed. | Finishing Mac setup registers the runtime; the "Check while closed" switch registers the helper. macOS shows a "Background items added" banner, and a Login Items approval if it needs one. | The page says it needs approval and opens Login Items (`openApprovalSettings`). |
| **Keychain / iCloud** | Gateway secrets, device credentials and iCloud alerts. | Keychain access is silent. iCloud alerts ask only after the person turns them on. | iCloud alerts stay off. |

Things that look like permissions but are not: the Photos picker (`PhotosPicker`) and file
importer run out of process and need no permission. Picking a folder to import on the Mac is the
person's own choice in the open panel.

## Where each one is asked, in order

- **Mac setup** (`OnboardingView`, step `.permissions`): Notifications and Local Network, each a row
  with a one-line reason and an Allow button, a tick once on, and "Not now" at the foot. Accessibility
  and Screen Recording are not here.
- **iPhone setup**: nothing until the phone is connected. The Ready step then shows the Notifications
  row. The camera is asked in the scanner and Local Network on the link screen.
- **Using the Mac** (Mac download): the Nollie Computer switch opens the walkthrough
  (`ComputerPermissionsView`), which uses the same row.
- **Settings › Privacy › Permissions**: every row for this device, its state, and Open Settings when
  declined.

## Nothing asked at launch

Audited start paths:

- `AppDelegate.didFinishLaunching` (iPhone) sets the notification delegate and registers categories.
  The only request is behind the debug launch flag `-nollie-request-notifications`.
- `MacAppDelegate.applicationDidFinishLaunching` does the same, then starts the services: Continuity
  menu filter, sleep and wake, saved sign-ins, and (download version) the computer broker, Stop
  watcher and live picture relay. None touches a protected resource: the live picture checks Screen
  Recording with a read-only call before it captures.
- `PushRegistrar.refreshAuthorization()` runs at launch and on coming to the front. It reads the
  status and registers for a push token only when notifications are already allowed.
- Bonjour browsing (`NollieLinkClient.discover`) runs only when a linked Mac is saved, which only
  the link screen creates, after the question above. A new install has no saved Mac.
- Local Network is not read at all until the person has pressed Allow once. After that a short quiet
  look is used (the answer is already given, so it shows no prompt).
- Face ID appears at launch only when the person turned the app lock on.

## Voice stays on the device

Talk mode records to a temporary file, reads it with on-device speech recognition and deletes it;
only the words go to the bot, as a typed message would. Replies are spoken by the system's voices on
the device. Nothing new leaves it, so voice adds nothing to Papertrail. Hermes has its own voice
routes (`/api/audio/transcribe`, `/api/audio/speak`) that can use cloud providers; Nollie does not use them.
While a card is up talk mode shuts the mic and sends nothing: approvals are answered with a tap,
never by voice (`TalkLoop`, `TalkRules`).

## Local Network on the Mac

macOS and iOS give no call to read Local Network. `LocalNetworkAccess` asks by using the network
for a moment (a Bonjour browse and a throwaway service) and watches what the system does: a browse
that waits with a policy error is a no, a service that publishes is a yes. The answer is written down
so Settings can show it. Before the first Allow it is "not asked" and the network is untouched.

On the Mac the question is asked as Nollie itself. The door that the iPhone connects to is run by
Nollie Runtime, a separate helper, and macOS may keep its own record for that helper. If a
second Local Network question for Nollie Runtime ever shows up when the first iPhone links,
answer Allow. Check this with a real iPhone on the same Wi-Fi.

## Adding a permission

1. Add a case to `PermissionKind` with a title, one plain reason (no em dashes) and a symbol.
2. Add its client in `PermissionClients.swift`: `read` must never prompt; `request` is the prompt.
3. Add it to `PermissionKind.listed(isMac:direct:)` so Settings shows it, and to a setup list only
   if it is needed before first use.
4. Put the Info.plist usage string in the right target, and a line in the table above.
5. Ask from a button that says why. Never from `onAppear`, `init` or a launch path.
