import SwiftUI

/// One entry from the todo tool's list.
struct TodoItem: Identifiable, Hashable {
    var id: String
    var content: String
    var status: String
    private static let prefix = "todo"

    /// Turns the todo tool's arguments (a "todos" array of content, id and status) into items.
    /// Any other tool, or arguments without entries, give nil.
    static func parse(name: String, argsText: String?) -> [TodoItem]? {
        guard name.lowercased().hasPrefix(prefix), let entries = todoList(in: argsText) else { return nil }
        return entries.enumerated().map { index, entry in
            TodoItem(id: entry["id"] as? String ?? "\(entry["id"] ?? index)",
                     content: [entry["content"], entry["title"]].lazy.compactMap { $0 as? String }.first ?? "",
                     status: (entry["status"] as? String ?? "pending").lowercased())
        }
    }

    private static func todoList(in argsText: String?) -> [[String: Any]]? {
        guard let argsText,
              let json = try? JSONSerialization.jsonObject(with: Data(argsText.utf8)) as? [String: Any],
              let list = json["todos"] as? [[String: Any]] else { return nil }
        return list.isEmpty ? nil : list
    }

    var isDone: Bool { Self.finished.contains(status) }

    private static let finished: Set<String> = ["completed", "done"]
    private static let underway: Set<String> = ["in_progress", "in-progress", "active", "doing"]
    private static let dropped: Set<String> = ["cancelled", "canceled", "skipped"]

    /// Tick, arrow, cross or empty ring, depending on the status.
    var mark: (symbol: String, tint: Color) {
        if isDone { return ("checkmark.circle.fill", .green) }
        if Self.underway.contains(status) { return ("arrow.right.circle.fill", .blue) }
        return Self.dropped.contains(status) ? ("xmark.circle", .secondary) : ("circle", .secondary)
    }
}

/// A checklist view of the todo tool. Closed it shows four entries and a tally, open it shows every entry.
struct TodoChecklist: View {
    var items: [TodoItem]
    var all: Bool

    private var shown: [TodoItem] { all ? items : Array(items.prefix(4)) }
    private var doneCount: Int { items.filter(\.isDone).count }

    private var tally: String {
        let left = items.count - shown.count
        return "\(doneCount) of \(items.count) done" + (left > 0 ? ", \(left) more" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(shown) { row(for: $0) }
            if items.count > shown.count || !all { Text(tally).quiet(.caption2) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Todo list, \(doneCount) of \(items.count) done")
    }

    private func row(for item: TodoItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Glyph(item.mark.symbol, .caption, item.mark.tint)
            Text(item.content)
                .font(.caption)
                .strikethrough(item.isDone, color: .secondary)
                .foregroundStyle(item.isDone ? .secondary : .primary)
                .lineLimit(all ? nil : 2)
        }
    }
}
