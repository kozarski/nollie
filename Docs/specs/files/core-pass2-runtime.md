# Core runtime, second pass

What changed in each file, in plain words. Behaviour is the same as before.

- KanbanStore: the board and its workers are swapped as one piece. Lookups walk the lists in a
  plain loop. The plugin socket request now comes ready-made from the runtime.
- KanbanStore+Writing: a change is sent, the board read, and only then are the server's words
  stored (the read clears older errors). Clearing and keeping the words each have one helper.
  A move builds its patch from one note, picked by status.
- GatewayRuntime: the socket hooks are built as separate named closures. Call parameters are
  built by adding the bot to a copy and dropping nulls.
- GatewayRuntime+Auth: both main-socket addresses come from one signing helper. The plugin
  socket request is built from a key name and a secret. A refused socket is looked for in two
  views of its state.
- GatewayRuntime+Bots: stores are asked one by one in a helper that returns the live or
  archived holders and the last trouble. The live holder wins over an archived one.
- GatewayRuntime+Capabilities, +Events, +Chats: small regroupings (plugin refresh step,
  notification posting helper, chat opening names).
- Maintenance: each action is a plain description (name, label, route, patience) instead of
  a switch per property. Starting, polling and the closing verdict are separate steps.
- PushRelay: credentials get an explicit initialiser; sealed payloads are opened through one
  list of decoded parts. The device file fields are built from named parts.
- ProjectsStore, Hooks: field order and parameter names changed only.

Public API is unchanged. What still matches the old code is public signatures other code calls.
