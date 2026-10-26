#if os(macOS)
import ApplicationServices
import Foundation
import NollieCore

/// What Hermes says about the chat a request came from: the only source of a task's chat, its
/// title and its platform. Nothing the caller says about itself is trusted.
struct ComputerSessionFacts: Equatable, Sendable {
    /// The chat across context compression: the first session of its lineage.
    var chat: String
    var title: String
    var source: String
    /// The pending `mac_start` call this request answers; each is used once.
    var callID: String
    /// The bot, as Hermes files the chat (never as the caller says).
    var profile: String = ""
    /// Where the chat lives, for the card: "Nollie" for the app itself, else the messaging app.
    var platform: String = ""
    /// The chat's session ids Hermes knows: the one that asked, back to the first.
    var lineage: [String] = []
}

/// Binds a request to the process that sent it and to Hermes's own record of it.
///
/// - The sender is the nollie-mac add-on, run directly by Hermes's gateway or dashboard (the ones
///   launchd starts), from that bot's own plugin folder (`ComputerPeer`). A `hermes chat` run, a
///   terminal or a bot's own tools run their add-on elsewhere, so they never get this far.
/// - Hermes saves an assistant turn's tool calls before it runs any of them, so a real request
///   has, in that bot's history, a latest assistant turn with an unanswered `mac_start` call for
///   exactly these apps and this task, made seconds ago.
/// - The chat is one a person is in: from the dashboard, a chat open in this Nollie with a turn
///   it sent running now (which only this app knows); from the gateway, a messaging chat the
///   gateway itself routes (its session key and chat id).
enum ComputerSessionCheck {
    static let notConnected = "Nollie isn't connected to Hermes right now, so it can't check which chat asked. Try again in a moment."
    static let unknown = "Nollie couldn't find that chat for this bot, so it won't ask the person."
    static let scheduled = "This isn't a chat someone is in, and Nollie only lets a bot use the Mac from one."
    static let noPendingCall = "Nollie couldn't find this request in the chat, so it won't ask the person."
    static let groupChat = "Nollie only lets a bot use the Mac from a direct chat with it, not a group."
    static let notTheAddOn = "Nollie only takes this from its add-on, run by Hermes on this Mac. Nothing was done."
    static let notOpenHere = "Nollie only lets a bot use the Mac from a chat open in Nollie on this Mac, or from a messaging app."
    /// Where Hermes's gateway takes messages from people. Terminal, scheduled, kanban and API runs never qualify.
    /// Matrix isn't here: Hermes guesses a direct room from its size, which can be out of date.
    static let messagingSources: Set<String> = Set(
        "sms mattermost slack discord telegram signal whatsapp whatsapp_cloud bluebubbles photon"
            .split(separator: " ").map(String.init))
    /// The chats the Nollie app runs through the dashboard.
    static let appSources: Set<String> = ["tui", "desktop"]

    /// The full name Hermes records for the add-on's tool: `mcp__` + the server's name (nollie-mac,
    /// with `-` as `_`) + `__mac_start`. Only this exact name counts.
    static let toolName = "mcp__nollie_mac__mac_start"
    /// How old the pending call may be when Nollie checks it.
    static let freshFor: TimeInterval = 90

    @MainActor static func check(_ request: ComputerStartRequest) async -> Result<ComputerSessionFacts, ComputerCenter.Refusal> {
        await check(request, ownChat: openHereWithTurnRunning)
    }

    /// Whether one of these session ids is a chat open in this Nollie with a turn it sent running.
    @MainActor static func openHereWithTurnRunning(_ ids: [String], profile: String) -> Bool {
        AppModel.shared.runtime?.chats.contains { chat in
            chat.profileName == profile && chat.turnStartedHere
                && (ids.contains(chat.storedID) || chat.formerStoredIDs.contains(where: ids.contains))
        } ?? false
    }

    @MainActor static func check(_ request: ComputerStartRequest,
                                 ownChat: ([String], String) -> Bool) async -> Result<ComputerSessionFacts, ComputerCenter.Refusal> {
        guard let peer = request.peer, peer.profile == request.profile else { return .failure(.init(message: notTheAddOn)) }
        guard let api = AppModel.shared.runtime?.api else { return .failure(.init(message: notConnected)) }
        guard !request.profile.isEmpty, isSessionID(request.sessionID) else { return .failure(.init(message: unknown)) }
        do {
            let row: JSONValue = try await api.get("/api/sessions/\(request.sessionID)", profile: request.profile)
            guard let id = row["id"]?.stringValue, id == request.sessionID else { return .failure(.init(message: unknown)) }
            if let refusal = judge(row, host: peer.host) { return .failure(.init(message: refusal)) }
            let page = try await latestMessages(api, session: id, profile: request.profile)
            guard let callID = pendingStart(in: page["messages"]?.arrayValue ?? [], apps: request.apps, purpose: request.purpose,
                                            now: Date()) else {
                return .failure(.init(message: noPendingCall))
            }
            // The chat is the first session of its lineage: compression gives a chat new ids.
            var lineage = [id]
            var parent = row["parent_session_id"]?.stringValue
            for _ in 0..<30 {
                guard let next = parent, !next.isEmpty, !lineage.contains(next) else { break }
                lineage.append(next)
                let up: JSONValue? = try? await api.get("/api/sessions/\(next)", profile: request.profile)
                parent = up?["parent_session_id"]?.stringValue
            }
            guard var facts = facts(row: row, root: lineage.last!, callID: callID, host: peer.host) else { return .failure(.init(message: unknown)) }
            facts.lineage = lineage
            if ComputerOtherControl.isPrivate(facts.profile, connection: AppModel.shared.runtime?.connection.id) || facts.profile != peer.profile { return .failure(.init(message: unknown)) }
            if peer.host == .dashboard, !ownChat(lineage, facts.profile) { return .failure(.init(message: notOpenHere)) }
            return .success(facts)
        } catch HermesAPIError.http(let status, _) where status == 404 {
            return .failure(.init(message: unknown))
        } catch {
            return .failure(.init(message: notConnected))
        }
    }

    /// A session id as Hermes writes them, before it goes into a path.
    static func isSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.count < 200
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "_-.:".unicodeScalars.contains($0) }
    }

    /// The session a chat continued from, by Hermes's own record of it for this bot; nil when
    /// there is none or Hermes can't be asked.
    @MainActor static func parent(profile: String, of id: String) async -> String? {
        guard isSessionID(id), let api = AppModel.shared.runtime?.api,
              let row: JSONValue = try? await api.get("/api/sessions/\(id)", profile: profile),
              row["id"]?.stringValue == id, row["profile"]?.stringValue == profile,
              let parent = row["parent_session_id"]?.stringValue, !parent.isEmpty else { return nil }
        return parent
    }

    /// The chat's newest twenty messages, without inline pictures.
    private static func latestMessages(_ api: HermesAPI, session: String, profile: String) async throws -> JSONValue {
        let wanted = [("order", "latest"), ("limit", "20"), ("inline_images", "false")]
        return try await api.get("/api/sessions/\(session)/messages",
                                 query: wanted.map { URLQueryItem(name: $0.0, value: $0.1) }, profile: profile)
    }

    /// After the person's yes: the same call is still the latest one, still waiting for its answer
    /// (the card may have taken two minutes, so its age doesn't count here).
    @MainActor static func stillPending(_ request: ComputerStartRequest, callID: String) async -> Bool {
        guard let api = AppModel.shared.runtime?.api else { return false }
        guard let page = try? await latestMessages(api, session: request.sessionID, profile: request.profile) else { return false }
        return pendingStart(in: page["messages"]?.arrayValue ?? [], apps: request.apps, purpose: request.purpose, now: Date(),
                            freshFor: 24 * 60 * 60) == callID
    }

    /// What the card and the task use, all from Hermes's own record of the chat: its bot, its
    /// first session (the chat across compression), title and platform. Nothing the caller sent
    /// (its session id, chat or bot) is used, only the row Hermes returned for it.
    static func facts(row: JSONValue, root: String, callID: String, host: ComputerPeer.Host) -> ComputerSessionFacts? {
        guard let profile = row["profile"]?.stringValue, !profile.isEmpty, !root.isEmpty else { return nil }
        let title = row["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled chat"
        let source = row["source"]?.stringValue ?? ""
        return ComputerSessionFacts(chat: profile + "/" + root, title: title, source: source, callID: callID, profile: profile,
                                    platform: host == .dashboard ? "Nollie" : ComputerOtherControl.platformName(source))
    }

    /// Nil for a chat someone is in, run where the add-on says it was; otherwise why not.
    static func judge(_ row: JSONValue, host: ComputerPeer.Host) -> String? {
        guard let source = row["source"]?.stringValue?.lowercased(), !source.isEmpty, !(row["archived"]?.boolValue ?? false) else {
            return unknown
        }
        switch host {
        case .dashboard:
            return appSources.contains(source) ? nil : scheduled
        case .gateway:
            guard messagingSources.contains(source) else { return scheduled }
            // A chat the gateway routes: its key names the platform, and it has the chat's id.
            let key = row["session_key"]?.stringValue ?? ""
            guard key.hasPrefix("agent:"), key.contains(":\(source):"), !(row["chat_id"]?.stringValue ?? "").isEmpty else { return unknown }
            // Only a direct chat: in a group, someone else may have asked.
            let type = row["chat_type"]?.stringValue?.lowercased() ?? ""
            guard type == "dm" || (type.isEmpty && key.contains(":\(source):dm:")) else { return groupChat }
            // Slack calls a group DM a DM too: only a one-to-one channel ("D…") counts.
            if source == "slack", !(row["chat_id"]?.stringValue ?? "").hasPrefix("D") { return groupChat }
            return nil
        }
    }

    /// The id of the latest assistant turn's `mac_start` call for these apps and this task, when it
    /// is recent and not yet answered. `messages` is newest first or oldest first; both work.
    static func pendingStart(in messages: [JSONValue], apps: [String], purpose: String, now: Date,
                             freshFor: TimeInterval = ComputerSessionCheck.freshFor) -> String? {
        // Oldest first, keeping Hermes's own order among rows of the same second.
        let ordered = (time(messages.first ?? .null) ?? 0) > (time(messages.last ?? .null) ?? 0) ? Array(messages.reversed()) : messages
        guard let index = ordered.lastIndex(where: { $0["role"]?.stringValue == "assistant" && !($0["tool_calls"]?.arrayValue ?? []).isEmpty }) else {
            return nil
        }
        let turn = ordered[index]
        guard let at = time(turn), now.timeIntervalSince1970 - at < freshFor, at - now.timeIntervalSince1970 < 5 else { return nil }
        let answered = Set(ordered[(index + 1)...].compactMap { $0["role"]?.stringValue == "tool" ? $0["tool_call_id"]?.stringValue : nil })
        for call in turn["tool_calls"]?.arrayValue ?? [] {
            let function = call["function"] ?? call
            guard function["name"]?.stringValue == toolName, let id = call["id"]?.stringValue ?? call["call_id"]?.stringValue,
                  !answered.contains(id) else { continue }
            let arguments: [String: Any]
            if let text = function["arguments"]?.stringValue {
                arguments = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
            } else if let object = function["arguments"], let data = try? JSONEncoder().encode(object) {
                arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            } else {
                continue
            }
            guard sameArguments(arguments, apps: apps, purpose: purpose) else { continue }
            // With the turn's own time: Hermes's fallback ids repeat for the same call in one chat.
            return id + "@" + String(Int(at * 1000))
        }
        return nil
    }

    /// The call's arguments are the request, byte for byte: exactly `apps` (strings) and `task`
    /// (a string), plus the add-on's own `_nollie` stamp, and nothing else.
    static func sameArguments(_ arguments: [String: Any], apps: [String], purpose: String) -> Bool {
        guard Set(arguments.keys).subtracting(["_nollie"]) == ["apps", "task"],
              let asked = arguments["apps"] as? [Any], let task = arguments["task"] as? String else { return false }
        let names = asked.compactMap { $0 as? String }
        guard names.count == asked.count else { return false }
        return names.map { Array($0.utf8) } == apps.map { Array($0.utf8) } && Array(task.utf8) == Array(purpose.utf8)
    }

    private static func time(_ message: JSONValue) -> Double? {
        if let seconds = message["timestamp"]?.doubleValue { return seconds > 1e12 ? seconds / 1000 : seconds }
        if let text = message["timestamp"]?.stringValue {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return (formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text))?.timeIntervalSince1970
        }
        return nil
    }
}

/// The Hermes tool calls that already had their card, kept on disk so a restart of Nollie can't
/// make one good again. The newest 500 are kept.
final class ComputerUsedCalls {
    let path: String
    private var calls: [String]?

    init(path: String = ComputerHelper.supportDirectory.appendingPathComponent("used-calls.json").path) {
        self.path = path
    }

    private var loaded: [String] {
        if let calls { return calls }
        let read = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        calls = read
        return read
    }

    func contains(_ call: String) -> Bool { loaded.contains(call) }

    func insert(_ call: String) {
        var all = loaded
        all.append(call)
        all = Array(all.suffix(500))
        calls = all
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(all) {
            FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}

/// Nollie's own look at an element, through its own Accessibility permission, just before it
/// types or presses a key there: the role and subrole the app reports now, which is where a
/// password field says it is one.
enum ComputerAXProbe {
    /// The element at the centre of `frame` (screen points, top left), or, with no frame, the
    /// app's focused element. Nil when the app doesn't answer.
    static func target(pid: Int, frame: CGRect?) -> ComputerAction.Target? {
        shortTimeouts()
        let app = AXUIElementCreateApplication(pid_t(pid))
        AXUIElementSetMessagingTimeout(app, 1)
        var element: AXUIElement?
        if let frame {
            guard AXUIElementCopyElementAtPosition(app, Float(frame.midX), Float(frame.midY), &element) == .success else { return nil }
        } else {
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
            element = (focused as! AXUIElement)
        }
        guard let element else { return nil }
        func string(_ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
        var frame: CGRect?
        var position: CFTypeRef?, size: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
           let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
            var origin = CGPoint.zero, extent = CGSize.zero
            if AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) {
                frame = CGRect(origin: origin, size: extent)
            }
        }
        // The words, as the driver reads them: the first of title, description and value that has any.
        let words = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].lazy.compactMap { string($0) }.first { !$0.isEmpty }
        let role = string(kAXRoleAttribute)
        // A link's address is its own AXURL. Pictures and pages have one too (the picture's source,
        // the page's address), which is never where a click goes.
        var target = ComputerAction.Target(role: role, label: words, subrole: string(kAXSubroleAttribute), frame: frame,
                                           url: role == "AXLink" ? url(of: element) : nil)
        if role == "AXWebArea" { target.inWebContent = true }
        // Up to the window: a link anywhere above (a web page opens it from any depth) makes this a
        // link, with that link's address or none; web content anywhere above takes keys first.
        var node = element
        var reachedTop = role == "AXWindow" || role == "AXApplication"
        var unsure = false
        for _ in 0..<ancestorLimit where !reachedTop {
            var value: CFTypeRef?
            let read = AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &value)
            // Only an app that says there is no parent has shown the top; a slow or busy one hasn't.
            if read == .noValue || read == .attributeUnsupported { reachedTop = true; break }
            guard read == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { unsure = true; break }
            let parent = value as! AXUIElement
            node = parent
            var roleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(parent, kAXRoleAttribute as CFString, &roleValue) == .success else { unsure = true; break }
            let up = roleValue as? String
            if up == "AXWindow" || up == "AXApplication" { reachedTop = true; break }
            if up == "AXWebArea" { target.inWebContent = true }
            if up == "AXLink", !target.inLink, target.role != "AXLink" {
                target.inLink = true
                target.url = url(of: parent)
            }
        }
        // Too deep, or the app didn't answer: whatever is above can't be ruled out.
        if !reachedTop || unsure { target.inLink = true; target.inWebContent = true }
        return target
    }

    /// How far up Nollie looks for a link or a page, before it gives up and assumes one.
    static let ancestorLimit = 64

    /// One second at most for any app to answer, for every element Nollie asks about (setting it
    /// on the app alone covers only the app's own element).
    private static let shortTimeoutsOnce: Void = { AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1) }()
    static func shortTimeouts() { _ = shortTimeoutsOnce }

    private static func url(of element: AXUIElement) -> String? {
        guard let value = attribute(element, kAXURLAttribute) else { return nil }
        return (value as? URL)?.absoluteString ?? (value as? String)
    }

    /// Virtual key codes for the named keys a menu item may use instead of a character.
    static let keyCodes: [String: Int] = ["return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "forward_delete": 117,
                                          "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
                                          "left": 123, "right": 124, "down": 125, "up": 126]

    /// The menu item a key combination runs in the app, from its own menu bar. Nil when no item
    /// has that shortcut (or the app doesn't answer), which Nollie treats as "don't press it".
    static func shortcut(pid: Int, key: String, modifiers: [String]) -> ComputerAction.Shortcut? {
        shortTimeouts()
        let app = AXUIElementCreateApplication(pid_t(pid))
        AXUIElementSetMessagingTimeout(app, 1)
        guard let bar = element(app, kAXMenuBarAttribute) else { return nil }
        var wanted = 0
        if modifiers.contains("shift") { wanted |= 1 }
        if modifiers.contains("option") { wanted |= 2 }
        if modifiers.contains("ctrl") { wanted |= 4 }
        if !modifiers.contains("cmd") { wanted |= 8 }
        var visited = 0
        // Every item with that shortcut: an enabled one is what the key runs, as the app decides.
        var found: [(title: String, enabled: Bool, inAppleMenu: Bool)] = []
        func search(_ node: AXUIElement, depth: Int, inAppleMenu: Bool) {
            for child in children(node) {
                visited += 1
                guard visited < 4000, found.count < 8 else { return }
                if let title = matching(child, key: key, modifiers: wanted) {
                    found.append((title, attribute(child, kAXEnabledAttribute) as? Bool ?? true, inAppleMenu))
                }
                if depth < 4 { search(child, depth: depth + 1, inAppleMenu: inAppleMenu) }
            }
        }
        for (index, menu) in children(bar).enumerated() { search(menu, depth: 0, inAppleMenu: index == 0) }
        // Any match in the Apple menu wins: those stay with the person whatever else matches.
        if let apple = found.first(where: \.inAppleMenu) { return ComputerAction.Shortcut(title: apple.title, inAppleMenu: true) }
        guard let item = found.first(where: \.enabled) ?? found.first else { return nil }
        return ComputerAction.Shortcut(title: item.title)
    }

    private static func matching(_ item: AXUIElement, key: String, modifiers: Int) -> String? {
        let char = attribute(item, kAXMenuItemCmdCharAttribute) as? String
        let code = (attribute(item, kAXMenuItemCmdVirtualKeyAttribute) as? NSNumber)?.intValue
        guard (char?.isEmpty == false) || code != nil else { return nil }
        let mods = (attribute(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? 0
        guard mods == modifiers else { return nil }
        let keyMatches = key.count == 1 ? char?.lowercased() == key : (code != nil && code == keyCodes[key])
        guard keyMatches else { return nil }
        return attribute(item, kAXTitleAttribute) as? String ?? ""
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ parent: AXUIElement) -> [AXUIElement] {
        (attribute(parent, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}
#endif

#if os(macOS)
import Darwin
import LocalAuthentication

/// Anything else that can drive this Mac. While one is on, Nollie doesn't start, and a running task
/// ends: another driver with Accessibility could press Nollie's own Allow, and two ways in at once
/// can't be kept apart. Checked before the card, again after Touch ID, and every second of a task.
enum ComputerOtherControl {
    static let systemControlOn = "Mac control is on for %@ in its settings. The person needs to turn it off before a bot can use apps this way."
    static let otherDriver = "Another computer-control helper is running on this Mac, outside Nollie. The person needs to quit it first."

    static let cantList = "Nollie couldn't check the bots' Mac control just now, so it won't start. Try again in a moment."
    static let cantCheckControl = "Nollie couldn't check whether %@ can control the Mac by itself, so it won't start. Try again in a moment."

    /// What Hermes's own computer_use gate says for each bot, as last read: true when it could act
    /// on this Mac now. Absent: not read, which never counts as off.
    @MainActor private static var couldDrive: [String: Bool] = [:]

    /// Asks Hermes for every bot (the list read again, never a private bot), then looks for
    /// another driver. Anything it can't read counts as on.
    @MainActor static func check() async -> String? {
        await refresh()
        return quickCheck(driverRunning: await Task.detached { otherDriverRunning() }.value)
    }

    /// Reads every bot's gate again.
    @MainActor static func refresh() async {
        guard let rt = AppModel.shared.runtime else { couldDrive = [:]; return }
        // The bots as Hermes lists them now: one made a minute ago counts too.
        let listed: JSONValue? = try? await rt.api.get("/api/profiles")
        var homes: [String: String] = [:]
        for entry in listed?["profiles"]?.arrayValue ?? [] {
            if let name = entry["name"]?.stringValue { homes[name] = entry["path"]?.stringValue ?? "" }
        }
        let all = Set(homes.keys).union(rt.profiles.map(\.name)).filter { !isPrivate($0, connection: rt.connection.id) }
        var read: [String: Bool] = [:]
        for profile in all.sorted() {
            if let on = await SystemControl.shared.hermesCouldDrive(profile, rt, home: homes[profile]) { read[profile] = on }
        }
        couldDrive = read
        readAt = Date()
        // An empty name stands for "the list itself couldn't be read".
        known = listed == nil ? all.union([""]) : all
    }

    @MainActor private static var known: Set<String> = []
    /// When the gates were last read. Older than `freshFor`, they count as on.
    @MainActor static var readAt: Date?
    static let freshFor: TimeInterval = 12

    /// Whether a bot is private on a gateway. Where no gateway is known, a bot private on any of them counts.
    static func isPrivate(_ profile: String, connection: UUID?) -> Bool {
        PrivateBots.isPrivate(profile, connection: connection) || profile.lowercased() == "private"
    }

    static func isPrivate(_ profile: String) -> Bool { isPrivate(profile, connection: nil) }

    /// The gates as last read, and whether a driver was seen: for the once-a-second check.
    @MainActor static func quickCheck(driverRunning: Bool) -> String? {
        let names = AppModel.shared.runtime?.profiles ?? []
        if AppModel.shared.runtime == nil { return String(format: cantCheckControl, "a bot") }
        return judge(known: known, couldDrive: couldDrive, readAt: readAt, now: Date(), driverRunning: driverRunning) { profile in
            names.first { $0.name == profile }?.shownName ?? profile
        }
    }

    /// Nil only when every bot's gate was read lately and is shut, and no driver runs. A reading
    /// older than `freshFor`, or one missing, counts as on.
    static func judge(known: Set<String>, couldDrive: [String: Bool], readAt: Date?, now: Date, driverRunning: Bool,
                      shown: (String) -> String = { $0 }) -> String? {
        guard let readAt, now.timeIntervalSince(readAt) < freshFor, !known.contains("") else { return cantList }
        if let profile = known.sorted().first(where: { couldDrive[$0] == nil }) { return String(format: cantCheckControl, shown(profile)) }
        if let profile = couldDrive.filter(\.value).keys.sorted().first { return String(format: systemControlOn, shown(profile)) }
        return driverRunning ? otherDriver : nil
    }

    /// Where a standalone Cua Driver listens. A socket that answers means one is running, whatever
    /// its program is called.
    static var driverSockets: [String] {
        ["cua-driver", "cua-driver-local"].map { NSHomeDirectory() + "/Library/Caches/\($0)/\($0).sock" }
    }

    /// The teams that sign Cua Driver.
    static let driverTeams: Set<String> = ["YCK386LBJ7", "4YEC26S9KF"]

    /// A driver process that isn't Nollie's own helper: by its program's name or the kernel's name
    /// for it, by its signature as the kernel holds it (a renamed, rebuilt or deleted copy keeps
    /// it), or by a driver socket that answers. Every process, every time: nothing is remembered.
    static func otherDriverRunning(ownHelper: String = ComputerHelper.executable.path, ownPID: Int32 = getpid()) -> Bool {
        if driverSockets.contains(where: answers) { return true }
        for pid in ComputerProcess.allPIDs() where pid != ownPID {
            // Another user's process (root's too) gives no details, but its program and signature still show.
            let info = ComputerProcess.info(pid)
            let path = ComputerProcess.path(of: pid)
            // Nollie's own helper, as its own child.
            if path == ownHelper, let info, Int32(info.pbi_ppid) == ownPID { continue }
            if isDriver(path ?? "", ownHelper: ownHelper) || info.map({ isDriverName(ComputerProcess.name($0)) }) == true { return true }
            let signature = ComputerSignature.of(pid: pid)
            if isDriverIdentifier(signature.identifier, team: signature.team) { return true }
        }
        return false
    }

    static func isDriverName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("cua-driver") || lower.hasPrefix("cua_driver") || lower == "cuadriver"
    }

    static func isDriver(_ executable: String, ownHelper: String) -> Bool {
        guard !executable.isEmpty, executable != ownHelper else { return false }
        return isDriverName((executable as NSString).lastPathComponent)
            || executable.contains("/CuaDriver.app/") || executable.contains("/CuaDriverLocal.app/")
    }

    /// Cua Driver however it was built or named (its identifiers all start `com.trycua.driver`,
    /// signed by Cua's teams or not at all), a plain build of it, or a Nollie helper.
    static func isDriverIdentifier(_ identifier: String?, team: String? = nil) -> Bool {
        guard let identifier = identifier?.lowercased() else { return false }
        if identifier.hasPrefix("com.trycua.driver") || isDriverName(identifier) { return true }
        if let team, driverTeams.contains(team), identifier.contains("driver") { return true }
        return identifier.hasPrefix("com.coreykozarski.nollie") && identifier.hasSuffix(".computer")
    }

    /// Whether something is listening on a Unix socket at `path`.
    static func answers(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    /// How a chat's platform reads on the card.
    static func platformName(_ source: String) -> String {
        let names = ["tui": "Terminal", "cli": "Terminal", "desktop": "Desktop", "photon": "iMessage", "sms": "SMS",
                     "whatsapp": "WhatsApp", "whatsapp_cloud": "WhatsApp", "bluebubbles": "iMessage"]
        return names[source.lowercased()] ?? source.capitalized
    }
}

/// The person proving they are at the Mac: Touch ID, or the Mac's password.
enum ComputerOwnerCheck {
    static func authenticate(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
#endif
