# Core models group: behaviour specs

Plain-English specs written before the files were replaced. API names stay as callers use them.

## Package.swift
One library product, NollieCore, iOS 26 and macOS 26, Swift 6 language mode, one target whose
sources live in Sources/NollieCore and whose only resource is the character resources folder.
No UI frameworks in the package; platform behaviour comes in through the protocols in Runtime/Hooks.swift.

## Models/JSONValue.swift
A dynamically typed JSON value (string, number, bool, null, array, object), Codable, Hashable,
Sendable, printable. Decodes any JSON; numbers are doubles; encodes whole numbers below 2^53 as integers.
Accessors: key subscript (objects), index subscript (arrays, bounds-safe), stringValue, doubleValue
(number or numeric string), intValue, boolValue (bool, nonzero number, or true/1/yes/on text),
arrayValue, objectValue, isNull, displayText, prettyPrinted (sorted keys, unescaped slashes), description.
decode(T) re-encodes and decodes with the shared snake_case decoder; static encode(T) goes the other way.
init(any:) builds from Foundation values. Literal conformances for string, int, float, bool, array,
dictionary and nil. Dictionary extension compactingNulls drops null entries. JSONCoding holds the
shared decoder (from snake case) and encoder (to snake case). foundationValue gives plist-friendly values.
Tests: the transport, remote and chat suites use it throughout.

## Models/BotPalette.swift
Ten default hex colours, and a deterministic pick by profile name (djb2-style hash over UTF-8,
modulo the count) so every device draws the same bot the same colour.

## Models/Projects.swift
Project (id, slug, name, description, icon, color, primaryPath, archived, createdAt, folders with
path/label/isPrimary), isArchived, startPath (primary path, else primary folder, else first folder),
hue (number inside the `hsl(` colour, mod 360, over 360). ProjectsListResponse (projects, activeId),
ProjectTreeNode (id, label, isAuto, isNoProject, sessionIds), ProjectsTreeResponse.

## Runtime/ProjectsStore.swift
Observable store of the selected bot's projects and which stored chat sits in which project.
available is nil until refresh, false on a method-not-found answer (-32601), true otherwise. refresh
loads list then tree. refreshTree reads membership (skips auto groups and the Home bucket).
refreshOthers(profiles) keeps projects and membership of the other bots by name (Scope), dropping
bots no longer asked for. Lookups: open, project(id:), project(forSession:), open(for:), projectID(forSession:).
move(sessionIDs, to:, profile:) moves chats' working folder with session.workspace.move to the project's
start path, or to the bot's own cwd (config.get key project) for none; shows result at once, then reads
the tree; throws MoveError (unsupported, noFolder, stillInProject); sets canMove false on method-not-found.
Tests: ProjectsTests.

## Runtime/KanbanStore.swift (and Models/Kanban.swift)
Kanban models: KanbanStatus (columns order, titles, symbols, move targets, not-movable reasons, asks
for summary, asks to confirm), KanbanTask and its parts, board, boards, comments, events (timeline
line text), runs, links, workers, logs, stats, events frame, KanbanNewTask and KanbanTaskPatch (json
bodies, patch only sends set fields; assignee double optional), KanbanAPI (routes under
/api/plugins/kanban with optional board query) and KanbanEventCursor (socket cursor).
KanbanStore: availability probe (404 means absent) cached per gateway in defaults, board choice
remembered per gateway, one shared in-flight read of board plus workers, live socket with backoff
and 300 ms coalesced refetch, background activity polling every 8 s (boards every 60 s) while permitted,
writes (move, priority, edit, reassign, comment, delete, create, stop, nudge) each followed by a read
and a dispatcher nudge, the server's words kept in lastError and lastRefusal. Tests: KanbanTests.

## Models/WireTypes.swift
Typed views of gateway answers: Usage, SessionLiveInfo, TranscriptMessage (decodes both the socket's
flat shape and the REST stored-row shape: content as string or parts, id, ISO timestamps, tool name in
tool_calls, display metadata markers, args as text or json, blank reasoning is absent), StoredSession
(displayTitle, lastDate), list and message responses, ApprovalRequest (choices default, alwaysScope
words), ClarifyQuestion/Request, ValuePromptRequest, model and provider options, profiles, auth
responses and providers, gateway status, native token, toolsets, skills, env var rows (hasValue, preview
strips the redaction wrapper), MCP servers, cron jobs, config schema, context breakdown, files listing,
upload result, commands catalog and dispatch result, Usage.computedContextPercent, usage analytics,
plugins hub. Everything optional on the wire is optional. Tests: HermesRemoteTests and others.

## Runtime/GatewayRuntime.swift
The live state for the active gateway: REST client, socket, profiles, open chats, attention set,
platform hooks, maintenance, projects, kanban. Handles auth refresh (with optional sign-in-again hook),
managed and linked endpoint resolution before each socket attempt, ws tickets for the main and plugin
sockets and the live-picture target, start/stop/reconnect, capability advertising, code-skew probe,
default bot, gateway identity, profile loading, rpc helpers (selected bot or a named owner), owner
lookup for a stored chat, chat open/new/close, event batch handling, server-request answering (app
auto-answer, open chats, unopened sessions) and notification names. Tests: GatewayRuntimeTests and others.

## Runtime/PushRelay.swift
Legacy encrypted-notification support: credentials in the keychain (install id, secret, payload key),
invitation save and validation (32 to 128 chars of letters, digits, dash, underscore), relay url is
disabled, registration/unregistration calls (no-ops without a url), registrationError mapping, AES-GCM
payload decrypt, RelayError texts. Tests: PushRelayEnrollmentTests, PushRelayCryptoTests.

## Runtime/Maintenance.swift
Observable MaintenanceModel running "update Hermes" and "restart gateway" via the dashboard, tailing
the action status every 2 s with a deadline (15 min, 2 min for restart), treating transport errors as
restarting, finishing early on request, reconnecting when done. isRestartRequired text check.

## Runtime/Hooks.swift
Protocols for turn activity, card notifications and push registration with default no-op extension
methods, plus NoTurnActivity.

## Runtime/ChatRegistry.swift
ChatIdentity protocol and a registry of open chats found by runtime id or by stored id (including
earlier stored ids). Scans, never keys by runtime id. add replaces same stored id; remove by identity.

## Runtime/MainChat.swift
MainChatLookup (found, missing, unknown) and GatewayRuntime.mainChat(profile:) / mainChatID: ask
profiles.list for canonical_session, else the "Bot Chat" titled chat in recent sessions, else a title search.

## Where the new code lives
The specs above describe behaviour. The replacement code is split like this:
- Models/WireTypes.swift (usage, chats, messages), WireRequests.swift (approval, clarify, value prompts),
  WireAccount.swift (models, bots, sign-in), WireSettings.swift (toolsets, keys, cron, config, files,
  commands, analytics, plugins).
- Models/Kanban.swift (status, task, board), KanbanTaskDetail.swift (comments, events, runs, links),
  KanbanWorkers.swift (assignees, workers, log, stats), KanbanAPI.swift (request bodies, event cursor,
  the plugin's routes).
- Runtime/KanbanStore.swift (reads, availability), KanbanStore+Writing.swift (changes), KanbanLive.swift
  (the live socket and the activity watch).
- Runtime/GatewayRuntime.swift (state, start and stop, calls) with extensions: +Auth (sessions and socket
  tickets), +Endpoints (managed and linked addresses, away from home), +Bots (profiles, identity, chat
  owner lookup), +Capabilities, +Chats, +Events (events and server requests); GatewayNotifications.swift
  holds the notification names.
- Runtime/Hooks.swift: CardNotifying is now a composition of CardArrivalNotifying and TurnEndNotifying.
