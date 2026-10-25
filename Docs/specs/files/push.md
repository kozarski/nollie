# Push area: behaviour specs

## hermes_push.py (the push companion)

One script, run next to a Hermes install, either as a user service (install.sh) or inside Hermes as a
plugin thread (plugin/nollie-push/__init__.py). It is a client of the gateway's `/api/ws`, watches live
sessions and sends notifications to the devices the apps registered. Source of truth is
`Companions/hermes-push/`; the app bundles a byte-identical copy (checked by a unit test), and uploads it
to `<HERMES_HOME>/push/` and `<HERMES_HOME>/plugins/nollie-push/`.

Config: `KEY=VALUE` lines (optional `export `, quotes stripped, `#` comments) in the file named by
`HERMES_PUSH_CONFIG`, else `<HERMES_HOME>/push/hermes-push.conf`. Real environment variables win over the file.
Keys: GATEWAY_URL, PUBLIC_URL, GATEWAY_TOKEN, GATEWAY_BEARER, GATEWAY_REFRESH_TOKEN,
CF_ACCESS_CLIENT_ID/SECRET, APNS_KEY_FILE/KEY_ID/TEAM_ID/TOPIC/SANDBOX, DEVICES_DIR, POLL_SECONDS,
RELEASE_IDLE_SECONDS, FINISH_EXPAND, FINISH_ISLAND, FINISH_LINGER. A rotated bearer or refresh token is
written back into the file.

Public names other code relies on: `VERSION` (must equal plugin.yaml's version), `SCRIPT_SHA256`,
`_load_conf()`, `_CONF`, `status_path()`, `CodeChanged`, `Relay` (with `run()`), `Gateway`, `APNs`,
`load_devices`, `is_silent_*`. The tests build a `Relay` without `__init__`, so every attribute the finish
and bot-chat paths touch has a class-level default.

Delivery:
- Device files `<push>/devices/*.json` (platform ios/macos/watchos, apns_token, registered_at, bundle_id,
  apns_environment, relay {url, install_id, secret}, payload_key (base64 AES-256 key), live activity
  fields, mute_desktop_origin, bots). One device per (platform, token); newest registration wins.
- Relay mode: POST `<relay>/v1/push` with install id and secret. Alerts are AES-GCM encrypted for the device
  (nonce+ciphertext, base64). Kinds: alert, sound, liveactivity (generic words only, no private text).
- Direct mode: HTTP/2 to APNs through curl with an ES256 token (refreshed every 45 minutes), sandbox host
  when the device says development or the sandbox flag is set, topic follows the device bundle id.
- `last_response` keeps what the far side answered; `dry_run` logs instead of sending.

Notifications (kinds): approval (time-sensitive), clarify (also sudo, secret, vault prompts), turn (finished),
cron (scheduled run or Bot Chat cron delivery), error, settled (quiet replacement of an old banner), test.
Payload is trimmed under about 2.3 KB (thread lines first, then text). Category by kind. Watches get no direct
push; a phone that muted desktop origin skips non-quiet pushes for chats last driven from a Mac (marker files
in `<push>/origins`, valid 12 hours). Origin, goal (`goals`, 8 hours) and answer (`answers`, 1 hour) markers
are pruned at most hourly.

Session tracking: poll every few seconds: profiles.list (labels, Bot Chats), a session-to-profile map from
the all-profiles list (rebuilt each minute, fallbacks per profile, then a probe), session.active_list.
New live sessions are mirrored with session.resume (never activate), pending approvals picked up.
Events: phase events drive Live Activity phases (thinking, streaming, tool; one push per change), usage events
(at most one push per 3 s), message.complete finishes the turn, request.cancel settles, session.title,
sessions.changed triggers a Bot Chat check, session.reclaimed drops tracking.

Finish: end the Live Activity ("done"/"error") then push the reply. Same reply for the same session within
60 s is not pushed twice. Silent results: `[SILENT]` or `NO_REPLY` alone (trimmed) on an automated
(cron) turn, or an explicit `intentional_silence` flag on a successful complete turn, finish the activity,
record the time and push nothing; errors and non-complete statuses are never silent. A human-typed literal
marker still notifies. Reply thread (up to 3 earlier messages, 200 chars each) is fetched with a short cap.

Bot Chat fallback: when a profile's Bot Chat message count grows, read the last 6 messages
(`/api/sessions/<id>/messages?order=latest&limit=6&profile=<p>`), find the newest user message, take only an
assistant reply after it, require the user text to start with `[Cronjob "`, skip tool-call replies, skip
typed silence (hidden row with control marker intentional_silence, or marker text) and remember it, otherwise push
kind cron titled "<bot> · <job>". Recorded per (chat id, count); not within 20 s of a turn push.

Live Activities: targets come from the device's `live_activities` list (or the single legacy fields), skipping
entries older than 8 hours or filed for another session. Update pushes carry phase, detail, usage, goal;
finish does an update (optionally with an expanding alert) then a delayed end with a dismissal date.
Push-to-start for a closed app, once per turn per 10 minutes. A reaper ends activities whose turn is over only
when the live list was read this poll and the session stayed idle for 45 s. Approvals announced are tracked and
settled (activity returns to work, banners replaced quietly except on the answering device) once the gateway
stops listing them across two polls, or on cancel/turn end.

Heartbeat `<push>/status.json`: version, script_sha256, pid, updated_at, profile, connected, gateway, transport,
attached, devices, error, last_test_*, last_la_*. A `test-request.json` dropped there is answered with one real
test push to all devices and the nonce is recorded. The loop reloads on config change, reconnects with backoff
(max 30 s), releases mirrored sessions after 10 idle minutes, and raises `CodeChanged` when the file on disk
differs from the running code (the host reloads or re-executes).

CLI: `--list`, `--test`, `--dry-run`, `-v`. Tests: `Companions/hermes-push/tests/test_silent_results.py`,
`PushCompanionBundleTests` in `Tests/Unit/HermesRemoteTests.swift`.

## install.sh
Installs/removes the user service. Reads `hermes-push.conf` beside itself; finds the Hermes venv python;
Linux: systemd user unit `hermes-push`; macOS: launch agent `com.coreykozarski.nollie.push`; then runs `--test`.
`--uninstall` stops the service, kills the script, deletes the plugin folder and the push folder.

## plugin/nollie-push/__init__.py
Hermes plugin entry `register(ctx)`: starts a daemon thread that takes a file lock (`relay.lock`, waits if
another Hermes process holds it) and runs `Relay().run()`; reloads the module on `CodeChanged`; stops on unload.


## Swift: Apps/Nollie/Push

### PushRegistrar.swift
Registers this device for notifications. Public: `NotificationAuthorizationClient` (status, request, register; `.system`),
`PushRegistrar` (observable: deviceToken, authorization, lastRegistrationPath, lastError, registeredAt, registrationFailure,
relayRegisteredAt, relayError, relayNeedsInvitation; installID kept in the Keychain with a one-time carry-over from
UserDefaults; `refreshAuthorization` and `requestAuthorization` coalesce concurrent callers and ask the system for a token
once permission allows; `didRegister(token:)`, `didFailToRegister`, `registerWithRelay`, `refreshRelayIfStale` (daily),
`syncRegistration(runtime:)` writes `<home>/push/devices/<install id>.json`, `removeRegistration`, `noteSend` (origin marker,
at most one a minute per chat), `noteAnswer`), `Notification.Name.hermesPushRegistrationNeedsSync`.
Covered by `PushAuthorizationTests`.

### LocalNotifier.swift
`LocalCardNotifier` (adapter for the core) and `LocalNotifier`: category and action names, `registerCategories`,
`clearDelivered`, `cardSettled`, `cardArrived`, `turnFinished` (only when the app is not in front and the companion does not
deliver), `userInfo` for routing, `showsPreview`. Without a preview the banner reads as a generic update.

### AwayWatch.swift (iPhone)
`left(runtime:)` holds background time while a turn runs; `returned(runtime:)` marks chats that end in the gateway's
"Operation interrupted" as stopped because the app was away (absence over 10 s, checked for 45 s). `endsInterrupted`.

### PushLog.swift
`PushLog.note` and `PushLog.lines`: the last twelve lines, thread-safe, also written to the system log.

### Companion setup (PushSetupModel and views)
`PushSetupModel` holds everything known about the companion on the gateway: the heartbeat read from `push/status.json`,
the installed plugin version and whether its script matches this build, the companion's own sign-in
(`CompanionSignInState`, saved per connection), install, restart, update and test progress. Extensions: install and uninstall
(back up six files first, write the push folder and the plugin, enable it, restart countdown), restart wait, update
(in place when the running companion can reload itself, else with a restart), and the test notification (drops
`test-request.json`, waits up to three minutes for the nonce to arrive). `CompanionBundle` reads the files this build ships.
Views: `PushSetupView` (six cards, a later one opening only when earlier ones are done), `CompanionView` (Settings,
Advanced, Companion), `CompanionStatusRows`, `CompanionUpdateRows`, `RestartCountdownRows`, `CompanionSignInSheet`,
`CompanionDiagnosticsView`. Covered by `CompanionSignInRecoveryTests` and `PushCompanionBundleTests`.
The relay path (`PushRelay.isConfigured`) is switched off in this build, so the own-APNs-key card is what people see; both
paths are kept because the relay type still exists in the core.

## Extensions and shared
- `NotificationService`: opens the encrypted payload or fetches a private iCloud preview, then shows the alert as a message from
  the bot (sender name and picture). Keeps the last note under Keychain account `push.nse.last`. Never shows details for a
  private bot or when the preview policy forbids it.
- `NotificationViewController`: the long-press reply card (avatar, bot, chat, time, bubble).
- The four plist and entitlements files keep the same keys and values.
- `Shared/CharacterAmbient.swift` (`BotAmbient`): shared gaze, tilt and flourish state for bots on screen; `Color(botHex:)`.
- `Shared/StopMac.swift`: `MacStopWords` and the Stop intent (a Live Activity intent, run in the app).

# Second pass (push setup files rewritten again)

## AwayWatch.swift (iPhone only)
`AwayWatch.shared.left(runtime:)` is called when the app goes off screen. It remembers which stored chats were
running and when the app left. If any were running it asks the system for extra background time, held until the
turns stop (polled once a second) or ten minutes pass or the system takes it back. The wait lives on a global
queue, so the system can always be answered. Only one hold at a time. `returned(runtime:)` gives the time back,
and if the absence lasted at least ten seconds it looks at those chats twice a second for up to 45 seconds while
they reload. A chat that has stopped running and is not resuming is checked once: if its newest spoken line
(assistant or user) is the assistant's interruption marker and it has no cause yet, it is marked as stopped
because the app was away. Chats that vanish are dropped. `endsInterrupted(_:)` is the pure check on a transcript.
Used by `NollieApp` (scene phase changes).

## CompanionSignInSheet.swift
A sheet that signs the companion in with credentials of its own, shown from the setup. With a password-mode
connection it shows username and password fields (filled by the Passwords app) and a Sign in button, enabled when
both are filled. Otherwise one button opens the gateway's own sign-in in the browser. The provider is the one this
device signed in with, else the connection's, else the first one the gateway offers that takes a password, else
"basic". While working the button says so; failures show under the form; success clears the password, hands the
secrets up and closes. Cancel is in the corner. `ProvisioningProfile.teamID` reads the Team ID from the embedded
profile (device and store builds), nil in the simulator.

## PushRegistrar.swift
Unchanged behaviour (see push.md). The authorization request asks for alert, sound, badge and time sensitive; the
platform name and device name are looked up the same way as before. Covered by `PushAuthorizationTests`.

## LocalNotifier.swift
Same API and behaviour as push.md. Cards and finished turns raise one `Event` through `announce(_:in:)`: a card
buzzes when the app is in front, and posts a time-sensitive banner when it is not and the companion does not
deliver. The banner words come from one small `Banner` type built from the event (approval, question, value
prompt, failed turn, finished turn with the last reply cut to 180 characters). `userInfo` is unchanged (its
`card` argument now defaults to nil). `takeDown` removes a settled card's pending and delivered banners.

## PushSetupModel.swift (+Install, +Restart, +Update, +Test)
State and rules as in push.md. Changes in shape only: the update progress lives in one `UpdateRun` value with
forwarding properties (`updating`, `updateStage`, ...); the heartbeat decodes by hand from the companion's
snake-case keys (the unread `attached` count is gone); "why Install cannot run" is an ordered list of reasons, the
first that holds wins; the companion config is built from a list of key and value pairs; files to upload are
`Parcel`s; the uninstall chat prompt and route are their own function; the restart countdown calls
`restartWhenDue`; the notification scan returns a small `Delivered` value.

## Companion views
- `CompanionSetupParts.swift`: shared building blocks (`Tone`, `note`, `StatusNote`, `SpinnerLabel`, `BusyButton`,
  `FormCard`, `ActionRow`, `StepPage` with its floating `StepMast`, `PeekableValue`, `InstalledFilesWindow`,
  `darkWell`).
- `CompanionView.swift`: the Settings, Advanced, Companion page (setup link, Software Update with a badge, status
  checks, this device's facts, uninstall, diagnostics), the uninstall alert and the page's refresh.
- `CompanionStatusViews.swift`: `CompanionStatusChecks` (two marks) and `CompanionStatusRows` (installed, running,
  warnings, update rows or reinstall, check now).
- `CompanionDiagnosticsView.swift`: last notification note and the last six push log lines.
- `CompanionUpdateRows.swift`: update card (badge, bar, console, Install Now) and `RestartCountdownRows`
  (waiting, countdown, reminder).
- `PushSetupView.swift`, `PushSetupView+Steps.swift`, `PushSetupScript.swift`, `PushSetupFooter.swift`: the six-card
  setup. Script holds the step list, when each is done and what the bot says; Footer holds Continue/Done, Exit or
  Cancel and the back button.
Covered by `CompanionSignInRecoveryTests` and `PushCompanionBundleTests`.


## Companion script, second pass
`hermes_push.py` keeps every public name and behaviour. The relay's reads and sends were reshaped (heartbeat written from a base record, error text built in one place, approvals and asks announced from a small details record, the run loop checks time differently) and `install.sh` runs "may not exist yet" commands through one quiet helper and writes the service unit from a here-document. The app's bundled copy is synced by `Tools/sync-push-companion.sh`.

## Notification extensions, second pass
`NotificationService`: one helper reads a field from the "hermes" block of the user info; the sender look (name, handle, picture) is worked out apart from building and donating the message intent; a test notification still gets Nollie's own look and no Reply action. `NotificationViewController`: the reply card is a header (avatar, names, time stamp) over the bubble, with the names and the time stamp as two small views; the card model reads the profile as before and falls back to "Hermes" when no title or profile is given.
