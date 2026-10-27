# Ask first

[← Nollie](../README.md) · [Architecture](architecture.md) · [Nollie Computer](nollie-computer.md) · [Saved sign-ins](saved-sign-ins.md)

Sending, buying, posting or deleting always waits for the person's yes. A Hermes hook in the
nollie-workflow add-on reads each tool call before it runs, by fixed rules, and holds the ones that
match. The model's own judgement is never asked. When the rules can't tell what a call does, they ask
too; that extra caution is the one thing a bot's Ask first switch turns off.

The one exception to "always" is **Quick pay** (off by default): small payments to sites paid before
skip the card, though the security code is still typed each time (Settings, Cards, on the Mac).

## Which bots are covered

In a setup Nollie manages, Ask first is on in every bot: the main bot, every other bot and every Private
bot. The starter setup, Add a bot and the crew's new helpers all include it, and every start of Nollie
Runtime brings each bot's copy up to date. Each bot keeps a small record that it was set up. During
setup, Nollie keeps a backup before changing a bot's settings and leaves its other add-ons alone. The
bots that were always private by name in older builds (`private` and `moss`) are never touched.

In **Bot settings → Instructions**, the **Ask first** switch shows that bot's current choice. Turning
it off asks, "Turn off Ask first for &lt;bot&gt;? Sending, buying, posting and deleting still wait for
your yes. Steps Nollie can't read won't ask." Choose **Turn Off** or **Cancel**. Turning it on needs no
question. Off, only the calls the rules can't read (cards of the kind `unsure`) run without a card;
everything the rules name as sending, buying, posting or deleting still asks, and so does a call the
rules choke on. A change applies to the bot's next call; it cannot undo something already sent.

The switch is its own file, `<bot home>/nollie-workflow/ask-first.json` (`{"version": 1, "enabled":
false}` turns it off; anything else, or no file, is on), read before every call. It never turns the
add-on off, so Papertrail and Board follow-through carry on either way. Older versions of Nollie turned
the whole add-on off instead; on its next start Nollie Runtime turns it back on in that bot with the
switch off, so the choice is kept and the four still ask.

A new crew member keeps the main bot's safety rules and cannot gain permissions the main bot lacks.
Ask first also works in a bot whose copy has Papertrail off.

**Private bots** load these rules too, and nothing else of the add-on: no Papertrail, no Night shift
record, no saved sign-ins. Their calls are read to decide whether to ask and kept nowhere; a picture
read from their screen stays in memory for that one decision. Their Ask first switch is hidden and
stays on. If the Private list cannot be read, the rules still load in every bot, and setup stops
instead of guessing which bots it may change.

For a Hermes setup you manage yourself, the rules run only in bots where nollie-workflow is installed
and enabled. The [companion installer](../Companions/nollie-workflow/README.md) can add it to the
other non-private bots with `--recorder` or `--papertrail-bots`.

## What happens

- **In a chat.** The call waits for an approval card that says the whole action in plain words: who
  it goes to, what it says, the command it runs. The card offers Allow once and Deny. Each call gets
  its own fresh key, so no earlier answer (Session or Always included) covers a later one. On
  surfaces that still offer Always (Hermes's own command line), Always works as once, and leaves an
  unused entry in that bot's allow list.
- **A click on a labelled button.** The card adds a check: "You're about to press “Send”." It is read
  from the screen where the click lands, not from what the helper says it is clicking.
- **In a schedule, a Board task or any run nobody can answer.** The call is held and never done. The
  helper is told to say so in its report. While Night shift is on, schedules, Board tasks and their
  helpers are also listed in the morning as "Held: needs your yes", in the same plain words. Other
  runs nobody can answer (a single question from the command line, a webhook) say so only in their
  own reply.
- **With approvals switched off (YOLO).** Hermes would wave a card through, so Ask first holds the call
  instead and the helper is told to explain.
- **If the rule can't load,** the add-on refuses every call that could send, buy, post, delete or use
  a computer, rather than letting them run unchecked.
- **Board tools are exempt.** A Board worker commenting on or handing back its own task is not held.

## What counts

| Class | Examples the rules hold |
| :--- | :--- |
| Send | `mail`, `sendmail`, `msmtp`; `curl`/`wget`/`httpie` with data or POST; `scp` to another computer; Messages or Mail through `osascript`; `shortcuts run`; code using `smtplib`, `requests.post`, Twilio, Slack; MCP and connector tools named send, reply, forward, notify, submit; a click on Send, Reply, Submit, Share |
| Pay or buy | Stripe, PayPal and other payment hosts; checkout, pay, order and charge addresses; tools named buy, purchase, checkout, pay, transfer, subscribe, place order; a click on Buy, Pay, Place order, Checkout |
| Post | `git push`, `gh issue create` and friends, `npm publish` and other publishers; tools named publish, post, tweet, comment, upload, react; a click on Post, Publish, Tweet, Comment |
| Delete | `rm`, `find -delete`, `git clean`, `git branch -D`, `trash`, `mv` to the Trash, `docker rm`, `kubectl delete`, `terraform destroy`, SQL `DROP`/`DELETE`/`TRUNCATE`, disk erase; code using `shutil.rmtree`, `os.remove`; a patch that deletes a file; tools named delete, remove, trash, close account, cancel subscription; a click on Delete, Remove, Trash |

Replacing a file counts as deleting what it held: `write_file`, another server's `write_file`, a patch
that adds or moves a file onto one, and a command that writes over one (`>`, `tee` without `-a`, `cp`,
`mv`, `install` or `ditto` onto it) ask when the file was already there before this turn. A file the bot
made itself this turn, its own scratch folder (`<bot home>/cache/scratch`) and the computer's temporary
folders are free. A path that can't be checked (a container or another computer) asks.

Return or Enter on a computer is held when the screen shows any of those words (or Message, Chat, Order).
Cmd-Return and Ctrl-Return (send in most apps), Cmd-Shift-D (Mail) and Option-S (Outlook) are always held,
and so are Cmd-Backspace and Shift-Delete. A script run by name, a here-document and text piped into a shell
are read with the same rules. When the rules can't tell, they ask: a script they can't read, a program chosen
when the command runs (`$(which rm)`, `$TOOL`), text piped in from somewhere else, a tool that runs a whole
task or workflow, a click with no readable label, and any other server's click, key or page-script tool.

### Programs that run other code

A program the rules don't know asks, unless its own first words only look (`remindctl today`,
`box files:get`, `kubectl get`, `--help`). Common tools that do one job on the Mac (`ffmpeg`, `pandoc`,
`sips`, `soffice` and the rest of `KNOWN_PROGRAMS`) pass, unless they stream to another computer
(`rtmp://` and the like). What runs other code is read where it can be:

- `npm run`, `npm test`, `yarn <script>`, `pnpm`, `bun run`: the script from `package.json`, with its
  `pre` and `post` steps, read with the same rules. No package.json, or no such script, asks.
- `make` and `just`: the recipes for the targets asked for (and what they depend on) from the Makefile
  or justfile, with plain variables filled in. A recipe built at run time (`$(shell ...)`) asks.
- A program run by its path (`./tool`, `/Users/sam/bin/tool`): read as a script, with its `#!` line
  deciding the language. A compiled program, which can't be read, asks.
- `ssh host command`: the command is read as if it ran here.
- Installers and fetch-and-run tools ask: `npm install`, `pip install`, `brew install`, `npx`, `uvx`,
  `pipx run`, `cargo run`, `go run`, `swift run`, `docker run` and the other task runners (`rake`, `tox`,
  `gradle` beyond build and test). Building and testing (`cargo build`, `swift test`, `go test`) pass.
- In code: running a program the rules don't know asks, and so does running one chosen at run time
  (`subprocess.run(cmd)`, `os.system(command)`).

### Other servers' tools

An MCP server's or connector's tool asks unless its own name plainly only looks: a reading verb (get,
list, search, read, fetch, view and the like) and no changing verb before it (`get_order`,
`messages_list`, `API-post-search` pass; `sync_items`, `get_and_archive`, `API-patch-page` ask). Opening,
choosing and closing browser pages pass, and so do drafts and plain web page requests. What the tool said
about itself when Hermes registered it is read too, and can only add a reason to ask: a first sentence
that says it sends, deletes, posts or buys, or fields for someone to send to and something to say, make
it that kind. Nollie Computer and Cua's tools keep their own rules.

### OK, Continue and pages

A button that names no action (OK, Continue, Done, Yes, "Confirm and continue") is judged by what is
around it: the window or sheet in this Mac's latest capture, the dialog or form it sits in on a page, or
the words recognised near it on a Cua computer. When those name sending, buying, posting or deleting
("Delete 3 photos?", "Pay £24.00"), the card says so and quotes the line; when they can't be read, it
asks. On Hermes's own browser, a press on a button also reads the page's own form (its action address
and method, by a short script that only reads) and the page's address: a form that posts to a checkout,
payment, message, comment or delete address asks as that kind whatever the button says, and an OK or
Continue on a checkout page asks as paying.

False alarms are accepted: `rm` of a scratch file, `git push` to a private branch, `pytest -k delete`,
a read-only GraphQL POST, and Return in a shop's search box ask too. The
rules and their look-alikes are fixtures in
[`tests/fixtures/ask_first.json`](../Companions/nollie-workflow/tests/fixtures/ask_first.json): every
class has cases that must be held, and ordinary calls (searching, reading, `grep delete`, a draft) that
must not be. An adversarial review found 124 calls that slipped past an earlier version; all but one (a
bare Delete key) are held now and stay in the fixtures.

Everyday work stays quiet, and a test keeps it so
([`tests/fixtures/everyday.json`](../Companions/nollie-workflow/tests/fixtures/everyday.json),
`test_everyday.py`). Measured on 27 Oct 2026, before and after the rules above:

| Calls | Before | After |
| :--- | ---: | ---: |
| 94 everyday reading and tidying calls (web, files, terminal, code, MCP reads, browser, clicks on OK) | 0 cards | 0 cards |
| 50 look-alikes in the fixtures | 0 | 0 |
| 32 changes that don't send, buy, post or delete (installs, edits, builds, MCP writes) | 3 | 15 |
| 405 shell commands from Hermes's own skills | 99 | 209 |

The new cards on changes are two files replaced and thirteen `unsure` asks (installers, `docker compose
up`, a program chosen at run time, MCP tools that create or update). Of the 110 new cards on skills'
commands, all are `unsure`, mostly CLIs Nollie doesn't know that change things (Box, Notion's `ntn`,
`remindctl add`, `memo`). With a bot's Ask first switch off, only the two replaced files would ask.

## Where the label under a click comes from

| Computer | Source |
| :--- | :--- |
| A helper's own Cua computer | A fresh screenshot through Cua's command line, read with the Mac's own text recognition. The click's coordinates are in the screenshot's pixels, so the text in that spot is the label. The picture stays in memory for one reading. |
| This Mac, through Hermes's `computer_use` | The element labels from the helper's own latest capture, remembered from its result. |
| This Mac, through Nollie Computer | The Mac app reads the button's accessibility label itself and asks with Touch ID; its card shows the same check. See [Nollie Computer](nollie-computer.md). |
| Hermes's own browser | The accessible names from the helper's latest page snapshot. |

When nothing can be read (no capture yet, Cua unreachable, text recognition failed or found no words
at all, or no words near the click), the click asks, with "Nollie couldn't read a label there". What the
helper says it is clicking only words the card; it never lets a click through.

While a saved sign-in is being typed, Ask first never takes a screenshot: the click is held instead.

## Calendar, Reminders and Contacts

Adding, changing, completing or deleting anything in the Mac's calendar, reminders or contacts always
waits for a yes, whatever this switch says. Those tools ask for themselves with the Mac's own words for
the change, so these rules leave them alone (`APPLE_DATA`) and nothing is asked twice. Their cards use
the kinds `calendar`, `reminders` and `contacts`: "Scout wants to change your calendar". See
[Calendar, Reminders and Contacts](calendar-reminders-contacts.md).

## This Mac starts off

Hermes reads a bot with no desktop lease (`<bot home>/bot-desktop/lease.json`) as free to use the
screen. So a bot never starts without one: Nollie Runtime gives every bot that has none a person's lease
(holder `human`, epoch 1) at setup, when a bot is made and on every start, and the app does the same the
first time it reads a bot's This Mac switch on a Hermes it didn't set up (never for a Private bot there,
and never over a lease that appeared meanwhile). A lease the person or the bot already has stays. Until
the person turns This Mac on, Hermes refuses every screen action, captures included, before any card.

## What it can't see

Ask first reads names, arguments, files, pages and screens. It can't know everything a page means.

- **A click whose meaning only the page's code knows.** A button that names a harmless action ("Show
  more", "Save") whose script pays or sends without a form, a page whose words around an OK are
  themselves misleading, or an icon whose accessibility label says nothing risky. (An icon with no
  label at all asks.) Forms that only fetch a page never count.
- **Return in a box with no risky word on screen**, such as a chat field whose send button is an icon.
- **Single keys** a site or app defines, such as `#` or a bare Delete to remove a message in some mail
  apps, and drags (a file onto the Trash).
- **Text recognition mistakes.** A misread label is not held. On a Mac whose graphics are unwell,
  recognition returns nothing and every click on a Cua computer asks.
- **Programs that do more than their words say.** A known tool used in an unusual way, a program
  whose own first words look but whose flags change things, code downloaded or decoded inside a script
  it did read, a file written over by code (`open(path, "w")`) rather than by a command or file tool,
  and a script on another computer, which can't be read from here.
- **Another server's tool that lies.** A tool named `get_items` whose description also says nothing
  risky but which sends mail. Other Hermes add-ons' own tools (not MCP or connectors) are read by
  their names alone, as before.
- **Bots outside Nollie's setup without the add-on.** The rule runs only where nollie-workflow is
  installed and enabled, and someone running Hermes themselves can still turn the add-on off.
- **Quick pay**, when the person turns it on, skips the card for small payments to sites paid before.
- **Hermes's own delivery.** A schedule's result reaching the person through `send_message` is Hermes
  delivering the report, not a tool call, and is not held.
- **Changing account or security settings** is not one of the four classes. The helpers' instructions
  still say to ask; nothing enforces it yet.
- **A Board worker in its own process** is treated as unattended by the same checks, but that the
  add-on loads in those processes has not been checked end to end.

## Pieces

| Piece | Where |
| :--- | :--- |
| The rules and the hook | `Companions/nollie-workflow/ask_first.py` |
| Reading the screen | `Companions/nollie-workflow/screen_text.py`, `screen_text.js` |
| Registration, and the stand-in if it fails | `Companions/nollie-workflow/__init__.py` |
| One-time default, keeping the add-on on, the human lease | `Services/Runtime/managed_addons.py`; each bot's `nollie-workflow/ask-first-initialized` record |
| Settings switch and model | `Apps/Nollie/Chat/AskFirstSection.swift`, `Apps/Nollie/App/AskFirstModel.swift`; the bot's `nollie-workflow/ask-first.json` |
| Settings route | `GET` and `PUT /api/plugins/nollie-computer/ask-first?profile=<bot>`; kept outside workflow so it can turn workflow back on |
| The lease on a Hermes Nollie didn't set up | `Apps/Nollie/App/SystemControl.swift` |
| Night shift receipts | `receipts.py`, `recorder.py`, `night_shift.py` in the same add-on |
| The card | `Apps/Nollie/Chat/AskFirstCard.swift`, `AskFirstAsk` in NollieCore |
| Tests | `Companions/nollie-workflow/tests/test_ask_first.py`, `test_everyday.py`, `test_screen_text.py`, `test_night_plumbing.py`, `Companions/nollie-computer/tests/test_ask_first.py`, `Companions/nollie-crew/tests/`, `Tools/runtime-helper/test_managed_addons.py`, `Tests/Unit/AskFirstTests.swift`, `AskFirstSettingsTests.swift`, `SystemControlScopeTests.swift`, `Tests/UI/AskFirstUITests.swift` |

The approval reaches the app as an ordinary Hermes plugin approval: `pattern_key`
`plugin_rule:nollie-ask-first:<kind>:<id>` (kind `send`, `buy`, `post`, `delete`, `unsure`, or `calendar`,
`reminders` and `contacts` from the Mac's data tools; a fresh
32-character id) and the whole action in `description`, with the check line last when there is one.
