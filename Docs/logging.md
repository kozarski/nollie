# Logging

Nollie logs through one subsystem, `com.coreykozarski.nollie`, so the app, the demo copy, the
extensions and the Mac runtime helper all show up under one filter.

## Watch it in Console

1. Open Console, pick the Mac (or the iPhone, plugged in) in the sidebar, and press Start.
2. In the search field, type `subsystem:com.coreykozarski.nollie`. Add `category:chat` (or any
   category below) to narrow it.
3. In the Action menu, turn on **Include Info Messages** and **Include Debug Messages**. Without
   them only notice and above show.

From a terminal: `log stream --level debug --predicate 'subsystem == "com.coreykozarski.nollie"'`.
Add `--info` or `--debug` to `log show` for the past.

## Categories

`app`, `connection`, `chat`, `runtime`, `helpers`, `computer` (using the Mac), `alerts`, `pairing`,
`link`, `board`, `intents`, `updates`, `perf`.

## Writing a log line

```swift
import NollieCore

NollieLog.chat.info("Reply arrived")
NollieLog.connection.error("Sign-in refused", detail: "\(host) answered \(status)")
```

Pick the channel for the part of Nollie you are in. `NollieLog.channel(.board)` also works.

| Level | Use it for |
| --- | --- |
| `debug` | Noisy steps you only want while chasing something. |
| `info` | Ordinary steps. |
| `notice` | What is worth keeping if something goes wrong later. |
| `error` | A failure Nollie recovers from or shows. |
| `fault` | Something that should never happen. |

## Privacy

A log can end up in someone else's hands (a shared diagnostics file), so:

- Never a token, key, password, cookie or sign-in code, in the message or the detail.
- The **message** is public and plain: what happened, with numbers or states at most. No chat text,
  names, paths, hosts or addresses.
- Anything personal that helps find the cause goes in **`detail`**. The system keeps it private. The
  Mac log files show it as `<private>` in Release and in full only in a Debug build.
- Build the message from fixed words. Do not log whole responses, requests or error objects in it;
  put them in `detail`.

## Mac log files

Notice-and-above entries are also written to `~/Library/Logs/Nollie/`, which Console shows under
**Log Reports**:

| File | Written by |
| --- | --- |
| `Nollie.log` | The app (`Nollie Demo.log` for the demo copy) |
| `Nollie Runtime.log` | The runtime helper |
| `Hermes/` | A link to the managed Hermes's own `logs` folder (agent, errors, gateway), kept up to date by the helper |

Hermes writes the start of each message into its own logs (the first 80 characters in `agent.log` and `gateway.log`,
the first 100 of a schedule's prompt) and has no setting to stop it. The workflow add-on installs a log record
factory in every Hermes process it loads in (`Companions/nollie-workflow/log_privacy.py`) that writes `[left out]`
in their place: every log line in the pinned Hermes that passes a slice of a message, prompt, reply or body (a test
finds them in the source), any `msg=` field, and anything quoting 16 or more characters of a recent message or reply.
Lines written before the add-on loads, or by a Hermes without it, are not covered.

Each file rotates at 10 MB and five are kept (`Nollie.1.log` is the previous one). The folder is
0700 and the files 0600. Writing happens on a background queue. The app starts it with
`NollieLogFiles.start(.app)` and the helper with `NollieLogFiles.start(.runtimeHelper)`. The iPhone
has no files: use Console or Diagnostics.

## Diagnostics

Settings › About › Diagnostics makes one text file for the last 24 hours and offers Share. It holds the
app version and build, the system and device model, whether a gateway is connected (never which), the
app's own system log entries since launch, and on the Mac the tail of each file above. From Hermes's
files only warnings and errors are included, as a second guard should a line quote a chat. Everything
passes through `LogRedactor`, which hides bearer tokens, `sk-` and `ghp_` keys, `token=` and
`password=` values, long hex and base64 strings and email addresses. Add a case to
`LogRedactorTests` when a new kind of secret turns up.

## Code

`Packages/NollieCore/Sources/NollieCore/Logging/`: `NollieLog` (channels), `LogFileWriter`
(rotation), `NollieLogFiles` (Mac startup), `HermesLogLink`, `LogRedactor`, `DiagnosticsReport`.
The runtime helper compiles these files directly rather than linking NollieCore, so a new file the
helper needs must also be added to its target.
