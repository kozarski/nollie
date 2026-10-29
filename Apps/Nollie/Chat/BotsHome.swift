import SwiftUI
import NollieCore

/// Chats as a list of bots, the way Messages lists people: one row per bot, which is its one
/// continuous conversation (the main chat), with its face, the last thing it said and what it is
/// doing right now. A bot's other chats are its history, a tap away. On the Mac the same rows are
/// the window's sidebar.
@MainActor
@Observable
final class BotsHome {
    static let shared = BotsHome()

    struct Entry: Equatable, Sendable {
        var storedID: String?
        var lastText: String?
        var lastDate: Date?
        /// Its main chat is mid-turn as far as the gateway's record shows (the newest row is a
        /// prompt or a tool's, minutes old at most): work started elsewhere (Signal, a phone, the
        /// terminal) still shows as working here.
        var busy = false
    }

    /// Per gateway and bot. Kept between appearances, so a row never comes back blank.
    private(set) var entries: [String: Entry] = [:]
    /// When each bot's main chat was last looked at here, for the unread dot.
    private(set) var seen: [String: Date] = BotsHome.loadSeen()
    private var refreshing = false
    private var refreshedAt: [UUID: Date] = [:]

    /// The bots pinned to the top: large faces on the phone and the first rows on Mac.
    nonisolated static let pinnedKey = "bots.pinned"
    nonisolated static let seenKey = "bots.lastSeen"
    static let maxPinned = 4

    nonisolated static func key(_ gateway: UUID, _ profile: String) -> String { gateway.uuidString + "|" + profile }

    func entry(_ runtime: GatewayRuntime, _ profile: String) -> Entry { entries[Self.key(runtime.connection.id, profile)] ?? Entry() }

    /// Something new from the bot since its chat was last open here. A bot never opened on this
    /// device counts as read: the first launch is not a wall of dots.
    func unread(_ runtime: GatewayRuntime, _ profile: String) -> Bool {
        let k = Self.key(runtime.connection.id, profile)
        guard let last = entries[k]?.lastDate, let s = seen[k] else { return false }
        return last > s.addingTimeInterval(1)
    }

    func markSeen(_ runtime: GatewayRuntime, _ profile: String) {
        let k = Self.key(runtime.connection.id, profile)
        seen[k] = max(Date(), entries[k]?.lastDate ?? .distantPast)
        saveSeen()
    }

    /// The bots in the list's order: the default bot first (the one Corey talks to most), then the
    /// others by their last word, newest first, then by name.
    func ordered(_ runtime: GatewayRuntime) -> [ProfileInfo] {
        let first = runtime.defaultProfile ?? runtime.profiles.first(where: { $0.isDefault == true })?.name
        return runtime.profiles.sorted { a, b in
            if (a.name == first) != (b.name == first) { return a.name == first }
            let da = entry(runtime, a.name).lastDate ?? .distantPast
            let db = entry(runtime, b.name).lastDate ?? .distantPast
            if da != db { return da > db }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
    }

    /// The pinned bots, in the order they were pinned (Pin in a bot's menu).
    func pinned(_ ordered: [ProfileInfo], raw: String) -> [ProfileInfo] {
        var seen = Set<String>()
        let names = raw.split(separator: ",").map(String.init).filter { seen.insert($0).inserted }
        return Array(names.compactMap { n in ordered.first { $0.name == n } }.prefix(Self.maxPinned))
    }

    /// One order for the sidebar, launch selection and keyboard navigation.
    func visibleOrder(_ ordered: [ProfileInfo], raw: String) -> [ProfileInfo] {
        let pins = pinned(ordered, raw: raw)
        let names = Set(pins.map(\.name))
        return pins + ordered.filter { !names.contains($0.name) }
    }

    /// With four bots or more and nothing pinned yet, the default bot and the next two are
    /// pinned once, so the top of the list starts out the way Messages' does. Nil: leave it.
    func firstPins(_ ordered: [ProfileInfo], raw: String) -> String? {
        guard raw.isEmpty, ordered.count >= 4 else { return nil }
        return ordered.prefix(3).map(\.name).joined(separator: ",")
    }

    static func toggledPin(_ raw: String, _ profile: String) -> String {
        var seen = Set<String>()
        var names = raw.split(separator: ",").map(String.init).filter { $0 != "-" && seen.insert($0).inserted }
        if let i = names.firstIndex(of: profile) { names.remove(at: i) } else if names.count < maxPinned { names.append(profile) }
        // Unpinning the last one must not bring the automatic three back.
        return names.isEmpty ? "-" : names.joined(separator: ",")
    }

    /// Every bot's main chat and the last thing it said there: one `profiles.list` for the main
    /// chats, then each bot's newest messages side by side. At most every 15 seconds unless forced.
    func refresh(_ runtime: GatewayRuntime, force: Bool = false) async {
        guard !refreshing else { return }
        let gateway = runtime.connection.id
        if !force, let at = refreshedAt[gateway], Date().timeIntervalSince(at) < 15 { return }
        refreshing = true
        defer { refreshing = false; refreshedAt[gateway] = Date() }
        if runtime.profiles.isEmpty { await runtime.loadProfiles() }
        let names = runtime.profiles.map(\.name)
        guard !names.isEmpty else { return }
        var ids: [String: String] = [:]
        if let r = try? await runtime.rpc("profiles.list", timeout: 15), let rows = r["profiles"]?.arrayValue {
            for row in rows {
                guard let name = row["name"]?.stringValue, let cs = row["canonical_session"], !cs.isNull,
                      let id = cs["resolved_id"]?.stringValue ?? cs["id"]?.stringValue, !id.isEmpty else { continue }
                ids[name] = id
            }
        }
        // A gateway that did not say: the bot's "Bot Chat", found the long way, once.
        for name in names where ids[name] == nil {
            if let known = entries[Self.key(gateway, name)]?.storedID { ids[name] = known }
            else if let found = await runtime.mainChatID(profile: name) { ids[name] = found }
        }
        #if os(macOS)
        CloudAlertHelperController.shared.updateCanonicalSession(connectionID: gateway, sessionID: ids["default"])
        #endif
        // One bot at a time (a handful of small reads); each row fills in as its answer comes.
        for name in names {
            let k = Self.key(gateway, name)
            var e = Entry(storedID: ids[name] ?? entries[k]?.storedID)
            if let sid = e.storedID, let last = await Self.lastReply(runtime, storedID: sid, profile: name) {
                // Mid-turn with nothing said yet: the row keeps the last thing it did say.
                e.lastText = last.text.isEmpty ? entries[k]?.lastText : last.text
                e.lastDate = last.date ?? entries[k]?.lastDate
                e.busy = last.busy
            } else if let old = entries[k], old.storedID == e.storedID {
                // Nothing came back this time (a slow or failed read): the row keeps what it
                // showed rather than falling back to "Say hello" until the next refresh.
                e.lastText = old.lastText
                e.lastDate = old.lastDate
                e.busy = old.busy
            }
            // A reply seen live since is newer than what the gateway said a moment ago.
            if let old = entries[k], let od = old.lastDate, od > (e.lastDate ?? .distantPast) {
                e.lastText = old.lastText
                e.lastDate = od
            }
            if e != entries[k] { entries[k] = e }
            if seen[k] == nil { seen[k] = e.lastDate ?? Date(); saveSeen() }
        }
        // Each bot's System control switch (at most once a minute), for its menu and its cards.
        await SystemControl.shared.refreshAll(runtime)
    }

    /// A reply that just finished in a chat open on this device: its bot's row shows it at once,
    /// counted as read when that chat is the one in front.
    func noteReply(_ runtime: GatewayRuntime, storedID: String, text: String, visible: Bool) {
        let prefix = runtime.connection.id.uuidString + "|"
        guard let k = entries.first(where: { $0.key.hasPrefix(prefix) && $0.value.storedID == storedID })?.key else { return }
        entries[k]?.lastText = MainChatCard.oneLine(PlainReply.text(text))
        entries[k]?.lastDate = Date()
        entries[k]?.busy = false
        if visible { seen[k] = Date(); saveSeen() }
    }

    /// The last thing a bot said in its main chat: fresh from the gateway, else what this device
    /// kept of the thread.
    static func lastReply(_ runtime: GatewayRuntime, storedID: String, profile: String) async -> (text: String, date: Date?, busy: Bool)? {
        var messages: [TranscriptMessage] = []
        var busy = false
        // Quiet background runs can fill the small preview page. Expand only for those
        // replies, far enough to find their prompt and the last useful answer.
        for limit in [12, 60, 200] {
            let page = [URLQueryItem(name: "limit", value: "\(limit)"), URLQueryItem(name: "order", value: "latest")]
            guard let reply: JSONValue = try? await runtime.api.get("/api/sessions/\(storedID)/messages", query: page, profile: profile) else { break }
            let raw = (reply["messages"]?.arrayValue ?? []).compactMap { try? $0.decode(TranscriptMessage.self) }
            busy = midTurn(raw)
            messages = TranscriptItem.withPromotedAnswers(raw)
            let last = messages.last(where: { $0.role == "assistant" && !($0.text ?? "").isEmpty })
            guard AutomatedReply.isControlMarker(last?.text) || last?.controlMarker == "intentional_silence", raw.count >= limit else { break }
            let prompt = messages.last(where: { $0.role == "user" })
            let hasContext = prompt != nil
            let visible = AutomatedReply.previewMessages(messages)
            let hasReply = visible.contains { $0.role == "assistant" && !($0.text ?? "").isEmpty }
            if hasContext && hasReply { break }
        }
        if messages.isEmpty, let cached = TranscriptCache.load(connection: runtime.connection.id, storedID: storedID) { messages = cached }
        guard let last = latestVisibleReply(in: messages) else { return messages.isEmpty ? nil : ("", nil, busy) }
        let text = MainChatCard.oneLine(PlainReply.text(last.text ?? ""))
        return (text, last.timestamp.map { Date(timeIntervalSince1970: $0) }, busy)
    }

    nonisolated static func latestVisibleReply(in messages: [TranscriptMessage]) -> TranscriptMessage? {
        AutomatedReply.previewMessages(messages).last {
            ($0.role == "assistant" || $0.role == "error") && !($0.text ?? "").isEmpty
        }
    }

    /// The newest stored row is a prompt waiting for its answer or a step of a turn (a tool's row,
    /// or a reply that asked for tools), and it is recent: the turn is still going.
    nonisolated static func midTurn(_ rows: [TranscriptMessage], now: Date = Date(), window: TimeInterval = 150) -> Bool {
        guard let last = rows.last(where: { $0.role != "system" }), let t = last.timestamp else { return false }
        guard now.timeIntervalSince1970 - t < window else { return false }
        return last.role == "user" || last.role == "tool" || (last.role == "assistant" && last.hasToolCalls)
    }

    /// "9:41 AM", "Yesterday", "Tuesday", else "12 Oct": how Messages dates a conversation.
    static func when(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        let wasYesterday = cal.date(byAdding: .day, value: -1, to: now).map { cal.isDate(date, inSameDayAs: $0) } ?? false
        if wasYesterday { return String(localized: "Yesterday") }
        let thisWeek = cal.date(byAdding: .day, value: -6, to: now).map { date > $0 } ?? false
        if thisWeek { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    nonisolated private static func loadSeen() -> [String: Date] {
        guard let d = UserDefaults.standard.data(forKey: seenKey), let m = try? JSONDecoder().decode([String: Double].self, from: d) else { return [:] }
        return m.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func saveSeen() {
        if let d = try? JSONEncoder().encode(seen.mapValues(\.timeIntervalSince1970)) { UserDefaults.standard.set(d, forKey: Self.seenKey) }
    }
}

/// What a bot is up to across this device's open chats, the board and its main chat's record:
/// working, and whether a chat of its waits on Corey.
@MainActor
struct BotPresence {
    var working = false
    var needsYou = false
    /// The chat it is working in, for its row's line and for where a click on the row goes.
    var live: ChatSession?
    /// A card of its is being worked on the board.
    var onBoard = false

    init(runtime: GatewayRuntime, profile: String, mainID: String?, remoteBusy: Bool = false) {
        let chats = runtime.chats.filter { $0.profileName == profile }
        live = chats.first { $0.isRunning }
        onBoard = runtime.kanban.activity.state(for: profile) == .working
        working = live != nil || onBoard || remoteBusy || BotComputerActivity.hasDelegatedWork(runtime: runtime, profile: profile)
        needsYou = chats.contains { runtime.needsAttention.contains($0.storedID) } || (mainID.map { runtime.needsAttention.contains($0) } ?? false)
    }
}
