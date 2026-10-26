# Setting up Nollie

[← Nollie](../README.md)

The normal path starts on the Mac, then connects the phone.
These are development instructions; a complete fresh-install experience is still being validated.

## Choose how to start

| Option | What happens | What stays untouched |
| :--- | :--- | :--- |
| Start new | The Direct Mac edition prepares a separate home under Application Support/Nollie/Setups | Existing Hermes installations |
| Connect existing | Nollie signs in to the gateway you choose | Its profiles, models, chats, schedules, Board and permissions |
| Import a configuration copy | Preview selected root files, verify a backup, then copy instructions into a new home with Nollie's starter settings | The original installation and its data |

Import is not a complete migration. Original configuration is archived inactive for review.
Profiles, separate credential files, chats, schedules, Board and computer permissions are not copied.
Configuration files can contain sensitive settings, so backups belong in a private folder you choose.

Nollie's managed runtime is available only in the Direct Mac edition.
One "Getting Nollie ready" step downloads and checks everything: about 180 MB, usually two to five minutes.
It installs fixed, tested versions of uv, Python and Hermes Agent, Hermes's own locked libraries, Nollie's reviewed
changes to Hermes and Nollie's add-ons (Board follow-through with Papertrail and the Night shift, the crew, the page
reader and computer previews). "What's installed" names each one. A newer Nollie brings newer add-ons into the setup
by itself; Hermes loads them the next time the background service starts.
Starting its background service is an explicit action. The Mac must remain awake and online for work to continue:
Settings › Keep awake holds it awake for the crew while helpers work and, plugged in, until the night's schedules
have run. When it slept anyway, the morning's Night shift card says so.

## Choose where it thinks

- **On your Mac:** use a local model, with a download appropriate to the computer.
- **Online:** connect a supported provider account or API.
- **Both:** choose a mix that suits the work.

**If my plan runs out** is off until chosen. It sets a second model (one downloaded to the assistant's computer, or
another plan or key the assistant is signed in to) as the first entry of the bot's Hermes `fallback_providers`. When
the main model hits a limit or stops answering, Hermes moves to it and the chat says so in one line; Hermes moves back
by itself on the first message after the time it gives (or the next message), and the chat says that too. Papertrail
lists each reply under the route that answered it. Turning it off empties the list.

This preference does not silently rewrite imported routing.
A model being selected is different from a successful reply, and a successful reply is different from reliable tool use.
Local web tools still contact the internet. Online providers receive the context sent to them and may charge for usage.

The managed local-model flow includes download progress and a separate reply check.
Fresh model download and inference still need real acceptance testing; provider sign-in also remains a release gate.

## Connect an existing gateway

Use its dashboard base address, such as `https://hermes.example.com`, including any reverse-proxy prefix.
Do not enter a model's `/v1` endpoint or an SSH address.

Nollie supports a session token, supported username/password sign-in, or browser sign-in where the gateway offers it.
Optional Cloudflare Access headers are in the technical connection settings.
Use the app's sign-in controls; do not put credentials into repository files or screenshots.

A saved connection must pass dashboard, credential and WebSocket readiness checks.
An HTTP response alone does not prove the chat connection works.
See [the protocol notes](architecture.md#gateway-contract) when diagnosing a connection.

## Connect the phone

The Mac creates a short-lived, single-use invitation. The phone scans it, confirms the destination and receives
its own credentials. Closing or locking the pairing flow cancels unfinished work.

Current pairing requires a phone-reachable HTTPS address, owner authentication and the pairing companion.
A fresh managed runtime is loopback-only. Automatic secure transport and physical QR enrollment remain unfinished
acceptance work; a QR preview is not proof of a usable phone connection.

## Notifications and access

iCloud alerts are an optional choice. Settings stay on each device.
The Direct Mac notification helper can check for results while the main app is closed.
It needs consent, a reachable assistant, iCloud, notification permission, and an awake Mac.

Message previews can be hidden on each device; App Lock overrides them.
Alert records may contain bounded preview text and a chat location, retained for up to seven days.
Turning previews off hides notification content on that device; it is not a promise that no preview data is stored.

Computer access is a separate permission. Pausing a preview only pauses pictures.
Stopping Mac control waits for a confirmed lease change and does not claim to cancel every in-flight action or VM task.
