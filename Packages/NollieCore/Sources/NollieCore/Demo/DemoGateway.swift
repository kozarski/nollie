import Foundation

/// A gateway that lives inside the app, for "Try a demo". It answers the same REST calls and the
/// same JSON-RPC socket a Hermes gateway does, from a small made-up world, so every screen runs
/// its normal code and nothing is special-cased in a view. It never touches the network, the
/// Keychain, or any real gateway or chat.
///
/// The REST side is in `DemoGateway+REST.swift`, the scripted replies in `DemoGateway+Turns.swift`
/// and the doors it is reached through (a URL protocol and a socket transport) in
/// `DemoTransport.swift`.
public actor DemoGateway {
    struct Fault: Error {
        var code: Int
        var message: String
    }

    /// A chat currently open on the gateway, shared among all sockets that resumed it.
    struct Live {
        var id: String
        var stored: String
        var profile: String
        var members: Set<ObjectIdentifier> = []
        var running = false
        var turnStartedAt = 0.0
        var inflight: JSONValue?
        var openFrames: [String: JSONValue] = [:]
        var outputTokens = 0
    }

    /// The made-up address every demo runtime uses. Nothing resolves it: the URL protocol answers
    /// first, and the name can never reach a real server.
    public nonisolated let host: String

    let started: Double
    var chats: [DemoSeed.Chat]
    var lives: [String: Live] = [:]
    var channels: [ObjectIdentifier: DemoChannel] = [:]
    var waiters: [String: CheckedContinuation<String, Never>] = [:]
    var replies = 0
    var kanban: DemoKanban
    var schedules: [JSONValue]
    var askFirst: [String: Bool] = [:]
    var seededAsk = false
    var closed = false
    /// Paces the replies: the typing bubble, words a few at a time, a moment per step. Tests pass a clock that does
    /// not wait, so a turn takes no real time and nothing hangs on how busy the computer is.
    let pace: any Clock<Duration>

    public init(pace: any Clock<Duration> = ContinuousClock()) {
        self.pace = pace
        let id = UUID().uuidString.prefix(8).lowercased()
        host = "demo-\(id).nollie.invalid"
        let now = Date().timeIntervalSince1970.rounded(.down)
        started = now
        chats = DemoSeed.chats(now: now)
        kanban = DemoKanban(now: now)
        schedules = DemoRoutes.schedules(now: now)
    }

    /// The address the demo's runtime connects to.
    public nonisolated var address: GatewayURL {
        // The host is built here and always valid.
        (try? GatewayURL.normalize("https://\(host)")) ?? (try! GatewayURL.normalize("https://demo.nollie.invalid"))
    }

    /// The two doors a runtime opens to reach this gateway.
    public nonisolated var backend: GatewayBackend {
        DemoGateways.register(self)
        return GatewayBackend(urlSession: DemoGateways.session(), transport: DemoTransport(gateway: self))
    }

    /// Ends every sleeping turn and closes every socket. The runtime calls this when the demo ends.
    public func shutdown() {
        closed = true
        for (_, waiting) in waiters { waiting.resume(returning: "deny") }
        waiters = [:]
        for (_, channel) in channels { channel.close(code: 1001) }
        channels = [:]
        DemoGateways.unregister(host)
    }

    // MARK: Sockets

    func attach(_ channel: DemoChannel) {
        channels[ObjectIdentifier(channel)] = channel
        channel.push(Self.event("gateway.ready", session: "", payload: [
            "skin": ["name": "default"], "change_events": true, "heartbeat": true, "replay_epoch": .string(UUID().uuidString.prefix(8).lowercased()),
        ]))
    }

    func detach(_ channel: DemoChannel) {
        let key = ObjectIdentifier(channel)
        channels[key] = nil
        for id in lives.keys { lives[id]?.members.remove(key) }
    }

    /// One message from the app: a call to answer, or the answer to a question asked of it.
    func receive(_ text: String, from channel: DemoChannel) async {
        for piece in text.split(separator: "\n") {
            guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(piece.utf8)) else { continue }
            if frame["method"] == nil, let id = frame["id"]?.stringValue {
                settle(request: id, with: frame["result"]?["choice"]?.stringValue ?? "deny")
                continue
            }
            guard let method = frame["method"]?.stringValue, let id = frame["id"] else { continue }
            do {
                let result = try await call(method, frame["params"] ?? [:], from: channel)
                channel.push(Self.encode(["jsonrpc": "2.0", "id": id, "result": result]))
            } catch let fault as Fault {
                channel.push(Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(fault.code)), "message": .string(fault.message)]]))
            } catch {
                channel.push(Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": "That did not work."]]))
            }
        }
    }

    private func call(_ method: String, _ params: JSONValue, from channel: DemoChannel) async throws -> JSONValue {
        let bot = params["profile"]?.stringValue ?? "default"
        switch method {
        case "ping", "gateway.ping": return ["pong": true, "ok": true]
        case "client.capabilities":
            return ["server_requests": ["approval", "clarify"], "declines_not_shown": true]
        case "gateway.capabilities": return ["per_session_exclusive_submit": true]
        case "profiles.list": return profilesList()
        case "session.active_list":
            return ["sessions": .array(lives.values.map { live in
                ["id": .string(live.id), "session_key": .string(live.stored), "title": .string(chat(live.stored)?.title ?? ""),
                 "source": "ios", "status": live.running ? "streaming" : "idle", "current": false]
            })]
        case "config.get": return configGet(params, bot: bot)
        case "config.set": return configSet(params, bot: bot)
        case "session.create": return create(bot: bot, channel: channel)
        case "session.resume", "session.activate":
            return try await resume(params["session_id"]?.stringValue ?? "", bot: bot, channel: channel, omit: params["omit_messages"]?.boolValue == true)
        case "session.usage": return Self.usage(output: lives[params["session_id"]?.stringValue ?? ""]?.outputTokens ?? 0)
        case "session.context_breakdown": return contextBreakdown()
        case "session.list": return ["sessions": .array(chats.map(sessionRow))]
        case "session.title": return title(params)
        case "session.interrupt": return ["status": "interrupted", "interrupted": true]
        case "session.close", "session.delete":
            let id = params["session_id"]?.stringValue ?? ""
            lives[id]?.members.remove(ObjectIdentifier(channel))
            return ["closed": true, "deleted": .string(id)]
        case "session.workspace.move": return ["cwd": params["cwd"] ?? "", "branch": nil, "git_repo_root": nil]
        case "projects.list": return ["projects": [], "active_id": nil]
        case "projects.tree": return projectsTree()
        case "projects.create", "projects.update", "projects.archive", "projects.delete", "projects.set_active", "projects.get":
            return ["projects": [], "active_id": nil]
        case "commands.catalog": return Self.commandCatalog
        case "slash.exec": return ["output": "That command isn't part of the demo.", "warning": ""]
        case "command.dispatch": return ["type": "exec", "output": "That command isn't part of the demo."]
        case "prompt.submit": return try submit(params)
        case "approval.pending": return approvalPending(params)
        case "approval.respond":
            let request = params["request_id"]?.stringValue ?? ""
            let frame = lives.values.flatMap { $0.openFrames }.first { $0.value["params"]?["request_id"]?.stringValue == request }
            guard let frameID = frame?.key else { return ["resolved": 0] }
            settle(request: frameID, with: params["choice"]?.stringValue ?? "deny")
            return ["resolved": 1]
        case "approval.received": return ["acknowledged": true]
        case "image.attach_bytes", "pdf.attach", "file.attach":
            throw Fault(code: -32000, message: "Attachments are not part of the demo.")
        default:
            throw Fault(code: -32601, message: "unknown method: \(method)")
        }
    }

    // MARK: Looking things up

    func chat(_ id: String) -> DemoSeed.Chat? {
        chats.first { $0.id == id }
    }

    func chatIndex(_ id: String) -> Int? {
        chats.firstIndex { $0.id == id }
    }

    func live(for stored: String) -> Live? {
        lives.values.first { $0.stored == stored || $0.id == stored }
    }

    static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    func preview(of chat: DemoSeed.Chat) -> String {
        let last = chat.rows.last { $0.role == "assistant" && !$0.text.isEmpty } ?? chat.rows.last
        return String(Self.clean(last?.text ?? "").prefix(120))
    }

    func sessionRow(_ chat: DemoSeed.Chat) -> JSONValue {
        [
            "id": .string(chat.id), "title": .string(chat.title), "preview": .string(preview(of: chat)),
            "source": .string(chat.source), "model": .string(DemoSeed.model),
            "started_at": .number(chat.startedAt), "last_active": .number(chat.lastActive),
            "message_count": .number(Double(chat.rows.count)), "is_active": false,
            "archived": .bool(chat.archived), "pinned": .bool(chat.pinned),
            "profile": .string(chat.profile), "cwd": .string(chat.cwd),
        ]
    }

    func profilesList() -> JSONValue {
        .object(["profiles": .array(DemoSeed.bots.map { bot in
            let main = chat(bot.main)
            return [
                "name": .string(bot.name), "is_default": .bool(bot.name == "default"),
                "canonical_session": [
                    "id": .string(bot.main), "resolved_id": .string(bot.main),
                    "title": .string(main?.title ?? ""), "message_count": .number(Double(main?.rows.count ?? 0)),
                ],
            ]
        })])
    }

    func projectsTree() -> JSONValue {
        let home: JSONValue = [
            "id": "__no_project__", "label": "Home", "isAuto": false, "isNoProject": true,
            "sessionCount": .number(Double(chats.count)), "sessionIds": .array(chats.map { .string($0.id) }),
        ]
        return ["projects": [home], "active_id": nil, "scoped_session_ids": []]
    }

    func configGet(_ params: JSONValue, bot: String) -> JSONValue {
        switch params["key"]?.stringValue {
        case "profile": return ["home": "/home/demo/.hermes", "display": .string(bot)]
        case "project": return ["cwd": "/home/demo", "branch": nil]
        default: return ["value": "", "config": DemoRoutes.config]
        }
    }

    func configSet(_ params: JSONValue, bot: String) -> JSONValue {
        let value = params["value"]?.stringValue ?? ""
        return ["key": params["key"] ?? "", "value": .string(value), "info": info(title: "", running: false, bot: bot)]
    }

    func title(_ params: JSONValue) -> JSONValue {
        let id = params["session_id"]?.stringValue ?? ""
        guard let live = lives[id], let at = chatIndex(live.stored), let words = params["title"]?.stringValue, !words.isEmpty else {
            return ["title": ""]
        }
        chats[at].title = words
        emit(live, "session.title", ["session_id": .string(live.stored), "title": .string(words)])
        return ["title": .string(words)]
    }

    func contextBreakdown() -> JSONValue {
        let rows: [(String, String, Int, String)] = [("system", "System prompt", 4_820, "blue"), ("tools", "Tools", 6_140, "purple"),
                                                      ("skills", "Skills", 2_260, "teal"), ("conversation", "Conversation", 1_200, "orange"),
                                                      ("free", "Free", 185_580, "gray")]
        return [
            "categories": .array(rows.map { ["id": .string($0.0), "label": .string($0.1), "tokens": .number(Double($0.2)), "color": .string($0.3)] }),
            "context_max": 200_000, "context_percent": 7, "context_used": 14_420, "estimated_total": 14_420,
            "context_estimated": false, "context_source": "demo", "model": .string(DemoSeed.model), "context_files": [],
        ]
    }

    static let commandCatalog: JSONValue = [
        "pairs": [["new", "Start a new chat"], ["status", "Show session status"], ["usage", "Show token usage"]],
        "categories": [], "canon": ["/new": "/new"],
        "commands": ["/new": ["argument_mode": "text", "desktop": nil], "/status": ["argument_mode": nil, "desktop": nil],
                     "/usage": ["argument_mode": "text", "desktop": nil]],
        "skills": [:], "skill_count": 0, "warning": "",
    ]

    // MARK: Sessions

    func info(title: String, running: Bool, bot: String) -> JSONValue {
        [
            "model": .string(DemoSeed.model), "provider": .string(DemoSeed.provider), "reasoning_effort": "medium",
            "reasoning_effort_wire": "medium", "service_tier": "", "fast": false, "yolo": false, "approval_mode": "smart",
            "tools": [:], "skills": [:], "cwd": "/home/demo", "branch": nil, "terminal_backend": "local", "personality": "",
            "running": .bool(running), "title": .string(title), "stored_session_id": "", "version": "demo", "release_date": "",
            "update_command": "", "usage": Self.usage(output: 0), "profile_name": .string(bot), "mcp_servers": [], "lazy": false,
        ]
    }

    static func usage(output: Int) -> JSONValue {
        let used = 14_420 + 4 * output
        return [
            "model": .string(DemoSeed.model), "input": 12_800, "output": .number(Double(output)), "reasoning": 0,
            "total": .number(Double(12_800 + output)), "calls": 1, "compressions": 0, "context_used": .number(Double(used)),
            "context_max": 200_000, "context_percent": .number(Double(used * 100 / 200_000)), "context_source": "demo",
            "context_estimated": false, "cache_hit_pct": 0, "avg_tps": 40.0, "cost_usd": 0.0, "cost_status": "estimated",
        ]
    }

    func create(bot: String, channel: DemoChannel) -> JSONValue {
        let stored = "demo-" + UUID().uuidString.prefix(8).lowercased()
        let runtime = String(UUID().uuidString.prefix(8).lowercased())
        let now = Date().timeIntervalSince1970
        chats.append(DemoSeed.Chat(id: stored, profile: bot, title: "New chat", startedAt: now, lastActive: now, rows: []))
        var live = Live(id: runtime, stored: stored, profile: bot)
        live.members.insert(ObjectIdentifier(channel))
        lives[runtime] = live
        return ["session_id": .string(runtime), "stored_session_id": .string(stored), "message_count": 0, "messages": [],
                "info": info(title: "New chat", running: false, bot: bot)]
    }

    func resume(_ requested: String, bot: String, channel: DemoChannel, omit: Bool) async throws -> JSONValue {
        let stored = chat(requested)?.id ?? live(for: requested)?.stored
        guard let stored, let chat = chat(stored) else { throw Fault(code: 4007, message: "session not found") }
        await seedAskIfNeeded()
        var live = self.live(for: stored) ?? Live(id: String(UUID().uuidString.prefix(8).lowercased()), stored: stored, profile: chat.profile)
        live.members.insert(ObjectIdentifier(channel))
        lives[live.id] = live

        var result: [String: JSONValue] = [
            "session_id": .string(live.id), "stored_session_id": .string(stored), "message_count": .number(Double(chat.rows.count)),
            "messages": omit ? [] : .array(chat.rows.map(Self.flatRow)),
            "info": info(title: chat.title, running: live.running, bot: chat.profile),
            "running": .bool(live.running), "resumed": .string(requested),
            "open_requests": .array(live.openFrames.map { ["id": .string($0.key), "method": $0.value["method"] ?? "approval", "params": $0.value["params"] ?? [:]] }),
        ]
        if live.running {
            result["turn_started_at"] = .number(live.turnStartedAt)
            result["inflight"] = live.inflight ?? .null
        }
        return .object(result)
    }

    /// A stored row as `session.resume` lists it.
    static func flatRow(_ row: DemoSeed.Row) -> JSONValue {
        var out: [String: JSONValue] = ["role": .string(row.role), "text": .string(row.text), "timestamp": .number(row.at), "row_id": .number(Double(row.id))]
        if row.role == "tool" {
            out["name"] = .string(row.name ?? "tool")
            out["context"] = .string(row.context ?? "")
            if let args = row.args { out["args"] = args }
        }
        return .object(out)
    }

    /// A stored row as the messages page lists it. The two shapes share their keys.
    static func pageRow(_ row: DemoSeed.Row) -> JSONValue {
        var out = flatRow(row).objectValue ?? [:]
        out["id"] = .number(Double(row.id))
        out["content"] = .string(row.text)
        return .object(out)
    }

    // MARK: Approvals

    func approvalPending(_ params: JSONValue) -> JSONValue {
        let wanted = params["session_id"]?.stringValue ?? ""
        let frames = live(for: wanted)?.openFrames.values.filter { $0["method"]?.stringValue == "approval" } ?? []
        return ["approvals": .array(frames.compactMap { $0["params"] })]
    }

    /// The answer to a question the gateway asked, from this app or from a call. Wakes the turn waiting on it.
    func settle(request id: String, with choice: String) {
        for key in Array(lives.keys) { lives[key]?.openFrames[id] = nil }
        waiters.removeValue(forKey: id)?.resume(returning: choice)
    }

    // MARK: Sending frames

    func emit(_ live: Live, _ type: String, _ payload: JSONValue? = nil) {
        let text = Self.event(type, session: live.id, payload: payload)
        for key in live.members { channels[key]?.push(text) }
    }

    static func event(_ type: String, session: String, payload: JSONValue?) -> String {
        var params: [String: JSONValue] = ["type": .string(type), "session_id": .string(session)]
        if let payload { params["payload"] = payload }
        return encode(["jsonrpc": "2.0", "method": "event", "params": .object(params)])
    }

    static func encode(_ value: JSONValue) -> String {
        RPCFrames.encode(value)
    }
}
