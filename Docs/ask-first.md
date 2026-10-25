# Ask first

[← Nollie](../README.md) · [Architecture](architecture.md) · [Nollie Computer](nollie-computer.md) · [Saved sign-ins](saved-sign-ins.md)

With Ask first on, sending, buying, posting or deleting waits for the person's yes. A Hermes hook in
the nollie-workflow add-on reads each tool call before it runs, by fixed rules, and holds the ones that
match. The model's own judgement is never asked.

## Which bots are covered

In a setup Nollie manages, Ask first starts on for the main bot and every other bot that is not Private.
The starter setup, Add a bot and the crew's new helpers all include it. Existing bots get it on the
first time this version of Nollie Runtime starts. Each bot keeps a small record that this has happened.
Later starts and add-on updates keep the person's choice, including when they disable nollie-workflow
or remove it from `plugins.enabled`. During setup, Nollie keeps a backup before changing a bot's
settings and leaves its other add-ons alone.

In **Bot settings → Instructions**, the **Ask first** switch shows that bot's current choice. Turning
it off asks, "Turn off Ask first for &lt;bot&gt;? It will send, buy, post and delete without asking." Choose
**Turn Off** or **Cancel**. Turning it on needs no question. A change applies to the bot's next calls;
it cannot undo something already sent. The switch changes nollie-workflow itself, so its other features,
including Papertrail and Board follow-through, also pause while it is off.

A new crew member keeps the main bot's safety rules and cannot gain permissions the main bot lacks.
Ask first also works in a bot whose copy has Papertrail off.

Private bots, including Moss, are left alone. They are not given add-ons and do not load these rules.
If the Private list cannot be read, setup stops instead of guessing which bots it may change.

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
- **If the rule can't load,** or the Private list is damaged, the add-on refuses every call that could
  send, buy, post, delete or use a computer, rather than letting them run unchecked.
- **Board tools are exempt.** A Board worker commenting on or handing back its own task is not held.

## What counts

| Class | Examples the rules hold |
| :--- | :--- |
| Send | `mail`, `sendmail`, `msmtp`; `curl`/`wget`/`httpie` with data or POST; `scp` to another computer; Messages or Mail through `osascript`; `shortcuts run`; code using `smtplib`, `requests.post`, Twilio, Slack; MCP and connector tools named send, reply, forward, notify, submit; a click on Send, Reply, Submit, Share |
| Pay or buy | Stripe, PayPal and other payment hosts; checkout, pay, order and charge addresses; tools named buy, purchase, checkout, pay, transfer, subscribe, place order; a click on Buy, Pay, Place order, Checkout |
| Post | `git push`, `gh issue create` and friends, `npm publish` and other publishers; tools named publish, post, tweet, comment, upload, react; a click on Post, Publish, Tweet, Comment |
| Delete | `rm`, `find -delete`, `git clean`, `git branch -D`, `trash`, `mv` to the Trash, `docker rm`, `kubectl delete`, `terraform destroy`, SQL `DROP`/`DELETE`/`TRUNCATE`, disk erase; code using `shutil.rmtree`, `os.remove`; a patch that deletes a file; tools named delete, remove, trash, close account, cancel subscription; a click on Delete, Remove, Trash |

Return or Enter on a computer is held when the screen shows any of those words (or Message, Chat, Order).
Cmd-Return and Ctrl-Return (send in most apps), Cmd-Shift-D (Mail) and Option-S (Outlook) are always held,
and so are Cmd-Backspace and Shift-Delete. A script run by name, a here-document and text piped into a shell
are read with the same rules. When the rules can't tell, they ask: a script they can't read, a program chosen
when the command runs (`$(which rm)`, `$TOOL`), text piped in from somewhere else, a tool that runs a whole
task or workflow, a click with no readable label, and any other server's click, key or page-script tool.

False alarms are accepted: `rm` of a scratch file, `git push` to a private branch, `pytest -k delete`,
a read-only GraphQL POST, and Return in a shop's search box ask too. The
rules and their look-alikes are fixtures in
[`tests/fixtures/ask_first.json`](../Companions/nollie-workflow/tests/fixtures/ask_first.json): every
class has cases that must be held, and ordinary calls (searching, reading, `grep delete`, a draft) that
must not be. An adversarial review found 124 calls that slipped past an earlier version; all but one (a
bare Delete key) are held now and stay in the fixtures.

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

## What it can't see

Ask first reads names, arguments and screens. It can't know what a page means.

- **A click whose meaning only the page knows.** A button labelled only Continue, Next, OK or Done, a
  word near the click that isn't the button's own label, or an icon whose accessibility label says
  nothing risky. (An icon with no label at all asks.)
- **Return in a box with no risky word on screen**, such as a chat field whose send button is an icon.
- **Single keys** a site or app defines, such as `#` or a bare Delete to remove a message in some mail
  apps, and drags (a file onto the Trash).
- **Text recognition mistakes.** A misread label is not held. On a Mac whose graphics are unwell,
  recognition returns nothing and every click on a Cua computer asks.
- **Programs that do more than their name says.** A compiled program, `make` or `npm run` targets
  (held only when the target's name says deploy, publish, delete and the like), shell aliases and
  functions, and code that is downloaded or decoded inside a script it did read.
- **A tool with a neutral name** whose arguments carry no action word and no one to send to, for
  example an MCP tool called `sync_items` that happens to send mail.
- **Bots outside Nollie's setup without the add-on.** The rule runs only where nollie-workflow is
  installed and enabled. Private bots never load it.
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
| One-time default | `Services/Runtime/managed_addons.py`; each bot's `nollie-workflow/ask-first-initialized` record |
| Settings switch and model | `Apps/Nollie/Chat/AskFirstSection.swift`, `Apps/Nollie/App/AskFirstModel.swift` |
| Settings route | `GET` and `PUT /api/plugins/nollie-computer/ask-first?profile=<bot>`; kept outside workflow so it can turn workflow back on |
| Night shift receipts | `receipts.py`, `recorder.py`, `night_shift.py` in the same add-on |
| The card | `Apps/Nollie/Chat/AskFirstCard.swift`, `AskFirstAsk` in NollieCore |
| Tests | `Companions/nollie-workflow/tests/test_ask_first.py`, `test_screen_text.py`, `test_night_plumbing.py`, `Companions/nollie-computer/tests/test_ask_first.py`, `Companions/nollie-crew/tests/`, `Tools/runtime-helper/test_managed_addons.py`, `Tests/Unit/AskFirstTests.swift`, `AskFirstSettingsTests.swift`, `Tests/UI/AskFirstUITests.swift` |

The approval reaches the app as an ordinary Hermes plugin approval: `pattern_key`
`plugin_rule:nollie-ask-first:<kind>:<id>` (kind `send`, `buy`, `post`, `delete` or `unsure`; a fresh
32-character id) and the whole action in `description`, with the check line last when there is one.
