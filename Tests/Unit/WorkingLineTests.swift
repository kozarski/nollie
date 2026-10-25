import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// The one-line status for a chat that is working: when a new line is due, how the model's
/// words are trimmed to fit, what the model is shown, and the loop that ties them together.
@MainActor @Suite struct WorkingLineTests {
    private typealias Pace = ChatGoals.Pace

    /// One question for the pacing rule: what exists, how old the turn is, and how many steps and
    /// seconds have gone by since the last line was made.
    private struct Moment {
        var madeWith: (steps: Int, turn: String)?
        var turn = "u1"
        var turnAge: TimeInterval
        var steps: Int
        var sinceLine: TimeInterval = 0

        func isDue(from origin: Date) -> Bool {
            let goal = madeWith.map { ChatGoals.Goal(text: "Tracing the slowdown", turn: $0.turn, madeAt: origin, steps: $0.steps) }
            return Pace.due(goal: goal, turn: turn, turnAge: turnAge, steps: steps, now: origin.addingTimeInterval(sinceLine))
        }
    }

    @Test func aLineIsDueSoonAfterATurnBeginsThenOnlyAsTheWorkMovesOn() {
        let origin = Date(timeIntervalSince1970: 2_000)
        let table: [(String, Moment, Bool)] = [
            // A very new turn gets nothing: a quick answer would finish first.
            ("one second in", Moment(turnAge: 1, steps: 0), false),
            ("two seconds in", Moment(turnAge: 2, steps: 0), true),
            // The first line is based on the prompt only; it is reconsidered once two steps and fifteen seconds have passed.
            ("first line, many steps, too soon", Moment(madeWith: (0, "u1"), turnAge: 30, steps: 5, sinceLine: 10), false),
            ("first line, long ago, too few steps", Moment(madeWith: (0, "u1"), turnAge: 30, steps: 1, sinceLine: 60), false),
            ("first line, two steps and fifteen seconds", Moment(madeWith: (0, "u1"), turnAge: 30, steps: 2, sinceLine: 15), true),
            // Later ones need three more steps and 45 seconds, so a line isn't rewritten on every tool call.
            ("later line, long ago, too few steps", Moment(madeWith: (4, "u1"), turnAge: 90, steps: 6, sinceLine: 120), false),
            ("later line, many steps, too soon", Moment(madeWith: (4, "u1"), turnAge: 90, steps: 9, sinceLine: 30), false),
            ("later line, three steps and 45 seconds", Moment(madeWith: (4, "u1"), turnAge: 90, steps: 7, sinceLine: 45), true),
            // A fresh turn starts the count again.
            ("another turn", Moment(madeWith: (4, "u1"), turn: "u2", turnAge: 3, steps: 0, sinceLine: 1), true),
        ]
        for (label, moment, due) in table { #expect(moment.isDue(from: origin) == due, "\(label)") }
    }

    @Test func theModelsWordsAreTrimmedToOneLine() {
        let trimmed: [(String, String?)] = [
            ("\"Working out why the sync stalls.\"", "Working out why the sync stalls"),
            ("  looking at the mail queue…", "Looking at the mail queue"),
            ("Pruning old caches\nplus a second line nobody asked for", "Pruning old caches"),
            ("ok", nil),
            ("", nil),
        ]
        for (raw, expected) in trimmed { #expect(ChatGoals.clean(raw) == expected, "\(raw)") }

        let rambling = "Going through every cached thumbnail on the server to find which app keeps filling the volume so fast"
        let cut = ChatGoals.clean(rambling) ?? ""
        #expect(cut.hasSuffix("…") && cut.count <= 65 && !cut.contains("  "))
    }

    @Test func theModelIsShownThisTurnsPromptItsStepsAndItsLastWords() {
        func user(_ id: String, _ words: String) -> TranscriptItem { TranscriptItem(id: id, kind: .user(text: words, attachments: [])) }
        func assistant(_ id: String, _ words: String, streaming: Bool) -> TranscriptItem {
            TranscriptItem(id: id, kind: .assistant(text: words, reasoning: nil, streaming: streaming))
        }
        func toolCall(_ name: String, _ context: String) -> TranscriptItem {
            let id = UUID().uuidString
            return TranscriptItem(id: id, kind: .tool(ToolActivity(id: id, name: name, context: context, argsText: nil)))
        }
        let calls = (0..<10).map { toolCall("terminal", "du -sh /var/mail/box\($0)") }
        let thread = [user("u0", "an older question"), assistant("a0", "an older answer", streaming: false),
                      user("u1", "The mail server is at 91% disk. Could you look?")]
            + calls
            + [assistant("a1", "The spool is the biggest part.", streaming: true),
               TranscriptItem(id: "s1", kind: .steer(text: "do not touch postfix", status: "delivered"))]

        let shown = ChatGoals.input(thread, earlier: "Checking the disk")
        #expect(shown.prompt.hasPrefix("The mail server is at 91% disk."))
        #expect(shown.prompt.contains("do not touch postfix") && !shown.prompt.contains("older question"))
        #expect(shown.steps.count == 8, "only the latest steps")
        #expect(shown.steps.last == "terminal: du -sh /var/mail/box9")
        #expect([shown.said, shown.earlier] == ["The spool is the biggest part.", "Checking the disk"])
        #expect([ChatGoals.turnKey(thread), "\(ChatGoals.stepCount(thread))"] == ["u1", "10"])
    }

    // MARK: the loop

    /// A clock and a writer under the test's control; the writer's answers are taken from a list.
    private final class Studio: @unchecked Sendable {
        var clock = Date(timeIntervalSince1970: 9_000)
        var replies: [String?]
        private(set) var questions: [ChatGoals.Input] = []
        private let lock = NSLock()
        init(replies: [String?]) { self.replies = replies }

        func respond(to input: ChatGoals.Input) -> String? {
            lock.lock(); defer { lock.unlock() }
            questions.append(input)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
    }

    private func goals(_ studio: Studio) -> ChatGoals {
        let goals = ChatGoals()
        goals.on = { true }
        goals.now = { studio.clock }
        goals.writer = { studio.respond(to: $0) }
        return goals
    }

    private func letItWrite(_ goals: ChatGoals) async {
        var polls = 0
        while goals.isWriting && polls < 200 {
            polls += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
        await Task.yield()
    }

    private func busy(_ chat: String, turn: String = "u1", steps: Int = 0) -> ChatGoals.Working {
        let log = [String](repeating: "terminal", count: steps)
        let asked = ChatGoals.Input(prompt: "Find out why the sync stalls", steps: log, said: nil, earlier: nil)
        return ChatGoals.Working(id: chat, turn: turn, steps: steps, input: asked)
    }

    @Test func aWorkingChatGetsALineAndLosesItWhenTheTurnEnds() async {
        let studio = Studio(replies: ["Finding out why the sync stalls."])
        let goals = goals(studio)
        var liveTurn: [String: String] = ["x": "u1"]
        let turnOf: @MainActor (String) -> String? = { liveTurn[$0] }

        goals.tick([busy("x")], turnNow: turnOf)
        await letItWrite(goals)
        #expect(goals.goal(for: "x") == nil, "no line is written during a turn's first two seconds")
        #expect(studio.questions.isEmpty)

        studio.clock += 3
        goals.tick([busy("x")], turnNow: turnOf)
        await letItWrite(goals)
        #expect(goals.goal(for: "x") == "Finding out why the sync stalls")

        // Further looks do nothing until the work has progressed.
        studio.clock += 5
        goals.tick([busy("x", steps: 1)], turnNow: turnOf)
        await letItWrite(goals)
        #expect(studio.questions.count == 1)

        liveTurn = [:]
        goals.tick([], turnNow: turnOf)
        #expect(goals.goal(for: "x") == nil)
    }

    @Test func aLineArrivingAfterTheTurnChangedIsDropped() async {
        let studio = Studio(replies: ["Finding the slow query"])
        let goals = goals(studio)
        var liveTurn: [String: String] = ["x": "u1"]
        goals.tick([busy("x")], turnNow: { liveTurn[$0] })
        studio.clock += 3
        liveTurn["x"] = "u2"   // another message was sent while the model was writing
        goals.tick([busy("x")], turnNow: { liveTurn[$0] })
        await letItWrite(goals)
        #expect(goals.goal(for: "x") == nil)
    }

    @Test func aModelThatFailedToWriteIsNotAskedAgainStraightAway() async {
        let studio = Studio(replies: [nil, "Finding the slow query"])
        let goals = goals(studio)
        let turnOf: @MainActor (String) -> String? = { _ in "u1" }
        goals.tick([busy("x")], turnNow: turnOf)
        studio.clock += 3
        goals.tick([busy("x")], turnNow: turnOf)
        await letItWrite(goals)
        #expect(studio.questions.count == 1)

        studio.clock += 10
        goals.tick([busy("x")], turnNow: turnOf)
        await letItWrite(goals)
        #expect(studio.questions.count == 1, "asked \(studio.questions.count - 1) more times inside the gap")

        studio.clock += ChatGoals.Pace.gap
        goals.tick([busy("x")], turnNow: turnOf)
        await letItWrite(goals)
        #expect(goals.goal(for: "x") == "Finding the slow query")
    }

    @Test func switchedOffThereIsNoLineAndNoQuestion() async {
        let studio = Studio(replies: ["Finding the slow query"])
        let goals = goals(studio)
        goals.on = { false }
        goals.tick([busy("x")], turnNow: { _ in "u1" })
        studio.clock += 3
        goals.tick([busy("x")], turnNow: { _ in "u1" })
        await letItWrite(goals)
        #expect(studio.questions.isEmpty)
        #expect(goals.goal(for: "x") == nil)
    }
}
