# Nollie Link

[← Nollie](../README.md) · [Architecture](architecture.md)

Nollie Link is how an iPhone reaches the assistant that the Direct Mac edition runs.
The phone talks to one TLS 1.3 door inside Nollie Runtime. Hermes stays bound to 127.0.0.1 and never faces the network.
The phone trusts the Mac's key, pinned from a QR code, instead of any certificate authority.

Only `NOLLIE_DIRECT` builds open the door. Store builds and phones have no listener.

| Piece | Where |
| :--- | :--- |
| The door: listener, parser, policy, devices, identity | `Services/Runtime/LinkDoor*.swift` |
| Its place in the helper and the app's XPC requests | `Services/Runtime/RuntimeLink.swift`, `RuntimeIPC.swift`, `RuntimeService.swift` |
| The phone side: offer, pin, client, resolver | `Packages/NollieCore/Sources/NollieCore/Link/` |
| Linked connections in the core | `GatewayConnection.linkedMac`, `GatewaySecrets.linkedDevice`, `GatewayTrust`, `GatewayRuntime.linkResolver` |
| Mac screen | `Apps/Nollie/Connect/NollieLinkSheet.swift`, opened from Settings > Connection & Setup and the last onboarding step |
| iPhone screen | `PhoneDevicePairingView` in `Apps/Nollie/Connect/DevicePairingView.swift` |
| Tests | `Tests/Unit/NollieLinkDoorTests.swift` and `LinkDoorLiveTests.swift` (Mac), `Tests/Unit/NollieLinkTests.swift` (both) |

## Threat model

What is worth protecting: the Hermes session token (full control of the assistant), each phone's device credential, the single-use pairing secret, and the chats themselves.

A device credential is powerful. It is meant to let a phone do what Nollie on a phone does: read and write chats with every bot, start new ones, answer approval cards (including ones that let a bot run commands), change a bot's instructions, model and description, move chats between projects, manage the Board, and pause, resume, run or delete scheduled tasks. Whoever holds it can ask a bot to act, and approve what the bot asks to do. The door limits what the credential reaches beyond that, not what the bots can do once asked.

| Who | What they can do | What stops them |
| :--- | :--- | :--- |
| Someone else on the same Wi-Fi | Connect to the door's port, see the Bonjour advert, watch traffic, try to sit in the middle | TLS 1.3 only; the phone accepts the Mac's pinned key and nothing else; every request needs a device credential; Hermes's own token never leaves the Mac |
| Someone on the internet | Nothing, normally: the Mac is behind a router | Sources outside private ranges are refused before the handshake, even if a port is forwarded |
| Another device on the person's tailnet | Reach the door's port through Tailscale | With Away from home off (the default for a new Mac) Tailscale's ranges (100.64.0.0/10, fd7a:115c:a1e0::/48) are refused before the handshake like the internet's, and the Mac gives out no tailnet host. With it on, the same TLS pin and device credential as at home |
| Someone who sees the QR code | Use it first, within two minutes | One open offer at a time, spent on first use, gone after 120 seconds or when the sheet closes, Nollie locks, the screen locks or the app goes to the background. The Mac says "Linked to <phone>" and lists the device, so a stranger's link shows up and can be removed |
| A fake Nollie code | Point the phone at a look-alike server, with its own pin | The phone asks "Link to <name>?" and says to link only a Mac you own; addresses in a code must be private; the real Mac shows no "Linked to" message. This is the residual risk: a phone that scans an attacker's code links to the attacker |
| A web page in a browser on the network | Try cross-site requests or DNS rebinding | No cookies; the credential is a custom header, which needs a preflight the door never answers; the door's certificate is not trusted by browsers; Hermes still checks the rewritten Host |
| A lost or stolen phone | Keep using its credential | Remove on the Mac deletes the credential's hash and closes the device's live connections at once |
| A guess at a credential | Try values | 256-bit random credentials, compared in constant time against every stored hash |
| A malformed or hostile request | Smuggle a second request, a huge head, an odd path | A strict HTTP/1.1 reader: one request per connection, no chunked bodies, no folded headers, size and header-count limits, no dot segments or encoded separators |
| A linked phone, or whoever holds its credential | Reach admin routes or the Mac's disk directly | An explicit route allowlist: no keys or providers, no configuration (not even reading it: `/api/config` returns secrets), no plugin or MCP management, updates, restarts, logs, raw file system or git, no Hermes file routes at all (they are not confined to a folder the door can enforce), no creating or changing scheduled tasks (their scripts can't be checked), no deleting bots, nothing in bulk |
| The same, over the socket | Call gateway methods the app never uses (`shell.exec`, `cli.exec`, `config.set`, vault, connectors, approval modes) | Every frame the phone sends is read and unmasked. On `/api/ws` only the JSON-RPC methods the app itself sends pass, `config.set` only for model, reasoning and fast mode, `config.get` only for profile and project; slash commands (`slash.exec`, `command.dispatch`) are refused because they run the full command line. Anything else is answered by the door and never forwarded. Compression is never agreed, so nothing hides in a compressed frame |
| The same, on the live picture | Reach Hermes through it, send it video or commands, or open many streams | `/nollie/live` is answered by the door itself and never reaches Hermes. It needs the device credential, exactly one `profile` and one `session_id` (plain identifiers) and nothing else; whether that chat may be watched is the provider's call (private bots are refused there). The phone may send only small text asking for a keyframe or reporting what it showed: binary closes the stream (1003), anything else or over 512 bytes closes it (1008). One stream per device, a newer one replaces the older. No compression is agreed |
| Many connections from the network | Crowd out a linked phone | One ten-second deadline for everything before a credential is accepted, claim body included; four unproven connections per address and sixteen in all, out of 64 |

Out of scope: malware on the Mac account or the phone, and someone using the unlocked Mac. The door gives no isolation from other software on the Mac: Hermes listens on loopback with its own token, as it did before Nollie Link, and a local process that has that token never needed the door. The door only decides what reaches Hermes from the network.

## Sharing a helper at home

A linked phone is an owner (every phone linked with an ordinary code, and every one from before) or a member:
someone at home a helper was shared with, who joined with a version 2 code (`"f": {"o": owner, "b": [helpers]}`). The
door decides the role from the offer that was claimed and keeps it in `link.json`. Members get their own short
allowlist, filtered JSON-RPC both ways on `/api/ws`, their approvals routed to the owner, home only (never through
Tailscale), and no Stop, live picture, Take over or Away from home. The door's own routes are under `/nollie/family`.
Everything is in [Sharing a helper at home](specs/family-sharing.md); the code is `Services/Runtime/LinkDoorFamily*.swift`
and its tests `Tests/Unit/LinkDoorFamilyTests.swift` (Mac) and `FamilySharingTests.swift` (both).

## Protocol

1. **Offer.** The Mac app asks Nollie Runtime over its code-signed XPC connection. The helper makes a 32-byte random secret, valid for 120 seconds, replacing any open offer, and starts listening. It returns the Mac's name, the pin, the port, candidate hosts and its install tag.
2. **Code.** The app draws `https://nollie.app/pair#<payload>`, where the payload is base64url JSON with exactly the keys `v` (1), `n` (Mac name), `k` (pin), `p` (port), `h` (hosts), `t` (install tag), `s` (secret) and `e` (expiry, Unix seconds). Everything is after the `#`, so even opened in Safari it never reaches a server. The code refreshes 15 seconds before it runs out.
3. **Confirm.** The phone scans it (or opens it as a link) and parses it strictly: Mac name without control or direction characters, 32-byte pin and secret, port 1024 to 65535, up to eight private IPv4 addresses, Tailscale IPv6 addresses (fd7a:115c:a1e0::/48), or `.local` and `.ts.net` names, expiry within the next ten minutes. It asks "Link to <Mac name>?". The Mac puts home addresses and its `.local` name in the code, and, only while Away from home is on, the MagicDNS name and Tailscale IPv4 address (IPv4 only, so an older Nollie on the phone still reads it).
4. **Find.** The phone tries a TLS 1.3 handshake with each host. It succeeds only when the server's leaf key hashes to the pin (SHA-256 of the P-256 SubjectPublicKeyInfo). System trust, names and dates play no part.
5. **Claim.** Over that pinned connection: `POST /nollie/link/claim` with `{"name": "...", "secret": "<base64url>"}`. The door answers `200 {"credential", "device", "mac"}`, or `410` when the offer is spent or expired, `403` for a wrong secret (the offer stays open for the real phone). The credential is 32 random bytes as hex; the Mac stores only its SHA-256, in `Application Support/Nollie/RuntimeService/link.json` (0600, atomic writes, no links). The phone keeps it in the Keychain as the connection's session token.
6. **Check and save.** The phone runs the usual connection check through the door (status, profiles, `/api/ws` until `gateway.ready`), then saves a session-token connection to `https://<host>:<port>` with `linkedMac` set, and switches to it. Both sides confirm by name: "Linked to <Mac name>" on the phone, "Linked to <phone name>" on the Mac.
7. **Every request.** Source address check before the handshake, then the request head, then the device credential (the `X-Hermes-Session-Token` header, or `?token=` on a WebSocket upgrade; two different values count as none), then the route allowlist. The door strips incoming credentials, cookies, forwarding and hop-by-hop headers, sets `Host: 127.0.0.1:<port>`, adds Hermes's own token in the same place and `Connection: close`, and passes the request to the ready API child. After Hermes answers `101` to a socket upgrade, Hermes's frames pass straight through, and every frame from the phone is read in full, checked and sent on re-masked: on `/api/ws` only allowed JSON-RPC calls and answers to Hermes's own requests (approval cards); on the Board's event socket nothing but control frames. A refused call gets `{"error": {"code": 4403, "message": "This can only be done on your Mac."}}` with its id, sent only between Hermes's messages.
8. **Finding it again.** Before each socket attempt the phone tries the address that worked last, then Bonjour (`_nollie._tcp`, matched by install tag and then proven by the pin). With no Bonjour answer (away, or behind an exit node), the tailnet name and addresses go first and the home addresses race behind them: the earliest in that order that proves the pin wins as soon as every one before it has failed, so a home address that hangs on mobile data holds nothing up. When the address that worked last was a tailnet one, the tailnet is tried first and Bonjour only after. Every path checks the pin. A new address is saved for next time.
   **Where the Mac is now.** After each successful find the phone asks `GET /nollie/link/hosts` with its credential. The door answers itself, never Hermes: `{"hosts": [...], "away": Bool, "tailscale": "ready"|"stopped"|"missing"}`, the Mac's current home addresses, `.local` name and, only while Away from home is on, its tailnet name and addresses (IPv6 too). The phone reads it strictly (valid hosts only, at most eight), stores it on the saved link and registers each new host with the same pin. `POST /nollie/link/away/on` and `/off`, with no body, turn Away from home on or off from a linked phone; since the door refuses Tailscale sources while it is off, a phone can only turn it on from home.
9. **Stop.** Stop ends the job on your Mac, stops replies and pauses schedules. It is in Siri and
   Shortcuts ("Stop Nollie on my Mac"); on the Lock Screen and in the Dynamic Island while the iPhone can
   see a helper using a computer (a Live Activity, "Scout is using your Mac", started while Nollie is
   open, since there is no server to start one); and on the "Scout started using your Mac" alert when
   notification details are shown. Each asks for the phone to be unlocked, then the app sends
   `POST /nollie/stop` with no body and the device credential, and stops the replies the phone itself
   has running. The door answers it itself, never Hermes: it records the press (a count, the device's
   name, the time) and replies `200 {"stopped":true}`. The Mac app reads the record from the helper's link status, every two seconds
   while a phone is linked, and acts once per press: a Nollie Computer task ends ("You stopped it from
   your iPhone."), every reply running in the app stops, and every schedule that would start more work is
   paused (a private bot's are left alone). A notification on the Mac says what stopped and how many
   schedules were paused; they stay paused until resumed in Schedules.
10. **Watch.** The live picture of a helper's computer is a socket the door answers itself:
    `GET /nollie/live?profile=<p>&session_id=<id>` with the credential, upgraded with the door's own `101`
    (no extensions). The door asks a provider (the Mac app, which captures and encodes) for a feed and
    relays its messages unchanged: video as binary, everything else as JSON text. One video message is
    with the connection at a time; a newer keyframe replaces one waiting, and after any drop the door
    withholds frames up to the next keyframe and asks the provider for one, once. Text is never dropped,
    but if 32 messages wait the stream closes. Once a second the door hands the provider its counts
    (`{"type":"stats","sent","withheld","taken","waiting","heard"}`) so it can lighten the picture. The
    phone's keyframe requests and reports go to the provider as sent. A provider may send before it
    answers with its feed; until then the door keeps its own keyframe request and the phone's latest
    keyframe request and report, and hands them over when the feed arrives. With no provider, or one that
    refuses, the phone gets `{"type":"end","reason":...}` and a close, and falls back to snapshots.
    The feed is closed when the socket ends, on Remove and when the door stops. Away from home it
    works the same way: the phone finds the door as it does for every socket (the tailnet first, the
    pin checked), a stream from a Tailscale address is only let in while Away from home is on, and
    turning it off closes that stream with every other Tailscale connection. While Nollie types a
    saved sign-in the host sends no video, and its beats say `"hold": "sign_in"` (see
    [The live picture](live-picture.md)).
11. **Remove.** The Mac app asks the helper to remove a device: its hash is deleted and its open connections, phone side and Hermes side, are cancelled straight away.

**Away from home.** One switch, kept in `link.json` with the devices: off for a new Mac; a state file from before the switch with a phone already linked keeps it on once, so that phone keeps working where it did. Off: no tailnet hosts in the code or the hosts answer, Tailscale sources refused before the handshake, and turning it off closes every connection that came in through Tailscale at once. Nollie Runtime finds Tailscale without admin rights or network calls of its own: `status --json` from the command line inside `/Applications/Tailscale.app` (standalone or Mac App Store) or Homebrew's `tailscale`, with a three-second limit; failing that, an address in Tailscale's ranges on this Mac means it is on, without a name. A name the person types under "Enter it yourself" is offered first. The Mac app reads and changes all of this over XPC (`linkAway`).

The door listens only while a device is linked or an offer is open. Its port is chosen once, at random in 50000 to 59999, and saved. Its P-256 key is made once and kept in the helper's Data Protection Keychain; a self-signed certificate wraps it because TLS needs one. ALPN is fixed to `http/1.1`.

| Limit | Value |
| :--- | :--- |
| Request head | 16 KiB, 64 headers, 8 KiB a line, 4 KiB target |
| Request body | Content-Length only, up to 64 MiB; the claim body up to 4 KiB |
| Socket message from the phone | 32 MiB, 512 bytes on the live picture; control frames 125 bytes, never fragmented |
| Live picture | One stream per device; video messages up to 8 MiB, text up to 4 KiB; 32 text messages waiting |
| Time before a credential is accepted | 10 seconds for the handshake, head and any claim body together |
| Open connections | 64, of which at most 16 without a credential, at most 4 of those from one address |
| Linked devices | 16 |

Allowed routes, everything else refused: status and health; `/api/ws`; sessions (list, search, one chat's details, rename or archive, delete, messages); profiles (list, create, active, rename, soul, description, model, never delete); model options; configuration schema; media and the media proxy (Hermes confines both); scheduled tasks (list, details, pause, resume, run now, delete); usage analytics; skills and toolsets read; the Board's routes except import, reset and attachments, and its event socket; the nollie-workflow attention count, private-bot list and Papertrail (read only); a saved sign-in card's claim (`POST /api/plugins/nollie-workflow/sign-ins/requests/*/claim`, which only says the phone is answering); the nollie-computer preview; Watch's Take over and Hand back (`POST /api/plugins/nollie-computer/take-over` and `/hand-back`, exact paths, POST only, and a query of exactly one `profile=<name>`; the phone asks for Face ID first and the add-on still refuses private bots); the door's own live picture socket (`GET /nollie/live` as an upgrade only); what a helper remembers (`GET /api/plugins/nollie-workflow/memory`, `POST`, `PUT` and `DELETE .../memory/notes`, `PUT .../memory/switch`, exact paths, and a query of exactly one `bot=<name>`, so a phone can never say `on_this_mac`; the add-on refuses Moss and every private bot from a phone). Hermes's own `/api/memory` routes (provider and reset) stay refused.

The listener is one attempt at a time. Each stop moves a generation on, so a listener that becomes ready after a stop is cancelled at once, and the port is never shared with another listener. On the phone, a linked Mac's pin is trusted process-wide only once the link is saved, one pin per address, replaced by a later link and forgotten when the connection is removed; pairing and the first connection check carry the offer's pin themselves.

## What the tests prove

`NollieLinkDoorTests` (Mac, in the Direct unit run) compiles the door's own sources into the test bundle:

- The parser accepts strict requests and socket upgrades, refuses a corpus of 42 malformed heads (bare LF or CR, other versions and methods, absolute and asterisk targets, folded or duplicate headers, chunked or duplicate lengths, dot segments, encoded separators, NUL, non-ASCII, bad upgrades), enforces every size limit, and survives 6,000 seeded mutations with every invariant holding.
- Source filtering for IPv4, IPv6, mapped addresses, names and services; Tailscale's ranges told apart, including mapped IPv4.
- Away from home: off for a new Mac, kept on for a Mac that already had a phone, decided once; the hosts answer leaves out tailnet hosts while off; on and off from a linked phone, through the app's own client, never reaching Hermes; a body refused.
- Take over and Hand back: POST with one `profile` only; other methods, extra or repeated query items and other add-on paths refused; the allowed ones reach Hermes and the refused ones never do.
- The route allowlist, with about 80 admin, file, configuration, scheduled-task, bulk session, bot deletion, plugin-management and page routes refused.
- The phone's socket frames: fragments with a ping between them, a byte at a time; unmasked, compressed, fragmented control, long control, unknown opcode, stray continuation, bad text, oversized and interleaved frames refused. Hermes's frame boundaries tracked so the door's replies never split a message.
- JSON-RPC: allowed calls and approval answers pass; `shell.exec`, `cli.exec`, `config.set` for auto-approve or approval modes, `config.get` for other keys, vault, connectors, slash commands, batches, odd ids and non-JSON are refused with the right id. A scan of the app's source fails when it sends a method that is not classified for the door.
- Listening: concurrent starts share one listener; in 25 interleavings of start and stop, a start that lost leaves nothing up and at most one listener is ever up.
- Crowding: a third idle connection from one address is turned away, unproven connections close at the deadline (a claim whose body never comes too), and a linked phone gets in again.
- Header rewriting: credentials, cookies, forwarding headers and connection-named headers stripped, the loopback token injected.
- Offers: single use, a wrong secret leaves the offer open, expiry, replacement and cancel. Credentials: full-length constant-time checks, removal, persistence without the credential, and a refused claim when the state can't be saved. The state file's mode and its refusal when shared.
- The identity: made once in the Keychain and kept; its pin matches its certificate in both the door's and the phone's code; another key is a mismatch.
- End to end on loopback: a door in front of a fake Hermes. A forged code is refused before its secret is sent; the real code links once and then reads as expired; the app's own connection check passes through the door; Hermes sees only its own token and loopback Host; nothing is trusted process-wide until the link is saved; a stranger gets 401 and an admin route 403 without reaching Hermes; on the live socket `shell.exec` and `config.set yolo` get the door's error and never reach Hermes while `ping` does; a live socket closes within a second of Remove; the door stops listening when nothing is linked.
- A refused source never completes a handshake; without Hermes the door answers 503; two requests in one write get 400.
- The live picture's route: only a GET upgrade at exactly `/nollie/live`; other methods, plain requests, a trailing slash, sub-paths, `/api/nollie/live`, case and encoded variants, and the preview as a socket are refused.

`LinkDoorLiveTests` (Mac, same bundle) covers the live picture:

- The send gate: one video message in flight; a newer keyframe takes a waiting frame's place; after a drop, frames up to the next keyframe are withheld and exactly one keyframe is asked for; text is never dropped but 32 may wait; each second's counts and their JSON.
- The upgrade: RFC 6455's accept value; missing, empty, duplicate, odd or extra `profile` and `session_id` refused with 400; no extensions agreed even when offered; only `keyframe` and `report` text accepted from the phone.
- End to end on loopback with a pretend Mac app: strangers get 401 and the provider is never asked; a linked phone gets `101` with the right accept value and the provider's text and a 100 KB frame byte for byte; its keyframe request and report reach the provider, and the next second's stats say a report was heard; a provider that sends a big keyframe and deltas before it answers still gets the door's keyframe request and the phone's early report; pings are answered; binary from the phone closes 1003, oversized, unknown or non-JSON text 1008, an unmasked frame 1002, and each closes the feed; Remove cuts the stream within a second; a second stream from the same device replaces the first; door stop ends it; no provider, a refusing provider and a provider ending a stream each send the right end message and close code; nothing reaches Hermes.

`DesignSnapshotTests/theNollieLinkSheet` draws the Mac sheet (code with a linked device, the confirmation, the hidden state) in light and dark; `DevicePairingUITests/testLinkConfirmationNamesTheMacAndStaysInert` drives the iPhone's inert "Link to Studio Mac?" in the demo copy.

`NollieLinkTests` (iPhone and Mac) covers the offer format and its tampering, expiry and host rules, pins replaced and forgotten per saved connection and the missing-pin cases, the resolver's order, the credential on every request, and that older saved connections still decode.

`NollieLinkAwayTests` (iPhone and Mac) covers telling tailnet hosts apart, Tailscale IPv6 in a link, which hosts go out with the switch on and off, the strict hosts answer and what the phone keeps, Tailscale's `status --json` read from fixtures in `Tests/Unit/Fixtures/Tailscale` (running, exit node, stopped, signed out), and the resolver at home, away with a hanging home address, behind an exit node, and the pin on every path. On the Mac it also drives detection: not installed, installed but not running, running with its name (app or Homebrew), running without the command line, and an exit node from the status or from the default route on Tailscale's interface. `AwayFromHomeUITests` drives the iPhone screen, the away card and the exit node card in the demo copy against the mock's `/nollie/link/*` fixture; `DesignSnapshotTests/theAwayFromHomePage` draws the Mac page (off, needing Tailscale with the exit node card, ready).

## What still needs a real iPhone

Corey's spike, on one Wi-Fi network, with a DirectDebug or DirectRelease build whose background service is on:

1. On the Mac, open Settings > Connection & Setup > Use Nollie on your iPhone. Expect the macOS Local Network prompt for Nollie Runtime the first time it listens or advertises (see below). Note whether it appears and what it names.
2. On the iPhone, open Nollie, choose Scan QR code and scan the Mac's code. Expect the iOS Local Network prompt on the first link. Confirm "Link to <Mac name>?", then Link.
3. Check that the phone shows "Linked to <Mac name>" and the Mac shows "Linked to <phone name>" with the phone in Linked devices.
4. Chat from the phone, send a photo, dictate a message, open the Board. Note anything refused that should not be.
5. Turn Wi-Fi off and on, sleep and wake both devices, change the Mac's address if possible, and see the phone find it again (last address, then Bonjour).
6. Remove the phone on the Mac and check the phone loses its connection within a second.
7. Away from home: turn it on on the Mac (Settings › Away from home), with Tailscale on both. Open Nollie at home once, then on mobile data: the bots list should say "Connected through Tailscale". Try Take over in Watch (Face ID first), and check the live picture plays there too. Turn it off on the Mac and check the phone loses its connection and says "Away · alerts only". Try with an exit node on the phone, and with the macOS firewall on.

Not covered by tests yet: Bonjour on real Wi-Fi, the Local Network prompts, the helper's Keychain access as a LaunchAgent after login, scanning the code from a screen, real Tailscale (the fixtures follow its documented `status --json` shape but were written by hand; whether the Mac App Store app's command line answers a LaunchAgent; whether macOS names the utun as the primary interface under an exit node), sleep and wake on long sockets, and large uploads through the door.

## Prompts to expect

| Device | Prompt | When |
| :--- | :--- | :--- |
| Mac | Local Network: "Nollie Runtime would like to find and connect to devices on your local network" (macOS 15 and later) | The first time the helper listens or advertises over Bonjour. Whether a background LaunchAgent can show it, and how it is attributed, is part of the spike |
| Mac | Application Firewall: allow incoming connections for Nollie Runtime | Only if the firewall is on and does not already allow signed software |
| Mac | None for the Keychain | The identity uses the helper's Data Protection Keychain group, which does not prompt |
| iPhone | Local Network, using "Find and connect to Nollie on your Mac, or to a Hermes dashboard on your local network." | The first link, or the first Bonjour search |
| iPhone | Camera | The first scan, as before |

## Known gaps

- Universal links need the `applinks:nollie.app` associated domain and an apple-app-site-association file on nollie.app, which is not set up. The app handles the link when it is opened; until then, scan inside Nollie.
- Away, the first connection after leaving home waits for the last home address and Bonjour (up to three seconds each) before the tailnet; after that the tailnet goes first.
- A phone that has never connected since Away from home was turned on only knows the tailnet hosts from a code scanned while it was on. Open Nollie at home once, or link again.
- Send and Stop while away without Tailscale, through the person's own iCloud, are planned, not built.
- One request per TLS connection keeps the door simple; keep-alive would save a handshake per request.
- A Mac renamed while the helper runs keeps its old name until the helper restarts.
- If the connection check fails after a claim and the phone gives up, the Mac lists a device that was never saved. Remove it there.
- On a phone linked this way, these stay on the Mac for now: keys, plugins, MCP servers, skills, toolsets, providers, settings that read or write configuration, files, new or edited scheduled tasks, deleting bots, slash commands and turning on auto-approve. The app shows the door's message where it tries one.
