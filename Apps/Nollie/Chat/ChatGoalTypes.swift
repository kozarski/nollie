import Foundation
import NollieCore

extension Notification.Name {
    /// Posted when a working chat gets a new or reworded status line. The userInfo holds "storedID" and "goal".
    static let nollieGoalChanged = Notification.Name("nollie.goalChanged")
}

extension ChatGoals {
    /// One written status line and the moment it was written.
    struct Goal: Sendable, Equatable {
        var text: String
        /// Which turn this line is about; it is dropped when the turn is over.
        var turn: String
        var madeAt: Date
        /// Steps taken in the turn at the moment of writing.
        var steps: Int

        /// A line written from the prompt alone, before any step had happened.
        var isFirst: Bool { steps == 0 }
    }

    /// Everything the model reads when it writes a line.
    struct Input: Sendable, Equatable {
        var prompt: String
        var steps: [String]
        var said: String? = nil
        var earlier: String? = nil

        var hasContent: Bool { !prompt.isEmpty || !steps.isEmpty }
    }

    /// When a line may be written. Kept out of the model code so tests can reach it.
    enum Pace {
        /// Quick turns finish before a line could be read, so a turn must be this old before it gets one.
        static let firstDelay: TimeInterval = 2
        /// After the first line (made from the prompt alone) the next one is allowed sooner.
        static let gapAfterFirst: TimeInterval = 15
        static let gap: TimeInterval = 45
        static let stepsAfterFirst = 2
        static let steps = 3

        /// How much new work and how much time must pass before a line is replaced.
        private static func requirement(after goal: Goal) -> (steps: Int, wait: TimeInterval) {
            goal.isFirst ? (stepsAfterFirst, gapAfterFirst) : (steps, gap)
        }

        static func due(goal: Goal?, turn: String, turnAge: TimeInterval, steps taken: Int, now: Date) -> Bool {
            guard let goal = goal, goal.turn == turn else {
                return turnAge >= firstDelay
            }
            let need = requirement(after: goal)
            let enoughWork = taken - goal.steps >= need.steps
            let enoughTime = now.timeIntervalSince(goal.madeAt) >= need.wait
            return enoughWork && enoughTime
        }
    }

    /// A snapshot of a busy chat, with just what is needed to decide on and write a line.
    struct Working: Equatable, Sendable {
        var id: String
        var turn: String
        var steps: Int
        var input: Input

        init(id: String, turn: String, steps: Int, input: Input) {
            self.id = id
            self.turn = turn
            self.steps = steps
            self.input = input
        }

        @MainActor init(_ chat: ChatSession, earlier: String?) {
            let items = chat.items
            self.init(id: chat.storedID,
                      turn: ChatGoals.turnKey(items),
                      steps: ChatGoals.stepCount(items),
                      input: ChatGoals.input(items, earlier: earlier))
        }
    }
}
