import Foundation
import Observation
import NollieCore

/// Turning System control on didn't work.
struct SystemControlFailure: Error {}

/// System control: whether a bot may use this Mac's apps and screen (Hermes's computer_use), as one
/// switch per bot.
///
/// On: the bot may use the screen, and its desktop lease is the agent's. Each screen action is
/// allowed for the chat it asks in, never always, so a scheduled or unattended run (with no one to
/// answer) can't drive the Mac. Nothing goes on the bot's always-allowed list.
/// Off: the bot's desktop lease is a person's (`<home>/bot-desktop/lease.json`, holder "human").
/// Hermes reads that file before every screen action, captures included, in every process and chat,
/// and refuses the action before any approval card (tools/bot_desktop/lease.py,
/// tools/computer_use/tool.py). Changing the epoch also discards a result returned after control
/// changed. It cannot undo input already sent to an app.
@MainActor
@Observable
final class SystemControl {
    static let shared = SystemControl()

    /// One bot on one gateway. Two gateways can each have a bot called "default"; consent given
    /// to one is never the other's.
    struct Key: Hashable, Sendable {
        let connection: UUID
        let profile: String
        init(_ connection: UUID, _ profile: String) { (self.connection, self.profile) = (connection, profile) }
    }

    /// What each bot's switch shows. Absent: not read yet.
    private(set) var states: [Key: Bool] = [:]
    /// Whether each bot has computers of its own (Cua Spaces, its `cua` MCP server).
    private(set) var spaces: [Key: Bool] = [:]
    /// The bots whose switch is being written.
    private(set) var busy: Set<Key> = []
    /// The last thing that went wrong, for the bot's Computer page.
    var lastError: String?
    /// The gateway address each state was read from or written to. A state only counts while the
    /// connection still points there.
    private var source: [Key: GatewayURL] = [:]
    private var readAt: [Key: Date] = [:]
    private var writeGeneration: [Key: UUID] = [:]

    /// Every screen action Hermes asks about (the actions that change something, and bringing a
    /// window to the front), in the background and in front.
    static let actions = ["click", "double_click", "right_click", "middle_click", "drag", "scroll",
                          "type", "key", "set_value", "focus_app", "bring_to_front"]
    static let keys: [String] = actions.flatMap { ["cua:\($0):background", "cua:\($0):foreground"] }
        + ["cua:launch_app:background"]

    static func key(_ profile: String, _ rt: GatewayRuntime) -> Key { Key(rt.connection.id, profile) }

    /// The switch as read from this gateway. Nil: not read yet, or read from another address.
    func state(_ profile: String, _ rt: GatewayRuntime?) -> Bool? {
        guard let rt else { return nil }
        return state(Self.key(profile, rt), gateway: rt.connection.gateway)
    }

    func state(_ key: Key, gateway: GatewayURL) -> Bool? {
        guard source[key] == gateway else { return nil }
        return states[key]
    }

    func isOn(_ profile: String, _ rt: GatewayRuntime?) -> Bool { state(profile, rt) == true }

    func isBusy(_ profile: String, _ rt: GatewayRuntime?) -> Bool {
        guard let rt else { return false }
        return busy.contains(Self.key(profile, rt))
    }

    /// The app's own answer to an approval, before any card: allowed in this chat for a screen
    /// action of a bot whose System control is on. Nil shows the card as usual. Only a switch read
    /// from this gateway counts.
    func autoAnswer(_ approval: ApprovalRequest, profile: String, connection: UUID, gateway: GatewayURL) -> String? {
        let key = Key(connection, profile)
        guard !busy.contains(key) else { return nil }
        return Self.autoAnswer(approval, controlOn: state(key, gateway: gateway) == true)
    }

    /// Never "always": a screen grant ends with the chat it was given in.
    static func autoAnswer(_ approval: ApprovalRequest, controlOn: Bool) -> String? {
        guard isScreen(approval), controlOn, approval.offeredChoices.contains("session") else { return nil }
        return "session"
    }

    /// Whether an approval is about the Mac's screen.
    static func isScreen(_ approval: ApprovalRequest) -> Bool { (approval.patternKey ?? "").hasPrefix("cua:") }

    /// A screen approval answered on its System control card: on (the switch, then this action
    /// allowed in this chat), or off (the switch, then Deny).
    static func answer(_ on: Bool, card: PendingCard, chat: ChatSession) {
        #if os(iOS)
        if on { HelperAtWorkActivities.shared.allowedHere(profile: chat.profileName) }
        #endif
        Task {
            await shared.set(on, profile: chat.profileName, rt: chat.runtime)
            await chat.respond(card: card, result: ["choice": .string(on ? "session" : "deny")])
        }
    }

    // MARK: Reading

    /// Every bot's switch, at most once a minute each unless `force`.
    func refreshAll(_ rt: GatewayRuntime, force: Bool = false) async {
        for p in rt.profiles {
            let key = Self.key(p.name, rt)
            if !force, source[key] == rt.connection.gateway, let t = readAt[key], Date().timeIntervalSince(t) < 60 { continue }
            await refresh(p.name, rt)
        }
    }

    func refresh(_ profile: String, _ rt: GatewayRuntime) async {
        let key = Self.key(profile, rt)
        guard !busy.contains(key), let home = home(rt, profile) else { return }
        let generation = writeGeneration[key]
        let gateway = rt.connection.gateway
        readAt[key] = Date()
        guard let cfg = try? await config(rt, profile) else { return }
        // An answer that comes back after the connection moved or a write began is dropped.
        guard rt.connection.gateway == gateway, writeGeneration[key] == generation else { return }
        spaces[key] = cfg.spaces
        guard let lease = try? await readLease(rt, home) else { return }
        guard !busy.contains(key), writeGeneration[key] == generation, rt.connection.gateway == gateway else { return }
        states[key] = lease.explicitAgent && !cfg.disabled.contains("computer_use")
        source[key] = gateway
    }

    /// Whether Hermes's own computer_use could act on this Mac for a bot now, by Hermes's own
    /// rule: the tools aren't switched off and the lease isn't a person's (no lease file is the
    /// agent's). Nil when either can't be read. Reads only; the switch shown doesn't change.
    func hermesCouldDrive(_ profile: String, _ rt: GatewayRuntime, home listedHome: String? = nil) async -> Bool? {
        guard let home = listedHome.flatMap({ $0.isEmpty ? nil : $0 }) ?? home(rt, profile), let cfg = try? await config(rt, profile) else {
            return nil
        }
        if cfg.disabled.contains("computer_use") { return false }
        // The lease as Hermes reads it: no file is the agent's; a file only a person's when it says so.
        do {
            let r: JSONValue = try await rt.api.get("/api/fs/read-text", query: [URLQueryItem(name: "path", value: Self.leasePath(home))])
            guard let text = r["text"]?.stringValue,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let holder = obj["holder"] as? String else { return nil }
            return holder != "human"
        } catch HermesAPIError.http(let status, _) where status == 404 {
            return true
        } catch {
            return nil
        }
    }

    // MARK: Writing

    /// Turns a bot's System control on or off. On: the lease goes to the agent, and computer_use comes
    /// out of its switched-off tools. Off: the lease goes to a person, which stops the bot's next
    /// screen action. Either way, screen rules an older version left on the always-allowed list go.
    @discardableResult
    func set(_ on: Bool, profile: String, rt: GatewayRuntime) async -> Bool {
        let key = Self.key(profile, rt)
        guard !busy.contains(key) else { return false }
        guard let home = home(rt, profile) else {
            lastError = "The gateway didn't say where this bot lives."
            return false
        }
        let gateway = rt.connection.gateway
        busy.insert(key)
        writeGeneration[key] = UUID()
        defer { busy.remove(key) }
        let (was, wasFrom) = (states[key], source[key])
        states[key] = on
        source[key] = gateway
        do {
            let current = (try? await readLease(rt, home)) ?? Lease(holder: "agent", epoch: 0)
            try await writeLease(rt, home, holder: on ? "agent" : "human", epoch: current.epoch + 1)
            let cfg = try await config(rt, profile)
            var body: [String: JSONValue] = [:]
            let kept = Self.withoutScreenRules(cfg.allow)
            if kept.count != cfg.allow.count { body["command_allowlist"] = .array(kept.map { .string($0) }) }
            if on, cfg.disabled.contains("computer_use") {
                body["agent"] = .object(["disabled_toolsets": .array(cfg.disabled.filter { $0 != "computer_use" }.map { .string($0) })])
            }
            if !body.isEmpty {
                let _: JSONValue = try await rt.api.send("PUT", "/api/config", profile: profile, json: ["config": .object(body)])
            }
            lastError = nil
            readAt[key] = Date()
            return true
        } catch {
            states[key] = was
            source[key] = wasFrom
            lastError = error.localizedDescription
            return false
        }
    }

    /// Revokes this bot's next Mac screen actions. It does not stop a virtual computer,
    /// cancel the whole task, or undo input that has already reached an app.
    @discardableResult
    func stopMacControl(profile: String, rt: GatewayRuntime,
                        allowed: @escaping @MainActor () -> Bool) async -> Bool {
        guard let home = home(rt, profile) else {
            lastError = "The gateway didn't say where this bot lives."
            return false
        }
        return await stopMacControl(key: Self.key(profile, rt), home: home, api: rt.api, allowed: allowed)
    }

    @discardableResult
    func stopMacControl(key: Key, home: String, api: HermesAPI,
                        allowed: @escaping @MainActor () -> Bool) async -> Bool {
        guard !busy.contains(key), !Task.isCancelled, allowed() else { return false }
        busy.insert(key)
        writeGeneration[key] = UUID()
        defer { busy.remove(key) }
        var attemptedWrite = false
        do {
            let gateway = await api.gateway
            try await checkStopAllowed(api: api, gateway: gateway, allowed: allowed)
            let current = try await readLease(api, home)
            let (epoch, overflow) = max(0, current.epoch).addingReportingOverflow(1)
            guard !overflow else { throw StopFailure.unconfirmed }
            try await checkStopAllowed(api: api, gateway: gateway, allowed: allowed)
            attemptedWrite = true
            try await writeLease(api, home, holder: "human", epoch: epoch)
            try await checkStopAllowed(api: api, gateway: gateway, allowed: allowed)
            let confirmed = try await readLease(api, home)
            try await checkStopAllowed(api: api, gateway: gateway, allowed: allowed)
            guard confirmed.confirmedHuman, confirmed.epoch >= epoch else { throw StopFailure.unconfirmed }
            states[key] = false
            source[key] = gateway
            readAt[key] = Date()
            lastError = nil
            return true
        } catch {
            if attemptedWrite {
                // An interrupted acknowledgement leaves the result unknown, never reported as off.
                states.removeValue(forKey: key)
                source.removeValue(forKey: key)
                readAt.removeValue(forKey: key)
            }
            lastError = "Couldn't confirm Mac control is off. Check the connection and try again."
            return false
        }
    }

    private enum StopFailure: Error { case unconfirmed }

    private func checkStopAllowed(api: HermesAPI, gateway: GatewayURL,
                                  allowed: @MainActor () -> Bool) async throws {
        try Task.checkCancellation()
        guard allowed() else { throw CancellationError() }
        let current = await api.gateway
        try Task.checkCancellation()
        guard allowed(), current == gateway else { throw CancellationError() }
    }

    // MARK: The pieces

    /// The always-allowed list without screen rules (`cua:*`), which System control no longer keeps.
    static func withoutScreenRules(_ allow: [String]) -> [String] { allow.filter { !$0.hasPrefix("cua:") } }

    struct Lease {
        var holder: String
        var epoch: Int
        var confirmedHuman = false
        /// The file exists and names the agent. A missing file is Hermes's default, not the switch.
        var explicitAgent = false
    }

    private func home(_ rt: GatewayRuntime, _ profile: String) -> String? {
        if let p = rt.profiles.first(where: { $0.name == profile })?.path, !p.isEmpty { return p }
        return profile == rt.selectedProfile ? rt.profileHome : nil
    }

    private static func leasePath(_ home: String) -> String { home + "/bot-desktop/lease.json" }

    /// The lease, read as a file of the Mac's own (no profile: a bot whose files live elsewhere,
    /// a sandbox, still keeps its lease in its Hermes home). No file: the agent's, epoch 0.
    private func readLease(_ rt: GatewayRuntime, _ home: String) async throws -> Lease {
        try await readLease(rt.api, home)
    }

    private func readLease(_ api: HermesAPI, _ home: String) async throws -> Lease {
        do {
            let r: JSONValue = try await api.get("/api/fs/read-text", query: [URLQueryItem(name: "path", value: Self.leasePath(home))])
            guard let text = r["text"]?.stringValue, let data = text.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Hermes reads a file it can't parse as a person's: off.
                return Lease(holder: "human", epoch: 0)
            }
            let holder = obj["holder"] as? String ?? "human"
            let epoch = (obj["epoch"] as? NSNumber)?.intValue ?? 0
            return Lease(holder: holder == "agent" ? "agent" : "human", epoch: epoch,
                         confirmedHuman: holder == "human" && obj["epoch"] is NSNumber,
                         explicitAgent: holder == "agent")
        } catch HermesAPIError.http(let status, _) where status == 404 {
            return Lease(holder: "agent", epoch: 0)
        }
    }

    private func writeLease(_ rt: GatewayRuntime, _ home: String, holder: String, epoch: Int) async throws {
        try await writeLease(rt.api, home, holder: holder, epoch: epoch)
    }

    private func writeLease(_ api: HermesAPI, _ home: String, holder: String, epoch: Int) async throws {
        var lease: [String: Any] = ["holder": holder, "since": Date().timeIntervalSince1970, "epoch": epoch]
        lease["viewer_id"] = holder == "human" ? "nollie-app" : NSNull()
        lease["reason"] = holder == "human" ? "System control is off in the Nollie app" : ""
        let data = try JSONSerialization.data(withJSONObject: lease, options: [.sortedKeys])
        let body: JSONValue = ["path": .string(Self.leasePath(home)),
                               "data_url": .string("data:application/json;base64," + data.base64EncodedString()),
                               "overwrite": true]
        let result: ManagedUploadResult = try await api.send("POST", "/api/files/upload", json: body)
        guard result.ok != false, result.path == Self.leasePath(home) else { throw StopFailure.unconfirmed }
    }

    private func config(_ rt: GatewayRuntime, _ profile: String) async throws -> (allow: [String], disabled: [String], spaces: Bool) {
        let cfg: JSONValue = try await rt.api.get("/api/config", profile: profile)
        let root = cfg["config"] ?? cfg
        let allow = (root["command_allowlist"]?.arrayValue ?? []).compactMap(\.stringValue)
        let disabled = (root["agent"]?["disabled_toolsets"]?.arrayValue ?? []).compactMap(\.stringValue)
        let spaces = root["mcp_servers"]?["cua"].map { !$0.isNull } ?? false
        return (allow, disabled, spaces)
    }
}
