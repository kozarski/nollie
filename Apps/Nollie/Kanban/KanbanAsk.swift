import NollieCore
import SwiftUI

/// A question asked before a board change is made. Done needs a summary, Block needs a reason and
/// Comment needs its text; Archive, Delete and Stop just need a yes.
enum KanbanAsk: Identifiable {
    case done(KanbanTask)
    case block(KanbanTask)
    case comment(KanbanTask)
    case archive(KanbanTask)
    case delete(KanbanTask)
    case stop(KanbanTask)

    /// Everything the question says, in one place.
    private struct Script {
        var title: String
        var verb: String
        /// The text box's hint; nil when there is no text box.
        var hint: String? = nil
        var destructive = false
        var message: String
    }

    private var script: Script {
        switch self {
        case .done:
            Script(title: String(localized: "Mark as done"), verb: String(localized: "Done", comment: "A button that marks a task done"),
                   hint: String(localized: "What was done"),
                   message: String(localized: "A short note on the result. The gateway wants one unless the task is coming out of review."))
        case .block:
            Script(title: String(localized: "Block this task"), verb: String(localized: "Block", comment: "A button that blocks a task"),
                   hint: String(localized: "Why it is blocked (optional)"),
                   message: String(localized: "The reason stays on the card for whoever picks it up next."))
        case .comment:
            Script(title: String(localized: "Comment", comment: "A title: comment on a task"), verb: String(localized: "Send", comment: "A button that sends a comment"),
                   hint: String(localized: "Your comment"), message: task.title)
        case .archive:
            Script(title: String(localized: "Archive this task?"), verb: String(localized: "Archive", comment: "A button that archives a task"),
                   message: String(localized: "It leaves the board, and the gateway keeps a copy."))
        case .delete:
            Script(title: String(localized: "Delete this task?", comment: "Safety: deleting; keep exact meaning"),
                   verb: String(localized: "Delete", comment: "Safety: a button that deletes a task"), destructive: true,
                   message: String(localized: "This deletes \"\(task.title)\" from the gateway, along with its comments and runs.",
                                   comment: "Safety: what deleting removes; keep exact meaning"))
        case .stop:
            Script(title: String(localized: "Stop the worker?", comment: "Safety: Stop; keep exact meaning"),
                   verb: String(localized: "Stop", comment: "Safety: a button that stops the worker on a task"), destructive: true,
                   message: String(localized: "The worker on \"\(task.title)\" stops and the card returns to Ready.",
                                   comment: "Safety: what Stop does; keep exact meaning"))
        }
    }

    var task: KanbanTask {
        switch self {
        case .stop(let found), .delete(let found), .archive(let found),
             .comment(let found), .block(let found), .done(let found):
            return found
        }
    }

    var id: String { "\(verb)-\(task.id)" }

    /// Whether the question has a text box.
    var asksForText: Bool { script.hint != nil }

    var destructive: Bool { script.destructive }

    var title: String { script.title }

    /// The label on the confirming button.
    var verb: String { script.verb }

    var placeholder: String { script.hint ?? "" }

    var message: String { script.message }
}

/// Rules the Board, its task sheet and the Mac's card menu and inspector share, kept as plain functions.
extension KanbanAsk {
    /// The question a move to this status has to answer first (a note, or a yes), if there is one.
    static func gate(_ task: KanbanTask, movingTo status: KanbanStatus) -> KanbanAsk? {
        switch status {
        case .done: .done(task)
        case .blocked: .block(task)
        case .archived: .archive(task)
        default: nil
        }
    }

    /// Where a hand can put a card from `column`: every status but its own and the ones only the gateway sets.
    static func moveTargets(from column: KanbanStatus?) -> [KanbanStatus] {
        KanbanStatus.moveTargets.filter { $0 != column }
    }
}

extension KanbanStore {
    /// Carries out a question the person confirmed, with what they typed. Nil means nothing was
    /// asked of the gateway (a comment with no words); otherwise whether it went through.
    func carryOut(_ confirmed: KanbanAsk, typed: String) async -> Bool? {
        switch confirmed {
        case .done(let task): await move(task, to: .done, summary: typed)
        case .block(let task): await move(task, to: .blocked, blockReason: typed)
        case .comment(let task): typed.isEmpty ? nil : await comment(task, typed)
        case .archive(let task): await move(task, to: .archived)
        case .delete(let task): await delete(task)
        case .stop(let task): await stop(task, reason: "stopped from Nollie") // Goes to the gateway, so it stays in English.
        }
    }
}

/// The question put to the person before a board change: a text box for Done, Block and
/// Comment, a plain yes or no for the rest.
struct BoardQuestions: ViewModifier {
    @Binding var question: KanbanAsk?
    @Binding var reply: String
    let settle: (KanbanAsk) -> Void

    private func showing(text: Bool) -> Binding<Bool> {
        Binding(
            get: { question.map { $0.asksForText == text } ?? false },
            set: { if !$0 { question = nil } })
    }

    func body(content: Content) -> some View {
        content
            .alert(question?.title ?? "", isPresented: showing(text: true), presenting: question) { ask in
                TextField(ask.placeholder, text: $reply)
                Button(ask.verb) { settle(ask) }
                Button("Cancel", role: .cancel) { (question, reply) = (nil, "") }
            } message: { ask in
                Text(ask.message)
            }
            .confirmationDialog(question?.title ?? "", isPresented: showing(text: false), titleVisibility: .visible, presenting: question) { ask in
                Button(ask.verb, role: ask.destructive ? .destructive : nil) { settle(ask) }
                Button("Cancel", role: .cancel) { (question, reply) = (nil, "") }
            } message: { ask in
                Text(ask.message)
            }
    }
}
