import Foundation
import NollieCore

/// Created per chat by the runtime (`activityReporterFactory`). It holds the chat's row on the board
/// from a turn's first word until that turn finishes.
@MainActor
final class MenuBarTurnReporter: TurnActivityReporting {
    private var listedID: String?
    private var began = Date()

    // If a chat is closed or deleted partway through a turn, its row has to go too. A leftover row
    // kept all the idle bots' eyes moving (#248).
    isolated deinit {
        if let listedID { TurnBoard.shared.remove(listedID) }
    }

    func start(for chat: ChatSession) {
        // Fires for each chunk of a reply and again when the session snapshot lands. A turn already on the
        // list holds its original start time, so the timer never snaps back to 0:00.
        guard let listed = listedID else {
            began = Date()
            listedID = chat.storedID
            publish(chat, line: String(localized: "Thinking…"), attention: false)
            return
        }
        if listed != chat.storedID {
            TurnBoard.shared.remove(listed)
            listedID = chat.storedID
        }
        update(for: chat, attention: chat.firstCard != nil, detail: nil)
    }

    func update(for chat: ChatSession, attention: Bool, detail: String?) {
        guard listedID != nil else { return }
        let line: String
        if let detail {
            line = detail
        } else if attention {
            line = Self.waitingLine(for: chat.firstCard)
        } else {
            line = chat.statusWords ?? String(localized: "Thinking…")
        }
        publish(chat, line: line, attention: attention)
    }

    func end(for chat: ChatSession, phase: String) {
        let finished = listedID
        listedID = nil
        BotAmbient.shared.turnFinished(profile: chat.profileName)
        if let finished { TurnBoard.shared.remove(finished) }
    }

    /// What a turn says while it waits on the person.
    private static func waitingLine(for card: PendingCard?) -> String {
        switch (card?.method, card?.approval?.description) {
        case ("sudo", _): return String(localized: "sudo password needed")
        case (_, let words?): return words
        case ("approval", nil): return String(localized: "Approval needed")
        default: return String(localized: "Needs your answer")
        }
    }

    private func publish(_ chat: ChatSession, line: String, attention: Bool) {
        let bot = chat.runtime.profiles.first { $0.name == chat.profileName }
        TurnBoard.shared.upsert(TurnBoard.Turn(
            id: chat.storedID, title: chat.title, bot: bot?.shownName ?? chat.profileName,
            profile: chat.profileName, detail: line, attention: attention, startedAt: began, chat: chat))
    }
}
