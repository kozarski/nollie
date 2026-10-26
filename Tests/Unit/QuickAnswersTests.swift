import Foundation
import FoundationModels
import Testing
@testable import Nollie
@testable import NollieCore

/// Quick answers end to end with a stand-in model: what reaches the model, what never does,
/// how failures read, and how a question waits for the Mac.
@MainActor @Suite struct QuickAnswersTests {
    /// Replies from a script and remembers what it was asked.
    final class ScriptedEngine: QuickAnswerEngine, @unchecked Sendable {
        var replies: [Result<[String], Error>]
        private(set) var asked: [(question: String, earlier: [QuickAnswerRules.Exchange])] = []

        init(_ replies: [Result<[String], Error>]) { self.replies = replies }

        func answer(_ question: String, earlier: [QuickAnswerRules.Exchange], place: QuickAnswerRules.Place) -> AsyncThrowingStream<String, Error> {
            asked.append((question, earlier))
            let next = replies.isEmpty ? .success([]) : replies.removeFirst()
            return AsyncThrowingStream { continuation in
                switch next {
                case .success(let parts):
                    parts.forEach { continuation.yield($0) }
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    struct Broken: Error {}

    @Test func anEverydayQuestionIsAnsweredHere() async {
        let engine = ScriptedEngine([.success(["Lima", "Lima is the capital of Peru."])])
        let answers = QuickAnswers(place: .macAway, engine: engine)
        answers.ask("  What's the capital of Peru?  ")
        await answers.settle()
        #expect(engine.asked.map(\.question) == ["What's the capital of Peru?"])
        #expect(answers.turns.last?.answer == "Lima is the capital of Peru.")
        #expect(answers.turns.last?.state == .done)
        #expect(answers.turns.last?.canHandOff == true)
    }

    @Test func anActionNeverReachesTheModel() async {
        let engine = ScriptedEngine([])
        let answers = QuickAnswers(place: .macAway, engine: engine)
        answers.ask("Text Sam that I'm running late")
        await answers.settle()
        #expect(engine.asked.isEmpty)
        #expect(answers.turns.last?.state == .helper(.action))
        #expect(answers.turns.last?.answer == QuickAnswerRules.helperLine(.action, place: .macAway))
        #expect(answers.turns.last?.canHandOff == true)
    }

    @Test func aReplyClaimingItActedIsReplaced() async {
        let engine = ScriptedEngine([.success(["Done! I've booked a table for two at eight."])])
        let answers = QuickAnswers(place: .macSetup, engine: engine)
        answers.ask("Is eight a good time for dinner?")
        await answers.settle()
        #expect(answers.turns.last?.state == .helper(.action))
        #expect(answers.turns.last?.answer == QuickAnswerRules.helperLine(.action, place: .macSetup))
    }

    @Test func onlyFinishedAnswersAreRememberedForTheNextQuestion() async {
        let engine = ScriptedEngine([.success(["Try an omelette."]), .success(["Add feta."])])
        let answers = QuickAnswers(place: .phoneSetup, engine: engine)
        answers.ask("Dinner ideas with eggs?")
        await answers.settle()
        answers.ask("Send it to Mum")
        await answers.settle()
        answers.ask("And something to go with it?")
        await answers.settle()
        #expect(engine.asked.count == 2)
        #expect(engine.asked.last?.earlier == [QuickAnswerRules.Exchange(question: "Dinner ideas with eggs?", answer: "Try an omelette.")])
    }

    @Test func aFullWindowTriesOnceMoreWithoutTheEarlierChat() async {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let full = LanguageModelError.contextSizeExceeded(.init(contextSize: 4_096, tokenCount: 5_000, debugDescription: "full"))
        let engine = ScriptedEngine([.success(["First answer."]), .failure(full), .success(["Second answer."])])
        let answers = QuickAnswers(place: .macAway, engine: engine)
        answers.ask("One?")
        await answers.settle()
        answers.ask("Two?")
        await answers.settle()
        #expect(engine.asked.count == 3)
        #expect(engine.asked[1].earlier.count == 1)
        #expect(engine.asked[2].earlier.isEmpty)
        #expect(answers.turns.last?.answer == "Second answer.")
    }

    @Test func failuresReadPlainlyAndNeverShowTheFrameworksWords() async {
        let engine = ScriptedEngine([.failure(NSError(domain: "FoundationModels.LanguageModelError", code: -1,
                                                      userInfo: [NSLocalizedDescriptionKey: "com.apple.SensitiveContentAnalysisML error 15."])),
                                     .success(["   "])])
        let answers = QuickAnswers(place: .macAway, engine: engine)
        answers.ask("Hello?")
        await answers.settle()
        #expect(answers.turns.last?.state == .failed(.unavailable))
        #expect(answers.turns.last?.canHandOff == false)
        // A model that can't answer at all takes the way in away until the next launch.
        #expect(QuickAnswers.stoppedWorking)
        #expect(!QuickAnswers.offered)
        QuickAnswers.stoppedWorking = false
        answers.ask("Anyone there?")
        await answers.settle()
        #expect(answers.turns.last?.state == .failed(.empty))
        for failure in [QuickAnswerFailure.contextFull, .busy, .declined, .language, .unavailable, .empty, .cancelled] {
            #expect(!failure.words.contains("Error"))
            #expect(!failure.words.contains("—"))
        }
        if #available(iOS 27.0, macOS 27.0, *) {
            #expect(QuickAnswerFailure(LanguageModelSession.Error.concurrentRequests) == .busy)
        }
        #expect(QuickAnswerFailure(CancellationError()) == .cancelled)
        #expect(QuickAnswerFailure(Broken()) == .unavailable)
    }

    @Test func aBlankQuestionAsksNothing() async {
        let engine = ScriptedEngine([])
        let answers = QuickAnswers(place: .macAway, engine: engine)
        answers.ask("   \n ")
        #expect(answers.turns.isEmpty)
        #expect(engine.asked.isEmpty)
    }

    @Test func theInstructionsSayItHasNoToolsAndNameTheRightHelper() {
        #expect(QuickAnswerBrief.instructions(for: .macAway).contains("You have no tools"))
        #expect(QuickAnswerBrief.instructions(for: .macAway).contains("Nollie on their Mac"))
        #expect(QuickAnswerBrief.instructions(for: .macSetup).contains("once it is set up"))
        let prompt = QuickAnswerBrief.prompt("And then?", earlier: [.init(question: "First?", answer: "Yes.")])
        #expect(prompt.contains("Person: First?\nNollie: Yes."))
        #expect(prompt.hasSuffix("Now the person asks: And then?"))
        #expect(QuickAnswerBrief.prompt("Just this", earlier: []) == "Just this")
    }

    @Test func aQuestionForTheMacWaitsOnThisDeviceUntilSentOrTakenBack() {
        let suite = "quickAnswers.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID(), second = UUID()
        let handoff = QuickAnswerHandoff(defaults: defaults)
        handoff.queue(id: first, text: "Book the dentist")
        handoff.queue(id: second, text: "Text Sam")
        #expect(handoff.state(of: first) == .waiting)

        // Still there after the app starts again.
        let reopened = QuickAnswerHandoff(defaults: defaults)
        #expect(reopened.waiting.map(\.text) == ["Book the dentist", "Text Sam"])
        #expect(reopened.state(of: second) == .waiting)

        reopened.cancel(first)
        #expect(reopened.waiting.map(\.id) == [second])
        #expect(reopened.state(of: first) == nil)
        #expect(QuickAnswerHandoff(defaults: defaults).waiting.map(\.id) == [second])
    }

    @Test func aHandedOffQuestionCanNeverRunAGatewayCommand() {
        #expect(QuickAnswerHandoff.message("/new") == "new")
        #expect(QuickAnswerHandoff.message("  //reset everything ") == "reset everything")
        #expect(QuickAnswerHandoff.message("Book a table") == "Book a table")
        #expect(QuickAnswerHandoff.message("/").isEmpty)
    }
}
