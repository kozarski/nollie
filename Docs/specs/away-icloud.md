# Away from home through iCloud

[← Architecture](../architecture.md) · [Nollie Link](../nollie-link.md) · [Papertrail](papertrail.md)

Status: written before the code (26 Oct 2026, Nollie 1.2 "In your pocket"). The build follows this file; where
they differ, the code is wrong or this file says why.

## Purpose

Today a linked iPhone reaches its Mac only on the same Wi-Fi (Nollie Link) or through Tailscale. People who are
not technical will not install a VPN. Away from home, through iCloud, lets a linked iPhone or iPad keep using
Nollie anywhere with nothing to set up beyond what they already have: both devices signed in to the same Apple
Account, and the phone linked to the Mac once at home.

What works away through iCloud:

| Works | How |
| :--- | :--- |
| Chat | Send a message to a helper's chat. The reply comes back when the turn ends. |
| Approve | The helper's approval cards for that turn come to the phone. Allow once or Deny, within ten minutes. |
| Stop | The same Stop as the Lock Screen and Siri: ends the task, stops replies, pauses schedules. |
| Status | Which helpers are working and which wait for you. |

What stays at home (or with Tailscale, the Advanced path): attachments and files, the live picture and Take over,
the Board, schedules, bot settings, memory, slash commands, and anything else the Link door already keeps on the
Mac. The phone shows the away card for those, as it does today.

No servers of ours. The person's own iCloud private database is the mailbox. Everything that matters is sealed
between the two paired devices before it reaches iCloud.

## Behaviour in plain words

1. The person links the phone at home as today. In the same visit the phone and the Mac swap a second pair of
   public keys over the pinned Link connection. A phone that was linked before 1.2 does this the next time it
   reaches the Mac at home.
2. Away from home, Nollie on the phone notices the Mac is out of reach. If iCloud is on and the keys are there,
   the composer, approvals and Stop keep working. The bots list says "Away · through iCloud".
3. Sending writes one sealed record to the person's private iCloud database, addressed to the Mac. iCloud wakes
   the Mac app with a push. The Mac opens the record, checks it, says "received", then sends the message into the
   chat with its own Hermes, exactly as if it had been typed on the Mac.
4. If the turn needs an approval, the Mac sends the card to that phone, sealed, with a ten-minute life. The
   phone shows it as it shows any approval card, and asks for Face ID first where the Mac would ask. The answer
   goes back the same way. After ten minutes the phone's answer is refused and the card stays on the Mac.
5. When the turn ends, the Mac sends the reply. The phone shows it in the chat. When the phone is back home the
   chat reloads from Hermes, which already holds the same messages.
6. Stop writes one sealed record. The Mac acts on it as it does on a Stop from the Lock Screen at home.

The Mac answers while Nollie is open on it (it keeps running in the menu bar) and the Mac is awake. A sleeping
or switched-off Mac answers nothing; messages wait up to fifteen minutes and then the phone says they did not
reach the Mac. The Mac writes a "last seen" time every five minutes so the phone can say "Your Mac is asleep"
straight away instead of waiting.

## The setting, and when it is on by default

Phone: Settings › Away from home, one switch "Use iCloud away from home". Mac: the same page, one switch
"Answer through iCloud".

The switch is on by default only when all of these are true; otherwise it reads off and cannot be turned on until
they are:

- This phone is linked to the Mac (Nollie Link, Direct Mac edition) and the two have swapped away keys.
- iCloud is signed in on this device and CloudKit says the account is available.
- The record type exists in iCloud (the first write succeeded, or the schema is deployed).

A person who turns it off keeps it off. Turning it off on the phone deletes this phone's records and
subscriptions; on the Mac it removes the Mac's subscription and stops answering. Removing a phone on the Mac
forgets its key at once: records from it are ignored.

## Pieces

| Piece | Where | Owns |
| :--- | :--- | :--- |
| Sealing | `Packages/NollieCore/Sources/NollieCore/Away/AwaySeal.swift` | Keys, the shared channel, sealing and opening, tags |
| Wire | `.../Away/AwayWire.swift` | The envelope header and the sealed notes, strict decoding |
| Rules | `.../Away/AwayRules.swift` | The allowlist, limits, expiry and approval choices |
| Mailbox | `.../Away/AwayMailbox.swift` | `AwayCloud` (the storage boundary), `AwayDesk` (Mac side), `AwayCourier` (phone side), the seen list |
| Phone key swap | `.../Runtime/GatewayRuntime+Away.swift` | `swapAwayKeys()` after each find at home; `LinkedMac.awayKey` |
| CloudKit | `Apps/Nollie/Away/CloudKitAwayCloud.swift` | The private database zone, record type, subscriptions, presence |
| Mac bridge | `Apps/Mac/AwayMacBridge.swift` | Turns notes into chat sends, card answers, Stop and status on the Mac's own Hermes; Papertrail lines |
| Phone | `Apps/Nollie/Away/AwayPhone.swift` | Carries the composer, approvals and Stop while away; shows replies |
| Key swap | `Services/Runtime/LinkDoor*.swift`, `RuntimeIPC.swift` | `POST /nollie/link/seal` and the device's away key |
| Screen | `Apps/Nollie/Settings/AwayFromHomeView.swift` | BLUF hero, the iCloud switch, Tailscale under Advanced |

## Keys and pairing

- The Mac app makes one X25519 key pair (CryptoKit `Curve25519.KeyAgreement`) and keeps the private key in its
  Keychain. It gives the public key to Nollie Runtime over the signed XPC connection; the helper keeps it in
  `link.json` beside the devices. Only public keys cross XPC.
- Each phone makes its own X25519 key pair per linked Mac and keeps the private key in its Keychain.
- `POST /nollie/link/seal` on the Link door, with the device credential, over the pinned TLS 1.3 connection:
  body `{"key": "<base64url 32 bytes>"}`, answer `{"key": "<the Mac's public key>"}`. The door stores the
  phone's key on its device entry. It answers 503 when the Mac app has not given its key yet. The pin and the
  credential make this exchange as trustworthy as the link itself: nobody who can only see iCloud can join it.
- Both sides compute `shared = X25519(own private, other public)` and derive, with HKDF-SHA256 (salt
  `nollie-away-v1`, info the Mac's public key then the phone's), a 32-byte root; from it one key for each
  direction (`to-mac`, `to-phone`), so a record can never be reflected back to its sender.
- Tags: `mac = hex(SHA-256("nollie-away-mac" ‖ macPublic))[0..<32]`, the same for the phone. They address
  records and say nothing about the person.
- Linking again or removing a phone replaces or forgets the keys. There is no forward secrecy across a key's
  life: someone who later steals a device's private key and has kept old records could open them. Records live at
  most a day, which bounds this.

## Records

One custom zone, `NollieAwayV1`, in the private database of the container `iCloud.com.coreykozarski.nollie`.

`NollieAwayNoteV1`, one record per message:

| Field | Kind | Seen by Apple | Purpose |
| :--- | :--- | :--- | :--- |
| record name | `aw1_` + 64 hex, random | yes | Identity, bound into the seal |
| `v` | Int64, 1 | yes | Version |
| `fromTag`, `toTag` | String, 32 hex tags, queryable | yes | Addressing and subscriptions |
| `expiresAt` | Timestamp, queryable | yes | Clean-up, and the receiver's first expiry check |
| `alert` | Int64 0 or 1, queryable | yes | Whether the phone gets a visible notification |
| `box` | Bytes in `encryptedValues` | no | The sealed note |

The box is ChaChaPoly (CryptoKit) with a random nonce, and authenticates the header: `nollie-away-v1`, the
record name, both tags, `expiresAt` (whole seconds) and `alert`. A record whose header was changed does not
open. Inside, the note is JSON: `{"v":1,"id","at","kind",...}`, at most 64 KiB.

`NollieAwayPresenceV1`, one record per Mac, named `ap1_<mac tag>`: `seenAt` only, rewritten every five minutes
while the Mac answers.

Subscriptions (`CKQuerySubscription`, record creation only):

| Id | Who | Predicate | Push |
| :--- | :--- | :--- | :--- |
| `nollie-away-mac-v1` | Mac | `toTag == <mac tag>` | Silent (content-available) |
| `nollie-away-phone-v1` | Phone | `toTag == <phone tag> AND alert == 0` | Silent |
| `nollie-away-phone-alert-v1` | Phone | `toTag == <phone tag> AND alert == 1` | Visible, fixed words: "Nollie has something for you." |

The visible push never carries anything from the record. Each side deletes the records it has read; each side
deletes its own records once they expire, and on Remove Nollie or when the switch goes off.

## Notes

Phone to Mac, and only these (the allowlist):

| Kind | Fields | Life | Mac does |
| :--- | :--- | :--- | :--- |
| `send` | `bot`, `chat` (optional), `text` | 15 min | Opens the chat (or a new one) for that bot and sends the text as typed |
| `answer` | `card`, `choice` (`once` or `deny`) | the card's | Answers that one card, once |
| `stop` | none | 10 min | The Lock Screen Stop |
| `status` | none | 2 min | Answers with helpers' status |

Mac to phone: `received` (picked up), `reply`, `card`, `closed` (a card went: answered, answered on the Mac,
withdrawn, expired), `stopped` (with the number of schedules paused), `helpers` (the answer to `status`) and
`refused` (with a fixed reason code). Replies live a day; everything else at most an hour.

Refused before anything reaches Hermes:

- Any kind not listed, extra or missing fields, a note over its size, a header that does not match the seal.
- Text that starts with `/` (slash commands run the full command line), is empty, is over 8,000 characters, or
  holds control characters other than new lines and tabs.
- A bot that is private, unknown, or not a plain identifier; a chat id that is not a plain identifier or belongs
  to another bot.
- Attachments, files, configuration, schedules, Board changes, bot settings, shell and anything else: there is
  no note for them, so they cannot be asked for.
- A note from a phone the Mac no longer knows, a note seen before (the seen list keeps every id until it
  expires), a note that has expired, or one dated more than five minutes in the future.

## Approvals keep their Ask first meaning

- Only cards raised by the turn the phone started are sent, only to that phone, and only approvals. Questions
  that ask for a password, a secret, a vault code, a saved sign-in or system control stay on the Mac.
- The phone may answer Allow once or Deny. "For this chat" and "Always" are never offered and are refused if
  sent. A card whose Hermes choices do not include both is shown as "Answer on your Mac".
- The yes goes through the phone's owner check (Face ID) first, exactly where the Mac would ask. The Mac then
  answers without asking again, because the person was checked on the phone.
- A card is good for ten minutes from when the Mac sent it and for one answer. The Mac checks the card id it
  issued, the phone it went to, the time, and that the card is still up. Otherwise it says `closed` and does
  nothing.
- Ask first's fixed rules (sending, buying, posting, deleting, calendar, reminders, contacts) are untouched: they
  still need this yes, now from either device.

## Stop is fast

The phone writes the Stop record first, before anything else it is doing. The Mac hears it three ways:

1. The push from the subscription, usually within a few seconds.
2. While any helper is working (a running chat or a task using the Mac), the Mac also looks every three seconds.
3. Otherwise it looks every thirty seconds, and after any note for two minutes every three seconds.

A Stop is acted on once, and the phone shows "Stopped" when the Mac's `stopped` comes back.

## Latency

| Step | Typical | Worst normal case |
| :--- | :--- | :--- |
| Phone writes a record | 0.3 to 1 s | a few seconds on a poor network |
| iCloud push to the running Mac | 1 to 3 s | not delivered: the Mac's own look catches it (3 s while working, 30 s idle) |
| Mac to phone, app open | 1 to 3 s by push, and the phone looks every three seconds while it waits | same |
| Mac to phone, app closed | a visible notification for cards and replies, usually within seconds | iOS may hold silent pushes; the phone catches up when opened |

So a Stop while a helper works usually lands in two to five seconds, and within about five seconds even when the
push is lost. A message to an idle Mac usually lands in a few seconds, at worst about half a minute.

## Limits

- Text only: 8,000 characters out, 32,000 back. No attachments, pictures, voice or files.
- Replies come when the turn ends. No streaming, no tool rows, no thinking. The full chat is there at home.
- One card at a time per turn; ten minutes each.
- New chats from the phone while away are supported by the Mac side (`send` without `chat`); the phone's screen
  carries existing chats in this version.
- iCloud's own limits: the private database counts against the person's iCloud storage (records are tiny and
  short-lived), and CloudKit may slow a very busy account (it answers `requestRateLimited`; Nollie waits as told).
- The Direct Mac edition only, because the key swap rides on Nollie Link.

## Failure handling

| Case | What the person sees | What Nollie does |
| :--- | :--- | :--- |
| Not signed in to iCloud, or iCloud off for Nollie | The switch is off and says "Sign in to iCloud" | Nothing is written |
| Different Apple Accounts on phone and Mac | "Waiting for your Mac" then "Didn't reach your Mac" | The records land in different databases; the Mac's presence is never seen. The phone says to use the same Apple Account |
| Account changes | The switch goes off | Keys stay; records and subscriptions are rebuilt on the next explicit turn on |
| Mac asleep or Nollie closed | "Your Mac is asleep" when its last seen is over ten minutes old; a message says "Didn't reach your Mac" after 15 minutes | The record expires and is deleted |
| No network on the phone | The message stays in the composer with "No connection" | Nothing is retried by itself |
| Lost answer after a write | "Sent" stays until `received`; never sent twice by itself | The phone never repeats a send on its own |
| Card expired | "This ran out. Answer on your Mac." | The Mac refuses the late answer |
| Card answered on the Mac first | The card closes on the phone | `closed` with `answeredOnMac` |
| Phone removed on the Mac | "Link again at home" | The Mac ignores its records |
| iCloud storage full | "Your iCloud storage is full" | Nothing else |
| Schema not deployed (production) | The switch stays off with "Not available yet" | The first write fails with `unknownItem`/`invalidArguments`; nothing is retried in a loop |

## Threat model

What is worth protecting: the person's messages and replies, the power to approve an action, the power to stop
the crew, and the Mac's Hermes token (which never leaves the Mac in this design).

| Who | What they can do | What stops them |
| :--- | :--- | :--- |
| Apple, or anyone with iCloud's servers | See that records exist, their size, times, tags, and whether a visible notification was asked for | The box is in `encryptedValues` (keys held in iCloud Keychain, so Apple cannot read it) and, inside that, sealed with a key only the two devices hold. Tags are hashes of public keys |
| Someone who gets into the person's Apple Account | Read the private database, add or delete records, replay old ones | Without a device's private key they cannot open a box or make one that opens: a forged or altered record fails to open; a replay is in the seen list or expired. They can delete records (the message is lost and the phone says so) |
| Another app on the same account | Nothing | The container is Nollie's alone |
| A stolen, unlocked phone | Send, approve and stop as the person | The same as the phone at home: remove it on the Mac (its key is forgotten at once), and Face ID guards the yeses Ask first protects |
| A stolen Mac private key or phone private key | Open records it can still find (a day at most) and make new ones | Remove the phone on the Mac and link again; keys never leave the devices' Keychains |
| A note that asks for more than the allowlist | Reach files, configuration, shell, slash commands, schedules, bot changes | No such note exists; the Mac decodes strictly and refuses everything else before Hermes |
| An old or delayed approval | Approve something later than the person meant | Ten minutes, once, the issued card id, the phone it went to, and the card still being up |
| A record moved from one device's mailbox to another's | Confuse which device asked | The tags are bound into the seal, and each direction has its own key |

Out of scope: malware on either device, and someone using the unlocked Mac.

## What Apple sees

- That this Apple Account uses Nollie's container, when, how often and from which devices (as for any CloudKit
  app), and the size of each record.
- Per record: its random name, two random-looking tags, an expiry time and the alert flag.
- Per Mac: a presence record and when it was last updated (so, roughly, when the Mac was awake with Nollie open).
- Never: the text of a message or reply, a bot's name, a chat, an approval's words, or which helper did what.

## Papertrail

Nothing new leaves the Mac without showing up in Papertrail. Every note the Mac writes for a bot (a reply, a card,
status) is recorded in that bot's Papertrail as "Your iCloud" with the time and the kind of note, never its words,
through the add-on's `POST /api/plugins/nollie-workflow/papertrail/icloud` (the Mac app only; the Link door does
not let a phone reach it). Stop and status notes that belong to no one bot are recorded under the main bot.

## What Corey must do in Apple's portals

1. **Container.** `iCloud.com.coreykozarski.nollie` already exists and is in every app's entitlements (iPhone,
   Mac App Store, Mac Direct, the alert helper and the notification extensions). Nothing new to create.
2. **App IDs.** iCloud (CloudKit) and Push Notifications are already on for `com.coreykozarski.nollie` and the Mac
   app IDs. Check the Direct Mac's Developer ID provisioning profile still includes iCloud and Push (it does for
   alerts today); regenerate it if Xcode reports a mismatch.
3. **Schema, development.** Import `Tools/cloudkit/nollie-alerts.ckdb` (it now holds the away types too) with
   `xcrun cktool import-schema --team-id 5985LRZFZS --container-id iCloud.com.coreykozarski.nollie
   --environment development --file Tools/cloudkit/nollie-alerts.ckdb`, or run a development build once on two
   devices so CloudKit makes the types, then check the indexes below in the CloudKit Console.
4. **Indexes.** `NollieAwayNoteV1`: `recordName` queryable, `toTag` queryable, `fromTag` queryable, `expiresAt`
   queryable and sortable, `alert` queryable. `box` must be an encrypted bytes field.
5. **Deploy to production.** CloudKit Console › Deploy Schema Changes. Without this, TestFlight and App Store
   builds cannot write the records, and the switch stays off ("Not available yet").
6. **Real devices.** Push from CloudKit does not reach the Simulator reliably; the end-to-end check needs an iPhone
   and the Mac on different networks (phone on mobile data), both signed in to the same Apple Account with iCloud
   Keychain on (needed for `encryptedValues`).

## Test plan

Unit (Swift Testing, `NollieTests` and `NollieMacTests`):

- `AwaySealTests`: both sides derive the same keys; each direction's key differs; a box opens only with the right
  key, header and direction; any changed header field, a flipped byte, a swapped `to`, a reflected record, the
  wrong phone, or a truncated box fails; tags are stable and differ by role.
- `AwayRulesTests`: every allowed note passes; slash commands, empty, overlong, control characters, private and
  odd bot names, odd chat ids, unknown kinds and extra fields are refused; choices other than once and deny are
  refused; expiry and future dates; card life.
- `AwayMailboxTests` with a fake `AwayCloud`: a send reaches the desk once and gets `received` then `reply`; a
  replay is ignored; an expired note is dropped and deleted; a note from a removed phone is ignored; a card is
  answered once, refused after ten minutes, refused from another phone, refused with `session` or `always`; Stop
  is acted on once; the courier waits, then says "Didn't reach your Mac" after expiry; presence says asleep;
  records are deleted after reading; the courier never repeats a send by itself.
- Door: `/nollie/link/seal` stores the phone's key, answers the Mac's, refuses a bad key, a body on the wrong
  method, no credential, and 503 before the app gave its key.

Screens: the Away from home page in light and dark (phone), iCloud ready and off.

Needs real devices (not provable here): push delivery and its timing, CloudKit `encryptedValues` with a real
account, the production schema, a sleeping Mac, two Apple Accounts.

## Decisions and open questions

- Settled: the person's own private database; X25519 + HKDF + ChaChaPoly on top of `encryptedValues`; keys
  swapped over Nollie Link; approvals once or deny, ten minutes; Stop polled while helpers work.
- Open: a Mac App Store Mac has no Link door, so no key swap. iCloud Keychain could carry a shared key between
  devices of one account (it is end-to-end encrypted), which would also work without Link. Corey's call for 1.3.
- Open: the notification service extension could open the box and show the real reply in the notification. It
  would need the phone's private key in the shared Keychain group. Not in this version.
- Open: the alert helper (login item) could answer while the main Mac app is closed. Not in this version.
