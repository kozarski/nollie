# Nollie Mac add-on

Lets a bot use a few apps on this Mac for one task, after the person approves them in Nollie.
Two small pieces, both installed as one Hermes plugin folder:

- `server.py`, an MCP server (stdio, standard library only) with three tools: `mac_start`,
  `mac_do` and `mac_done`. A bot never sees the screen: `mac_do(app, step)` asks for one step,
  a model on the Mac does the clicking, and only a short sentence comes back.
- `__init__.py`, a plugin hook. Hermes gives an MCP server no session context, so before every
  `mcp__nollie_mac__*` call the hook refuses scheduled (cron), single-query and other unattended
  runs, and stamps the call with its chat (`_nollie`), replacing anything the model wrote there.
  The server refuses any call without that stamp. A stamp alone proves nothing (a model could
  write one where the hook isn't loaded), so Nollie also asks Hermes about the session itself.

No Hermes source changes. Nothing runs on the Mac until the person turns Nollie Computer on (it is
off by default, in Beta) and says yes on the Mac with Touch ID. That yes is the boundary; Nollie's
checks on this process and on Hermes are defence in depth.

## How a task goes

1. `mac_start(apps, task)` asks Nollie through its socket,
   `~/Library/Application Support/Nollie/Computer/control.sock` (this user only). Nollie looks the
   session up in that bot's Hermes history and refuses a session it can't find, one from a
   scheduled, kanban or webhook run, or one whose latest turn isn't this very `mac_start` call
   still waiting for its answer. It also checks which process is asking: only this server, run by
   Hermes's own gateway or dashboard from the bot's plugin folder, so it must be added with the
   command below (not run by hand). The task then answers to that process alone. It also refuses at once when nobody is at the Mac (locked,
   asleep, or no keyboard or mouse use for 5 minutes), when the permissions are missing (it opens
   its walkthrough instead), or when every app is one it never offers. Otherwise it shows the approval card; no answer in two minutes is a no.
2. After a yes, Nollie starts Nollie Computer with a manifest of just those apps and returns a
   secret task id, which the server keeps per chat.
3. Each step goes to Nollie with that id. A model on this Mac looks at the window and picks each
   action; Nollie checks every one, asks the person first when it is risky, and runs it in its own
   trusted session with the helper. Only words come back, at most 300 characters. The add-on never reaches the
   helper: its shared socket allows nothing but a permission check, and only Nollie, its parent
   process, can open the sessions that act.
4. `mac_done`, Stop, 30 minutes, 5 idle minutes, the Mac locking or sleeping, or Nollie quitting
   end the task, and the helper process with it.

The rules (in Nollie, `Apps/Mac/Computer/`): never Nollie, terminals and coding tools, password
managers, System Settings, or money and crypto apps; browsers view-only; sending, buying, deleting,
uploading, accepting terms, installing and signing in confirmed by the person every time; nothing
typed into a password or code field.

## In Nollie's own setup

Nollie's setup carries the add-on in its Setup Kit (`Tools/pins.json`, checked against `kit.json`
like the others). At every start Nollie Runtime copies it into every bot that is not private
(`Services/Runtime/managed_addons.py`) and lists it, with its MCP server on Nollie's own Python
(`<setup>/python/<version>/bin/python3.14 -I <bot>/plugins/nollie-mac/server.py`), only in bots whose
desktop lease is the agent's: This Mac on. Turning This Mac on or off on the Mac applies it at once
for new chats (`ComputerManagedAddOn`); from the iPhone, at Hermes's next start. Nollie accepts it
from that Python only by its exact path and the hash its installer recorded, under the gateway or
dashboard this Nollie's Runtime started (`ComputerPeer.Managed`).

## Installation (a hand-installed ~/.hermes)

Plan first, for one bot:

```sh
python3 Companions/nollie-mac/install.py --profile career
```

After approving the change:

```sh
python3 Companions/nollie-mac/install.py --profile career --apply
```

That copies the three files to the bot's `plugins/nollie-mac`, keeps any older copy in
`plugin-backups`, and enables the plugin through Hermes. Then add the server with Hermes's own
command, which it prints (Hermes probes the server and asks to confirm):

```sh
hermes --profile career mcp add nollie-mac --command /usr/bin/python3 --args -I ~/.hermes/profiles/career/plugins/nollie-mac/server.py
```

Nothing is restarted. The server name must be `nollie-mac`, so the tools are named
`mcp__nollie_mac__*`, which is what the hook matches.

## Tests

```sh
python3 -m unittest discover -s Companions/nollie-mac/tests -v
```

The tests use a fake Nollie socket and injected Hermes context; they never touch a real Hermes.
