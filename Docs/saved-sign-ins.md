# Saved sign-ins

[← Nollie](../README.md) · [Architecture](architecture.md) · [Nollie Computer](nollie-computer.md)

A helper working on its computer reaches a sign-in page. It asks Nollie to sign in. The person
says yes, and Nollie on the Mac types the saved username and password. The helper is never told
them, and pictures of its computer pause while they are typed.

## How it works

1. **Save.** On the Mac, Settings › Sign-ins: add a site, a username, a password and, if you like,
   a note about one-time codes. Nollie tells the Hermes add-on which sites are saved. Sites only.
2. **Ask.** The helper calls `request_sign_in(site, computer)` from the `nollie_sign_in` toolset of
   the nollie-workflow add-on. A site with nothing saved gets "not saved yet" and nobody is asked.
3. **Answer.** The add-on asks through Hermes's own approval gate, so the card and the usual alert
   come as for any approval: "Scout wants to sign in to example.com", Allow once or Deny. There is
   no Always.
   - On the Mac, Allow asks for Touch ID or the Mac's password, then reads the sign-in.
   - On the iPhone, Allow asks for Face ID. The Mac then asks for Touch ID or its password before it
     reads the sign-in (see [What is not done](#what-is-not-done)).
4. **Fill.** Nollie on the Mac types into the helper's computer: the username, Tab, the password and
   Return. For a Cua computer it uses Cua's public command line with only three permissions (look
   the computer up, type, press keys), and checks the computer is the one named and running first.
   It waits a moment after saying it is about to start, so a picture already being taken finishes
   before anything is typed. See [Pictures pause](#pictures-pause-while-it-is-typed).
5. **Answer the helper.** The helper gets one of: signed in, declined, not saved yet, or not signed
   in with a reason. Never a username, a password or the note. If the note exists, it hears only
   that a one-time code may come next.
6. **Remember.** Each use is one line in the history, shown in Settings › Sign-ins under Recent:
   when, which helper, which site, who said yes, and how it went.

## Where things are kept

| What | Where | Who can read it |
| :--- | :--- | :--- |
| Password and code note | This Mac's Data Protection Keychain, service `….signins`, this device only, never synced, only while the Mac has a password | Nollie, after Touch ID or the Mac's password, every time |
| Site and username | The same Keychain, service `….signins.list`, this device only, never synced | Nollie, while the Mac is unlocked (Settings lists them without asking) |
| Which sites are saved | `~/.hermes/nollie-workflow/sign-ins/sites.json` (0600) | Hermes and anything running as you |
| Open requests | `…/sign-ins/requests/<id>.json` (0600), gone within two hours | Hermes and anything running as you |
| History | `…/sign-ins/history.jsonl` (0600), 90 days | Hermes and anything running as you |

The iPhone never holds a password. Nothing about sign-ins goes to iCloud.

## Threat model, in plain words

What is worth protecting: the passwords. Second: that a sign-in only happens when the person meant it.

| Who | What they could try | What stops them |
| :--- | :--- | :--- |
| The helper (the model) | Read the password | It is never in a tool result, a chat, a prompt or a log. The tool takes no secret and returns fixed words. While it is typed, and for 10 seconds after, every new screenshot, recording and action on a computer is refused and the preview pauses. A fill never starts while a recording the helper started is running. |
| The helper | Sign in without asking | Every request needs a yes on the card, and the Mac reads the password only after Touch ID or the Mac's password, whoever answered the card. |
| The helper | Ask again and again | Each request is its own card. Schedules and Board work are refused outright: nobody is there to say yes. |
| A private bot (Moss) | Use a sign-in | The tool is not loaded for a private bot, the add-on refuses it at every call, and the Mac refuses it too. Its requests and history never show. |
| Someone with your unlocked Mac or iPhone | Allow a sign-in | They still need Touch ID or the Mac's password on the Mac before anything is typed. |
| Someone who steals the Mac's disk or a backup | Read passwords | Data Protection Keychain items for this device only: not in backups, not synced, sealed by the Secure Enclave. |
| iCloud | Hold a copy | Items are never synchronizable. |
| A process running as you (or a helper's own shell) | Fake an approval, or claim it came from the iPhone | It can answer Hermes's card, but it can't answer Touch ID. "Who approved" in the history is a label, not proof. |
| A process running as you | Read the site list, requests or history | It can. They hold no secrets: sites, bot names, times, outcomes. |

What this does **not** protect against:

- **The helper's own computer.** Once typed, the password is in a page on a computer the helper
  controls. A helper that set out to could read it back from that page (a script, a screenshot of a
  "show password" box after the pause). Saved sign-ins keep the password out of the model's words and
  out of pictures while it is typed; they don't make a computer the helper drives safe from the helper.
- **A password left showing.** The fill types blind: if focus was on the wrong box, or the site
  shows passwords in plain text, the password can stay visible after the 10 second pause ends, and
  a later screenshot would show it.
- **A look-alike page.** Nollie can't see the address the helper's browser shows. If the helper was
  tricked onto a fake page and asks for the real site, a yes types the password into the fake page.
  Before you allow, look at the helper's screen in the chat when you can. Sites are matched exactly
  or by subdomain (`example.com` covers `login.example.com`, never `example.com.evil.net`), and
  other scripts show as `xn--` names on the card.
- **Malware running as you on the Mac** while you approve with Touch ID: it could watch the typing.
- **Cua's own logs.** Nollie never logs what it types; whether the Cua daemon or the computer does
  is up to them.

## Pictures pause while it is typed

From the moment a request is approved until 10 seconds after the Mac reports how the fill went (35
seconds if the helper is stopped mid-fill, since the Mac may still be typing):

- **Screenshots and actions are refused.** A `pre_tool_call` hook in the add-on
  (`sign_ins.PicturePause`) refuses every call that could take a picture of a computer, record it or
  act on it: every Cua tool, Cua Driver recordings, Hermes's `computer_use`, Nollie Computer, any tool
  whose name says screenshot, capture, record, snapshot, screen or vision, and shell or code that runs
  `screencapture`, `cua` or a screen recorder. It reads the request files directly on every such call,
  so a screenshot from another chat or another bot is refused too. A request file it can't read counts
  as a fill in progress.
- **No fill during a recording.** `request_sign_in` refuses while a screen recording the helper started
  through a tool is still running, and asks it to stop the recording first.
- **Late pictures are thrown away.** A call that passed the check but finished once a fill had begun
  (one waiting on an approval card, say) gives back no picture, and Hermes's cached copy is deleted.
- **The Mac checks again.** After saying it is about to type, the Mac waits a moment, then types only
  if the request is still being filled.
- **The preview pauses.** The nollie-computer preview answers "paused" with no picture, discards a
  frame captured while a fill began, and the app shows "Paused while a sign-in is typed" instead of
  falling back to an older screenshot.
- **The live picture pauses too.** A helper's own computer: the Mac's host gets the same paused
  answer, encodes and sends nothing, drops its encoder with the last picture it kept, and its beats
  say `"hold": "sign_in"`. Nollie Computer's window on this Mac: the Mac stops capturing whenever
  `GET /api/plugins/nollie-computer/paused` (the preview's own rule) says so, asked twice a second,
  and captures nothing before the first answer. Watch clears the picture at once, shows the same
  paused line, and never brings back anything from before the pause. See
  [The live picture](live-picture.md#while-a-saved-sign-in-is-typed).
- **Ask first never looks.** Its check of a button's label takes no screenshot during the window; the
  click is held instead.
- **The helper waits.** `request_sign_in` answers only after the 10 seconds, so the helper's next
  screenshot lands after the pause.

What is kept, and where the password could appear:

| Place | Why it can't hold the password |
| :--- | :--- |
| Tool results and chat | The tool takes no secret and answers in fixed words (tested). |
| Night shift receipts | Sign-ins never run unattended; a call line holds the site only. |
| Papertrail | Keeps tool names and counts, never arguments. |
| Logs | Nollie logs no typed text; the Mac's fill job prints as hidden. |
| Screenshots, preview frames, recordings | New ones refused or paused during the window, above. |
| A recording already running | Not paused. A fill won't start while one the helper started through a tool runs; one started some other way (a background `ffmpeg` in a terminal) is not seen. |
| Cua's own logs | Not known: Nollie can't see inside Cua. |

## Turning it on

The tool is in its own toolset, so a bot only gets it when asked for:

1. Update the add-on: `python3 Companions/nollie-workflow/install.py --apply` (and `--recorder` or
   `--papertrail-bots` for the other bots, as before), then restart the gateway and dashboard.
2. Add `nollie_sign_in` to the bot's toolsets in Hermes, next to its computer tools.
3. Add a sign-in in Nollie on the Mac: Settings › Sign-ins.

## Pieces

| Piece | Where |
| :--- | :--- |
| Tool, request files, history | `Companions/nollie-workflow/sign_ins.py` |
| Routes (`/api/plugins/nollie-workflow/sign-ins/...`) | `Companions/nollie-workflow/dashboard/plugin_api.py` |
| Keychain store, wire types, card recognition | `Packages/NollieCore/Sources/NollieCore/SignIns/` |
| The card, answering it | `Apps/Nollie/Chat/SignInCard.swift` |
| Settings › Sign-ins, the Mac's watcher, filling | `Apps/Mac/SignIns/` |
| The phone's one route through Nollie Link | `POST …/sign-ins/requests/*/claim` in `Services/Runtime/LinkDoorPolicy.swift` |
| Picture pause | `PicturePause`, `typing_now` in `sign_ins.py`; the preview's pause and `/paused` in `Companions/nollie-computer/dashboard/`; the live picture's hold in `Apps/Mac/Live/` and `LiveWatch` |
| Tests | `Companions/nollie-workflow/tests/test_sign_ins.py`, `Companions/nollie-computer/tests/test_preview.py`, `Tests/Unit/SavedSignInTests.swift`, `Tools/mock-gateway/test_sign_ins.py`, `Tests/UI/SignInUITests.swift` |

Routes, default profile only, `Cache-Control: no-store`:

- `GET` / `PUT /sign-ins/sites`: `{"sites": ["example.com"]}`. Hosts only; anything else is 422.
- `GET /sign-ins/requests`, `GET /sign-ins/requests/{id}`: open requests, no secrets.
- `POST /sign-ins/requests/{id}/claim` `{"approver": "mac" | "iphone"}`: first one wins, else 409.
- `POST /sign-ins/requests/{id}/start`: the Mac is about to type. Once, and only while the helper
  still waits; else 409. A request the helper gave up on is never typed.
- `POST /sign-ins/requests/{id}/result` `{"outcome", "reason", "code_note"}`: fixed words only.
- `GET /sign-ins/history?days=30`.

## What is not done

- **iPhone approval still needs the Mac.** The design asked that an Allow with Face ID on the iPhone
  leave the Mac nothing more to ask. That can't hold together with "Touch ID or the Mac's password for
  every read": the Keychain will not hand over the password without someone at the Mac. This build
  keeps the stronger rule. Doing both needs a second, phone-unlocked copy: a Secure Enclave key on
  the iPhone (Face ID per use) signs each yes, the Mac pins that key once with a matching code on
  both screens, and only a signed yes opens an "away" copy of the password. It is a design choice
  for Corey, not a gap to paper over.
- **Filling on This Mac** (Nollie Computer) answers "Nollie can't type into this computer yet."
  Nollie Computer keeps browsers view-only and refuses typing into password fields, both rules a
  security review signed off. Filling there needs its own reviewed exception.
- **A real Cua computer** has not been filled yet. The steps are tested against a recorded
  exchange; the key names (`tab`, `enter`) and a real Space are not proven.
