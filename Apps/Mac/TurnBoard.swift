import AppKit
import NollieCore

/// Everything the Mac is occupied with, in one list: turns underway and approvals that need the
/// person. The status item in the menu bar lists these, and the Dock tile counts the ones awaiting a reply.
@MainActor
@Observable
final class TurnBoard {
    static let shared = TurnBoard()

    struct Turn: Identifiable {
        /// A chat's turn here, or work the gateway reports that no chat here shows.
        enum Kind: Equatable {
            case chat
            case schedule(jobID: String)
            case board(taskID: String)
        }

        let id: String
        let startedAt: Date
        var title: String
        var bot: String
        var profile: String
        var detail: String
        var attention: Bool
        var kind: Kind
        weak var chat: ChatSession?

        /// The schedule whose run this row is.
        var jobID: String? {
            if case .schedule(let id) = kind { return id }
            return nil
        }

        init(id: String, title: String, bot: String, profile: String, detail: String,
             attention: Bool, startedAt: Date, chat: ChatSession? = nil, kind: Kind = .chat) {
            self.id = id
            self.startedAt = startedAt
            self.title = title
            self.bot = bot
            self.profile = profile
            self.detail = detail
            self.attention = attention
            self.kind = kind
            self.chat = chat
        }
    }

    /// Rows for gateway work have ids under this, so a chat's stored id never meets one.
    nonisolated static let gatewayPrefix = "gateway:"

    private(set) var turns = [Turn]()

    var running: Int { turns.count(where: { !$0.attention }) }
    var attention: Int { turns.count(where: \.attention) }

    /// Approvals the menu bar may refuse but never grant. An Ask first hold has to be read in
    /// full on its card, and a saved sign-in needs Touch ID.
    nonisolated static func answersInApp(_ approval: ApprovalRequest) -> Bool {
        let reserved = [AskFirstAsk.rulePrefix, SignInAsk.rulePrefix]
        return approval.patternKey.map { key in reserved.contains(where: key.hasPrefix) } ?? false
    }

    func upsert(_ turn: Turn) {
        switch turns.firstIndex(where: { $0.id == turn.id }) {
        case let slot?: turns[slot] = turn
        case nil: turns.append(turn)
        }
        showIndicators()
    }

    func remove(_ id: String) {
        turns.removeAll { $0.id == id }
        showIndicators()
    }

    /// Schedules running and Board cards being worked, as the gateway reports them, as rows beside
    /// the chats' turns: started by the Mac's scheduler, the Board or another device. A schedule's
    /// row has its own Stop. Private bots never show (the gateway's lists leave them out).
    func showGatewayWork(_ runtime: GatewayRuntime?, now: Date = Date()) {
        let fresh = Self.gatewayTurns(runtime, now: now)
        let ids = Set(fresh.map(\.id))
        let before = turns.map(\.id)
        turns.removeAll { $0.id.hasPrefix(Self.gatewayPrefix) && !ids.contains($0.id) }
        for turn in fresh {
            switch turns.firstIndex(where: { $0.id == turn.id }) {
            case let slot?: turns[slot] = turn
            case nil: turns.append(turn)
            }
        }
        if turns.map(\.id) != before { showIndicators() }
    }

    static func gatewayTurns(_ runtime: GatewayRuntime?, now: Date = Date()) -> [Turn] {
        guard let runtime else { return [] }
        func name(_ profile: String) -> String {
            runtime.profiles.first { $0.name == profile }?.shownName ?? ProfileInfo.shownName(of: profile)
        }
        let isPrivate = { (profile: String) in PrivateBots.isPrivate(profile, connection: runtime.connection.id) }
        var found: [Turn] = []
        for run in runtime.schedules.activity.current(now: now) where !isPrivate(run.profile) {
            found.append(Turn(id: gatewayPrefix + "schedule:" + run.jobID, title: run.name, bot: name(run.profile), profile: run.profile,
                              detail: String(localized: "Running on schedule", comment: "A schedule's run is in progress"),
                              attention: false, startedAt: run.startedAt, kind: .schedule(jobID: run.jobID)))
        }
        let board = runtime.kanban.activity
        for profile in board.work.keys.sorted() where !isPrivate(profile) {
            guard let card = board.work(for: profile, now: now) else { continue }
            found.append(Turn(id: gatewayPrefix + "board:" + card.taskID, title: card.title, bot: name(profile), profile: profile,
                              detail: String(localized: "Working on the Board", comment: "A helper is working a Board task"),
                              attention: false, startedAt: card.since ?? now, kind: .board(taskID: card.taskID)))
        }
        return found
    }

    private func showIndicators() {
        NSApp.dockTile.badgeLabel = attention > 0 ? "\(attention)" : nil
        // Idle bots only play with their eyes while something is working (#248).
        let anyoneBusy = !turns.isEmpty
        guard BotAmbient.shared.anyWorking != anyoneBusy else { return }
        BotAmbient.shared.anyWorking = anyoneBusy
    }
}

/// Keeps the menu bar's rows for gateway work in step with what the runtime last saw, for as long
/// as the app runs, whichever gateway is in use.
@MainActor
enum GatewayWorkMirror {
    private static var started = false

    static func start(_ model: AppModel) {
        guard !started else { return }
        started = true
        follow(model)
    }

    private static func follow(_ model: AppModel) {
        withObservationTracking {
            let runtime = model.runtime
            _ = runtime?.schedules.activity
            _ = runtime?.kanban.activity
            _ = runtime?.profiles
            TurnBoard.shared.showGatewayWork(runtime)
        } onChange: {
            Task { @MainActor in follow(model) }
        }
    }
}
