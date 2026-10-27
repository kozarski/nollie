import SwiftUI
import NollieCore

/// A task as it reads on the board: title, a line of preview, who has it and where it stands.
/// Everything else lives in the task's detail sheet.
struct BoardTaskRow: View {
    let task: KanbanTask

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Titles and previews wrap freely at accessibility text sizes, and stop at two lines otherwise.
    private var wrapLimit: Int? { typeSize.isAccessibilitySize ? nil : 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(task.title).font(.body).fontWeight(.medium).lineLimit(wrapLimit)
            if let preview = task.preview {
                Text(preview).small().lineLimit(wrapLimit)
            }
            // Side by side when there is room, stacked when there is not.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { chips }
                VStack(alignment: .leading, spacing: 5) { chips }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var chips: some View {
        let owner = TaskOwner(raw: task.assignee, profiles: model.runtime?.profiles ?? [])
        Label(owner.name, systemImage: owner.symbol)
            .labelStyle(.titleAndIcon)
            .small()
            .fixedSize()
        Text(TaskStage.words(for: task))
            .small(.caption2)
            .fontWeight(.medium)
            .inset(h: 6, v: 2)
            .background(.quaternary, in: .capsule)
            .fixedSize()
    }
}

/// Who holds a task, as the row names them.
private struct TaskOwner {
    let name: String
    let symbol: String

    init(raw: String?, profiles: [ProfileInfo]) {
        guard let raw, !raw.isEmpty else {
            (name, symbol) = (String(localized: "Unassigned", comment: "A task no bot holds"), "person.slash")
            return
        }
        symbol = "person.crop.circle"
        name = profiles.first { $0.name == raw }?.shownName ?? raw.prefix(1).uppercased() + raw.dropFirst()
    }
}

/// Where a task stands, in a word or two for the row's chip.
private enum TaskStage {
    static func words(for task: KanbanTask) -> String {
        guard let column = task.column else { return task.status }
        switch column {
        case .running: return String(localized: "Working", comment: "Where a task stands")
        case .review: return String(localized: "Being reviewed", comment: "Where a task stands")
        case .blocked: return task.needsUserAction ? String(localized: "Needs your help", comment: "Where a task stands")
                                                    : String(localized: "Waiting to continue", comment: "Where a task stands")
        case .triage, .todo, .ready: return String(localized: "Queued", comment: "Where a task stands")
        default: return column.title
        }
    }
}
