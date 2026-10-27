import SwiftUI
import NollieCore

/// Handing a quick-answer question to Nollie on the Mac, with one tap. With the Mac in reach it
/// goes into Nollie's main chat at once, which then opens. Out of reach, it waits on this device
/// and goes the moment the Mac is back. Each question is sent once at most: it leaves the waiting
/// list before the send starts, so a lost answer is never repeated. Whatever the helper does next
/// goes through Ask first as any message would.
@Observable @MainActor
final class QuickAnswerHandoff {
    static let shared = QuickAnswerHandoff()

    struct Waiting: Codable, Equatable, Identifiable {
        var id: UUID
        var text: String
        var at: Date
    }

    enum State: Equatable {
        case waiting, sending, sent
    }

    enum Outcome: Equatable {
        case sent
        /// It never reached the chat, so trying again cannot send it twice.
        case notSent
    }

    private static let key = "quickAnswers.forMac"

    private(set) var waiting: [Waiting]
    /// How each handed-off question stands, by the id of its quick-answer turn.
    private(set) var states: [UUID: State] = [:]
    /// Set when waiting questions went to the Mac, for the short note in the Chats list.
    private(set) var delivered: (count: Int, at: Date)?
    private var delivering = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        waiting = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Waiting].self, from: $0) } ?? []
        for entry in waiting { states[entry.id] = .waiting }
    }

    func state(of id: UUID) -> State? { states[id] }

    /// The one tap. Sends now when the Mac is in reach, otherwise keeps it for later.
    func handOff(id: UUID, text: String, model: AppModel) async {
        guard states[id] == nil else { return }
        guard let runtime = model.runtime, runtime.socketState.isOpen, !model.lock.isLocked else {
            queue(id: id, text: text)
            return
        }
        states[id] = .sending
        let bot = Self.mainBot(runtime)
        switch await Self.send(text, bot: bot, runtime: runtime) {
        case .sent:
            states[id] = .sent
            _ = await model.openMainChat(bot)
        case .notSent:
            states[id] = nil
            queue(id: id, text: text)
        }
    }

    /// Takes a waiting question back before it has gone.
    func cancel(_ id: UUID) {
        guard states[id] == .waiting else { return }
        waiting.removeAll { $0.id == id }
        states[id] = nil
        save()
    }

    /// Sends everything waiting, oldest first, once the Mac is back. Nothing opens; a short note
    /// says they went.
    func deliverWaiting(model: AppModel) async {
        guard !delivering, !waiting.isEmpty, let runtime = model.runtime, runtime.socketState.isOpen,
              !model.lock.isLocked else { return }
        delivering = true
        defer { delivering = false }
        // Just after a reconnect the bots may not be listed yet, and the main bot is picked from them.
        let giveUp = Date().addingTimeInterval(10)
        while runtime.profiles.isEmpty, Date() < giveUp, model.runtime === runtime {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let bot = Self.mainBot(runtime)
        var count = 0
        while let next = waiting.first, model.runtime === runtime, runtime.socketState.isOpen {
            // Off the list before sending: an answer lost on the way must not send it twice.
            waiting.removeFirst()
            save()
            states[next.id] = .sending
            guard await Self.send(next.text, bot: bot, runtime: runtime) == .sent else {
                // Nothing went, so it waits for the next try.
                waiting.insert(next, at: 0)
                states[next.id] = .waiting
                save()
                break
            }
            states[next.id] = .sent
            count += 1
        }
        if count > 0 { delivered = (count, Date()) }
    }

    func clearDelivered() { delivered = nil }

    /// Nollie, the main bot, when the gateway has it; otherwise the bot in use.
    static func mainBot(_ runtime: GatewayRuntime) -> String? {
        runtime.profiles.contains { $0.name == "default" } ? "default" : runtime.selectedProfile
    }

    /// Keeps a question on this device until the Mac is back.
    func queue(id: UUID, text: String) {
        let entry = Waiting(id: id, text: text, at: Date())
        waiting.removeAll { $0.id == entry.id }
        waiting.append(entry)
        states[entry.id] = .waiting
        save()
    }

    private func save() {
        if waiting.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let blob = try? JSONEncoder().encode(waiting) {
            defaults.set(blob, forKey: Self.key)
        }
    }

    /// The words as a message: a leading slash would make it a gateway command, so it is dropped.
    nonisolated static func message(_ text: String) -> String {
        var words = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while words.first == "/" { words = words.dropFirst() }
        return words.trimmingCharacters(in: .whitespaces)
    }

    /// Into the bot's main chat, starting one if it has none yet.
    private static func send(_ text: String, bot: String?, runtime: GatewayRuntime) async -> Outcome {
        let words = message(text)
        guard let name = bot, !words.isEmpty else { return .notSent }
        let chat: ChatSession
        switch await runtime.mainChat(profile: name) {
        case .found(let id):
            guard let open = try? await runtime.openChat(storedID: id, profile: name, waitForResume: true) else { return .notSent }
            chat = open
        case .missing:
            guard let started = try? await runtime.newChat(profile: name) else { return .notSent }
            await started.rename("Bot Chat") // A title the gateway matches on, so it stays in English.
            chat = started
        case .unknown:
            return .notSent
        }
        // A sentence back means the chat could not be opened, so nothing went.
        guard await chat.send(words) == nil else { return .notSent }
        NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
        return .sent
    }
}
