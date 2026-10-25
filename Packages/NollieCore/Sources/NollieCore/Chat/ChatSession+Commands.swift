import Foundation

/// A typed `/command` taken apart.
private struct SlashInvocation {
    let body: String
    let name: String
    /// Everything after the name, if there is anything.
    let argument: String?

    init(_ text: String) {
        body = String(text.dropFirst())
        let pieces = body.split(separator: " ", maxSplits: 1)
        name = pieces.first.map { $0.lowercased() } ?? ""
        argument = pieces.dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The argument, when there is a non-empty one.
    var given: String? { argument.flatMap { $0.isEmpty ? nil : $0 } }
}

extension ChatSession {
    // MARK: Slash commands

    private func commandsCatalog() async -> CommandsCatalog? {
        let fetched: CommandsCatalog? = try? await ask("commands.catalog").decode()
        if let fetched { catalogCache = fetched }
        return fetched
    }

    /// Why a command the gateway marks as not for the app is not run, in words for the person.
    private static func reason(forDesktopFlag flag: String) -> String {
        let reasons = ["terminal": "it needs the terminal",
                       "settings": "use Settings instead",
                       "composer-voice": "use the mic button instead",
                       "messaging": "it is part of the messaging setup"]
        return reasons[flag] ?? "the app cannot run it"
    }

    /// Executes a typed `/command`. Some commands belong to this app: approve, stop, title, model,
    /// plus a handful more. Anything else is forwarded to the gateway's `slash.exec`, which knows
    /// the built-in, plugin and quick commands. `command.dispatch` is an older route that only
    /// covers skills, bundles, plugins and quick commands; it is used when the gateway asks (skills)
    /// and for everything on gateways that lack `slash.exec`. Result: text to prefill, if any.
    func dispatchSlash(_ text: String, depth: Int = 0) async -> String? {
        let typed = SlashInvocation(text)
        if await runOwnCommand(typed) { return nil }

        if catalogCache == nil { _ = await commandsCatalog() }
        if let flag = catalogCache?.commands?["/" + typed.name]?.desktop, flag != "hidden" {
            addNote("/\(typed.name): \(Self.reason(forDesktopFlag: flag)).", symbol: "info.circle")
            return nil
        }
        do {
            let answer = try await ask("slash.exec", ["command": .string(typed.body)])
            if answer.text("type") != nil, let result = try? answer.decode(CommandDispatchResult.self) {
                return await carryOut(result, for: typed, depth: depth)
            }
            var printed = answer.text("output") ?? ""
            if let warning = answer.text("warning"), !warning.isEmpty {
                printed = printed.isEmpty ? warning : warning + "\n\n" + printed
            }
            addNote(printed.isEmpty ? "/\(typed.name) done" : printed)
            return nil
        } catch let failure as RPCError where Self.needsCommandDispatch(failure) {
            return await dispatchViaCommand(typed, depth: depth)
        } catch {
            addFailure("/\(typed.name): \(error.localizedDescription)")
            return nil
        }
    }

    /// True when the gateway says to try `command.dispatch` instead: skills, snapshot restores, or
    /// no `slash.exec` at all on an older gateway.
    private static func needsCommandDispatch(_ failure: RPCError) -> Bool {
        if failure.code == RPCError.methodNotFound { return true }
        guard failure.code == 4018 else { return false }
        return failure.message.hasPrefix("skill command: use command.dispatch")
            || failure.message.contains("use command.dispatch for /snapshot restore")
    }

    /// The commands the app handles itself. True when it did.
    private func runOwnCommand(_ typed: SlashInvocation) async -> Bool {
        let approval = cards.first { $0.method == "approval" }
        switch typed.name {
        case "approve":
            if let approval { await respond(card: approval, result: ["choice": "once"]) } else { banner = "No approval is waiting." }
        case "deny":
            if let approval { await respond(card: approval, result: ["choice": "deny"]) }
        case "stop":
            await stop()
        case "title", "rename":
            guard let name = typed.given else { return false }
            await rename(name)
            addNote("Renamed to \(name)", symbol: "pencil")
        case "model":
            guard let model = typed.given else { return false }
            await switchModel(model)
        case "reasoning", "effort":
            guard let effort = typed.given else { return false }
            do {
                try await setReasoning(effort)
                addNote("Reasoning set to \(effort)", symbol: "brain")
            } catch {
                addFailure("/\(typed.name): \(error.localizedDescription)")
            }
        case "new", "reset", "clear":
            // This chat stays put; a new chat with the same bot opens in front of it.
            let bot: [String: String] = ["profile": profileName]
            NotificationCenter.default.post(name: .hermesNewChatRequested, object: nil, userInfo: bot)
        case "help", "commands":
            await showCommandHelp()
        default:
            return false
        }
        return true
    }

    private func showCommandHelp() async {
        var known = catalogCache
        if known == nil { known = await commandsCatalog() }
        guard let catalog = known else { return }
        let groups = (catalog.categories ?? []).map { group in
            let lines = (group.pairs ?? []).map { "  " + $0.joined(separator: "  ") }
            return ([group.name ?? "Commands"] + lines).joined(separator: "\n")
        }
        if groups.isEmpty {
            addNote(catalog.allPairs.map { "/\($0.name)  \($0.description)" }.joined(separator: "\n"), symbol: "questionmark.circle")
        } else {
            addNote(groups.joined(separator: "\n\n"), symbol: "questionmark.circle")
        }
    }

    private func dispatchViaCommand(_ typed: SlashInvocation, depth: Int) async -> String? {
        var params: [String: JSONValue] = ["name": .string(typed.name)]
        if let argument = typed.argument { params["arg"] = .string(argument) }
        do {
            let result: CommandDispatchResult = try await ask("command.dispatch", params).decode()
            return await carryOut(result, for: typed, depth: depth)
        } catch {
            addFailure("/\(typed.name): \(error.localizedDescription)")
            return nil
        }
    }

    /// Applies a command's typed result to the chat.
    private func carryOut(_ result: CommandDispatchResult, for typed: SlashInvocation, depth: Int) async -> String? {
        switch result.type {
        case "exec", "plugin":
            addNote(result.display ?? result.output ?? result.notice ?? "/\(typed.name) done")
        case "send", "skill":
            if let message = result.message { await submit(text: message, queued: false) }
        case "prefill":
            return result.message
        case "alias":
            // Aliases that point at themselves, or loop in a ring, would recurse forever and crashed the
            // phone with a stack overflow as soon as such a command was sent, so the depth is capped.
            if let target = result.target, target != typed.name, depth < 4 {
                let rest = typed.argument.map { " " + $0 } ?? ""
                return await dispatchSlash("/" + target + rest, depth: depth + 1)
            }
            banner = "/\(typed.name) points at /\(result.target ?? typed.name), which loops back to /\(typed.name)."
            return nil
        default:
            if let text = result.notice ?? result.display { addNote(text, symbol: "info.circle") }
        }
        if let notice = result.notice, result.type != "exec" { banner = notice }
        return nil
    }

    // MARK: Model, effort and modes (this session only)

    /// Handles `/model name`: switch for this session, then say so in the thread.
    private func switchModel(_ model: String) async {
        do {
            try await setModel(provider: nil, model: model)
            addNote("Model set to \(model)", symbol: "cpu")
        } catch {
            addFailure("/model: \(error.localizedDescription)")
        }
    }

    /// One `config.set` for this session.
    private func configure(_ key: String, _ value: String, sessionScope: Bool = false, extra: [String: JSONValue] = [:]) async throws -> JSONValue {
        var params: [String: JSONValue] = ["key": .string(key), "value": .string(value)]
        if sessionScope { params["scope"] = "session" }
        return try await ask("config.set", params.merging(extra) { $1 })
    }

    public func setModel(provider: String?, model: String) async throws {
        let provider = provider.flatMap { $0.isEmpty ? nil : " --provider " + $0 } ?? ""
        let value = model + provider + " --session"
        let answer = try await configure("model", value)
        if answer.flag("confirm_required") {
            _ = try await configure("model", value, extra: ["confirm_expensive_model": true])
        }
        await loadUsage()
        if let fresh = try? answer["info"]?.decode(SessionLiveInfo.self) { info = fresh }
        let warning = (answer.text("warning") ?? "").trimmingCharacters(in: .whitespaces)
        if !warning.isEmpty { banner = warning }
        if answer.flag("deferred") { banner = "The new model starts with your next message." }
    }

    /// Changes one setting and ignores what the gateway says back.
    private func change(_ key: String, to value: String, forSession: Bool = false) async throws {
        _ = try await configure(key, value, sessionScope: forSession)
    }

    public func setReasoning(_ effort: String) async throws {
        try await change("reasoning", to: effort, forSession: true)
    }

    public func setFast(_ on: Bool) async throws {
        try await change("fast", to: on ? "on" : "off")
    }

    public func setYolo(_ on: Bool) async throws {
        try await change("yolo", to: on ? "on" : "off", forSession: true)
    }

    // MARK: Names

    public func rename(_ newTitle: String) async {
        let answer = try? await ask("session.title", ["title": .string(newTitle)])
        if let confirmed = answer?.text("title") { title = confirmed }
        // The chat list shows the gateway's stored rows and refreshes them on this notice. Without it
        // a renamed row showed the old name until the chat was opened again, which was obvious on the
        // Mac with the list next to the chat.
        defer { NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil) }
        Self.markRenamedByPerson(storedID)
    }

    /// Stored ids of chats the person renamed. Their own name always wins over one the device
    /// generated (#303).
    public static let renamedByPersonKey = "chats.renamedByPerson"
    private static let renamedByPersonLimit = 500

    private static var namedChats: [String] {
        UserDefaults.standard.stringArray(forKey: renamedByPersonKey) ?? []
    }

    public static func renamedByPerson(_ storedID: String) -> Bool {
        namedChats.contains(storedID)
    }

    public static func markRenamedByPerson(_ storedID: String) {
        let known = namedChats
        guard !storedID.isEmpty, !known.contains(storedID) else { return }
        let kept = Array((known + [storedID]).suffix(renamedByPersonLimit))
        UserDefaults.standard.set(kept, forKey: renamedByPersonKey)
    }
}
