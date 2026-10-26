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
            Script(title: "Mark as done", verb: "Done", hint: "What was done",
                   message: "A short note on the result. The gateway wants one unless the task is coming out of review.")
        case .block:
            Script(title: "Block this task", verb: "Block", hint: "Why it is blocked (optional)",
                   message: "The reason stays on the card for whoever picks it up next.")
        case .comment:
            Script(title: "Comment", verb: "Send", hint: "Your comment", message: task.title)
        case .archive:
            Script(title: "Archive this task?", verb: "Archive", message: "It leaves the board, and the gateway keeps a copy.")
        case .delete:
            Script(title: "Delete this task?", verb: "Delete", destructive: true,
                   message: "This deletes \"\(task.title)\" from the gateway, along with its comments and runs.")
        case .stop:
            Script(title: "Stop the worker?", verb: "Stop", destructive: true,
                   message: "The worker on \"\(task.title)\" stops and the card returns to Ready.")
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
        case .stop(let task): await stop(task, reason: "stopped from Nollie")
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
