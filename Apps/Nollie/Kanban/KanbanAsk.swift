import Foundation
import NollieCore

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
