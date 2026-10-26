import FoundationModels
import SwiftUI
import NollieCore

/// Quick answers: short replies from the model built into this device, for when the helper on the
/// Mac is out of reach or not set up yet. It talks only: no tools, no actions, none of the
/// person's own things, and nothing leaves the device. A request that needs more goes to the
/// helper by fixed rules (`QuickAnswerRules`), never by the model's judgement. Nothing is saved:
/// the conversation lasts as long as the sheet.
@Observable @MainActor
final class QuickAnswers {
    struct Turn: Identifiable, Equatable {
        enum State: Equatable {
            case writing
            case done
            /// Not for this device. The fixed line says why; the helper can take it.
            case helper(QuickAnswerRules.Reason)
            case failed(QuickAnswerFailure)
        }

        let id: UUID
        var question: String
        var answer = ""
        var state: State = .writing

        init(id: UUID = UUID(), question: String) {
            self.id = id
            self.question = question
        }

        /// A finished reply that the helper on the Mac could carry on with.
        var canHandOff: Bool {
            switch state {
            case .done, .helper: true
            case .writing, .failed: false
            }
        }
    }

    nonisolated static let enabledKey = "quickAnswers.enabled"

    let place: QuickAnswerRules.Place
    private(set) var turns: [Turn] = []
    private let engine: QuickAnswerEngine
    private var task: Task<Void, Never>?

    init(place: QuickAnswerRules.Place, engine: QuickAnswerEngine? = nil) {
        self.place = place
        self.engine = engine ?? (Self.pretend ? StandInEngine() : OnDeviceEngine())
    }

    var isWriting: Bool { turns.last?.state == .writing }

    // MARK: Availability

    /// On unless switched off in Settings.
    nonisolated static var isOn: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Debug builds can pass `-nollie-test-quick-answers`: a simulator or a Mac without Apple
    /// Intelligence then gets stand-in replies, so the screens can be seen and tested.
    nonisolated static var pretend: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-nollie-test-quick-answers")
        #else
        false
        #endif
    }

    /// Apple Intelligence is on, its model is ready and it speaks the person's language.
    nonisolated static var isAvailable: Bool {
        if pretend { return true }
        let model = SystemLanguageModel.default
        return model.availability == .available && model.supportsLocale()
    }

    /// Whether to show quick answers at all. When the model can't run here, the option is simply
    /// not there.
    nonisolated static var offered: Bool { isOn && isAvailable && !stoppedWorking }

    /// Set when the model says it is ready but can't answer at all, as some Macs do while Apple's
    /// safety check fails. The way in then goes quietly until the next launch.
    nonisolated(unsafe) static var stoppedWorking = false

    // MARK: Asking

    /// Answers on this device, or hands back the fixed line when the request is the helper's.
    func ask(_ raw: String) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isWriting else { return }
        var turn = Turn(question: question)
        if case .helper(let reason) = QuickAnswerRules.route(question) {
            turn.answer = QuickAnswerRules.helperLine(reason, place: place)
            turn.state = .helper(reason)
            turns.append(turn)
            return
        }
        let earlier = turns.compactMap { past -> QuickAnswerRules.Exchange? in
            guard past.state == .done else { return nil }
            return QuickAnswerRules.Exchange(question: past.question, answer: past.answer)
        }
        turns.append(turn)
        let id = turn.id
        task = Task { await self.write(id, question: question, earlier: earlier) }
    }

    /// Stops the reply being written. What arrived so far stays.
    func stop() {
        task?.cancel()
        task = nil
        update(turns.last?.id) { turn in
            guard turn.state == .writing else { return }
            turn.state = turn.answer.isEmpty ? .failed(.cancelled) : .done
        }
    }

    /// Waits for the reply being written, for tests and the demo.
    func settle() async { await task?.value }

    private func write(_ id: UUID, question: String, earlier: [QuickAnswerRules.Exchange]) async {
        var memory = earlier
        while true {
            do {
                for try await text in engine.answer(question, earlier: memory, place: place) {
                    guard !Task.isCancelled else { return }
                    update(id) { $0.answer = text }
                }
                guard !Task.isCancelled else { return }
                finish(id)
                return
            } catch {
                guard !Task.isCancelled else { return }
                let failure = QuickAnswerFailure(error)
                let kind = error as NSError
                NollieLog.chat.notice("Quick answer failed", detail: "\(failure) \(kind.domain) \(kind.code)")
                if failure == .unavailable { Self.stoppedWorking = true }
                // A full window gets one more go without the earlier chat.
                if failure == .contextFull, !memory.isEmpty {
                    memory = []
                    update(id) { $0.answer = "" }
                    continue
                }
                update(id) { $0.state = .failed(failure) }
                return
            }
        }
    }

    /// A finished reply is checked before it stays: one that claims to have acted is replaced by
    /// the fixed line, as nothing was done.
    private func finish(_ id: UUID) {
        update(id) { turn in
            let said = turn.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if said.isEmpty {
                turn.state = .failed(.empty)
            } else if QuickAnswerRules.claimsAction(said) {
                turn.answer = QuickAnswerRules.helperLine(.action, place: place)
                turn.state = .helper(.action)
            } else {
                turn.answer = said
                turn.state = .done
            }
        }
        task = nil
    }

    private func update(_ id: UUID?, _ change: (inout Turn) -> Void) {
        guard let id, let at = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[at])
    }
}

/// Why a quick answer didn't come, in words for people. Never the framework's own message.
enum QuickAnswerFailure: Equatable {
    case contextFull, busy, declined, language, unavailable, empty, cancelled

    init(_ error: Error) {
        if error is CancellationError { self = .cancelled; return }
        if #available(iOS 27.0, macOS 27.0, *), let failure = Self.current(error) { self = failure; return }
        self = Self.earlier(error) ?? .unavailable
    }

    @available(iOS 27.0, macOS 27.0, *)
    private static func current(_ error: Error) -> QuickAnswerFailure? {
        if let session = error as? LanguageModelSession.Error {
            return session == .concurrentRequests ? .busy : .unavailable
        }
        guard let model = error as? LanguageModelError else { return nil }
        switch model {
        case .contextSizeExceeded: return .contextFull
        case .rateLimited, .timeout: return .busy
        case .guardrailViolation, .refusal: return .declined
        case .unsupportedLanguageOrLocale: return .language
        default: return .unavailable
        }
    }

    /// The errors of the 26 releases.
    private static func earlier(_ error: Error) -> QuickAnswerFailure? {
        guard let generation = error as? LanguageModelSession.GenerationError else { return nil }
        switch generation {
        case .exceededContextWindowSize: return .contextFull
        case .rateLimited, .concurrentRequests: return .busy
        case .guardrailViolation, .refusal: return .declined
        case .unsupportedLanguageOrLocale: return .language
        default: return .unavailable
        }
    }

    var words: String {
        switch self {
        case .contextFull: "That's a lot for a quick answer. Try a shorter question."
        case .busy: "Quick answers are busy. Try again in a moment."
        case .declined: "That's not one I can answer here."
        case .language: "Quick answers don't speak this language yet."
        case .unavailable: "Quick answers aren't working on \(DeviceWords.this) right now."
        case .empty: "No answer came back. Try asking another way."
        case .cancelled: "Stopped."
        }
    }
}

// MARK: Engines

/// Writes a reply, handing back the whole text so far each time it grows.
protocol QuickAnswerEngine: Sendable {
    func answer(_ question: String, earlier: [QuickAnswerRules.Exchange], place: QuickAnswerRules.Place) -> AsyncThrowingStream<String, Error>
}

/// Apple's model on this device, with no tools. A fresh session for each question keeps the small
/// window for the latest exchanges.
struct OnDeviceEngine: QuickAnswerEngine {
    func answer(_ question: String, earlier: [QuickAnswerRules.Exchange], place: QuickAnswerRules.Place) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let model = SystemLanguageModel.default
                    let memory = QuickAnswerRules.window(earlier, budget: QuickAnswerRules.memoryBudget(contextTokens: model.contextSize))
                    let session = LanguageModelSession(model: model, instructions: QuickAnswerBrief.instructions(for: place))
                    let options = GenerationOptions(temperature: 0.5, maximumResponseTokens: 450)
                    for try await snapshot in session.streamResponse(to: QuickAnswerBrief.prompt(question, earlier: memory), options: options) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}

/// What the model is told. It is also told it has no tools, but the rules around it do not rely
/// on that: it is given none.
enum QuickAnswerBrief {
    static func instructions(for place: QuickAnswerRules.Place) -> String {
        let helper = switch place {
        case .macAway: "Nollie on their Mac"
        case .macSetup, .phoneSetup: "Nollie, once it is set up on their Mac"
        }
        return """
            You are Nollie, a warm and friendly assistant, answering on the person's own device. \
            Keep answers short: a few plain sentences, or a short list when it helps. Use British spelling. \
            You can explain things, give ideas, and draft or reword text for the person to copy. \
            You have no tools. You cannot send, buy, book, post, delete, open apps, set reminders or change anything, \
            and you cannot see the person's calendar, mail, messages, files or the internet. \
            Never say or suggest that you did any of these. If asked, say that \(helper) can help. \
            If you are not sure of a fact, say so.
            """
    }

    static func prompt(_ question: String, earlier: [QuickAnswerRules.Exchange]) -> String {
        guard !earlier.isEmpty else { return question }
        let lines = earlier.map { "Person: \($0.question)\nNollie: \($0.answer)" }.joined(separator: "\n\n")
        return "Earlier in this chat:\n\(lines)\n\nNow the person asks: \(question)"
    }
}

/// Debug only: canned replies, a word at a time, for screens and UI tests.
struct StandInEngine: QuickAnswerEngine {
    func answer(_ question: String, earlier: [QuickAnswerRules.Exchange], place: QuickAnswerRules.Place) -> AsyncThrowingStream<String, Error> {
        let reply = Self.reply(to: question)
        return AsyncThrowingStream { continuation in
            let work = Task {
                var said = ""
                for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
                    try? await Task.sleep(for: .milliseconds(35))
                    if Task.isCancelled { break }
                    said += (said.isEmpty ? "" : " ") + word
                    continuation.yield(said)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    static func reply(to question: String) -> String {
        let asked = question.lowercased()
        if asked.contains("reword") || asked.contains("warmer") {
            return "Here's a warmer version:\n\n\"I'm so sorry I can't make it on Saturday. I hope it's a brilliant evening, and let's catch up soon.\""
        }
        if asked.contains("dinner") || asked.contains("cook") {
            return "A quick spinach and feta omelette, a tray of roast veg with chickpeas, or a simple tomato pasta with a big green salad."
        }
        return "Here's a short answer to get you going. Ask me to make it shorter or simpler if you like."
    }
}
